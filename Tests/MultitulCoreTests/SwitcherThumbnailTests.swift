import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func entry(_ key: Int, id: UInt32? = nil, minimized: Bool = false, allowed: Bool = true) -> SwitchEntry {
    var w = SwcFix.win(key, id: id, minimized: minimized)
    w.windowID = id ?? UInt32(1000 + key)
    return SwitchEntry(window: w, previewAllowed: allowed)
}

@Suite struct ThumbnailCacheTests {
    @Test func storeAndFetch() {
        let c = ThumbnailCache()
        #expect(c.peek(1) == nil)
        c.store(SwcCapturer.image(), for: 1, now: 5)
        #expect(c.peek(1) != nil && c.capturedAt(1) == 5 && c.count == 1 && c.totalBytes > 0)
    }

    @Test func overwritingDoesNotLeakBytes() {
        let c = ThumbnailCache()
        c.store(SwcCapturer.image(8, 6), for: 1, now: 1)
        let one = c.totalBytes
        c.store(SwcCapturer.image(8, 6), for: 1, now: 2)
        #expect(c.totalBytes == one && c.count == 1)
    }

    @Test func evictsTheLeastRecentlyUsedWhenFull() {
        let c = ThumbnailCache(maxCount: 3)
        for i in 1...3 { c.store(SwcCapturer.image(), for: UInt32(i), now: Double(i)) }
        _ = c.image(1, now: 10)
        c.store(SwcCapturer.image(), for: 4, now: 11)
        #expect(c.peek(2) == nil && c.peek(1) != nil && c.peek(3) != nil && c.peek(4) != nil)
    }

    @Test func byteBudgetIsEnforced() {
        let one = SwcCapturer.image(100, 100)
        let c = ThumbnailCache(maxCount: 100, maxBytes: one.bytesPerRow * one.height * 2)
        for i in 1...5 { c.store(SwcCapturer.image(100, 100), for: UInt32(i), now: Double(i)) }
        #expect(c.count == 2 && c.totalBytes <= c.maxBytes)
    }

    @Test func pruneKeepsOnlyLiveWindows() {
        let c = ThumbnailCache()
        for i in 1...4 { c.store(SwcCapturer.image(), for: UInt32(i), now: 1) }
        c.prune(keeping: [2, 3])
        #expect(c.count == 2 && c.peek(2) != nil && c.peek(1) == nil)
        c.remove(2)
        #expect(c.count == 1)
    }

    @Test func freshnessWindow() {
        let c = ThumbnailCache()
        c.store(SwcCapturer.image(), for: 1, now: 10)
        #expect(c.isFresh(1, now: 11, maxAge: 2) && !c.isFresh(1, now: 13, maxAge: 2) && !c.isFresh(9, now: 11, maxAge: 2))
    }
}

@Suite struct ThumbnailPlannerTests {
    @Test func selectedFirstThenVisibleThenTheRest() {
        let e = (1...6).map { entry($0) }
        let ids = ThumbnailPlanner.plan(entries: e, selected: 4, cache: ThumbnailCache(), now: 0, allowCapture: true, budget: 99, visibleRange: 1..<3)
        #expect(ids == [1005, 1002, 1003, 1001, 1004, 1006])
    }

    @Test func freshThumbnailsAreSkippedStaleOnesRetaken() {
        let c = ThumbnailCache()
        c.store(SwcCapturer.image(), for: 1001, now: 9.5)
        c.store(SwcCapturer.image(), for: 1002, now: 1)
        let ids = ThumbnailPlanner.plan(entries: [entry(1), entry(2)], selected: nil, cache: c, now: 10, allowCapture: true, budget: 9)
        #expect(ids == [1002])
    }

    @Test func minimizedWindowsAreRetakenRarely() {
        let c = ThumbnailCache()
        c.store(SwcCapturer.image(), for: 1001, now: 5)
        let ids = ThumbnailPlanner.plan(entries: [entry(1, minimized: true)], selected: nil, cache: c, now: 50, allowCapture: true, budget: 9)
        #expect(ids.isEmpty)
        let late = ThumbnailPlanner.plan(entries: [entry(1, minimized: true)], selected: nil, cache: c, now: 500, allowCapture: true, budget: 9)
        #expect(late == [1001])
    }

    @Test func excludedAppsAndWindowlessEntriesAreNeverCaptured() {
        let e = [entry(1, allowed: false), SwitchEntry(app: SwcFix.app(5)), entry(2)]
        #expect(ThumbnailPlanner.plan(entries: e, selected: nil, cache: ThumbnailCache(), now: 0, allowCapture: true, budget: 9) == [1002])
    }

    @Test func budgetAndPermissionLimitTheWork() {
        let e = (1...10).map { entry($0) }
        #expect(ThumbnailPlanner.plan(entries: e, selected: 0, cache: ThumbnailCache(), now: 0, allowCapture: true, budget: 3).count == 3)
        #expect(ThumbnailPlanner.plan(entries: e, selected: 0, cache: ThumbnailCache(), now: 0, allowCapture: false, budget: 3).isEmpty)
        #expect(ThumbnailPlanner.plan(entries: e, selected: 0, cache: ThumbnailCache(), now: 0, allowCapture: true, budget: 0).isEmpty)
    }

    @Test func duplicateWindowIDsAreRequestedOnce() {
        let e = [entry(1, id: 7), entry(2, id: 7)]
        #expect(ThumbnailPlanner.plan(entries: e, selected: nil, cache: ThumbnailCache(), now: 0, allowCapture: true, budget: 9) == [7])
    }
}

@Suite struct ThumbnailServiceTests {
    @Test func atMostFourCapturesRunAtOnce() {
        let cap = SwcCapturer()
        let s = ThumbnailService(capturer: cap, clock: { 1 })
        s.request(Array(1...9))
        #expect(cap.requests.count == ThumbnailService.maxInFlight && s.pending == 9)
        cap.finish(1)
        #expect(cap.requests.count == 5)
    }

    @Test func finishedCapturesLandInTheCacheAndNotify() {
        let cap = SwcCapturer()
        let s = ThumbnailService(capturer: cap, clock: { 7 })
        var seen: [UInt32] = []
        s.onUpdate = { seen.append($0) }
        s.request([5])
        cap.finish(5)
        #expect(seen == [5] && s.cache.capturedAt(5) == 7 && s.pending == 0)
    }

    @Test func aWindowAlreadyInFlightIsNotRequestedTwice() {
        let cap = SwcCapturer()
        let s = ThumbnailService(capturer: cap)
        s.request([1, 2])
        s.request([1, 2, 3])
        #expect(cap.requests == [1, 2, 3])
    }

    @Test func failuresBackOffAfterThreeTriesUntilReset() {
        let cap = SwcCapturer()
        let s = ThumbnailService(capturer: cap)
        for _ in 0..<3 { s.request([9]); cap.finish(9, ok: false) }
        s.request([9])
        #expect(cap.requests.count == 3)
        s.resetFailures()
        s.request([9])
        #expect(cap.requests.count == 4)
    }

    @Test func cancelQueuedDropsWaitingWorkOnly() {
        let cap = SwcCapturer()
        let s = ThumbnailService(capturer: cap)
        s.request(Array(1...8))
        s.cancelQueued()
        cap.finish(1)
        #expect(cap.requests.count == 4 && s.pending == 3)
    }
}
