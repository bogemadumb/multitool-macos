import Testing
import Foundation
@testable import MultitulCore

private typealias F = ExtFix

@Suite struct IslTmrCountdownTests {
    @Test func startRunsForTheGivenDuration() {
        var c = IslTmrCountdown()
        c.start(duration: 600, now: F.now)
        #expect(c.phase == .running && c.remaining(at: F.now) == 600 && c.remaining(at: F.at(100)) == 500)
    }

    @Test func tickBeforeTheEndDoesNothing() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        #expect(!c.tick(now: F.at(59.9)) && c.phase == .running)
    }

    @Test func tickAtTheEndFinishesExactlyOnce() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        let tk1 = c.tick(now: F.at(60))
        #expect(tk1)
        let tk2 = c.tick(now: F.at(61))
        #expect(!tk2)
        #expect(c.phase == .finished && c.finishedAt == F.at(60) && c.remaining(at: F.at(100)) == 0)
    }

    @Test func lateTickRecordsTheRealEndNotTheTickTime() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        _ = c.tick(now: F.at(500))
        #expect(c.finishedAt == F.at(60))
    }

    @Test func pauseFreezesTheRemainingTime() {
        var c = IslTmrCountdown()
        c.start(duration: 600, now: F.now)
        c.pause(now: F.at(100))
        #expect(c.phase == .paused && c.remaining(at: F.at(5000)) == 500)
        let tk3 = c.tick(now: F.at(5000))
        #expect(!tk3)
    }

    @Test func resumeContinuesFromThePausedRemainder() {
        var c = IslTmrCountdown()
        c.start(duration: 600, now: F.now)
        c.pause(now: F.at(100))
        c.resume(now: F.at(1000))
        #expect(c.phase == .running && c.remaining(at: F.at(1100)) == 400)
        let tk4 = c.tick(now: F.at(1500))
        #expect(tk4)
    }

    @Test func pauseAndResumeAreIgnoredInTheWrongPhase() {
        var c = IslTmrCountdown()
        c.pause(now: F.now)
        c.resume(now: F.now)
        #expect(c.phase == .idle)
        c.start(duration: 10, now: F.now)
        c.resume(now: F.at(1))
        #expect(c.phase == .running)
    }

    @Test func durationIsClamped() {
        var c = IslTmrCountdown()
        c.start(duration: 0, now: F.now)
        #expect(c.total == 1)
        c.start(duration: 10_000_000, now: F.now)
        #expect(c.total == IslTmrCountdown.maxSeconds)
        c.start(duration: .nan, now: F.now)
        #expect(c.total == IslTmrCountdown.maxSeconds)
    }

    @Test func addingTimeExtendsARunningTimer() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        c.add(seconds: 60, now: F.at(10))
        #expect(c.remaining(at: F.at(10)) == 110 && c.total == 120)
    }

    @Test func subtractingMoreThanRemainingKeepsOneSecond() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        c.add(seconds: -600, now: F.at(10))
        #expect(c.remaining(at: F.at(10)) == 1)
    }

    @Test func addingTimeWorksWhilePaused() {
        var c = IslTmrCountdown()
        c.start(duration: 60, now: F.now)
        c.pause(now: F.at(10))
        c.add(seconds: 30, now: F.at(20))
        #expect(c.remaining(at: F.at(99)) == 80)
    }

    @Test func progressGrowsFromZeroToOne() {
        var c = IslTmrCountdown()
        #expect(c.progress(at: F.now) == 0)
        c.start(duration: 100, now: F.now)
        #expect(c.progress(at: F.at(25)) == 0.25)
        _ = c.tick(now: F.at(100))
        #expect(c.progress(at: F.at(200)) == 1)
    }

    @Test func resetReturnsToIdle() {
        var c = IslTmrCountdown()
        c.start(duration: 100, now: F.now)
        c.reset()
        #expect(c == IslTmrCountdown())
    }
}

@Suite struct IslTmrStopwatchTests {
    @Test func countsFromStart() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        #expect(s.elapsed(at: F.at(12.5)) == 12.5)
    }

    @Test func pauseStopsTheClockAndResumeContinues() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        s.pause(now: F.at(10))
        #expect(s.elapsed(at: F.at(100)) == 10)
        s.resume(now: F.at(200))
        #expect(s.elapsed(at: F.at(205)) == 15)
    }

    @Test func lapsRecordElapsedTimeAndSplits() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        s.lap(now: F.at(30))
        s.lap(now: F.at(50))
        #expect(s.laps == [30, 50] && s.lapSplits == [30, 20])
    }

    @Test func lapsAreIgnoredWhenNotRunning() {
        var s = IslTmrStopwatch()
        s.lap(now: F.now)
        s.start(now: F.now)
        s.pause(now: F.at(5))
        s.lap(now: F.at(6))
        #expect(s.laps.isEmpty)
    }

    @Test func lapCountIsCapped() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        for i in 0..<(IslTmrStopwatch.maxLaps + 10) { s.lap(now: F.at(Double(i))) }
        #expect(s.laps.count == IslTmrStopwatch.maxLaps)
    }

    @Test func startingARunningStopwatchDoesNotRestartIt() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        s.start(now: F.at(50))
        #expect(s.elapsed(at: F.at(60)) == 60)
    }

    @Test func resetClearsEverything() {
        var s = IslTmrStopwatch()
        s.start(now: F.now)
        s.lap(now: F.at(3))
        s.reset()
        #expect(s == IslTmrStopwatch() && s.elapsed(at: F.at(9)) == 0)
    }
}

@Suite struct IslTmrPomodoroTests {
    private let cfg = IslPomSettings()

    private func run(_ p: inout IslTmrPomodoro, to seconds: TimeInterval, settings: IslPomSettings) -> [IslPomEvent] {
        p.tick(now: F.at(seconds), settings: settings)
    }

    @Test func startsAFocusSession() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        #expect(p.phase == .focus && p.session == 1 && p.clock.remaining(at: F.now) == 1500)
    }

    @Test func focusEndsIntoAShortBreakAutomatically() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        let e = run(&p, to: 1500, settings: cfg)
        #expect(e == [IslPomEvent(finished: .focus, next: .shortBreak, autoStarted: true, at: F.at(1500))])
        #expect(p.phase == .shortBreak && p.clock.phase == .running && p.completedFocus == 1)
        #expect(p.clock.remaining(at: F.at(1500)) == 300)
    }

    @Test func breakEndsIntoTheNextFocusSession() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        _ = run(&p, to: 1500, settings: cfg)
        let e = run(&p, to: 1800, settings: cfg)
        #expect(e.first?.finished == .shortBreak && e.first?.next == .focus)
        #expect(p.phase == .focus && p.session == 2)
    }

    @Test func longBreakComesAfterTheConfiguredNumberOfSessions() {
        var p = IslTmrPomodoro()
        var s = cfg
        s.sessionsBeforeLong = 2
        p.start(now: F.now, settings: s)
        var t = 0.0
        var phases: [IslPomPhase] = []
        for _ in 0..<4 {
            t += s.duration(of: p.phase)
            phases += run(&p, to: t, settings: s).map(\.finished)
        }
        #expect(phases == [.focus, .shortBreak, .focus, .longBreak])
        #expect(p.phase == .focus && p.session == 1)
    }

    @Test func manualModeWaitsForTheNextStart() {
        var p = IslTmrPomodoro()
        var s = cfg
        s.autoStart = false
        p.start(now: F.now, settings: s)
        let e = run(&p, to: 1500, settings: s)
        #expect(e.count == 1 && e[0].autoStarted == false)
        #expect(p.phase == .shortBreak && p.clock.phase == .idle && p.waiting)
        p.start(now: F.at(2000), settings: s)
        #expect(p.clock.phase == .running && p.clock.remaining(at: F.at(2000)) == 300)
    }

    @Test func aLongSleepCatchesUpThroughSeveralPhases() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        let e = run(&p, to: 1500 + 300 + 1500 + 10, settings: cfg)
        #expect(e.map(\.finished) == [.focus, .shortBreak, .focus])
        #expect(p.phase == .shortBreak && p.completedFocus == 2)
    }

    @Test func pausedPomodoroDoesNotAdvance() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        p.pause(now: F.at(100))
        let none = run(&p, to: 9999, settings: cfg)
        #expect(none.isEmpty)
        p.resume(now: F.at(10_000))
        #expect(p.clock.remaining(at: F.at(10_000)) == 1400)
    }

    @Test func skipJumpsToTheNextPhase() {
        var p = IslTmrPomodoro()
        p.start(now: F.now, settings: cfg)
        p.skip(now: F.at(60), settings: cfg)
        #expect(p.phase == .shortBreak && p.clock.remaining(at: F.at(60)) == 300 && p.completedFocus == 0)
    }

    @Test func skipBeforeStartingDoesNothing() {
        var p = IslTmrPomodoro()
        p.skip(now: F.now, settings: cfg)
        #expect(p == IslTmrPomodoro())
    }

    @Test func settingsAreClampedAndDurationsMapToPhases() {
        var s = IslPomSettings()
        s.focusMinutes = 0
        s.shortMinutes = 999
        s.longMinutes = 5
        s.sessionsBeforeLong = 1
        let c = s.sanitized
        #expect(c.focusMinutes == 1 && c.shortMinutes == 60 && c.longMinutes == 5 && c.sessionsBeforeLong == 2)
        #expect(c.duration(of: .longBreak) == 300 && IslPomSettings().duration(of: .focus) == 1500)
    }

    @Test func labelShowsTheSessionNumber() {
        var p = IslTmrPomodoro()
        #expect(p.label(settings: cfg) == "Фокус 1/4")
        p.phase = .longBreak
        #expect(p.label(settings: cfg) == "Длинный перерыв")
    }
}

@Suite struct IslTmrHubTests {
    private func hub() -> IslTmrHub { IslTmrHub() }

    @Test func defaultTimerLengthIsFifteenMinutes() {
        var h = hub()
        h.startTimer(now: F.now)
        #expect(h.state.timer.remaining(at: F.now) == 900)
    }

    @Test func customMinutesAreClamped() {
        var h = hub()
        h.startTimer(minutes: 5000, now: F.now)
        #expect(h.state.timer.total == 600 * 60)
        h.startTimer(minutes: 0, now: F.now)
        #expect(h.state.timer.total == 60)
    }

    @Test func toggleCyclesStartPauseResume() {
        var h = hub()
        h.toggleTimer(now: F.now)
        #expect(h.state.timer.phase == .running)
        h.toggleTimer(now: F.at(10))
        #expect(h.state.timer.phase == .paused)
        h.toggleTimer(now: F.at(20))
        #expect(h.state.timer.phase == .running)
    }

    @Test func toggleAfterFinishRestarts() {
        var h = hub()
        h.startTimer(seconds: 5, now: F.now)
        _ = h.tick(now: F.at(6))
        h.toggleTimer(now: F.at(7))
        #expect(h.state.timer.phase == .running)
    }

    @Test func finishedTimerRaisesAnEventAndAnAlertActivity() {
        var h = hub()
        h.startTimer(seconds: 60, now: F.now)
        let e = h.tick(now: F.at(60))
        #expect(e == [.timerFinished(at: F.at(60))])
        let a = h.activity(now: F.at(61))
        #expect(a?.token.hasPrefix("done|") == true && a?.peeks == true && a?.title == "Таймер закончился")
    }

    @Test func alertActivityExpiresAfterEightSeconds() {
        var h = hub()
        h.startTimer(seconds: 60, now: F.now)
        _ = h.tick(now: F.at(60))
        #expect(h.activity(now: F.at(67.9)) != nil)
        _ = h.tick(now: F.at(68.1))
        #expect(h.activity(now: F.at(68.1)) == nil)
    }

    @Test func runningTimerIsAnActivityAtTimerPriority() {
        var h = hub()
        h.startTimer(seconds: 300, now: F.now)
        let a = h.activity(now: F.at(10))
        #expect(a?.priority == IslPriority.timer && a?.section == IslSectionIDs.timer && a?.peeks == false)
    }

    @Test func pausedTimerStaysVisibleWithAPauseToken() {
        var h = hub()
        h.startTimer(seconds: 300, now: F.now)
        h.toggleTimer(now: F.at(10))
        #expect(h.activity(now: F.at(20))?.token.hasPrefix("pause|timer") == true)
        #expect(h.primary(now: F.at(20))?.seconds == 290 && h.primary(now: F.at(20))?.running == false)
    }

    @Test func nothingRunningMeansNoActivity() {
        #expect(hub().activity(now: F.now) == nil && hub().primary(now: F.now) == nil && !hub().anyActive)
    }

    @Test func primaryPrefersTheSoonestEnding() {
        var h = hub()
        h.startTimer(seconds: 3000, now: F.now)
        h.togglePomodoro(now: F.now)
        #expect(h.primary(now: F.now)?.kind == .pomodoro)
        h.startTimer(seconds: 60, now: F.now)
        #expect(h.primary(now: F.now)?.kind == .timer)
    }

    @Test func stopwatchIsTheLastResort() {
        var h = hub()
        h.toggleStopwatch(now: F.now)
        #expect(h.primary(now: F.at(5))?.kind == .stopwatch && h.primary(now: F.at(5))?.seconds == 5)
        h.startTimer(seconds: 500, now: F.now)
        #expect(h.primary(now: F.at(5))?.kind == .timer)
    }

    @Test func pomodoroPhaseChangeProducesATitleAndANewToken() {
        var h = hub()
        h.togglePomodoro(now: F.now)
        let t1 = h.activity(now: F.at(10))?.token
        let e = h.tick(now: F.at(1500))
        #expect(e.count == 1 && e[0].title.contains("короткий перерыв"))
        let t2 = h.activity(now: F.at(1509))?.token
        #expect(t1 != t2)
    }

    @Test func breakEndTitleCallsBackToWork() {
        var h = hub()
        h.togglePomodoro(now: F.now)
        _ = h.tick(now: F.at(1500))
        let e = h.tick(now: F.at(1800))
        #expect(e[0].title == "Перерыв закончился: пора за работу")
    }

    @Test func resetClearsOnlyTheChosenMachine() {
        var h = hub()
        h.startTimer(seconds: 100, now: F.now)
        h.toggleStopwatch(now: F.now)
        h.reset(.timer)
        #expect(h.state.timer.phase == .idle && h.state.stopwatch.phase == .running)
    }

    @Test func settingsUpdateIsSanitized() {
        var h = hub()
        var s = IslTmrSettings()
        s.sound = "Nope"
        s.defaultMinutes = 0
        h.updateSettings(s)
        #expect(h.settings.sound == "Glass" && h.settings.defaultMinutes == 1)
    }

    @Test func clockMovingBackwardDismissesTheAlert() {
        var h = hub()
        h.startTimer(seconds: 5, now: F.now)
        _ = h.tick(now: F.at(5))
        _ = h.tick(now: F.at(-100))
        #expect(h.activity(now: F.at(-100)) == nil)
    }
}

@Suite struct IslTmrSettingsAndPersistenceTests {
    @Test func defaultsWriteNothing() {
        let kv = WndMemoryStore()
        IslTmrSettingsStore(kv).save(IslTmrSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func settingsRoundTrip() {
        let kv = WndMemoryStore()
        var s = IslTmrSettings()
        s.defaultMinutes = 45
        s.hideCountdown = true
        s.soundEnabled = false
        s.sound = "Hero"
        s.soundRepeats = 3
        s.pomodoro.focusMinutes = 50
        s.pomodoro.autoStart = false
        IslTmrSettingsStore(kv).save(s)
        #expect(IslTmrSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("notch.timer.") })
    }

    @Test func unknownSoundFallsBack() {
        let kv = WndMemoryStore()
        kv.set("Dubstep", forKey: "notch.timer.sound")
        #expect(IslTmrSettingsStore(kv).load().sound == "Glass")
    }

    @Test func stateSurvivesARestart() {
        let kv = WndMemoryStore()
        var h = IslTmrHub()
        h.startTimer(seconds: 600, now: F.now)
        h.toggleStopwatch(now: F.now)
        IslTmrPersistence(kv).save(h.state)
        var restored = IslTmrHub(state: IslTmrPersistence(kv).load())
        #expect(restored.state.timer.remaining(at: F.at(100)) == 500)
        #expect(restored.state.stopwatch.elapsed(at: F.at(100)) == 100)
        let quiet = restored.tick(now: F.at(100))
        #expect(quiet.isEmpty)
    }

    @Test func idleStateClearsTheStoredValue() {
        let kv = WndMemoryStore()
        var h = IslTmrHub()
        h.startTimer(seconds: 5, now: F.now)
        IslTmrPersistence(kv).save(h.state)
        #expect(kv.values[IslTmrPersistence.keyForTests] != nil)
        IslTmrPersistence(kv).save(IslTmrState())
        #expect(kv.values.isEmpty)
    }

    @Test func garbageStateLoadsAsIdle() {
        let kv = WndMemoryStore()
        kv.set("{not json", forKey: IslTmrPersistence.keyForTests)
        #expect(IslTmrPersistence(kv).load() == IslTmrState())
    }

    @Test func timerFinishedWhileQuitFinishesAtItsOriginalEndTime() {
        let kv = WndMemoryStore()
        var h = IslTmrHub()
        h.startTimer(seconds: 60, now: F.now)
        IslTmrPersistence(kv).save(h.state)
        var restored = IslTmrHub(state: IslTmrPersistence(kv).load())
        let events = restored.tick(now: F.at(3600))
        #expect(events.count == 1)
        #expect(restored.state.timer.finishedAt == F.at(60))
    }

    @Test func formatsClockAndStopwatch() {
        #expect(IslTmrFormat.clock(125) == "2:05")
        #expect(IslTmrFormat.stopwatch(61.257) == "1:01.25")
        #expect(IslTmrFormat.parseMinutes(" 25 ") == 25)
        #expect(IslTmrFormat.parseMinutes("0") == nil && IslTmrFormat.parseMinutes("abc") == nil && IslTmrFormat.parseMinutes("601") == nil)
    }

    @Test func hotkeysAreAsciiAndUnassigned() {
        for h in IslTmrHotkeys.all {
            #expect(h.id.allSatisfy(\.isASCII) && h.defaultCombo.isNone)
        }
        #expect(ModuleID.notchTimer.info.hotkeys == IslTmrHotkeys.all)
    }
}
