import Testing
import Foundation
@testable import MultitulCore

private final class Clock { var t: TimeInterval = 100 }

private func engine(_ h: SndFakeHardware, order: [String] = ["airpods", "usb-headset", "speakers"], inputOrder: [String] = ["airpods", "builtin-mic"],
                    enabled: Bool = true, clock: Clock = Clock(), configure: (inout AudioPriorityConfig) -> Void = { _ in }) -> AudioPriorityEngine {
    var c = AudioPriorityConfig()
    c.output = AudioPriorityRule(enabled: enabled, order: order)
    c.input = AudioPriorityRule(enabled: enabled, order: inputOrder)
    configure(&c)
    let e = AudioPriorityEngine(hardware: h, config: c, now: { clock.t })
    e.prime()
    return e
}

@Suite struct AudioPriorityEngineTests {
    @Test func highPriorityDeviceTakesOverOnConnect() {
        let h = Snd.hardware()
        let e = engine(h)
        h.plug(Snd.airpods)
        let actions = e.refresh()
        #expect(actions.map(\.to) == ["airpods", "airpods"])
        #expect(actions.map(\.scope) == [.output, .input])
        #expect(h.outDefault == "airpods")
        #expect(h.inDefault == "airpods")
    }

    @Test func systemSelectingTheSameDeviceNeedsNoSwitch() {
        let h = Snd.hardware()
        let e = engine(h)
        h.plug(Snd.airpods, systemSelects: true)
        #expect(e.refresh().isEmpty)
        #expect(h.setCalls.isEmpty)
    }

    @Test func disconnectFallsToNextPriorityNotToMacOSChoice() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods, Snd.usb], out: "airpods", inp: "airpods")
        let e = engine(h)
        h.unplug("airpods")
        h.outDefault = "speakers"
        let actions = e.refresh()
        #expect(actions.first { $0.scope == .output }?.to == "usb-headset")
        #expect(actions.first { $0.scope == .output }?.reason == .activeLost)
        #expect(h.outDefault == "usb-headset")
    }

    @Test func returningDeviceTakesBackItsPlace() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h)
        h.unplug("airpods")
        e.refresh()
        #expect(h.outDefault == "speakers")
        h.plug(Snd.airpods)
        e.refresh()
        #expect(h.outDefault == "airpods")
    }

    @Test func returningDeviceStaysQuietUnderOnlyOnDisconnect() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h) { $0.onConnect = .onlyOnDisconnect }
        h.unplug("airpods")
        e.refresh()
        h.plug(Snd.airpods)
        #expect(e.refresh().isEmpty)
        #expect(h.outDefault == "speakers")
    }

    @Test func unrankedDeviceCannotStealTheOutput() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h)
        h.plug(Snd.hdmi, systemSelects: true)
        let actions = e.refresh()
        #expect(actions.map(\.reason) == [.systemMoved])
        #expect(h.outDefault == "airpods")
    }

    @Test func manualChoiceSurvivesUntilHardwareChanges() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h)
        h.outDefault = "speakers"
        #expect(e.refresh().isEmpty)
        #expect(h.outDefault == "speakers")
        h.plug(Snd.hdmi)
        #expect(e.refresh().isEmpty)
        #expect(h.outDefault == "speakers")
    }

    @Test func lateDefaultMoveInsideSettleWindowIsCorrected() {
        let clock = Clock()
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h, clock: clock)
        h.plug(Snd.hdmi)
        #expect(e.refresh().isEmpty)
        clock.t += 1.5
        h.outDefault = "hdmi"
        let actions = e.refresh()
        #expect(actions.map(\.to) == ["airpods"])
        #expect(h.outDefault == "airpods")
    }

    @Test func lateDefaultMoveOutsideWindowIsTreatedAsManual() {
        let clock = Clock()
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods], out: "airpods", inp: "airpods")
        let e = engine(h, clock: clock)
        h.plug(Snd.hdmi)
        e.refresh()
        clock.t += AudioPriorityEngine.settleWindow + 1
        h.outDefault = "hdmi"
        #expect(e.refresh().isEmpty)
        #expect(h.outDefault == "hdmi")
    }

    @Test func enforceAllAppliesListAfterPreferenceChange() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.usb])
        let e = engine(h, enabled: false)
        #expect(e.enforceAll().isEmpty)
        e.config.output.enabled = true
        let actions = e.enforceAll()
        #expect(actions.map(\.to) == ["usb-headset"])
        #expect(h.outDefault == "usb-headset")
        #expect(h.inDefault == "builtin-mic")
    }

    @Test func systemOutputFollowsOnlyWhenAsked() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods])
        let e = engine(h)
        h.plug(Snd.usb)
        e.refresh()
        #expect(h.sysOut == "usb-headset")

        let h2 = Snd.hardware([Snd.speakers, Snd.mic, Snd.airpods])
        let e2 = engine(h2) { $0.syncSystemOutput = false }
        h2.plug(Snd.usb)
        e2.refresh()
        #expect(h2.outDefault == "usb-headset")
        #expect(h2.sysOut == "speakers")
        #expect(h2.systemCalls.isEmpty)
    }

    @Test func inputNeverSyncsSystemOutput() {
        let h = Snd.hardware([Snd.speakers, Snd.mic])
        let e = engine(h, order: [], inputOrder: ["usb-headset", "builtin-mic"])
        h.plug(Snd.usb)
        e.refresh()
        #expect(h.inDefault == "usb-headset")
        #expect(h.systemCalls.isEmpty)
    }

    @Test func disabledScopeIsLeftToMacOS() {
        let h = Snd.hardware()
        let e = engine(h) { $0.input.enabled = false }
        h.plug(Snd.airpods)
        let actions = e.refresh()
        #expect(actions.map(\.scope) == [.output])
        #expect(h.inDefault == "builtin-mic")
    }

    @Test func failedSwitchIsReportedAndNotRepeatedOnTheNextQuietRefresh() {
        let h = Snd.hardware()
        let e = engine(h)
        h.failSet = true
        h.plug(Snd.airpods)
        let actions = e.refresh()
        #expect(actions.allSatisfy { !$0.success })
        h.setCalls.removeAll()
        #expect(e.refresh().isEmpty)
        #expect(h.setCalls.isEmpty)
    }

    @Test func primeAddsPresentDevicesToLists() {
        let h = Snd.hardware([Snd.speakers, Snd.mic, Snd.hdmi, Snd.blackhole])
        var placed: [(AudioScope, [String])] = []
        let e = AudioPriorityEngine(hardware: h, config: AudioPriorityConfig())
        e.onPlacement = { placed.append(($0, $1)) }
        e.prime()
        #expect(e.config.output.order == ["speakers", "hdmi"])
        #expect(e.config.input.order == ["builtin-mic"])
        #expect(placed.count == 2)
    }

    @Test func newDeviceJoinsListWhenItAppears() {
        let h = Snd.hardware()
        let e = engine(h, order: ["speakers"], inputOrder: ["builtin-mic"])
        h.plug(Snd.usb)
        e.refresh()
        #expect(e.config.output.order == ["speakers", "usb-headset"])
        #expect(e.config.input.order == ["builtin-mic", "usb-headset"])
    }

    @Test func ignoredDeviceNeverJoinsAndNeverWins() {
        let h = Snd.hardware()
        let e = engine(h, order: ["speakers"], inputOrder: ["builtin-mic"]) { $0.output.ignored = ["usb-headset"] }
        h.plug(Snd.usb, systemSelects: true)
        #expect(e.refresh().filter { $0.scope == .output }.isEmpty)
        #expect(!e.config.output.order.contains("usb-headset"))
        #expect(h.outDefault == "usb-headset")
    }
}
