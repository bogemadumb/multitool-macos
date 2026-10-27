import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixPlannerTests {
    private let devices = [Snd.speakers, Snd.airpods, Snd.usb, Snd.mic]

    private func entry(_ key: String, ids: [UInt32] = [1], out: Bool = true) -> MixAppEntry {
        MixAppEntry(key: key, name: key.uppercased(), processObjectIDs: ids, pids: [1], isOutputting: out)
    }

    private func desired(_ entries: [MixAppEntry], _ apps: [String: MixAppSetting] = [:], demand: MixLevelDemand = .none, failed: Set<String> = [], settings: MixSettings = MixSettings(), def: String? = "speakers") -> [MixDesiredTap] {
        MixPlanner.desired(entries: entries, apps: apps, settings: settings, devices: devices, defaultUID: def, demand: demand, failedKeys: failed)
    }

    @Test func untouchedAppsAreNotTapped() {
        #expect(desired([entry("a")]).isEmpty)
    }

    @Test func changedVolumeCreatesAProcessTapOnTheDefaultDevice() {
        let d = desired([entry("a")], ["a": MixAppSetting(volume: 0.5)])
        #expect(d.count == 1 && d[0].mode == .process && d[0].outputUID == "speakers")
        #expect(d[0].params.volume == 0.5 && !d[0].params.muted)
        #expect(d[0].processObjectIDs == [1] && d[0].name == "A")
    }

    @Test func muteAloneNeedsAProcessTap() {
        let d = desired([entry("a")], ["a": MixAppSetting(muted: true)])
        #expect(d.count == 1 && d[0].params.muted)
    }

    @Test func routingAloneNeedsAProcessTapOnThatDevice() {
        let d = desired([entry("a")], ["a": MixAppSetting(outputUID: "airpods")])
        #expect(d.count == 1 && d[0].outputUID == "airpods" && d[0].params.volume == 1)
    }

    @Test func pinningAloneIsNotProcessing() {
        #expect(desired([entry("a")], ["a": MixAppSetting(pinned: true)]).isEmpty)
    }

    @Test func idleAppWithSettingsIsPreTapped() {
        #expect(desired([entry("a", out: false)], ["a": MixAppSetting(volume: 0.3)]).count == 1)
    }

    @Test func appWithoutProcessObjectsCannotBeTapped() {
        #expect(desired([entry("a", ids: [])], ["a": MixAppSetting(volume: 0.3)]).isEmpty)
    }

    @Test func noOutputDeviceMeansNoTap() {
        let d = MixPlanner.desired(entries: [entry("a")], apps: ["a": MixAppSetting(volume: 0.3)], settings: MixSettings(), devices: [Snd.mic], defaultUID: nil, demand: .none)
        #expect(d.isEmpty)
    }

    @Test func missingRouteFallsBackToDefault() {
        let d = desired([entry("a")], ["a": MixAppSetting(outputUID: "gone")])
        #expect(d[0].outputUID == "speakers")
    }

    @Test func failedKeysAreSkipped() {
        #expect(desired([entry("a"), entry("b")], ["a": MixAppSetting(volume: 0.3), "b": MixAppSetting(volume: 0.3)], failed: ["a"]).map(\.key) == ["b"])
    }

    @Test func meterDemandTapsOnlyOutputtingUntouchedApps() {
        let d = desired([entry("a"), entry("b", out: false), entry("c")], ["c": MixAppSetting(volume: 0.5)], demand: MixLevelDemand(allApps: true))
        #expect(d.map(\.key) == ["a", "c"])
        #expect(d[0].mode == .meter && d[1].mode == .process)
    }

    @Test func meterTapOnlyForRequestedKeys() {
        let d = desired([entry("a"), entry("b")], demand: MixLevelDemand(keys: ["b"]))
        #expect(d.map(\.key) == ["b"] && d[0].mode == .meter)
    }

    @Test func bandsAreRequestedPerKey() {
        let d = desired([entry("a"), entry("b")], ["b": MixAppSetting(volume: 0.5)], demand: MixLevelDemand(allApps: true, bandKeys: ["a", "b"]))
        #expect(d.allSatisfy { $0.params.bandsOn })
        let d2 = desired([entry("a"), entry("b")], demand: MixLevelDemand(allApps: true, bandKeys: ["a"]))
        #expect(d2.first { $0.key == "a" }?.params.bandsOn == true && d2.first { $0.key == "b" }?.params.bandsOn == false)
    }

    @Test func boostLimitClampsTheTapVolume() {
        var s = MixSettings()
        s.maxBoost = 2
        let d = desired([entry("a")], ["a": MixAppSetting(volume: 3.5)], settings: s)
        #expect(d[0].params.volume == 2)
    }

    @Test func meterTapFollowsTheDefaultOutput() {
        let d = desired([entry("a")], demand: MixLevelDemand(allApps: true), def: "usb-headset")
        #expect(d[0].outputUID == "usb-headset")
    }

    private func tap(_ key: String = "a", ids: [UInt32] = [1], mode: MixTapMode = .process, out: String = "speakers", vol: Float = 0.5) -> MixDesiredTap {
        MixDesiredTap(key: key, name: key, processObjectIDs: ids, mode: mode, outputUID: out, params: MixParams(volume: vol))
    }

    @Test func missingTapsAreCreated() {
        #expect(MixPlanner.reconcile(desired: [tap()], live: [:]) == [.create(tap())])
    }

    @Test func staleTapsAreDestroyedInStableOrder() {
        let live = ["b": MixLiveTapInfo(desired: tap("b")), "a": MixLiveTapInfo(desired: tap("a"))]
        #expect(MixPlanner.reconcile(desired: [], live: live) == [.destroy("a"), .destroy("b")])
    }

    @Test func outputChangeReplacesTheTap() {
        let live = ["a": MixLiveTapInfo(desired: tap(out: "speakers"))]
        #expect(MixPlanner.reconcile(desired: [tap(out: "airpods")], live: live) == [.replace(tap(out: "airpods"))])
    }

    @Test func processSetChangeReplacesTheTap() {
        let live = ["a": MixLiveTapInfo(desired: tap(ids: [1]))]
        #expect(MixPlanner.reconcile(desired: [tap(ids: [1, 2])], live: live) == [.replace(tap(ids: [1, 2]))])
    }

    @Test func modeChangeReplacesTheTap() {
        let live = ["a": MixLiveTapInfo(desired: tap(mode: .meter))]
        #expect(MixPlanner.reconcile(desired: [tap(mode: .process)], live: live) == [.replace(tap(mode: .process))])
    }

    @Test func parameterChangeOnlyUpdates() {
        let live = ["a": MixLiveTapInfo(desired: tap(vol: 0.5))]
        #expect(MixPlanner.reconcile(desired: [tap(vol: 0.8)], live: live) == [.update("a", MixParams(volume: 0.8))])
    }

    @Test func equalStateProducesNoActions() {
        let live = ["a": MixLiveTapInfo(desired: tap())]
        #expect(MixPlanner.reconcile(desired: [tap()], live: live).isEmpty)
    }

    @Test func demandWantsLogic() {
        #expect(MixLevelDemand(allApps: true).wants("x"))
        #expect(MixLevelDemand(keys: ["x"]).wants("x") && !MixLevelDemand(keys: ["x"]).wants("y"))
        #expect(MixLevelDemand(bandKeys: ["x"]).wants("x"))
        #expect(!MixLevelDemand.none.wants("x"))
    }
}

@Suite struct MixOrphansTests {
    private func agg(_ id: UInt32, uid: String, name: String = "Aggregate") -> MixAggregateInfo { MixAggregateInfo(objectID: id, uid: uid, name: name) }

    @Test func ourAggregateByUidPrefixIsDestroyed() {
        let p = MixOrphans.plan(aggregates: [agg(10, uid: "dev.multitool.app.mix.ABC")], taps: [])
        #expect(p.aggregates == [10])
    }

    @Test func ourAggregateByNamePrefixIsDestroyed() {
        let p = MixOrphans.plan(aggregates: [agg(11, uid: "other", name: "Multitul Mix com.apple.Music")], taps: [])
        #expect(p.aggregates == [11])
    }

    @Test func foreignAggregatesAreUntouched() {
        let p = MixOrphans.plan(aggregates: [agg(1, uid: "BlackHole16ch_UID", name: "BlackHole"), agg(2, uid: "com.apple.CoreAudio.Aggregate", name: "Aggregate Device"), agg(3, uid: "x", name: "My Multitul Mix")], taps: [])
        #expect(p.isEmpty)
    }

    @Test func prefixMatchIsCaseSensitive() {
        #expect(MixOrphans.plan(aggregates: [agg(1, uid: "RU.BOGEMA.MULTITUL.MIX.1", name: "multitul mix x")], taps: []).isEmpty)
    }

    @Test func ownedAggregatesSurvive() {
        let owned = "dev.multitool.app.mix.KEEP"
        let p = MixOrphans.plan(aggregates: [agg(1, uid: owned), agg(2, uid: "dev.multitool.app.mix.DROP")], taps: [], ownedAggregateUIDs: [owned])
        #expect(p.aggregates == [2])
    }

    @Test func tapsAreMatchedByName() {
        let taps = [MixTapInfo(objectID: 5, uid: "u1", name: "Multitul Tap com.apple.Music"), MixTapInfo(objectID: 6, uid: "u2", name: "Other App Tap"), MixTapInfo(objectID: 7, uid: "u3", name: "")]
        #expect(MixOrphans.plan(aggregates: [], taps: taps).taps == [5])
    }

    @Test func ownedTapsSurvive() {
        let taps = [MixTapInfo(objectID: 5, uid: "u1", name: "Multitul Tap a"), MixTapInfo(objectID: 6, uid: "u2", name: "Multitul Tap b")]
        #expect(MixOrphans.plan(aggregates: [], taps: taps, ownedTapUIDs: ["u1"]).taps == [6])
    }

    @Test func emptyInputGivesAnEmptyPlan() {
        let p = MixOrphans.plan(aggregates: [], taps: [])
        #expect(p.isEmpty && p == MixCleanupPlan(aggregates: [], taps: []))
    }

    @Test func manyOrphansAreAllListed() {
        let aggs = (1...5).map { agg(UInt32($0), uid: "dev.multitool.app.mix.\($0)") }
        #expect(MixOrphans.plan(aggregates: aggs, taps: []).aggregates == [1, 2, 3, 4, 5])
    }

    @Test func identityHelpers() {
        #expect(MixIdentity.isOwnAggregateUID(MixIdentity.aggregateUID(for: "x")))
        #expect(!MixIdentity.isOwnAggregateUID("com.apple.x"))
        #expect(MixIdentity.aggregateUIDPrefix.allSatisfy { $0.isASCII })
        #expect(MixIdentity.aggregateUIDPrefix.hasPrefix(MixIdentity.ownBundleID))
    }
}

@Suite struct MixGuardTests {
    private func settings(_ on: Bool = true, cap: Int = 30) -> MixSettings {
        var s = MixSettings()
        s.headphoneGuard = on
        s.guardCapPercent = cap
        return s
    }

    @Test func bluetoothToSpeakersCapsTheVolume() {
        let a = MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 0.8, settings: settings())
        #expect(a == MixGuardAction(deviceUID: "speakers", from: 0.8, to: 0.3))
    }

    @Test func usbAndAirPlayCountAsPersonalToo() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.usb, current: Snd.speakers, currentVolume: 0.9, settings: settings()) != nil)
        #expect(MixHeadphoneGuard.decide(previous: MixT.airplayTV, current: Snd.speakers, currentVolume: 0.9, settings: settings()) != nil)
    }

    @Test func disabledGuardDoesNothing() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 0.9, settings: settings(false)) == nil)
    }

    @Test func quietEnoughVolumeIsLeftAlone() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 0.2, settings: settings()) == nil)
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 0.3, settings: settings()) == nil)
    }

    @Test func unknownVolumeMeansNoAction() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: nil, settings: settings()) == nil)
    }

    @Test func switchingToNonSpeakerOutputsIsNotGuarded() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.hdmi, currentVolume: 1, settings: settings()) == nil)
        #expect(MixHeadphoneGuard.decide(previous: Snd.speakers, current: Snd.airpods, currentVolume: 1, settings: settings()) == nil)
        #expect(MixHeadphoneGuard.decide(previous: Snd.hdmi, current: Snd.speakers, currentVolume: 1, settings: settings()) == nil)
    }

    @Test func sameDeviceOrMissingSidesDoNothing() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.speakers, current: Snd.speakers, currentVolume: 1, settings: settings()) == nil)
        #expect(MixHeadphoneGuard.decide(previous: nil, current: Snd.speakers, currentVolume: 1, settings: settings()) == nil)
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: nil, currentVolume: 1, settings: settings()) == nil)
    }

    @Test func capIsClampedToTheAllowedRange() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 1, settings: settings(cap: 0))?.to == 0.05)
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 1, settings: settings(cap: 400)) == nil)
    }

    @Test func customCapApplies() {
        #expect(MixHeadphoneGuard.decide(previous: Snd.airpods, current: Snd.speakers, currentVolume: 0.9, settings: settings(cap: 50))?.to == 0.5)
    }
}
