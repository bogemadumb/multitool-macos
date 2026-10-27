import Testing
import Foundation
@testable import MultitulCore

private func rule(_ order: [String], ignored: Set<String> = [], enabled: Bool = true) -> AudioPriorityRule {
    AudioPriorityRule(enabled: enabled, order: order, ignored: ignored)
}

private func decide(_ r: AudioPriorityRule, available: Set<String>, current: String?, _ t: AudioPriorityTrigger, policy: AudioConnectPolicy = .takeOverIfHigher) -> AudioPriorityOutcome {
    AudioPriorityLogic.decide(rule: r, policy: policy, available: available, current: current, trigger: t)
}

private func connected(_ added: Set<String>, previous: String?) -> AudioPriorityTrigger {
    .devicesChanged(added: added, removed: [], previousDefault: previous)
}

private func disconnected(_ removed: Set<String>, previous: String?) -> AudioPriorityTrigger {
    .devicesChanged(added: [], removed: removed, previousDefault: previous)
}

@Suite struct AudioPriorityLogicTests {
    @Test func disabledRuleKeepsEverything() {
        let r = rule(["airpods", "speakers"], enabled: false)
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", .enforce) == .keep(.disabled))
    }

    @Test func enforceSwitchesToBestPresent() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", .enforce) == .switchTo("airpods", .enforce))
    }

    @Test func enforceSkipsAbsentTop() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["usb", "speakers"], current: "speakers", .enforce) == .switchTo("usb", .enforce))
    }

    @Test func enforceWhenAlreadyBestKeeps() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "airpods", .enforce) == .keep(.alreadyBest))
    }

    @Test func noRankedDeviceLeavesMacOSAlone() {
        let r = rule(["airpods"])
        #expect(decide(r, available: ["speakers"], current: "speakers", .enforce) == .keep(.noRanked))
    }

    @Test func ignoredDeviceIsNeverChosen() {
        let r = rule(["blackhole", "speakers"], ignored: ["blackhole"])
        #expect(decide(r, available: ["blackhole", "speakers"], current: "hdmi", .enforce) == .switchTo("speakers", .enforce))
    }

    @Test func currentIgnoredDeviceIsNotTouched() {
        let r = rule(["airpods", "speakers"], ignored: ["blackhole"])
        #expect(decide(r, available: ["airpods", "blackhole"], current: "blackhole", .enforce) == .keep(.currentIgnored))
        #expect(decide(r, available: ["airpods", "blackhole"], current: "blackhole", connected(["airpods"], previous: "blackhole")) == .keep(.currentIgnored))
    }

    @Test func higherDeviceConnectingTakesOver() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", connected(["airpods"], previous: "speakers")) == .switchTo("airpods", .higherConnected))
    }

    @Test func lowerDeviceConnectingDoesNotTake() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "usb"], current: "airpods", connected(["usb"], previous: "airpods")) == .keep(.notHigher))
    }

    @Test func connectOutranksOrChangesNothing() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers", "usb"], current: "speakers", connected(["usb"], previous: "speakers")) == .switchTo("usb", .higherConnected))
        #expect(decide(r, available: ["airpods", "speakers", "hdmi"], current: "speakers", connected(["hdmi"], previous: "speakers")) == .keep(.noChange))
    }

    @Test func onlyOnDisconnectPolicyIgnoresConnects() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", connected(["airpods"], previous: "speakers"), policy: .onlyOnDisconnect) == .keep(.policyOnlyOnDisconnect))
    }

    @Test func highestOfSeveralAddedWins() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "usb", "speakers"], current: "speakers", connected(["usb", "airpods"], previous: "speakers")) == .switchTo("airpods", .higherConnected))
    }

    @Test func activeDeviceLostPicksBestRemaining() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["usb", "speakers"], current: "speakers", disconnected(["airpods"], previous: "airpods")) == .switchTo("usb", .activeLost))
    }

    @Test func activeDeviceLostWorksEvenWithOnlyOnDisconnectPolicy() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["speakers"], current: "hdmi", disconnected(["airpods"], previous: "airpods"), policy: .onlyOnDisconnect) == .switchTo("speakers", .activeLost))
    }

    @Test func activeLostWithNothingRankedLeft() {
        let r = rule(["airpods"])
        #expect(decide(r, available: ["speakers"], current: "speakers", disconnected(["airpods"], previous: "airpods")) == .keep(.noRanked))
    }

    @Test func removingNonActiveDeviceChangesNothing() {
        let r = rule(["airpods", "usb", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", disconnected(["usb"], previous: "speakers")) == .keep(.noChange))
    }

    @Test func systemHijackToUnrankedDeviceIsUndone() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers", "hdmi"], current: "hdmi", connected(["hdmi"], previous: "airpods")) == .switchTo("airpods", .systemMoved))
    }

    @Test func systemHijackIsKeptUnderOnlyOnDisconnect() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers", "hdmi"], current: "hdmi", connected(["hdmi"], previous: "airpods"), policy: .onlyOnDisconnect) == .keep(.policyOnlyOnDisconnect))
    }

    @Test func unrankedCurrentYieldsToRankedNewcomer() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "hdmi"], current: "hdmi", connected(["airpods"], previous: "hdmi")) == .switchTo("airpods", .higherConnected))
    }

    @Test func manualDefaultChangeNeverTriggersSwitch() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["airpods", "speakers"], current: "speakers", .defaultChanged) == .keep(.manualChoice))
    }

    @Test func noCurrentDeviceGetsBest() {
        let r = rule(["airpods", "speakers"])
        #expect(decide(r, available: ["speakers"], current: nil, .enforce) == .switchTo("speakers", .enforce))
    }
}

@Suite struct AudioPriorityPlacementTests {
    @Test func newDevicesAppendSortedByName() {
        let order = AudioPriorityLogic.placeNew(order: ["speakers"], ignored: [], devices: [Snd.usb, Snd.speakers, Snd.airpods], current: "speakers", policy: .append)
        #expect(order == ["speakers", "airpods", "usb-headset"])
    }

    @Test func adoptPutsSystemChosenDeviceOnTop() {
        let order = AudioPriorityLogic.placeNew(order: ["speakers"], ignored: [], devices: [Snd.speakers, Snd.airpods], current: "airpods", policy: .adoptIfSystemChose)
        #expect(order == ["airpods", "speakers"])
    }

    @Test func adoptLeavesOthersAtTheBottom() {
        let order = AudioPriorityLogic.placeNew(order: ["speakers"], ignored: [], devices: [Snd.speakers, Snd.airpods, Snd.usb], current: "usb-headset", policy: .adoptIfSystemChose)
        #expect(order == ["usb-headset", "speakers", "airpods"])
    }

    @Test func syntheticHiddenAndIgnoredDevicesStayOut() {
        let order = AudioPriorityLogic.placeNew(order: [], ignored: ["hdmi"], devices: [Snd.blackhole, Snd.hiddenTap, Snd.hdmi, Snd.speakers], current: nil, policy: .append)
        #expect(order == ["speakers"])
    }

    @Test func unchangedListStaysEqual() {
        let order = AudioPriorityLogic.placeNew(order: ["airpods", "speakers"], ignored: [], devices: [Snd.speakers, Snd.airpods], current: "speakers", policy: .adoptIfSystemChose)
        #expect(order == ["airpods", "speakers"])
    }

    @Test func moveClampsAndSwaps() {
        #expect(AudioPriorityLogic.move(["a", "b", "c"], uid: "b", by: -1) == ["b", "a", "c"])
        #expect(AudioPriorityLogic.move(["a", "b", "c"], uid: "c", by: 1) == ["a", "b", "c"])
        #expect(AudioPriorityLogic.move(["a", "b", "c"], uid: "a", by: 5) == ["b", "c", "a"])
        #expect(AudioPriorityLogic.move(["a", "b"], uid: "zzz", by: 1) == ["a", "b"])
    }

    @Test func sanitizedDropsDuplicatesAndEmpties() {
        #expect(AudioPriorityLogic.sanitized(["a", "", "b", "a"]) == ["a", "b"])
    }
}
