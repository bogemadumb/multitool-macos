import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixEngineTests {
    private let safari = "com.apple.Safari"
    private let music = "com.apple.Music"

    private func env(devices: [AudioDeviceInfo] = [Snd.speakers, Snd.airpods, Snd.usb, MixT.airplayTV, Snd.mic], out: String? = "speakers") -> MixT.Env {
        MixT.Env(devices: devices, out: out)
    }

    @Test func startRemovesOurOrphansOnly() {
        let e = env()
        e.driver.aggregates = [MixAggregateInfo(objectID: 10, uid: "dev.multitool.app.mix.OLD", name: "Multitul Mix a"), MixAggregateInfo(objectID: 11, uid: "foreign", name: "BlackHole")]
        e.driver.taps = [MixTapInfo(objectID: 20, uid: "t", name: "Multitul Tap a"), MixTapInfo(objectID: 21, uid: "t2", name: "Someone's tap")]
        e.engine.start()
        #expect(e.driver.destroyedAggregates == [10] && e.driver.destroyedTaps == [20])
    }

    @Test func nothingIsTappedWithoutSettings() {
        let e = env()
        e.engine.start()
        #expect(e.driver.created.isEmpty && e.engine.live.isEmpty)
        #expect(e.engine.list.entries.map(\.key).sorted() == [music, safari])
    }

    @Test func settingsAppliedBeforeTheAppStartedAreHonouredAtStart() {
        let e = env()
        MixSettingsStore(e.kv).saveApps([music: MixAppSetting(volume: 0.4)])
        e.engine.start()
        #expect(e.driver.created.map(\.key) == [music])
        #expect(e.driver.created[0].params.volume == 0.4)
    }

    @Test func loweringVolumeCreatesATapOnlyForThatApp() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        #expect(e.driver.created.count == 1 && e.driver.created[0].key == safari)
        #expect(e.driver.created[0].mode == .process && e.driver.created[0].outputUID == "speakers")
        #expect(e.engine.live.keys.sorted() == [safari])
    }

    @Test func boostIsAllowedAndClamped() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 3.5)
        #expect(e.driver.active[safari]?.params.volume == 3.5)
        e.engine.setVolume(safari, 99)
        #expect(e.driver.active[safari]?.params.volume == 4)
        e.engine.setVolume(safari, -2)
        #expect(e.driver.active[safari]?.params.volume == 0)
    }

    @Test func backToHundredPercentReleasesTheApp() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.setVolume(safari, 1)
        #expect(e.driver.destroyed == [safari] && e.engine.live.isEmpty)
        #expect(e.engine.apps[safari] == nil)
    }

    @Test func muteChangesTheRunningTapInPlace() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.setMuted(safari, true)
        #expect(e.driver.created.count == 1)
        #expect(e.driver.updates.last?.1 == MixParams(volume: 0.5, muted: true))
        e.engine.toggleMute(safari)
        #expect(e.driver.updates.last?.1.muted == false)
    }

    @Test func mutingAnUntouchedAppTapsItAndUnmutingReleasesIt() {
        let e = env()
        e.engine.start()
        e.engine.toggleMute(music)
        #expect(e.driver.active[music]?.params.muted == true)
        e.engine.toggleMute(music)
        #expect(e.driver.active[music] == nil)
    }

    @Test func dragDoesNotPersistUntilCommitted() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.7, persist: false)
        e.engine.setVolume(safari, 0.6, persist: false)
        #expect(e.kv.values["mixer.apps"] == nil)
        #expect(e.driver.active[safari]?.params.volume == 0.6)
        e.engine.setVolume(safari, 0.6, persist: true)
        #expect(MixSettingsStore(e.kv).loadApps()[safari]?.volume == 0.6)
    }

    @Test func routingToAirPlayBuildsATapOnThatDevice() {
        let e = env()
        e.engine.start()
        e.engine.setOutput(music, "airplay-tv")
        #expect(e.driver.active[music]?.outputUID == "airplay-tv")
        #expect(e.engine.snapshot().options.contains { $0.uid == "airplay-tv" && $0.transport == .airplay })
    }

    @Test func followsTheDefaultOutputChange() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.hardware.outDefault = "airpods"
        e.engine.handle(.defaultChanged(.output))
        #expect(e.driver.destroyed == [safari])
        #expect(e.driver.created.count == 2 && e.driver.created[1].outputUID == "airpods")
        #expect(e.engine.defaultUID == "airpods")
    }

    @Test func pinnedRouteIgnoresTheDefaultChange() {
        let e = env()
        e.engine.start()
        e.engine.setOutput(music, "usb-headset")
        e.hardware.outDefault = "airpods"
        e.engine.handle(.defaultChanged(.output))
        #expect(e.driver.created.count == 1 && e.driver.active[music]?.outputUID == "usb-headset")
    }

    @Test func systemOutputEventIsHarmless() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.handle(.systemOutputChanged)
        #expect(e.driver.created.count == 1)
    }

    @Test func deviceDisappearingFallsBackAndComesBack() {
        let e = env()
        e.engine.start()
        e.engine.setOutput(music, "usb-headset")
        e.hardware.unplug("usb-headset")
        e.engine.handle(.devicesChanged)
        #expect(e.driver.active[music]?.outputUID == "speakers")
        #expect(e.engine.snapshot().fallbackKeys == [music])
        #expect(e.engine.apps[music]?.outputUID == "usb-headset")
        e.hardware.plug(Snd.usb)
        e.engine.handle(.devicesChanged)
        #expect(e.driver.active[music]?.outputUID == "usb-headset")
        #expect(e.engine.snapshot().fallbackKeys.isEmpty)
    }

    @Test func lastOutputDisappearingDropsTheTap() {
        let e = env(devices: [Snd.speakers, Snd.mic])
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.hardware.unplug("speakers")
        e.engine.handle(.devicesChanged)
        #expect(e.engine.live.isEmpty && e.driver.active.isEmpty)
    }

    @Test func helperProcessAppearingRebuildsTheTap() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.driver.procs.append(MixT.proc(3, pid: 555, "com.apple.Safari.helper"))
        e.engine.refresh()
        #expect(e.driver.created.count == 2 && e.driver.created[1].processObjectIDs == [1, 3])
    }

    @Test func quittingAppDropsItsTapAndRelaunchRestoresIt() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.driver.procs.removeAll { $0.bundleID == safari }
        e.engine.refresh()
        #expect(e.engine.live.isEmpty && e.driver.active.isEmpty)
        e.driver.procs.append(MixT.proc(8, pid: 100, safari))
        e.engine.refresh()
        #expect(e.driver.active[safari]?.params.volume == 0.5)
    }

    @Test func presetsSurviveARestartOfTheEngine() {
        let first = env()
        first.engine.start()
        first.engine.setVolume(safari, 0.35)
        first.engine.setOutput(safari, "airpods")
        let second = MixT.Env(kv: first.kv)
        second.engine.start()
        #expect(second.driver.active[safari]?.params.volume == 0.35 && second.driver.active[safari]?.outputUID == "airpods")
    }

    @Test func failureIsReportedAndRetriedWithBackoff() {
        let e = env()
        e.driver.failures[safari] = .tapFailed(-1)
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        #expect(e.engine.errors[safari] == .tapFailed(-1) && e.engine.live.isEmpty)
        e.engine.refresh()
        #expect(e.driver.created.count == 1)
        e.clock.now += 1.1
        e.engine.refresh()
        #expect(e.driver.created.count == 2)
        e.clock.now += 1.5
        e.engine.refresh()
        #expect(e.driver.created.count == 2)
        e.driver.failures[safari] = nil
        e.clock.now += 1
        e.engine.refresh()
        #expect(e.driver.created.count == 3 && e.engine.errors[safari] == nil && e.engine.live[safari] != nil)
    }

    @Test func errorDisappearsWhenTheSettingIsReverted() {
        let e = env()
        e.driver.failures[safari] = .permissionDenied
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        #expect(e.engine.snapshot().errors[safari] == .permissionDenied)
        e.engine.setVolume(safari, 1)
        #expect(e.engine.errors.isEmpty)
    }

    @Test func otherAppsKeepWorkingWhenOneFails() {
        let e = env()
        e.driver.failures[safari] = .aggregateFailed(5)
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.setVolume(music, 0.5)
        #expect(e.engine.live.keys.sorted() == [music])
    }

    @Test func stopDestroysEverythingAndIgnoresLaterEvents() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.stop()
        #expect(e.driver.destroyAllCalls == 1 && e.driver.active.isEmpty && e.engine.live.isEmpty && !e.engine.isRunning)
        let before = e.driver.created.count
        e.hardware.outDefault = "airpods"
        e.engine.handle(.defaultChanged(.output))
        #expect(e.engine.refresh().isEmpty)
        #expect(e.driver.created.count == before)
        e.engine.stop()
        #expect(e.driver.destroyAllCalls == 1)
    }

    @Test func startingTwiceDoesNothingTheSecondTime() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.start()
        #expect(e.driver.created.count == 1)
    }

    @Test func meterTapsAppearOnlyForOutputtingAppsWhileSomeoneWatches() {
        let e = env()
        e.driver.procs = [MixT.proc(1, pid: 100, safari, out: true), MixT.proc(2, pid: 200, music, out: false)]
        e.engine.start()
        #expect(e.engine.live.isEmpty)
        e.engine.setDemand(owner: "ui", MixLevelDemand(allApps: true))
        #expect(e.engine.live.keys.sorted() == [safari] && e.engine.live[safari]?.desired.mode == .meter)
        e.engine.setDemand(owner: "ui", nil)
        #expect(e.engine.live.isEmpty && e.driver.destroyed == [safari])
    }

    @Test func disablingMetersTurnsTheUiDemandOff() {
        let e = env()
        e.engine.start()
        var s = e.engine.settings
        s.showMeters = false
        e.engine.update(settings: s)
        e.engine.setDemand(owner: "ui", MixLevelDemand(allApps: true))
        #expect(e.engine.live.isEmpty)
    }

    @Test func hooksWorkEvenWithMetersOff() {
        let e = env()
        e.engine.start()
        var s = e.engine.settings
        s.showMeters = false
        e.engine.update(settings: s)
        e.engine.setDemand(owner: "hook.island", MixLevelDemand(keys: [music], bandKeys: [music]))
        #expect(e.engine.live[music]?.desired.mode == .meter && e.engine.live[music]?.desired.params.bandsOn == true)
        #expect(e.engine.live[safari] == nil)
    }

    @Test func meterTapBecomesAProcessTapWhenTheVolumeChanges() {
        let e = env()
        e.engine.start()
        e.engine.setDemand(owner: "ui", MixLevelDemand(allApps: true))
        #expect(e.engine.live[safari]?.desired.mode == .meter)
        e.engine.setVolume(safari, 0.5)
        #expect(e.engine.live[safari]?.desired.mode == .process)
        #expect(e.driver.destroyed.contains(safari))
    }

    @Test func demandsFromSeveralOwnersAreMerged() {
        let e = env()
        e.engine.start()
        e.engine.setDemand(owner: "a", MixLevelDemand(keys: [safari]))
        e.engine.setDemand(owner: "b", MixLevelDemand(keys: [music]))
        #expect(e.engine.live.keys.sorted() == [music, safari])
        e.engine.setDemand(owner: "a", nil)
        #expect(e.engine.live.keys.sorted() == [music])
    }

    @Test func levelsComeOnlyFromLiveTapsAndAskForBandsPerKey() {
        let e = env()
        e.engine.start()
        e.driver.levelsByKey = [safari: MixLevels(peak: 0.5, rms: 0.2), music: MixLevels(peak: 0.1, rms: 0.05)]
        e.engine.setVolume(safari, 0.5)
        e.engine.setDemand(owner: "hook.island", MixLevelDemand(keys: [music], bandKeys: [music]))
        let l = e.engine.levels()
        #expect(Set(l.keys) == [safari, music] && l[safari]?.peak == 0.5)
        #expect(e.driver.lastBandsRequest[music] == true && e.driver.lastBandsRequest[safari] == false)
    }

    @Test func resetAllClearsEverythingButPins() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.setMuted(music, true)
        e.engine.setPinned(music, true)
        e.engine.resetAll()
        #expect(e.engine.live.isEmpty)
        #expect(e.engine.apps[music]?.pinned == true && e.engine.apps[music]?.muted == false)
        #expect(e.engine.apps[safari] == nil)
        #expect(Set(MixSettingsStore(e.kv).loadApps().keys) == [music])
    }

    @Test func resetOneAppLeavesTheRest() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.engine.setVolume(music, 0.5)
        e.engine.reset(safari)
        #expect(e.engine.live.keys.sorted() == [music])
        e.engine.reset("unknown.app")
        #expect(e.engine.live.keys.sorted() == [music])
    }

    @Test func loweringTheBoostLimitClampsSavedVolumes() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 3.5)
        var s = e.engine.settings
        s.maxBoost = 2
        e.engine.update(settings: s)
        #expect(e.engine.apps[safari]?.volume == 2 && e.driver.active[safari]?.params.volume == 2)
        #expect(MixSettingsStore(e.kv).loadApps()[safari]?.volume == 2)
        #expect(MixSettingsStore(e.kv).loadSettings().maxBoost == 2)
    }

    @Test func stepKeysUseTheConfiguredGranularity() {
        let e = env()
        e.engine.start()
        e.engine.step(safari, up: true)
        #expect(e.engine.apps[safari]?.volume == 1.05)
        var s = e.engine.settings
        s.fineSteps = true
        e.engine.update(settings: s)
        e.engine.step(safari, up: false)
        #expect(e.engine.apps[safari]?.volume == 1.04)
    }

    @Test func rowOrderIsRememberedAndApplied() {
        let e = env()
        e.driver.procs = [MixT.proc(1, pid: 100, safari), MixT.proc(2, pid: 200, music)]
        e.engine.start()
        #expect(e.engine.snapshot().rows.map(\.key) == [music, safari])
        e.engine.moveRow(safari, before: music)
        #expect(e.engine.snapshot().rows.map(\.key) == [safari, music])
        #expect(MixSettingsStore(e.kv).loadSettings().order == [safari, music])
        e.engine.nudgeRow(safari, by: 1)
        #expect(e.engine.snapshot().rows.map(\.key) == [music, safari])
    }

    @Test func pinnedAppShowsEvenWhenItIsNotRunning() {
        let e = env()
        e.engine.start()
        e.engine.setPinned(music, true)
        #expect(e.driver.created.isEmpty)
        e.driver.procs.removeAll { $0.bundleID == music }
        e.engine.refresh()
        let rows = e.engine.snapshot().rows
        #expect(rows.contains { $0.key == music && !$0.isRunning })
    }

    @Test func idleAppsAreHiddenButConfiguredOnesStay() {
        let e = env()
        e.driver.procs = [MixT.proc(1, pid: 100, safari, out: false), MixT.proc(2, pid: 200, music, out: false)]
        e.engine.start()
        #expect(e.engine.snapshot().rows.isEmpty)
        e.engine.setVolume(music, 0.5)
        #expect(e.engine.snapshot().rows.map(\.key) == [music])
        #expect(e.engine.live[music] != nil)
    }

    @Test func ownProcessNeverAppearsInTheList() {
        let e = env()
        e.driver.procs.append(MixT.proc(40, pid: 1, "com.apple.Safari"))
        e.engine.start()
        #expect(e.engine.list.entries.allSatisfy { !$0.pids.contains(1) })
    }

    @Test func refreshWithoutChangesDoesNotTouchTheDriver() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        let created = e.driver.created.count, destroyed = e.driver.destroyed.count, updates = e.driver.updates.count
        for _ in 0..<5 { _ = e.engine.refresh() }
        #expect(e.driver.created.count == created && e.driver.destroyed.count == destroyed && e.driver.updates.count == updates)
    }

    @Test func findsTheKeyOfTheFrontApp() {
        let e = env()
        e.engine.start()
        #expect(e.engine.key(forPID: 100, bundleID: safari) == safari)
        #expect(e.engine.key(forPID: 9999, bundleID: music) == music)
        #expect(e.engine.key(forPID: 9999, bundleID: "no.such") == nil)
        #expect(e.engine.key(forPID: 9999, bundleID: nil) == nil)
    }

    @Test func snapshotCarriesDefaultNameAndProcessingSet() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        let s = e.engine.snapshot()
        #expect(s.defaultOutputName == Snd.speakers.name && s.processing == [safari])
        #expect(s.settings == e.engine.settings)
    }

    @Test func headphoneGuardCapsTheSpeakersWhenBluetoothLeaves() {
        let e = env(out: "airpods")
        e.engine.start()
        var s = e.engine.settings
        s.headphoneGuard = true
        e.engine.update(settings: s)
        var fired: [(MixGuardAction, String)] = []
        e.engine.onGuard = { fired.append(($0, $1)) }
        e.volume.volumes["speakers"] = 0.9
        e.hardware.unplug("airpods")
        e.engine.handle(.devicesChanged)
        #expect(e.volume.sets.count == 1 && e.volume.sets[0].0 == "speakers" && abs(e.volume.sets[0].1 - 0.3) < 1e-6)
        #expect(fired.count == 1 && fired[0].1 == Snd.speakers.name)
    }

    @Test func headphoneGuardStaysQuietWhenOffOrAlreadyLow() {
        let off = env(out: "airpods")
        off.engine.start()
        off.volume.volumes["speakers"] = 0.9
        off.hardware.outDefault = "speakers"
        off.engine.handle(.defaultChanged(.output))
        #expect(off.volume.sets.isEmpty)
        let low = env(out: "airpods")
        low.engine.start()
        var s = low.engine.settings
        s.headphoneGuard = true
        low.engine.update(settings: s)
        low.volume.volumes["speakers"] = 0.1
        low.hardware.outDefault = "speakers"
        low.engine.handle(.defaultChanged(.output))
        #expect(low.volume.sets.isEmpty)
    }

    @Test func failedVolumeWriteDoesNotReportTheGuard() {
        let e = env(out: "airpods")
        e.engine.start()
        var s = e.engine.settings
        s.headphoneGuard = true
        e.engine.update(settings: s)
        var count = 0
        e.engine.onGuard = { _, _ in count += 1 }
        e.volume.failSet = true
        e.volume.volumes["speakers"] = 0.9
        e.hardware.outDefault = "speakers"
        e.engine.handle(.defaultChanged(.output))
        #expect(e.volume.sets.count == 1 && count == 0)
    }

    @Test func inputDefaultChangesAreIgnored() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        let n = e.driver.created.count
        e.engine.handle(.defaultChanged(.input))
        #expect(e.driver.created.count == n && e.driver.destroyed.isEmpty)
    }

    @Test func cleanupLeavesLiveSessionsAlone() {
        let e = env()
        e.engine.start()
        e.engine.setVolume(safari, 0.5)
        e.driver.aggregates = [MixAggregateInfo(objectID: 77, uid: MixIdentity.aggregateUID(for: safari), name: "Multitul Mix x")]
        let plan = e.engine.cleanupOrphans()
        #expect(plan.isEmpty && e.driver.destroyedAggregates.isEmpty)
    }
}

@Suite struct MixModuleInfoTests {
    @Test func moduleLivesInTheSoundGroupOffByDefault() {
        let i = ModuleID.mixer.info
        #expect(i.group == .sound && !i.enabledByDefault && i.title == "Микшер")
        #expect(i.permissions == [.systemAudio])
        #expect(!i.summary.isEmpty && !i.symbol.isEmpty)
    }

    @Test func hotkeysAreUnassignedAndAscii() {
        let h = ModuleID.mixer.info.hotkeys
        #expect(h.count == 2 && h.allSatisfy { $0.defaultCombo.isNone })
        #expect(h.allSatisfy { $0.id.allSatisfy { $0.isASCII } && $0.id.hasPrefix("mixer.") })
        #expect(h == MixHotkeys.all)
    }

    @Test func identifiersAndSettingKeysAreAscii() {
        #expect(ModuleID.mixer.rawValue == "mixer" && ModuleID.mixer.enabledKey == "module.mixer.enabled")
        #expect(MixIdentity.aggregateUIDPrefix.allSatisfy { $0.isASCII })
    }

    @Test func hotkeysAreRegisteredInTheCatalogWithoutConflicts() {
        let ids = Set(HotkeyHints.allSpecs.map(\.id))
        #expect(ids.contains("mixer.muteFront") && ids.contains("mixer.resetAll"))
    }

    @Test func errorsHaveReadableText() {
        let all: [MixTapError] = [.unsupported, .permissionDenied, .deviceUnavailable, .tapFailed(1), .aggregateFailed(2), .ioFailed(3), .badFormat]
        #expect(all.allSatisfy { !$0.text.isEmpty })
        #expect(MixTapError.tapFailed(7).text.contains("7"))
    }

    @Test func desiredTapShapeIgnoresParameters() {
        let a = MixDesiredTap(key: "k", name: "n", processObjectIDs: [1], mode: .process, outputUID: "u", params: MixParams(volume: 1))
        var b = a
        b.params = MixParams(volume: 3, muted: true)
        #expect(a.sameShape(as: b) && a != b)
        b.outputUID = "v"
        #expect(!a.sameShape(as: b))
    }

    @Test func settingFlags() {
        #expect(MixAppSetting().isNeutral && !MixAppSetting().needsProcessing)
        #expect(MixAppSetting(pinned: true).needsProcessing == false && !MixAppSetting(pinned: true).isNeutral)
        #expect(MixAppSetting(volume: 1.5).needsProcessing && MixAppSetting(muted: true).needsProcessing && MixAppSetting(outputUID: "x").needsProcessing)
        #expect(MixAppSetting(volume: 9).params.volume == 4)
    }

    @Test func plistTemplateAsksForAudioCapture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("NSAudioCaptureUsageDescription"))
    }

    @Test func liveDriverReportsSupportOnThisSystem() {
        #expect(MixLiveDriver.isSupported)
    }
}
