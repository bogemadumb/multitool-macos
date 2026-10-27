import Testing
import Foundation
@testable import MultitulCore

private func model(_ i: IslNowPlayingInfo, at t: TimeInterval = 0) -> IslNowPlayingModel {
    var m = IslNowPlayingModel()
    m.apply(i, now: IslFix.at(t))
    return m
}

@Suite struct IslElapsedTests {
    @Test func elapsedAdvancesWithRealTimeWhilePlaying() {
        let m = model(IslFix.info(elapsed: 10))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 10)
        #expect(m.value.elapsed(at: IslFix.at(5)) == 15)
    }

    @Test func pausedElapsedStaysPut() {
        let m = model(IslFix.info(elapsed: 42, playing: false))
        #expect(m.value.elapsed(at: IslFix.at(60)) == 42)
    }

    @Test func rateScalesTheInterpolation() {
        var i = IslFix.info(elapsed: 10)
        i.rate = 2
        let m = model(i)
        #expect(m.value.elapsed(at: IslFix.at(4)) == 18)
    }

    @Test func playingWithZeroRateAssumesNormalSpeed() {
        var i = IslFix.info(elapsed: 10)
        i.rate = 0
        i.isPlaying = true
        let m = model(i)
        #expect(m.value.rate == 1)
        #expect(m.value.elapsed(at: IslFix.at(3)) == 13)
    }

    @Test func missingPlayFlagIsDerivedFromTheRate() {
        var i = IslFix.info(elapsed: 5)
        i.isPlaying = nil
        i.rate = 1.5
        #expect(model(i).value.isPlaying)
        i.rate = 0
        #expect(!model(i).value.isPlaying)
    }

    @Test func timestampInThePastAddsTheGap() {
        let m = model(IslFix.info(elapsed: 10, timestamp: IslFix.at(-4)))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 14)
    }

    @Test func timestampInTheFutureIsClamped() {
        let m = model(IslFix.info(elapsed: 10, timestamp: IslFix.at(30)))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 10)
    }

    @Test func pausedTimestampDoesNotAddTheGap() {
        let m = model(IslFix.info(elapsed: 10, playing: false, timestamp: IslFix.at(-50)))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 10)
    }

    @Test func elapsedIsClampedToTheDuration() {
        let m = model(IslFix.info(duration: 100, elapsed: 98))
        #expect(m.value.elapsed(at: IslFix.at(50)) == 100)
        #expect(m.value.progress(at: IslFix.at(50)) == 1)
        #expect(m.value.remaining(at: IslFix.at(50)) == 0)
    }

    @Test func progressIsAFraction() {
        let m = model(IslFix.info(duration: 200, elapsed: 50, playing: false))
        #expect(m.value.progress(at: IslFix.at(0)) == 0.25)
        #expect(m.value.remaining(at: IslFix.at(0)) == 150)
    }

    @Test func unknownDurationMeansNoProgress() {
        let m = model(IslFix.info(duration: nil, elapsed: 50))
        #expect(m.value.progress(at: IslFix.at(1)) == 0)
        #expect(m.value.remaining(at: IslFix.at(1)) == nil)
        #expect(m.value.elapsed(at: IslFix.at(10)) == 60)
    }

    @Test func missingElapsedStartsAtZeroForANewTrack() {
        let m = model(IslFix.info(elapsed: nil))
        #expect(m.value.elapsed(at: IslFix.at(3)) == 3)
    }

    @Test func missingElapsedKeepsTheProjectionOfTheSameTrack() {
        var m = model(IslFix.info(elapsed: 20))
        m.apply(IslFix.info(elapsed: nil), now: IslFix.at(5))
        #expect(m.value.elapsed(at: IslFix.at(5)) == 25)
    }

    @Test func negativeElapsedIsNeverReported() {
        var m = IslNowPlayingModel()
        var i = IslFix.info(elapsed: 0, timestamp: nil)
        i.elapsed = -5
        m.apply(i, now: IslFix.at(0))
        #expect(m.value.elapsed(at: IslFix.at(0)) >= 0)
    }
}

@Suite struct IslTrackChangeTests {
    @Test func firstTrackFlagsEverything() {
        var m = IslNowPlayingModel()
        let c = m.apply(IslFix.info(), now: IslFix.at(0))
        #expect(c.contains(.track) && c.contains(.playback) && !c.contains(.app))
    }

    @Test func sameInfoAgainChangesNothing() {
        var m = model(IslFix.info(elapsed: 10))
        let c = m.apply(IslFix.info(elapsed: 11), now: IslFix.at(1))
        #expect(c.isEmpty)
    }

    @Test func newTitleIsATrackChange() {
        var m = model(IslFix.info("A"))
        #expect(m.apply(IslFix.info("B"), now: IslFix.at(1)).contains(.track))
    }

    @Test func trackChangeResetsTheClock() {
        var m = model(IslFix.info("A", elapsed: 150))
        m.apply(IslFix.info("B", elapsed: nil), now: IslFix.at(1))
        #expect(m.value.elapsed(at: IslFix.at(1)) == 0)
    }

    @Test func whitespaceAndCaseDoNotCountAsAChange() {
        var m = model(IslFix.info("Hello  World"))
        #expect(m.apply(IslFix.info("hello world"), now: IslFix.at(1)).isEmpty)
    }

    @Test func playPauseIsAPlaybackChange() {
        var m = model(IslFix.info(playing: true))
        let c = m.apply(IslFix.info(playing: false), now: IslFix.at(1))
        #expect(c == [.playback])
        #expect(!m.value.isPlaying)
    }

    @Test func rateChangeIsAPlaybackChange() {
        var m = model(IslFix.info())
        var i = IslFix.info()
        i.rate = 2
        #expect(m.apply(i, now: IslFix.at(1)).contains(.playback))
    }

    @Test func switchingTheAppIsDetected() {
        var m = model(IslFix.info("A", bundle: "com.apple.Music"))
        let c = m.apply(IslFix.info("A", bundle: "com.spotify.client"), now: IslFix.at(1))
        #expect(c.contains(.app) && c.contains(.track))
        #expect(m.value.track?.bundleID == "com.spotify.client")
    }

    @Test func appSwitchChangesTheArtworkKey() {
        var m = model(IslFix.info("A", bundle: "com.apple.Music"))
        let before = m.value.track?.artworkKey
        m.apply(IslFix.info("A", bundle: "com.spotify.client"), now: IslFix.at(1))
        #expect(m.value.track?.artworkKey != before)
    }

    @Test func largeJumpIsASeek() {
        var m = model(IslFix.info(elapsed: 10))
        let c = m.apply(IslFix.info(elapsed: 90), now: IslFix.at(1))
        #expect(c.contains(.seeked))
        #expect(m.value.elapsed(at: IslFix.at(1)) == 90)
    }

    @Test func normalDriftIsNotASeek() {
        var m = model(IslFix.info(elapsed: 10))
        #expect(!m.apply(IslFix.info(elapsed: 12), now: IslFix.at(1)).contains(.seeked))
    }

    @Test func emptyInfoKeepsTheTrackUntilTheGraceEnds() {
        var m = model(IslFix.info())
        m.apply(nil, now: IslFix.at(1))
        #expect(m.value.track != nil)
        #expect(m.prune(now: IslFix.at(2)).isEmpty)
        #expect(m.prune(now: IslFix.at(3.1)) == [.cleared])
        #expect(m.value.track == nil)
    }

    @Test func infoReturningCancelsTheClearing() {
        var m = model(IslFix.info())
        m.apply(nil, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 15), now: IslFix.at(2))
        #expect(m.prune(now: IslFix.at(10)).isEmpty)
        #expect(m.value.track != nil)
    }

    @Test func blankInfoCountsAsMissing() {
        var m = model(IslFix.info())
        m.apply(IslFix.info("", artist: "", album: ""), now: IslFix.at(1))
        #expect(m.prune(now: IslFix.at(4)) == [.cleared])
    }

    @Test func clearingWithoutATrackIsANoOp() {
        var m = IslNowPlayingModel()
        #expect(m.clear().isEmpty)
        #expect(m.prune(now: IslFix.at(100)).isEmpty)
    }
}

@Suite struct IslSeekTests {
    @Test func localSeekMovesTheClockImmediately() {
        var m = model(IslFix.info(elapsed: 10))
        #expect(m.seek(to: 120, now: IslFix.at(2)) == .seeked)
        #expect(m.value.elapsed(at: IslFix.at(2)) == 120)
        #expect(m.value.elapsed(at: IslFix.at(4)) == 122)
    }

    @Test func seekIsClampedToTheTrack() {
        var m = model(IslFix.info(duration: 100, elapsed: 10))
        m.seek(to: 500, now: IslFix.at(0))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 100)
        m.seek(to: -4, now: IslFix.at(0))
        #expect(m.value.elapsed(at: IslFix.at(0)) == 0)
    }

    @Test func seekWithoutATrackIsIgnored() {
        var m = IslNowPlayingModel()
        #expect(m.seek(to: 10, now: IslFix.at(0)).isEmpty)
        #expect(m.seek(to: .infinity, now: IslFix.at(0)).isEmpty)
    }

    @Test func staleRemoteElapsedIsIgnoredDuringTheHold() {
        var m = model(IslFix.info(elapsed: 10))
        m.seek(to: 120, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 11), now: IslFix.at(1.5))
        #expect(abs(m.value.elapsed(at: IslFix.at(1.5)) - 120.5) < 0.001)
    }

    @Test func confirmingRemoteElapsedEndsTheHold() {
        var m = model(IslFix.info(elapsed: 10))
        m.seek(to: 120, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 120.6), now: IslFix.at(1.5))
        #expect(abs(m.value.elapsed(at: IslFix.at(1.5)) - 120.6) < 0.001)
        let c = m.apply(IslFix.info(elapsed: 5), now: IslFix.at(1.6))
        #expect(c.contains(.seeked))
        #expect(m.value.elapsed(at: IslFix.at(1.6)) == 5)
    }

    @Test func afterTheHoldARemoteJumpWins() {
        var m = model(IslFix.info(elapsed: 10))
        m.seek(to: 120, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 30), now: IslFix.at(5))
        #expect(m.value.elapsed(at: IslFix.at(5)) == 30)
    }

    @Test func newTrackDuringTheHoldWinsOverTheSeek() {
        var m = model(IslFix.info("A", elapsed: 10))
        m.seek(to: 120, now: IslFix.at(1))
        m.apply(IslFix.info("B", elapsed: 3), now: IslFix.at(1.5))
        #expect(m.value.elapsed(at: IslFix.at(1.5)) == 3)
    }
}

@Suite struct IslPlayStateTests {
    @Test func optimisticPauseFreezesTheClock() {
        var m = model(IslFix.info(elapsed: 10))
        #expect(m.setPlaying(false, now: IslFix.at(5)) == .playback)
        #expect(m.value.elapsed(at: IslFix.at(5)) == 15)
        #expect(m.value.elapsed(at: IslFix.at(50)) == 15)
    }

    @Test func optimisticPlayResumes() {
        var m = model(IslFix.info(elapsed: 10, playing: false))
        m.setPlaying(true, now: IslFix.at(1))
        #expect(m.value.isPlaying && m.value.rate == 1)
        #expect(m.value.elapsed(at: IslFix.at(3)) == 12)
    }

    @Test func repeatingTheSameStateDoesNothing() {
        var m = model(IslFix.info())
        #expect(m.setPlaying(true, now: IslFix.at(1)).isEmpty)
    }

    @Test func withoutATrackNothingHappens() {
        var m = IslNowPlayingModel()
        #expect(m.setPlaying(true, now: IslFix.at(0)).isEmpty)
    }

    @Test func staleRemoteStateIsIgnoredDuringTheHold() {
        var m = model(IslFix.info(elapsed: 10, playing: true))
        m.setPlaying(false, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 11, playing: true), now: IslFix.at(1.4))
        #expect(!m.value.isPlaying)
    }

    @Test func remoteStateWinsAfterTheHold() {
        var m = model(IslFix.info(elapsed: 10, playing: true))
        m.setPlaying(false, now: IslFix.at(1))
        m.apply(IslFix.info(elapsed: 11, playing: true), now: IslFix.at(3))
        #expect(m.value.isPlaying)
    }

    @Test func playbackFinishedWithoutUpdatesStopsTheClock() {
        var m = model(IslFix.info(duration: 100, elapsed: 90))
        #expect(m.prune(now: IslFix.at(12)).isEmpty)
        #expect(m.prune(now: IslFix.at(30)) == [.playback])
        #expect(!m.value.isPlaying)
        #expect(m.value.elapsed(at: IslFix.at(40)) == 100)
    }

    @Test func longPausedTrackBecomesStale() {
        var m = model(IslFix.info(playing: false))
        #expect(m.prune(now: IslFix.at(3000)).isEmpty)
        #expect(m.prune(now: IslFix.at(3700)) == [.cleared])
    }

    @Test func stalenessThresholdIsConfigurable() {
        var m = model(IslFix.info(playing: false))
        m.stalePausedAfter = 10
        #expect(m.prune(now: IslFix.at(11)) == [.cleared])
    }

    @Test func playingTrackNeverGoesStaleByAge() {
        var m = model(IslFix.info(duration: nil, elapsed: 5))
        #expect(m.prune(now: IslFix.at(100_000)).isEmpty)
    }
}

@Suite struct IslArtworkKeyTests {
    @Test func keyIsStable() {
        let a = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "b", artworkID: nil)
        #expect(a == b && a.hasPrefix("art-"))
    }

    @Test func tracksOfTheSameAlbumShareTheKey() {
        let a = IslArtworkKey.make(title: "One", artist: "A", album: "Al", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "Two", artist: "A", album: "Al", bundleID: "b", artworkID: nil)
        #expect(a == b)
    }

    @Test func differentAlbumsDiffer() {
        let a = IslArtworkKey.make(title: "T", artist: "A", album: "X", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "T", artist: "A", album: "Y", bundleID: "b", artworkID: nil)
        #expect(a != b)
    }

    @Test func noAlbumFallsBackToTheTitle() {
        let a = IslArtworkKey.make(title: "One", artist: "A", album: "", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "Two", artist: "A", album: "", bundleID: "b", artworkID: nil)
        #expect(a != b)
    }

    @Test func caseAndSpacesAreNormalised() {
        let a = IslArtworkKey.make(title: "T", artist: "The  Band", album: "My Album", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "T", artist: "the band", album: " my   album ", bundleID: "b", artworkID: nil)
        #expect(a == b)
    }

    @Test func theSourceAppSeparatesKeys() {
        let a = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "x", artworkID: nil)
        let b = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "y", artworkID: nil)
        #expect(a != b)
    }

    @Test func anExplicitArtworkIdWins() {
        let a = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "b", artworkID: "id-1")
        let b = IslArtworkKey.make(title: "Other", artist: "B", album: "Zz", bundleID: "b", artworkID: "id-1")
        let c = IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "b", artworkID: "id-2")
        #expect(a == b && a != c)
    }

    @Test func cyrillicKeysDoNotCollide() {
        let a = IslArtworkKey.make(title: "Кино", artist: "Цой", album: "Группа крови", bundleID: "b", artworkID: nil)
        let b = IslArtworkKey.make(title: "Кино", artist: "Цой", album: "Звезда по имени Солнце", bundleID: "b", artworkID: nil)
        #expect(a != b)
        #expect(a.allSatisfy { $0.isASCII })
    }

    @Test func trackKeyComesFromTheInfo() {
        let t = IslTrack(IslFix.info("T", artist: "A", album: "Al", bundle: "b"))
        #expect(t.artworkKey == IslArtworkKey.make(title: "T", artist: "A", album: "Al", bundleID: "b", artworkID: nil))
    }

    @Test func subtitleJoinsArtistAndAlbum() {
        #expect(IslTrack(IslFix.info(artist: "A", album: "B")).subtitle == "A — B")
        #expect(IslTrack(IslFix.info(artist: "A", album: "")).subtitle == "A")
        #expect(IslTrack(IslFix.info(artist: "", album: "")).subtitle == "")
    }

    @Test func nonPositiveDurationIsDropped() {
        #expect(IslTrack(IslFix.info(duration: 0)).duration == nil)
        #expect(IslTrack(IslFix.info(duration: -3)).duration == nil)
        #expect(IslTrack(IslFix.info(duration: .infinity)).duration == nil)
    }
}

@Suite struct IslLruCacheTests {
    @Test func storesAndReturns() {
        var c = IslLRUCache<String, Int>(capacity: 2)
        c.set("a", 1)
        #expect(c.get("a") == 1 && c.peek("a") == 1 && c.count == 1)
        #expect(c.get("zzz") == nil)
    }

    @Test func evictsTheLeastRecentlyUsed() {
        var c = IslLRUCache<String, Int>(capacity: 2)
        c.set("a", 1)
        c.set("b", 2)
        c.set("c", 3)
        #expect(c.peek("a") == nil && c.peek("b") == 2 && c.peek("c") == 3)
    }

    @Test func readingPromotes() {
        var c = IslLRUCache<String, Int>(capacity: 2)
        c.set("a", 1)
        c.set("b", 2)
        _ = c.get("a")
        c.set("c", 3)
        #expect(c.peek("a") == 1 && c.peek("b") == nil)
    }

    @Test func peekDoesNotPromote() {
        var c = IslLRUCache<String, Int>(capacity: 2)
        c.set("a", 1)
        c.set("b", 2)
        _ = c.peek("a")
        c.set("c", 3)
        #expect(c.peek("a") == nil)
    }

    @Test func overwritingKeepsOneEntry() {
        var c = IslLRUCache<String, Int>(capacity: 3)
        c.set("a", 1)
        c.set("a", 5)
        #expect(c.count == 1 && c.get("a") == 5)
    }

    @Test func capacityIsAtLeastOne() {
        var c = IslLRUCache<String, Int>(capacity: 0)
        c.set("a", 1)
        c.set("b", 2)
        #expect(c.count == 1 && c.peek("b") == 2)
    }

    @Test func removeAllEmpties() {
        var c = IslLRUCache<String, Int>(capacity: 3)
        c.set("a", 1)
        c.removeAll()
        #expect(c.count == 0 && c.keys.isEmpty)
    }
}

@Suite struct IslMergeTests {
    private func src(_ name: String, _ info: IslNowPlayingInfo, at t: TimeInterval = 0) -> IslSourceInfo { IslSourceInfo(source: name, info: info, receivedAt: IslFix.at(t)) }

    @Test func emptyInputPicksNothing() {
        #expect(IslNowPlayingMerge.pick([], previous: nil) == nil)
        #expect(IslNowPlayingMerge.pick([src("a", IslNowPlayingInfo())], previous: nil) == nil)
    }

    @Test func playingBeatsPaused() {
        let r = IslNowPlayingMerge.pick([src("a", IslFix.info(playing: false), at: 5), src("b", IslFix.info(playing: true), at: 1)], previous: nil)
        #expect(r?.source == "b")
    }

    @Test func previousSourceIsPreferredAmongEquals() {
        let r = IslNowPlayingMerge.pick([src("a", IslFix.info(), at: 1), src("b", IslFix.info(), at: 9)], previous: "a")
        #expect(r?.source == "a")
    }

    @Test func freshestWinsWithoutAPreference() {
        let r = IslNowPlayingMerge.pick([src("a", IslFix.info(), at: 1), src("b", IslFix.info(), at: 9)], previous: nil)
        #expect(r?.source == "b")
    }

    @Test func aPausedPreviousLosesToAPlayingNewcomer() {
        let r = IslNowPlayingMerge.pick([src("a", IslFix.info(playing: false), at: 1), src("b", IslFix.info(playing: true), at: 2)], previous: "a")
        #expect(r?.source == "b")
    }

    @Test func sourceNameBreaksPerfectTies() {
        let r = IslNowPlayingMerge.pick([src("b", IslFix.info(), at: 1), src("a", IslFix.info(), at: 1)], previous: nil)
        #expect(r?.source == "a")
    }
}

@Suite struct IslHealthTests {
    @Test func startsUnknownAndNeverComplainsWhenNothingPlays() {
        var h = IslHealthTracker()
        #expect(h.health == .unknown)
        for _ in 0..<10 { h.observe(isPlayingFlag: false, infoEmpty: true) }
        #expect(h.health == .unknown)
    }

    @Test func playingWithEmptyInfoTurnsRestrictedAfterThreeTimes() {
        var h = IslHealthTracker()
        h.observe(isPlayingFlag: true, infoEmpty: true)
        h.observe(isPlayingFlag: true, infoEmpty: true)
        #expect(h.health != .restricted)
        h.observe(isPlayingFlag: true, infoEmpty: true)
        #expect(h.health == .restricted)
        #expect(h.health.note?.contains("MediaRemote") == true)
    }

    @Test func realInfoMakesItHealthy() {
        var h = IslHealthTracker()
        for _ in 0..<5 { h.observe(isPlayingFlag: true, infoEmpty: true) }
        h.observe(isPlayingFlag: true, infoEmpty: false)
        #expect(h.health == .ok && h.health.note == nil)
    }

    @Test func aGapInTheSuspicionResetsTheCount() {
        var h = IslHealthTracker()
        h.observe(isPlayingFlag: true, infoEmpty: true)
        h.observe(isPlayingFlag: true, infoEmpty: true)
        h.observe(isPlayingFlag: false, infoEmpty: true)
        h.observe(isPlayingFlag: true, infoEmpty: true)
        #expect(h.health != .restricted)
    }

    @Test func unavailableCarriesTheReason() {
        var h = IslHealthTracker()
        h.markUnavailable("нет API")
        #expect(h.health.note?.contains("нет API") == true)
    }
}

@MainActor
@Suite struct IslServiceTests {
    private func service(_ drivers: [IslFakeDriver], clock: Box<Date>) -> IslNowPlayingService {
        IslNowPlayingService(drivers: drivers, clock: { clock.value })
    }

    final class Box<T> {
        var value: T
        init(_ v: T) { value = v }
    }

    @Test func startsAndStopsEveryDriver() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        s.start()
        #expect(d.started == 1)
        s.stop()
        #expect(d.stopped == 1 && d.onInfo == nil)
    }

    @Test func driverUpdatesFlowIntoTheModel() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        d.push(IslFix.info("Song"))
        #expect(s.value.track?.title == "Song" && s.activeSource == "fake")
    }

    @Test func changesAreReported() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        var seen: [IslNowPlayingChange] = []
        s.onChange = { seen.append($0) }
        s.start()
        d.push(IslFix.info("A"))
        d.push(IslFix.info("B"))
        #expect(seen.count == 2 && seen[0].contains(.track) && seen[1].contains(.track))
    }

    @Test func artworkIsCachedUnderTheTrackKey() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        var i = IslFix.info("A")
        i.artworkData = Data([1, 2, 3])
        d.push(i)
        #expect(s.currentArtwork == Data([1, 2, 3]))
        d.push(IslFix.info("A"))
        #expect(s.currentArtwork == Data([1, 2, 3]))
    }

    @Test func artworkFollowsTheAlbumAcrossTracks() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        var i = IslFix.info("One", album: "Al")
        i.artworkData = Data([9])
        d.push(i)
        d.push(IslFix.info("Two", album: "Al"))
        #expect(s.currentArtwork == Data([9]))
        d.push(IslFix.info("Three", album: "Other"))
        #expect(s.currentArtwork == nil)
    }

    @Test func stoppingDropsEverything() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        d.push(IslFix.info())
        s.stop()
        #expect(s.value.track == nil && s.activeSource == nil && s.currentArtwork == nil)
    }

    @Test func togglePlayIsOptimisticAndForwarded() {
        let d = IslFakeDriver()
        let clock = Box(IslFix.at(0))
        let s = service([d], clock: clock)
        s.start()
        d.push(IslFix.info())
        clock.value = IslFix.at(2)
        s.send(.toggle)
        #expect(!s.value.isPlaying)
        #expect(d.sent == [.toggle])
    }

    @Test func seekUpdatesTheClockAndTheDriver() {
        let d = IslFakeDriver()
        let clock = Box(IslFix.at(0))
        let s = service([d], clock: clock)
        s.start()
        d.push(IslFix.info(elapsed: 10))
        s.send(.seek(100))
        #expect(s.value.elapsed(at: clock.value) == 100)
        #expect(d.sent == [.seek(100)])
    }

    @Test func skipSeeksRelativeToNow() {
        let d = IslFakeDriver()
        let clock = Box(IslFix.at(0))
        let s = service([d], clock: clock)
        s.start()
        d.push(IslFix.info(elapsed: 50))
        clock.value = IslFix.at(10)
        s.skip(by: 15)
        #expect(d.sent == [.seek(75)])
    }

    @Test func skipWithoutATrackSendsNothing() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        s.skip(by: 15)
        #expect(d.sent.isEmpty)
    }

    @Test func nextAndPreviousAreJustForwarded() {
        let d = IslFakeDriver()
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        d.push(IslFix.info())
        s.send(.next)
        s.send(.previous)
        #expect(d.sent == [.next, .previous] && s.value.isPlaying)
    }

    @Test func commandsGoToTheDriverThatReportedTheTrack() {
        let a = IslFakeDriver("a")
        let b = IslFakeDriver("b")
        let s = service([a, b], clock: Box(IslFix.at(0)))
        s.start()
        b.push(IslFix.info())
        s.send(.next)
        #expect(a.sent.isEmpty && b.sent == [.next])
    }

    @Test func aPlayingSourceBeatsAPausedOne() {
        let a = IslFakeDriver("a")
        let b = IslFakeDriver("b")
        let s = service([a, b], clock: Box(IslFix.at(0)))
        s.start()
        a.push(IslFix.info("Paused one", playing: false))
        b.push(IslFix.info("Live one", playing: true))
        #expect(s.value.track?.title == "Live one" && s.activeSource == "b")
        b.push(nil)
        #expect(s.value.track?.title == "Paused one")
    }

    @Test func tickPrunesMissingInfo() {
        let d = IslFakeDriver()
        let clock = Box(IslFix.at(0))
        let s = service([d], clock: clock)
        s.start()
        d.push(IslFix.info())
        clock.value = IslFix.at(1)
        d.push(nil)
        clock.value = IslFix.at(4)
        var cleared = false
        s.onChange = { if $0.contains(.cleared) { cleared = true } }
        s.tick()
        #expect(cleared && s.value.track == nil)
    }

    @Test func refreshAsksEveryDriver() {
        let a = IslFakeDriver("a")
        let b = IslFakeDriver("b")
        let s = service([a, b], clock: Box(IslFix.at(0)))
        s.refresh()
        #expect(a.refreshes == 1 && b.refreshes == 1)
    }

    @Test func healthNotesAreCollected() {
        let a = IslFakeDriver("a")
        a.health = .restricted
        let s = service([a, IslFakeDriver("b")], clock: Box(IslFix.at(0)))
        #expect(s.healthNotes.count == 1)
    }

    @Test func sendWithoutDriversFails() {
        let s = IslNowPlayingService(drivers: [], clock: { IslFix.at(0) })
        #expect(!s.send(.next))
    }

    @Test func failedDeliveryIsReported() {
        let d = IslFakeDriver()
        d.sendResult = false
        let s = service([d], clock: Box(IslFix.at(0)))
        s.start()
        d.push(IslFix.info())
        #expect(!s.send(.next))
    }
}

@Suite struct IslParserTests {
    @Test func mediaRemoteDictionaryIsParsed() {
        let ts = IslFix.at(-2)
        let dict: [String: Any] = [
            IslMediaRemoteKeys.title: "Song", IslMediaRemoteKeys.artist: "Band", IslMediaRemoteKeys.album: "Album",
            IslMediaRemoteKeys.duration: NSNumber(value: 215.5), IslMediaRemoteKeys.elapsed: NSNumber(value: 30), IslMediaRemoteKeys.rate: NSNumber(value: 1),
            IslMediaRemoteKeys.timestamp: ts, IslMediaRemoteKeys.artworkData: Data([1, 2]), IslMediaRemoteKeys.contentID: "cid"
        ]
        let i = IslMediaRemoteParser.parse(dict, isPlaying: true, bundleID: "com.apple.Music", appName: "Music")
        #expect(i.title == "Song" && i.artist == "Band" && i.album == "Album")
        #expect(i.duration == 215.5 && i.elapsed == 30 && i.rate == 1 && i.timestamp == ts)
        #expect(i.artworkData == Data([1, 2]) && i.contentID == "cid")
        #expect(i.isPlaying == true && i.bundleID == "com.apple.Music" && i.appName == "Music")
    }

    @Test func emptyDictionaryIsEmptyInfo() {
        let i = IslMediaRemoteParser.parse([:], isPlaying: false, bundleID: nil, appName: nil)
        #expect(i.isEmpty && i.duration == nil && i.elapsed == nil && i.rate == 0)
    }

    @Test func wrongTypesAreTolerated() {
        let dict: [String: Any] = [IslMediaRemoteKeys.title: 42, IslMediaRemoteKeys.duration: "abc", IslMediaRemoteKeys.elapsed: "12,5", IslMediaRemoteKeys.rate: "x"]
        let i = IslMediaRemoteParser.parse(dict, isPlaying: nil, bundleID: nil, appName: nil)
        #expect(i.title == "" && i.duration == nil && i.elapsed == 12.5 && i.rate == 0)
    }

    @Test func zeroDurationAndEmptyArtworkAreDropped() {
        let dict: [String: Any] = [IslMediaRemoteKeys.duration: 0, IslMediaRemoteKeys.artworkData: Data(), IslMediaRemoteKeys.title: "T"]
        let i = IslMediaRemoteParser.parse(dict, isPlaying: true, bundleID: nil, appName: nil)
        #expect(i.duration == nil && i.artworkData == nil)
    }

    @Test func uniqueIdentifierIsTheFallbackContentId() {
        let i = IslMediaRemoteParser.parse([IslMediaRemoteKeys.title: "T", IslMediaRemoteKeys.uniqueID: "u1"], isPlaying: true, bundleID: nil, appName: nil)
        #expect(i.contentID == "u1")
    }

    @Test func keyNamesAreAsciiAndUnique() {
        let keys = [IslMediaRemoteKeys.title, IslMediaRemoteKeys.artist, IslMediaRemoteKeys.album, IslMediaRemoteKeys.duration, IslMediaRemoteKeys.elapsed, IslMediaRemoteKeys.rate,
                    IslMediaRemoteKeys.timestamp, IslMediaRemoteKeys.artworkData, IslMediaRemoteKeys.artworkID, IslMediaRemoteKeys.contentID, IslMediaRemoteKeys.uniqueID]
        #expect(Set(keys).count == keys.count && keys.allSatisfy { $0.allSatisfy { $0.isASCII } })
    }

    @Test func musicNotificationIsParsed() throws {
        let i = try #require(IslScriptPlayer.music.parse(userInfo: ["Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "Al", "Total Time": 180_000, "Persistent ID": "ABC"]))
        #expect(i.title == "Song" && i.duration == 180 && i.isPlaying == true && i.bundleID == "com.apple.Music" && i.contentID == "ABC")
        #expect(i.elapsed == nil)
    }

    @Test func spotifyNotificationCarriesThePosition() throws {
        let i = try #require(IslScriptPlayer.spotify.parse(userInfo: ["Player State": "Paused", "Name": "S", "Artist": "A", "Duration": 200_000, "Playback Position": 42.5, "Track ID": "spotify:track:1"]))
        #expect(i.elapsed == 42.5 && i.duration == 200 && i.isPlaying == false && i.rate == 0)
    }

    @Test func stoppedOrBlankNotificationsMeanNothing() {
        #expect(IslScriptPlayer.music.parse(userInfo: ["Player State": "Stopped", "Name": "x"]) == nil)
        #expect(IslScriptPlayer.music.parse(userInfo: [:]) == nil)
        #expect(IslScriptPlayer.spotify.parse(userInfo: ["Player State": "Playing"]) == nil)
    }

    @Test func playerScriptsAreBuilt() {
        #expect(IslScriptPlayer.music.commandScript(.toggle) == "tell application \"Music\" to playpause")
        #expect(IslScriptPlayer.spotify.commandScript(.next) == "tell application \"Spotify\" to next track")
        #expect(IslScriptPlayer.music.commandScript(.previous) == "tell application \"Music\" to previous track")
        #expect(IslScriptPlayer.music.commandScript(.play) == "tell application \"Music\" to play")
        #expect(IslScriptPlayer.music.commandScript(.pause) == "tell application \"Music\" to pause")
    }

    @Test func seekScriptUsesADotDecimal() {
        #expect(IslScriptPlayer.spotify.commandScript(.seek(75.5)) == "tell application \"Spotify\" to set player position to 75.50")
        #expect(IslScriptPlayer.music.commandScript(.seek(-1)) == nil)
        #expect(IslScriptPlayer.music.commandScript(.seek(.nan)) == nil)
    }

    @Test func playerIdentitiesAreSane() {
        for p in IslScriptPlayer.allCases {
            #expect(!p.bundleID.isEmpty && !p.appName.isEmpty && !p.notificationName.isEmpty)
        }
        #expect(IslMediaRemoteKeys.commandToggle != IslMediaRemoteKeys.commandPlay)
    }
}

@Suite struct IslTimeFormatTests {
    @Test func minutesAndSeconds() {
        #expect(IslTimeFormat.clock(0) == "0:00")
        #expect(IslTimeFormat.clock(65) == "1:05")
        #expect(IslTimeFormat.clock(599.9) == "9:59")
    }

    @Test func hoursAppearWhenNeeded() {
        #expect(IslTimeFormat.clock(3600) == "1:00:00")
        #expect(IslTimeFormat.clock(3725) == "1:02:05")
    }

    @Test func badValuesAreSafe() {
        #expect(IslTimeFormat.clock(-5) == "0:00")
        #expect(IslTimeFormat.clock(.nan) == "0:00")
        #expect(IslTimeFormat.remaining(30) == "−0:30")
    }
}
