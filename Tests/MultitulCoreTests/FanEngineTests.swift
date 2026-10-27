import Testing
import Foundation
@testable import MultitulCore

@Suite struct FanEngineLifecycleTests {
    @Test func startDetectsFansAndLeavesThemToTheSystem() {
        let r = FanRig()
        #expect(r.engine.state == .system && r.engine.fans.count == 1)
        #expect(r.applier.calls.isEmpty && !r.engine.isControlling)
    }

    @Test func noFansPathDoesNothing() {
        let r = FanRig(start: false)
        r.hw.detection = .noFans
        r.engine.start()
        #expect(r.engine.state == .noFans)
        r.tick()
        #expect(!r.engine.setMode(.manualRpm))
        #expect(!r.engine.setMode(.curve))
        #expect(r.engine.update({ var c = FanConfig(); c.mode = .manualPercent; return c }()) == false)
        #expect(r.applier.calls.isEmpty && r.hw.readCalls == 0 && r.hw.thermalCalls == 0)
        #expect(FanText.status(r.engine.state, restorePending: false, asleep: false) == "На этом Маке нет вентиляторов")
    }

    @Test func zeroFanListIsTreatedAsNoFans() {
        let r = FanRig(start: false)
        r.hw.detection = .fans([])
        r.engine.start()
        #expect(r.engine.state == .noFans)
    }

    @Test func unsupportedHardwareIsReportedAndNeverWritten() {
        let r = FanRig(start: false)
        r.hw.detection = .unsupported("нет F0Md")
        r.engine.start()
        #expect(r.engine.state == .unsupported("нет F0Md"))
        #expect(!r.engine.setMode(.manualRpm))
        #expect(r.applier.calls.isEmpty)
        #expect(FanText.status(r.engine.state, restorePending: false, asleep: false).contains("нет F0Md"))
    }

    @Test func tickBeforeStartIsIgnored() {
        let r = FanRig(start: false)
        r.tick()
        #expect(r.hw.readCalls == 0 && r.engine.state == .stopped)
    }

    @Test func startTwiceDoesNotRedetect() {
        let r = FanRig()
        r.engine.start()
        #expect(r.hw.detectCalls == 1)
    }

    @Test func tickInSystemModeOnlyReads() {
        let r = FanRig()
        r.tick()
        #expect(r.engine.readings.count == 1 && r.engine.temperature == 50)
        #expect(r.applier.calls.isEmpty)
    }
}

@Suite struct FanEngineModeTests {
    @Test func manualRpmWritesTheRequestedSpeed() {
        let r = FanRig(config: { $0.manualRpm = 3200 })
        #expect(r.engine.setMode(.manualRpm))
        #expect(r.engine.state == .manual && r.lastRpm == 3200 && r.engine.config.mode == .manualRpm)
    }

    @Test func manualPercentUsesTheFanRange() {
        let r = FanRig(config: { $0.manualPercent = 50 })
        #expect(r.engine.setMode(.manualPercent))
        #expect(r.lastRpm == 3600)
    }

    @Test func manualBelowMinimumIsRaised() {
        let r = FanRig(config: { $0.manualRpm = 300 })
        _ = r.engine.setMode(.manualRpm)
        #expect(r.lastRpm == 1200)
    }

    @Test func manualAboveMaximumIsCut() {
        let r = FanRig(config: { $0.manualRpm = 9000 })
        _ = r.engine.setMode(.manualRpm)
        #expect(r.lastRpm == 6000)
    }

    @Test func zeroRpmIsNeverWrittenForAFanThatCannotStop() {
        let r = FanRig(config: { $0.manualRpm = 0 })
        _ = r.engine.setMode(.manualRpm)
        #expect(r.lastRpm == 1200)
        let p = FanRig(config: { $0.manualPercent = 0 })
        _ = p.engine.setMode(.manualPercent)
        #expect(p.lastRpm == 1200)
    }

    @Test func zeroRpmIsWrittenForAFanThatCanStop() {
        let r = FanRig(fans: [FanInfo(index: 0, minRpm: 0, maxRpm: 5000)], config: { $0.manualRpm = 0 })
        _ = r.engine.setMode(.manualRpm)
        #expect(r.lastRpm == 0)
    }

    @Test func everyWrittenValueStaysInsideEachFanLimits() {
        let r = FanRig(fans: FanRig.two, config: { $0.mode = .curve; $0.manualPercent = 100 })
        _ = r.engine.setMode(.curve)
        for t in [10.0, 40, 60, 80, 100, 125] {
            r.temp(t)
            r.tick()
        }
        for w in r.applier.rpmWrites {
            let f = FanRig.two[w.index]
            #expect(Double(w.rpm) >= f.minRpm && Double(w.rpm) <= f.maxRpm)
        }
    }

    @Test func twoFansGetTheirOwnPercentRange() {
        let r = FanRig(fans: FanRig.two, config: { $0.manualPercent = 100 })
        _ = r.engine.setMode(.manualPercent)
        #expect(r.applier.rpmWrites.map(\.rpm) == [6000, 5000])
    }

    @Test func stateMachineAutoManualCurveAuto() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        #expect(r.engine.state == .system)
        #expect(r.engine.setMode(.manualRpm) && r.engine.state == .manual)
        #expect(r.engine.setMode(.curve) && r.engine.state == .curve)
        #expect(r.engine.setMode(.auto) && r.engine.state == .system)
        #expect(r.applier.calls.last == "auto:all" && r.engine.config.mode == .auto)
        #expect(!r.store.dirty && r.hw.manual.isEmpty)
    }

    @Test func switchingModesKeepsTheDirtyFlagUntilRestore() {
        let r = FanRig()
        _ = r.engine.setMode(.manualRpm)
        #expect(r.store.dirty)
        _ = r.engine.setMode(.curve)
        #expect(r.store.dirty)
        _ = r.engine.setMode(.auto)
        #expect(!r.store.dirty)
    }

    @Test func dirtyFlagIsSetBeforeTheFirstWrite() {
        let r = FanRig()
        var dirtyAtFirstWrite: Bool?
        r.applier.hardware = nil
        let spy = FanSpyApplier { dirtyAtFirstWrite = dirtyAtFirstWrite ?? r.store.dirty }
        let e = FanEngine(hardware: r.hw, applier: spy, store: r.store, clock: r.clock, thermalState: { 0 })
        e.start()
        _ = e.setMode(.manualRpm)
        #expect(dirtyAtFirstWrite == true)
    }

    @Test func settingAutoWhileAlreadyAutoIsHarmless() {
        let r = FanRig()
        #expect(r.engine.setMode(.auto))
        #expect(r.engine.state == .system)
    }

    @Test func modeChangeIsPersisted() {
        let r = FanRig()
        _ = r.engine.setMode(.manualPercent)
        #expect(FanSettingsStore(r.kv).load().mode == .manualPercent)
    }

    @Test func updatingParametersWhileControllingTakesEffectOnTheNextTick() {
        let r = FanRig(config: { $0.manualRpm = 2000 })
        _ = r.engine.setMode(.manualRpm)
        var c = r.engine.config
        c.manualRpm = 4000
        #expect(r.engine.update(c))
        #expect(r.lastRpm == 2000)
        r.tick()
        #expect(r.lastRpm == 4000)
    }

    @Test func updatingTheModeEngagesIt() {
        let r = FanRig()
        var c = r.engine.config
        c.mode = .manualPercent
        c.manualPercent = 100
        #expect(r.engine.update(c) && r.engine.state == .manual && r.lastRpm == 6000)
        c.mode = .auto
        #expect(r.engine.update(c) && r.engine.state == .system)
    }

    @Test func presetApplicationSwitchesToTheCurve() {
        let r = FanRig()
        let lib = FanPresetLibrary(store: r.store)
        let cfg = lib.config(applying: "cool", to: r.engine.config)!
        #expect(r.engine.update(cfg) && r.engine.state == .curve && r.engine.config.curve == FanPresets.builtIn[2].config.curve)
    }
}

@Suite struct FanEngineCurveTests {
    private func curveRig(_ extra: ((inout FanConfig) -> Void)? = nil) -> FanRig {
        let r = FanRig(config: { $0.mode = .curve; $0.hysteresis = 3; extra?(&$0) })
        r.temp(40)
        return r
    }

    @Test func curveFollowsTheTemperature() {
        let r = curveRig()
        r.engine.update({ var c = r.engine.config; c.mode = .curve; return c }())
        r.temp(70)
        r.tick()
        #expect(r.engine.state == .curve && r.lastRpm == 4080)
        r.temp(85)
        r.tick()
        #expect(r.lastRpm == 6000)
    }

    @Test func belowTheFirstPointTheFanStaysAtMinimum() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        #expect(r.lastRpm == 1200)
    }

    @Test func hysteresisKeepsTheSpeedWhenTemperatureDipsSlightly() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.temp(70)
        r.tick()
        let high = r.lastRpm
        r.temp(68.5)
        r.tick()
        r.temp(67.5)
        r.tick()
        #expect(r.lastRpm == high && r.applier.rpmWrites.filter { $0.rpm < high! }.count == 1)
    }

    @Test func hysteresisReleasesAfterARealDrop() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.temp(70)
        r.tick()
        r.temp(65)
        r.tick()
        #expect(r.lastRpm! < 4080)
    }

    @Test func noisyTemperatureNeverMakesTheSpeedGoUpAndDown() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.temp(70)
        r.tick()
        for i in 0..<40 {
            r.temp(70 + (i % 2 == 0 ? 0.8 : -0.8))
            r.tick()
        }
        let seq = r.applier.rpmWrites.map(\.rpm)
        var reversals = 0
        for i in 2..<seq.count where (seq[i] - seq[i - 1]) * (seq[i - 1] - seq[i - 2]) < 0 { reversals += 1 }
        #expect(reversals == 0)
    }

    @Test func rampLimitsHowFastTheSpeedRises() {
        let r = FanRig(config: { $0.mode = .curve; $0.rampUp = 800; $0.rampDown = 200 })
        r.temp(40)
        _ = r.engine.setMode(.curve)
        r.hw.actual[0] = 1200
        r.temp(95)
        r.tick()
        let a = r.lastRpm!
        r.tick()
        let b = r.lastRpm!
        r.tick()
        r.tick()
        #expect(a <= 1200 + 1600 && b <= a + 1600 && b > a)
        #expect(r.lastRpm == 6000)
    }

    @Test func rampLimitsHowFastTheSpeedFalls() {
        let r = FanRig(config: { $0.manualRpm = 6000; $0.rampUp = 0; $0.rampDown = 200 })
        _ = r.engine.setMode(.manualRpm)
        r.hw.actual[0] = 6000
        var c = r.engine.config
        c.manualRpm = 1200
        r.engine.update(c)
        r.tick()
        #expect(r.lastRpm == 5600)
        r.tick()
        #expect(r.lastRpm == 5200)
    }

    @Test func firstManualStepStartsFromTheCurrentSpeed() {
        let r = FanRig(config: { $0.manualRpm = 6000; $0.rampUp = 800 })
        r.hw.actual[0] = 2000
        _ = r.engine.setMode(.manualRpm)
        #expect(r.lastRpm == 3600)
    }

    @Test func unchangedTargetIsNotRewrittenEveryTick() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.tick(); r.tick(); r.tick()
        #expect(r.applier.rpmWrites.count == 1)
    }

    @Test func targetIsRefreshedPeriodically() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.tick(16)
        #expect(r.applier.rpmWrites.count == 2)
    }

    @Test func tinyChangesBelowTheDeltaAreSkipped() {
        let r = curveRig()
        _ = r.engine.setMode(.curve)
        r.temp(40.2)
        r.tick()
        #expect(r.applier.rpmWrites.count == 1)
    }

    @Test func sensorChoiceIsUsed() {
        let r = FanRig(config: { $0.mode = .curve; $0.source = .gpu; $0.aggregate = .average })
        r.hw.thermal = FanThermal(cpu: [95], gpu: [40, 60])
        _ = r.engine.setMode(.curve)
        #expect(r.engine.temperature == 50)
    }
}

@Suite struct FanEngineSafetyTests {
    @Test func writeFailureReturnsFansToTheSystemAndNotifies() {
        let r = FanRig()
        r.applier.failRpm = true
        #expect(!r.engine.setMode(.manualRpm))
        #expect(r.engine.state == .system && r.engine.config.mode == .auto)
        #expect(r.engine.lastFault?.kind == .writeFailed)
        #expect(r.applier.calls.contains("auto:all") && !r.store.dirty)
        #expect(r.notes.items.count == 1 && r.notes.items[0].1.contains("fake failure"))
    }

    @Test func faultResetsThePersistedMode() {
        let r = FanRig()
        r.applier.failRpm = true
        _ = r.engine.setMode(.manualRpm)
        #expect(FanSettingsStore(r.kv).load().mode == .auto)
    }

    @Test func failedRestoreIsRetriedAndFlagged() {
        let r = FanRig()
        r.applier.failRpm = true
        r.applier.failAutoCount = 2
        _ = r.engine.setMode(.manualRpm)
        #expect(r.engine.restorePending && r.store.dirty)
        #expect(r.notes.items.contains { $0.0.contains("не удалось вернуть") })
        r.tick(6)
        #expect(!r.engine.restorePending && !r.store.dirty)
    }

    @Test func restoreRetryIsRateLimited() {
        let r = FanRig()
        r.applier.failRpm = true
        r.applier.failAutoCount = 100
        _ = r.engine.setMode(.manualRpm)
        let before = r.applier.autoCalls
        r.tick(1)
        r.tick(1)
        #expect(r.applier.autoCalls == before)
        r.tick(4)
        #expect(r.applier.autoCalls > before)
    }

    @Test func sensorLossIsToleratedBrieflyThenFansGoBack() {
        let r = FanRig(config: { $0.mode = .curve })
        r.temp(60)
        _ = r.engine.setMode(.curve)
        r.hw.thermal = nil
        r.tick(); r.tick()
        #expect(r.engine.state == .curve)
        r.tick()
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .sensorLost)
        #expect(r.hw.manual.isEmpty)
    }

    @Test func aRecoveredSensorResetsTheMissCounter() {
        let r = FanRig(config: { $0.mode = .curve })
        r.temp(60)
        _ = r.engine.setMode(.curve)
        r.hw.thermal = nil
        r.tick(); r.tick()
        r.temp(60)
        r.tick()
        r.hw.thermal = nil
        r.tick(); r.tick()
        #expect(r.engine.state == .curve)
    }

    @Test func emptyGroupCountsAsSensorLoss() {
        let r = FanRig(config: { $0.mode = .curve; $0.source = .gpu })
        r.hw.thermal = FanThermal(cpu: [60], gpu: [])
        _ = r.engine.setMode(.curve)
        r.tick(); r.tick(); r.tick()
        #expect(r.engine.lastFault?.kind == .sensorLost)
    }

    @Test func manualModeDoesNotNeedSensors() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        r.hw.thermal = nil
        _ = r.engine.setMode(.manualRpm)
        r.tick(); r.tick(); r.tick(); r.tick()
        #expect(r.engine.state == .manual && r.engine.lastFault == nil)
    }

    @Test func unreadableFansForThreeTicksReturnControl() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.hw.readFailures = 3
        r.tick(); r.tick()
        #expect(r.engine.state == .manual)
        r.tick()
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .fanReadLost)
    }

    @Test func engagingWithUnreadableFansFailsSafely() {
        let r = FanRig()
        r.hw.readsAlwaysFail = true
        #expect(!r.engine.setMode(.manualRpm))
        #expect(r.applier.rpmWrites.isEmpty && r.engine.lastFault?.kind == .fanReadLost)
    }

    @Test func seriousThermalStateHandsControlBack() {
        let r = FanRig(config: { $0.manualRpm = 2000 })
        _ = r.engine.setMode(.manualRpm)
        r.thermalLevel = 1
        r.tick()
        #expect(r.engine.state == .manual)
        r.thermalLevel = 2
        r.tick()
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .thermalPressure)
        #expect(r.notes.items.last?.1.contains("тепловая") == true)
    }

    @Test func thermalStateIsIgnoredWhenTheSystemIsInCharge() {
        let r = FanRig()
        r.thermalLevel = 3
        r.tick()
        #expect(r.engine.lastFault == nil && r.applier.calls.isEmpty)
    }

    @Test func afterAFaultTheEngineStaysInAutoUntilAskedAgain() {
        let r = FanRig(config: { $0.manualRpm = 2000 })
        _ = r.engine.setMode(.manualRpm)
        r.thermalLevel = 2
        r.tick()
        r.thermalLevel = 0
        r.tick(); r.tick()
        #expect(r.engine.state == .system)
        #expect(r.engine.setMode(.manualRpm) && r.engine.lastFault == nil)
    }

    @Test func systemTakingTheFansBackIsCounteredThenGivenUp() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.hw.reclaimOnRead = true
        r.tick()
        #expect(r.applier.rpmWrites.count == 2)
        for _ in 0..<FanPolicy.maxReclaims + 1 { r.tick() }
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .reclaimed)
    }

    @Test func aRealReclaimIsRewrittenImmediately() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.hw.manual = []
        r.tick()
        #expect(r.applier.rpmWrites.count == 2 && r.hw.manual == [0])
        r.tick()
        #expect(r.applier.rpmWrites.count == 2)
    }

    @Test func modeCannotBeChangedWhileTheFansHaveNoOwner() {
        let r = FanRig(start: false)
        #expect(!r.engine.setMode(.manualRpm))
    }
}

@Suite struct FanEngineSleepQuitTests {
    @Test func sleepReturnsFansToTheSystem() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.engine.sleep()
        #expect(r.engine.state == .system && r.hw.manual.isEmpty && r.engine.asleep && !r.store.dirty)
    }

    @Test func wakeReappliesTheSameMode() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.engine.sleep()
        r.engine.wake()
        #expect(r.engine.state == .manual && r.lastRpm == 3000 && r.hw.manual == [0] && r.store.dirty)
        #expect(r.applier.rpmWrites.count == 2)
    }

    @Test func wakeReappliesTheCurve() {
        let r = FanRig(config: { $0.mode = .curve })
        r.temp(70)
        _ = r.engine.setMode(.curve)
        r.engine.sleep()
        r.engine.wake()
        #expect(r.engine.state == .curve)
    }

    @Test func wakeAfterSleepInAutoDoesNothing() {
        let r = FanRig()
        r.engine.sleep()
        r.engine.wake()
        #expect(r.engine.state == .system && r.applier.calls.isEmpty)
    }

    @Test func ticksAndRequestsAreIgnoredWhileAsleep() {
        let r = FanRig()
        r.engine.sleep()
        let reads = r.hw.readCalls
        r.tick()
        #expect(r.hw.readCalls == reads && !r.engine.setMode(.manualRpm))
    }

    @Test func wakeFailureLeavesTheSystemInCharge() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.engine.sleep()
        r.applier.failRpm = true
        r.engine.wake()
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .writeFailed && r.engine.config.mode == .auto)
    }

    @Test func aFaultWhileControllingCancelsTheWakeResume() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.engine.sleep()
        r.engine.wake()
        r.thermalLevel = 2
        r.tick()
        r.engine.sleep()
        r.engine.wake()
        #expect(r.engine.state == .system)
    }

    @Test func quitRestoresAutoAndStops() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.engine.stop()
        #expect(r.engine.state == .stopped && r.hw.manual.isEmpty && !r.store.dirty && r.applier.calls.last == "auto:all")
    }

    @Test func quitWithNothingToRestoreWritesNothing() {
        let r = FanRig()
        r.engine.stop()
        #expect(r.applier.calls.isEmpty && r.engine.state == .stopped)
    }

    @Test func quitKeepsTheDirtyFlagWhenRestoreFails() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.applier.failAutoCount = 5
        r.engine.stop()
        #expect(r.store.dirty && r.engine.state == .stopped)
    }

    @Test func relaunchAfterACrashRestoresAuto() {
        let r = FanRig(start: false, configure: { $0.dirty = true })
        r.engine.start()
        #expect(r.applier.calls == ["auto:all"] && !r.store.dirty && r.engine.state == .system)
    }

    @Test func relaunchAfterAnUncleanQuitRetriesUntilItWorks() {
        let r = FanRig(start: false, configure: { $0.dirty = true })
        r.applier.failAutoCount = 2
        r.engine.start()
        #expect(r.engine.restorePending && r.store.dirty)
        r.tick(6)
        #expect(!r.engine.restorePending && !r.store.dirty)
    }

    @Test func relaunchWithoutResumeForgetsTheManualMode() {
        let r = FanRig(start: false, config: { $0.mode = .manualRpm; $0.manualRpm = 3000 })
        r.engine.start()
        #expect(r.engine.state == .system && r.engine.config.mode == .auto && r.applier.rpmWrites.isEmpty)
        #expect(FanSettingsStore(r.kv).load().mode == .auto)
    }

    @Test func relaunchWithResumeReappliesTheSavedMode() {
        let r = FanRig(start: false, config: { $0.mode = .manualRpm; $0.manualRpm = 3000; $0.resumeOnLaunch = true })
        r.engine.start()
        #expect(r.engine.state == .manual && r.lastRpm == 3000)
    }

    @Test func resumeThatFailsFallsBackToAuto() {
        let r = FanRig(start: false, config: { $0.mode = .manualRpm; $0.resumeOnLaunch = true })
        r.applier.failRpm = true
        r.engine.start()
        #expect(r.engine.state == .system && r.engine.config.mode == .auto)
    }
}

@Suite struct FanWatchdogTests {
    @Test func engineArmsTheWatchdogOnlyWhileControlling() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        #expect(!r.engine.watchdog.isArmed)
        _ = r.engine.setMode(.manualRpm)
        #expect(r.engine.watchdog.isArmed)
        _ = r.engine.setMode(.auto)
        #expect(!r.engine.watchdog.isArmed)
    }

    @Test func stalledEngineIsRescuedFromAnotherQueue() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.clock.advance(FanPolicy.watchdogTimeout + 1)
        #expect(r.engine.watchdog.check())
        #expect(r.applier.calls.last == "auto:all" && r.hw.manual.isEmpty)
        r.tick()
        #expect(r.engine.state == .system && r.engine.lastFault?.kind == .watchdog)
    }

    @Test func regularTicksKeepTheWatchdogQuiet() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        for _ in 0..<20 {
            r.tick(10)
            #expect(!r.engine.watchdog.check())
        }
        #expect(r.engine.state == .manual)
    }

    @Test func unarmedWatchdogNeverFires() {
        let r = FanRig()
        r.clock.advance(1000)
        #expect(!r.engine.watchdog.check() && r.applier.calls.isEmpty)
    }

    @Test func watchdogFiresOnlyOnce() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        r.clock.advance(100)
        #expect(r.engine.watchdog.check())
        #expect(!r.engine.watchdog.check())
        #expect(r.applier.autoCalls == 1)
    }

    @Test func failedRescueIsRetriedOnTheNextCheck() {
        let clock = FanFakeClock()
        var results = [false, true]
        var calls = 0
        let w = FanWatchdog(clock: clock, timeout: 5) { calls += 1; return results.removeFirst() }
        w.arm()
        clock.advance(10)
        #expect(w.check() && w.isArmed)
        #expect(w.check() && !w.isArmed)
        #expect(!w.check() && calls == 2)
    }

    @Test func tripIsConsumedOnce() {
        let clock = FanFakeClock()
        let w = FanWatchdog(clock: clock, timeout: 5) { true }
        w.arm()
        clock.advance(6)
        _ = w.check()
        #expect(w.consumeTrip() && !w.consumeTrip())
    }

    @Test func rearmingClearsAStaleTrip() {
        let clock = FanFakeClock()
        let w = FanWatchdog(clock: clock, timeout: 5) { true }
        w.arm()
        clock.advance(6)
        _ = w.check()
        w.arm()
        #expect(!w.consumeTrip())
    }
}

final class FanSpyApplier: FanApplying {
    let onRpm: () -> Void
    init(onRpm: @escaping () -> Void) { self.onRpm = onRpm }
    func setAuto(index: Int?) throws {}
    func setRpm(index: Int, rpm: Int) throws { onRpm() }
}
