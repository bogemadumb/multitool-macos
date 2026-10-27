import Testing
import Foundation
@testable import MultitulCore

private func act(_ id: String, _ section: String = "music", p: Int = 50, s: TimeInterval = 0, e: TimeInterval? = nil, urgent: Bool = false, peeks: Bool = false, token: String = "") -> IslActivity {
    IslFix.activity(id, section, priority: p, started: s, expires: e, urgent: urgent, peeks: peeks, token: token)
}

@Suite struct IslArbiterTests {
    @Test func nothingMeansNoWinner() {
        var a = IslArbiter()
        let r = a.resolve([], now: IslFix.at(0))
        #expect(r.winner == nil && r.ranked.isEmpty && !r.shouldPeek && !r.changed)
    }

    @Test func singleActivityWins() {
        var a = IslArbiter()
        let r = a.resolve([act("music")], now: IslFix.at(0))
        #expect(r.winner?.id == "music" && r.changed)
        #expect(a.currentID == "music")
    }

    @Test func higherPriorityWins() {
        var a = IslArbiter()
        let r = a.resolve([act("music", p: 50), act("recording", "shots", p: 90)], now: IslFix.at(0))
        #expect(r.winner?.id == "recording")
        #expect(r.secondary?.id == "music")
        #expect(r.ranked.map(\.id) == ["recording", "music"])
    }

    @Test func urgentBeatsHigherPriority() {
        var a = IslArbiter()
        let r = a.resolve([act("timer", "timer", p: 100), act("rec", "shots", p: 10, urgent: true)], now: IslFix.at(0))
        #expect(r.winner?.id == "rec")
    }

    @Test func equalPriorityPrefersTheNewest() {
        var a = IslArbiter()
        let r = a.resolve([act("a", p: 50, s: 1), act("b", "levels", p: 50, s: 5)], now: IslFix.at(10))
        #expect(r.winner?.id == "b")
    }

    @Test func idTieBreakIsDeterministic() {
        var a = IslArbiter()
        let r = a.resolve([act("b", p: 50, s: 1), act("a", "levels", p: 50, s: 1)], now: IslFix.at(10))
        #expect(r.winner?.id == "a")
    }

    @Test func currentWinnerIsStickyAtEqualPriority() {
        var a = IslArbiter()
        _ = a.resolve([act("a", p: 50, s: 0)], now: IslFix.at(1))
        let r = a.resolve([act("a", p: 50, s: 0), act("b", "levels", p: 50, s: 5)], now: IslFix.at(6))
        #expect(r.winner?.id == "a")
        #expect(!r.changed)
    }

    @Test func strictlyHigherPriorityPreempts() {
        var a = IslArbiter()
        _ = a.resolve([act("music")], now: IslFix.at(1))
        let r = a.resolve([act("music"), act("shot", "shots", p: 60, s: 2, e: 5)], now: IslFix.at(3))
        #expect(r.winner?.id == "shot" && r.changed)
    }

    @Test func expiredTransientHandsBackToMusic() {
        var a = IslArbiter()
        _ = a.resolve([act("music")], now: IslFix.at(1))
        _ = a.resolve([act("music"), act("shot", "shots", p: 60, s: 2, e: 5)], now: IslFix.at(3))
        let r = a.resolve([act("music"), act("shot", "shots", p: 60, s: 2, e: 5)], now: IslFix.at(5))
        #expect(r.winner?.id == "music" && r.changed)
    }

    @Test func expiredActivitiesAreDroppedFromTheRanking() {
        var a = IslArbiter()
        let r = a.resolve([act("x", e: 1)], now: IslFix.at(1))
        #expect(r.winner == nil && r.ranked.isEmpty)
    }

    @Test func urgentPreemptsANonUrgentCurrent() {
        var a = IslArbiter()
        _ = a.resolve([act("timer", "timer", p: 80)], now: IslFix.at(1))
        let r = a.resolve([act("timer", "timer", p: 80), act("rec", "shots", p: 5, urgent: true)], now: IslFix.at(2))
        #expect(r.winner?.id == "rec")
    }

    @Test func mutedSectionsNeverWin() {
        var a = IslArbiter()
        let r = a.resolve([act("music"), act("hud", "levels", p: 70)], now: IslFix.at(0), muted: ["levels"])
        #expect(r.winner?.id == "music" && r.ranked.count == 1)
    }

    @Test func duplicateIdsKeepTheNewest() {
        var a = IslArbiter()
        let r = a.resolve([act("music", s: 1, token: "old"), act("music", s: 4, token: "new")], now: IslFix.at(5))
        #expect(r.ranked.count == 1 && r.winner?.token == "new")
    }

    @Test func firstResolveNeverPeeks() {
        var a = IslArbiter()
        let r = a.resolve([act("music", peeks: true, token: "t1")], now: IslFix.at(0))
        #expect(!r.shouldPeek)
    }

    @Test func newTokenPeeks() {
        var a = IslArbiter()
        _ = a.resolve([act("music", peeks: true, token: "t1")], now: IslFix.at(0))
        #expect(!a.resolve([act("music", peeks: true, token: "t1")], now: IslFix.at(1)).shouldPeek)
        #expect(a.resolve([act("music", peeks: true, token: "t2")], now: IslFix.at(2)).shouldPeek)
        #expect(!a.resolve([act("music", peeks: true, token: "t2")], now: IslFix.at(3)).shouldPeek)
    }

    @Test func nonPeekingActivitiesStayQuiet() {
        var a = IslArbiter()
        _ = a.resolve([], now: IslFix.at(0))
        #expect(!a.resolve([act("music", peeks: false, token: "x")], now: IslFix.at(1)).shouldPeek)
    }

    @Test func aNewWinnerPeeksEvenWithTheSameToken() {
        var a = IslArbiter()
        _ = a.resolve([act("music", peeks: true, token: "t")], now: IslFix.at(0))
        let r = a.resolve([act("music", peeks: true, token: "t"), act("shot", "shots", p: 60, s: 1, e: 9, peeks: true, token: "7")], now: IslFix.at(1))
        #expect(r.winner?.id == "shot" && r.shouldPeek)
    }

    @Test func reappearingActivityPeeksAgain() {
        var a = IslArbiter()
        _ = a.resolve([act("music", peeks: true, token: "t")], now: IslFix.at(0))
        _ = a.resolve([], now: IslFix.at(1))
        #expect(a.resolve([act("music", peeks: true, token: "t")], now: IslFix.at(2)).shouldPeek)
    }

    @Test func resetForgetsEverything() {
        var a = IslArbiter()
        _ = a.resolve([act("music", peeks: true, token: "t")], now: IslFix.at(0))
        a.reset()
        #expect(a.currentID == nil)
        #expect(!a.resolve([act("music", peeks: true, token: "t")], now: IslFix.at(1)).shouldPeek)
    }

    @Test func activityExpiryBoundary() {
        let x = act("x", e: 5)
        #expect(!x.isExpired(at: IslFix.at(4.99)) && x.isExpired(at: IslFix.at(5)))
        #expect(!act("y").isExpired(at: IslFix.at(1e6)))
    }
}

@Suite struct IslActivityFactoryTests {
    @Test func pausedMusicHasNoActivity() {
        var m = IslNowPlayingModel()
        m.apply(IslFix.info(playing: false), now: IslFix.at(0))
        #expect(IslActivityFactory.music(m.value, now: IslFix.at(1)) == nil)
    }

    @Test func playingMusicProducesAPeekingActivity() throws {
        var m = IslNowPlayingModel()
        m.apply(IslFix.info("Hello", playing: true), now: IslFix.at(0))
        let a = try #require(IslActivityFactory.music(m.value, now: IslFix.at(1)))
        #expect(a.section == IslSectionIDs.music && a.priority == IslPriority.music && a.peeks && a.title == "Hello")
    }

    @Test func tokenChangesWithTheTrack() throws {
        var m = IslNowPlayingModel()
        m.apply(IslFix.info("A"), now: IslFix.at(0))
        let a = try #require(IslActivityFactory.music(m.value, now: IslFix.at(1)))
        m.apply(IslFix.info("B"), now: IslFix.at(2))
        let b = try #require(IslActivityFactory.music(m.value, now: IslFix.at(3)))
        #expect(a.token != b.token)
    }

    @Test func priorityLadderIsOrdered() {
        #expect(IslPriority.ambient < IslPriority.music && IslPriority.music < IslPriority.transient && IslPriority.transient < IslPriority.levelsHud)
        #expect(IslPriority.levelsHud < IslPriority.timer && IslPriority.timer < IslPriority.recording && IslPriority.recording < IslPriority.critical)
    }
}

@Suite struct IslShotTrackerTests {
    @Test func captureProducesAShortLivedActivity() throws {
        var t = IslShotTracker()
        t.apply(.captured(id: 5, mode: .area), now: IslFix.at(0))
        let a = try #require(t.activities(now: IslFix.at(1)).first)
        #expect(a.id == "shot" && a.token == "5" && a.peeks)
        #expect(t.activities(now: IslFix.at(4)).isEmpty)
    }

    @Test func recordingIsUrgentAndLasts() throws {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        let a = try #require(t.activities(now: IslFix.at(600)).first)
        #expect(a.id == "recording" && a.urgent && a.priority == IslPriority.recording)
    }

    @Test func elapsedFollowsTheClockAndFreezesOnPause() {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        #expect(t.elapsed(at: IslFix.at(10)) == 10)
        t.apply(.recordingPaused, now: IslFix.at(10))
        #expect(t.elapsed(at: IslFix.at(40)) == 10)
        t.apply(.recordingResumed, now: IslFix.at(40))
        #expect(t.elapsed(at: IslFix.at(45)) == 15)
    }

    @Test func pausedRecordingChangesTheToken() throws {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        let a = try #require(t.activities(now: IslFix.at(1)).first)
        t.apply(.recordingPaused, now: IslFix.at(2))
        let b = try #require(t.activities(now: IslFix.at(3)).first)
        #expect(a.token != b.token)
    }

    @Test func stoppingEndsTheRecordingAndLeavesANote() throws {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        t.apply(.recordingStopped(path: "/x.mov"), now: IslFix.at(5))
        #expect(!t.recording && t.elapsed(at: IslFix.at(6)) == 0)
        let a = try #require(t.activities(now: IslFix.at(6)).first)
        #expect(a.id == "shot.note" && a.title == "Запись сохранена")
        #expect(t.activities(now: IslFix.at(9)).isEmpty)
    }

    @Test func failureEndsTheRecordingToo() {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        t.apply(.recordingFailed(reason: "x"), now: IslFix.at(1))
        #expect(!t.recording && t.note == "Запись не удалась")
    }

    @Test func pauseWithoutRecordingIsIgnored() {
        var t = IslShotTracker()
        t.apply(.recordingPaused, now: IslFix.at(0))
        t.apply(.recordingResumed, now: IslFix.at(1))
        #expect(!t.recording && !t.paused)
    }

    @Test func copyAndLinkLeaveNotes() {
        var t = IslShotTracker()
        t.apply(.copied, now: IslFix.at(0))
        #expect(t.note == "Скопировано")
        t.apply(.linked(url: "https://x"), now: IslFix.at(1))
        #expect(t.note == "Ссылка скопирована")
    }

    @Test func deletionLeavesNoTrace() {
        var t = IslShotTracker()
        t.apply(.deleted(id: 1), now: IslFix.at(0))
        #expect(t.activities(now: IslFix.at(0.5)).isEmpty)
    }

    @Test func captureAndRecordingCoexistInTheArbiter() {
        var t = IslShotTracker()
        t.apply(.recordingStarted, now: IslFix.at(0))
        t.apply(.captured(id: 1, mode: .screen), now: IslFix.at(2))
        var arb = IslArbiter()
        let r = arb.resolve(t.activities(now: IslFix.at(3)), now: IslFix.at(3))
        #expect(r.winner?.id == "recording" && r.ranked.count == 2)
    }
}
