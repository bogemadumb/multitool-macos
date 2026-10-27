import Testing
import Foundation
@testable import MultitulCore

@Suite struct OutputCycleTests {
    @Test func movesToNextAvailableAndWraps() {
        let cycle = ["speakers", "airpods", "hdmi"]
        let all: Set = ["speakers", "airpods", "hdmi"]
        #expect(OutputCycle.next(cycle: cycle, available: all, current: "speakers") == "airpods")
        #expect(OutputCycle.next(cycle: cycle, available: all, current: "hdmi") == "speakers")
    }

    @Test func skipsDevicesThatAreNotConnected() {
        let cycle = ["speakers", "airpods", "hdmi"]
        #expect(OutputCycle.next(cycle: cycle, available: ["speakers", "hdmi"], current: "speakers") == "hdmi")
    }

    @Test func currentOutsideTheCycleStartsFromTheFirst() {
        #expect(OutputCycle.next(cycle: ["speakers", "airpods"], available: ["speakers", "airpods", "usb"], current: "usb") == "speakers")
        #expect(OutputCycle.next(cycle: ["speakers", "airpods"], available: ["speakers", "airpods", "usb"], current: "usb", step: -1) == "airpods")
        #expect(OutputCycle.next(cycle: ["speakers", "airpods"], available: ["speakers", "airpods"], current: nil) == "speakers")
    }

    @Test func nothingToSwitchToReturnsNil() {
        #expect(OutputCycle.next(cycle: [], available: ["speakers"], current: "speakers") == nil)
        #expect(OutputCycle.next(cycle: ["speakers"], available: ["speakers"], current: "speakers") == nil)
        #expect(OutputCycle.next(cycle: ["airpods"], available: ["speakers"], current: "speakers") == nil)
    }

    @Test func stepBackWraps() {
        let cycle = ["a", "b", "c"]
        #expect(OutputCycle.next(cycle: cycle, available: ["a", "b", "c"], current: "a", step: -1) == "c")
    }

    @Test func membershipKeepsOrderAndIsIdempotent() {
        #expect(OutputCycle.setMember(["a"], uid: "b", on: true) == ["a", "b"])
        #expect(OutputCycle.setMember(["a", "b"], uid: "b", on: true) == ["a", "b"])
        #expect(OutputCycle.setMember(["a", "b"], uid: "a", on: false) == ["b"])
    }

    @Test func switcherSetsOutputAndSystemOutput() {
        let h = Snd.hardware([Snd.speakers, Snd.airpods, Snd.mic])
        var s = OutputSwitcherSettings()
        s.cycle = ["speakers", "airpods"]
        let sw = OutputSwitcher(hardware: h, settings: s)
        let r = sw.switchNext()
        #expect(r == OutputSwitchResult(status: .switched, uid: "airpods"))
        #expect(h.outDefault == "airpods")
        #expect(h.sysOut == "airpods")
    }

    @Test func switcherCanLeaveSystemOutputAlone() {
        let h = Snd.hardware([Snd.speakers, Snd.airpods, Snd.mic])
        var s = OutputSwitcherSettings()
        s.cycle = ["speakers", "airpods"]
        s.syncSystemOutput = false
        _ = OutputSwitcher(hardware: h, settings: s).switchNext()
        #expect(h.outDefault == "airpods")
        #expect(h.sysOut == "speakers")
    }

    @Test func switcherIgnoresHiddenAndInputOnlyDevices() {
        let h = Snd.hardware([Snd.speakers, Snd.hiddenTap, Snd.mic])
        var s = OutputSwitcherSettings()
        s.cycle = ["speakers", "tap", "builtin-mic"]
        #expect(OutputSwitcher(hardware: h, settings: s).switchNext().status == .nothingToSwitch)
    }

    @Test func switcherReportsFailure() {
        let h = Snd.hardware([Snd.speakers, Snd.airpods])
        h.failSet = true
        var s = OutputSwitcherSettings()
        s.cycle = ["speakers", "airpods"]
        let r = OutputSwitcher(hardware: h, settings: s).switchNext()
        #expect(r.status == .failed)
        #expect(h.outDefault == "speakers")
    }
}
