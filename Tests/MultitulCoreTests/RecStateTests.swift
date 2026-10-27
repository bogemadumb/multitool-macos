import Testing
import Foundation
@testable import MultitulCore

@Suite struct RecStateTests {
    @Test func startsIdle() {
        let m = RecStateMachine()
        #expect(m.state == .idle && !m.state.isActive && !m.state.isCapturing)
    }

    @Test func startWithoutCountdownBeginsCapture() {
        var m = RecStateMachine()
        let t = m.send(.start(countdown: 0))
        #expect(t.accepted && t.to == .recording && t.effects == [.beginCapture])
    }

    @Test func startWithCountdownShowsHud() {
        var m = RecStateMachine()
        let t = m.send(.start(countdown: 3))
        #expect(t.to == .countdown(remaining: 3) && t.effects == [.showCountdown(3)])
    }

    @Test func countdownTicksDownThenRecords() {
        var m = RecStateMachine()
        m.send(.start(countdown: 2))
        #expect(m.send(.tick).to == .countdown(remaining: 1))
        let last = m.send(.tick)
        #expect(last.to == .recording && last.effects == [.hideCountdown, .beginCapture])
    }

    @Test func countdownUpdateEffectCarriesRemaining() {
        var m = RecStateMachine()
        m.send(.start(countdown: 5))
        #expect(m.send(.tick).effects == [.updateCountdown(4)])
    }

    @Test func cancelDuringCountdownReturnsToIdle() {
        var m = RecStateMachine()
        m.send(.start(countdown: 3))
        let t = m.send(.cancel)
        #expect(t.to == .idle && t.effects == [.hideCountdown])
    }

    @Test func pauseAndResume() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        #expect(m.send(.pause).to == .paused)
        #expect(m.state.isCapturing)
        let r = m.send(.resume)
        #expect(r.to == .recording && r.effects == [.resumeCapture])
    }

    @Test func pauseOnlyWhileRecording() {
        var m = RecStateMachine()
        #expect(!m.send(.pause).accepted)
        m.send(.start(countdown: 0))
        m.send(.pause)
        #expect(!m.send(.pause).accepted)
    }

    @Test func resumeOnlyFromPause() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        #expect(!m.send(.resume).accepted)
    }

    @Test func stopFromRecordingAndPausedGoesStopping() {
        var a = RecStateMachine()
        a.send(.start(countdown: 0))
        #expect(a.send(.stop).to == .stopping)
        var b = RecStateMachine()
        b.send(.start(countdown: 0))
        b.send(.pause)
        let t = b.send(.stop)
        #expect(t.to == .stopping && t.effects == [.endCapture(discard: false)])
    }

    @Test func finalizedDeliversResult() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        m.send(.stop)
        let t = m.send(.finalized)
        #expect(t.to == .finished && t.effects == [.deliverResult])
    }

    @Test func cancelWhileRecordingDiscards() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        let c = m.send(.cancel)
        #expect(c.to == .stopping && c.effects == [.endCapture(discard: true)] && m.discarding)
        let f = m.send(.finalized)
        #expect(f.to == .idle && f.effects == [.discardResult])
    }

    @Test func failureWhileRecordingEndsCaptureAndReports() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        let t = m.send(.fail("диск"))
        #expect(t.to == .failed("диск") && t.effects == [.endCapture(discard: false), .reportFailure("диск")])
    }

    @Test func failureDuringCountdownHidesHud() {
        var m = RecStateMachine()
        m.send(.start(countdown: 3))
        let t = m.send(.fail("нет доступа"))
        #expect(t.effects == [.hideCountdown, .reportFailure("нет доступа")])
    }

    @Test func failedStateAllowsNewStart() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        m.send(.fail("x"))
        #expect(m.send(.start(countdown: 0)).to == .recording)
    }

    @Test func finishedAllowsNewStartAndReset() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        m.send(.stop)
        m.send(.finalized)
        #expect(m.send(.reset).to == .idle)
        m.send(.start(countdown: 0))
        m.send(.stop)
        m.send(.finalized)
        #expect(m.send(.start(countdown: 0)).accepted)
    }

    @Test func cannotStartTwice() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        #expect(!m.send(.start(countdown: 0)).accepted)
        #expect(m.state == .recording)
    }

    @Test func rejectedActionsDoNotChangeCounter() {
        var m = RecStateMachine()
        m.send(.stop)
        m.send(.tick)
        m.send(.finalized)
        #expect(m.transitions == 0)
    }

    @Test func discardFlagClearsOnNextStart() {
        var m = RecStateMachine()
        m.send(.start(countdown: 0))
        m.send(.cancel)
        m.send(.finalized)
        m.send(.start(countdown: 0))
        m.send(.stop)
        #expect(m.send(.finalized).to == .finished)
    }

    @Test func stateTitlesAreRussian() {
        #expect(RecState.recording.title == "Идёт запись" && RecState.countdown(remaining: 3).title.contains("3"))
        #expect(RecState.failed("x").title == "Ошибка" && RecState.paused.title == "Пауза")
    }
}
