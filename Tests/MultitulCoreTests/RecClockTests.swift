import Testing
import Foundation
@testable import MultitulCore

private func outOf(_ r: RecRoute) -> Double? {
    if case .write(let o, _) = r { return o }
    return nil
}

private func approx(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool { a.map { abs($0 - b) < eps } ?? false }

@Suite struct RecPauseClockTests {
    @Test func timelineIsRelativeToOrigin() {
        var c = RecPauseClock()
        c.begin(at: 100)
        #expect(approx(c.timeline(for: 100), 0) && approx(c.timeline(for: 103.5), 3.5))
    }

    @Test func samplesBeforeOriginHaveNoTimeline() {
        var c = RecPauseClock()
        c.begin(at: 100)
        #expect(c.timeline(for: 99.9) == nil)
    }

    @Test func notStartedClockMapsNothing() {
        let c = RecPauseClock()
        #expect(c.timeline(for: 5) == nil && !c.isStarted && c.elapsed(at: 5) == 0)
    }

    @Test func pauseGapIsRemovedFromLaterSamples() {
        var c = RecPauseClock()
        c.begin(at: 10)
        c.pause(at: 12)
        c.resume(at: 17)
        #expect(approx(c.timeline(for: 11), 1))
        #expect(approx(c.timeline(for: 17), 2))
        #expect(approx(c.timeline(for: 20), 5))
    }

    @Test func samplesInsideGapAreDropped() {
        var c = RecPauseClock()
        c.begin(at: 10)
        c.pause(at: 12)
        c.resume(at: 17)
        #expect(c.timeline(for: 12) == nil && c.timeline(for: 15) == nil && c.timeline(for: 16.999) == nil)
        #expect(c.timeline(for: 17) != nil)
    }

    @Test func openGapDropsEverythingAfterPause() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 5)
        #expect(c.isPaused && c.timeline(for: 6) == nil && approx(c.timeline(for: 4), 4))
    }

    @Test func severalPausesAccumulate() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 2); c.resume(at: 3)
        c.pause(at: 5); c.resume(at: 8)
        #expect(approx(c.timeline(for: 10), 6))
        #expect(approx(c.pausedTotal(before: 10), 4))
    }

    @Test func lateArrivingSampleBeforePauseKeepsItsTime() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 5)
        c.resume(at: 9)
        #expect(approx(c.timeline(for: 4.9), 4.9))
    }

    @Test func elapsedExcludesPausesWhileRunning() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 4)
        c.resume(at: 6)
        #expect(approx(c.elapsed(at: 10), 8))
    }

    @Test func elapsedFreezesWhilePaused() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 4)
        #expect(approx(c.elapsed(at: 9), 4))
    }

    @Test func stopClosesOpenGapAndFixesDuration() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 4)
        c.stop(at: 10)
        #expect(approx(c.finalDuration(), 4))
        #expect(c.timeline(for: 11) == nil)
    }

    @Test func finalDurationWithPauses() {
        var c = RecPauseClock()
        c.begin(at: 100)
        c.pause(at: 110); c.resume(at: 115)
        c.stop(at: 130)
        #expect(approx(c.finalDuration(), 25))
        #expect(approx(c.totalPaused, 5))
    }

    @Test func doublePauseAndResumeAreIgnored() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.resume(at: 1)
        c.pause(at: 2)
        c.pause(at: 3)
        c.resume(at: 4)
        c.resume(at: 5)
        #expect(c.gaps.count == 1 && approx(c.timeline(for: 6), 4))
    }

    @Test func pauseBeforeBeginIsIgnored() {
        var c = RecPauseClock()
        c.pause(at: 3)
        #expect(c.gaps.isEmpty)
    }

    @Test func beginResetsPreviousSession() {
        var c = RecPauseClock()
        c.begin(at: 0)
        c.pause(at: 1); c.resume(at: 2)
        c.begin(at: 50)
        #expect(c.gaps.isEmpty && approx(c.timeline(for: 51), 1))
    }
}

@Suite struct RecSampleRouterTests {
    private func router(_ kinds: Set<RecTrackKind> = [.video, .systemAudio, .microphone]) -> RecSampleRouter {
        var r = RecSampleRouter(enabled: kinds)
        r.begin(at: 100)
        return r
    }

    @Test func videoIsRetimedToZero() {
        var r = router()
        #expect(approx(outOf(r.route(.video, pts: 100.2, duration: 0.033)), 0.2))
    }

    @Test func disabledTrackIsDropped() {
        var r = router([.video])
        #expect(r.route(.microphone, pts: 101, duration: 0.02) == .drop(.trackDisabled))
    }

    @Test func notStartedRouterDrops() {
        var r = RecSampleRouter(enabled: [.video])
        #expect(r.route(.video, pts: 1, duration: 0.03) == .drop(.notStarted))
    }

    @Test func videoBeforeOriginIsDropped() {
        var r = router()
        #expect(r.route(.video, pts: 99.9, duration: 0.03) == .drop(.beforeOrigin))
    }

    @Test func audioStraddlingOriginIsTrimmed() {
        var r = router()
        let x = r.route(.systemAudio, pts: 99.98, duration: 0.05)
        if case .write(let out, let trim) = x {
            #expect(abs(out) < 1e-9 && abs(trim - 0.02) < 1e-6)
        } else {
            Issue.record("expected write")
        }
    }

    @Test func audioEndingBeforeOriginIsDropped() {
        var r = router()
        #expect(r.route(.systemAudio, pts: 99.9, duration: 0.05) == .drop(.beforeOrigin))
    }

    @Test func pauseDropsAndCountsSamples() {
        var r = router()
        r.pause(at: 105)
        #expect(r.route(.video, pts: 106, duration: 0.03) == .drop(.paused))
        #expect(r.route(.systemAudio, pts: 107, duration: 0.02) == .drop(.paused))
        #expect(r.stat(.video).droppedPaused == 1 && r.stat(.systemAudio).dropped == 1)
    }

    @Test func resumeShiftsFollowingSamplesBackByTheGap() {
        var r = router()
        r.pause(at: 105)
        r.resume(at: 110)
        #expect(approx(outOf(r.route(.video, pts: 110.1, duration: 0.03)), 5.1))
        #expect(approx(outOf(r.route(.systemAudio, pts: 110.1, duration: 0.02)), 5.1))
    }

    @Test func videoAndAudioShareTheSameTimeline() {
        var r = router()
        r.pause(at: 101); r.resume(at: 104)
        let v = r.route(.video, pts: 105, duration: 0.03)
        let a = r.route(.microphone, pts: 105, duration: 0.02)
        #expect(v == a)
    }

    @Test func nonMonotonicSamplesAreDropped() {
        var r = router()
        _ = r.route(.video, pts: 100.5, duration: 0.03)
        #expect(r.route(.video, pts: 100.5, duration: 0.03) == .drop(.nonMonotonic))
        #expect(r.route(.video, pts: 100.4, duration: 0.03) == .drop(.nonMonotonic))
        #expect(r.route(.video, pts: 100.6, duration: 0.03) != .drop(.nonMonotonic))
    }

    @Test func tracksHaveIndependentMonotonicity() {
        var r = router()
        _ = r.route(.video, pts: 101, duration: 0.03)
        #expect(approx(outOf(r.route(.systemAudio, pts: 100.5, duration: 0.02)), 0.5))
    }

    @Test func samplesAfterStopAreDropped() {
        var r = router()
        r.stop(at: 110)
        #expect(r.route(.video, pts: 111, duration: 0.03) == .drop(.afterStop))
        #expect(r.route(.video, pts: 109, duration: 0.03) != .drop(.afterStop))
    }

    @Test func invalidValuesAreDropped() {
        var r = router()
        #expect(r.route(.video, pts: .nan, duration: 0.03) == .drop(.invalid))
        #expect(r.route(.video, pts: 101, duration: -1) == .drop(.invalid))
        #expect(r.route(.video, pts: .infinity, duration: 0) == .drop(.invalid))
    }

    @Test func statsCountWrittenAndLastEnd() {
        var r = router()
        _ = r.route(.video, pts: 101, duration: 0.5)
        _ = r.route(.video, pts: 102, duration: 0.5)
        #expect(r.stat(.video).written == 2 && abs(r.stat(.video).lastEnd - 2.5) < 1e-9)
    }

    @Test func avDriftMeasuresEndDifference() {
        var r = router()
        _ = r.route(.video, pts: 101, duration: 1)
        _ = r.route(.systemAudio, pts: 101, duration: 1.2)
        #expect(abs((r.avDrift(audio: .systemAudio) ?? 99) - 0.2) < 1e-9)
        #expect(r.avDrift(audio: .microphone) == nil)
    }

    @Test func durationAfterStopMatchesClock() {
        var r = router()
        r.pause(at: 102); r.resume(at: 104)
        r.stop(at: 108)
        #expect(abs((r.duration ?? 0) - 6) < 1e-9)
    }

    @Test func longSessionKeepsPrecision() {
        var r = RecSampleRouter(enabled: [.video])
        r.begin(at: 1_000_000)
        guard case .write(let out, _) = r.route(.video, pts: 1_000_000 + 3600.016, duration: 0.016) else { Issue.record("dropped"); return }
        #expect(abs(out - 3600.016) < 1e-6)
    }
}

@Suite struct RecTimeFormatTests {
    @Test func clockFormats() {
        #expect(RecTimeFormat.clock(0) == "00:00" && RecTimeFormat.clock(65.9) == "01:05" && RecTimeFormat.clock(3725) == "1:02:05")
        #expect(RecTimeFormat.clock(-3) == "00:00")
    }

    @Test func preciseFormat() {
        #expect(RecTimeFormat.precise(5.256) == "00:05.25" && RecTimeFormat.precise(61.5) == "01:01.50")
    }

    @Test func byteFormat() {
        #expect(RecTimeFormat.bytes(500_000) == "500 КБ" && RecTimeFormat.bytes(12_500_000) == "12.5 МБ" && RecTimeFormat.bytes(2_300_000_000) == "2.30 ГБ")
    }
}
