import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ShotRowHashTests {
    @Test func identicalRowsHashEqual() {
        let bm = ShotBitmap(width: 8, height: 4) { x, y in y % 2 == 0 ? (1, 2, 3, 255) : (UInt8(x), 0, 0, 255) }
        let h = ShotRowHash.hashes(of: bm)
        #expect(h.count == 4 && h[0] == h[2] && h[0] != h[1])
    }

    @Test func pageRowsAreAllDistinct() {
        let h = ShotRowHash.hashes(of: shotPage(rows: 1500))
        #expect(Set(h).count == 1500)
    }

    @Test func ignoredColumnsDoNotAffectTheHash() {
        var a = shotPage(rows: 5, width: 10), b = a
        for y in 0..<5 { b.setPixel(9, y, (1, 1, 1, 255)); b.setPixel(0, y, (2, 2, 2, 255)) }
        var cfg = ShotStitchConfig()
        #expect(ShotRowHash.hashes(of: a, config: cfg) != ShotRowHash.hashes(of: b, config: cfg))
        cfg.ignoreRightColumns = 1
        cfg.ignoreLeftColumns = 1
        #expect(ShotRowHash.hashes(of: a, config: cfg) == ShotRowHash.hashes(of: b, config: cfg))
        a.setPixel(5, 0, (9, 9, 9, 255))
        #expect(ShotRowHash.hashes(of: a, config: cfg)[0] != ShotRowHash.hashes(of: b, config: cfg)[0])
    }

    @Test func quantizationToleratesSmallColourNoise() {
        let a = ShotBitmap(width: 6, height: 2, color: (100, 100, 100, 255))
        let b = ShotBitmap(width: 6, height: 2, color: (101, 99, 102, 255))
        var cfg = ShotStitchConfig()
        #expect(ShotRowHash.hashes(of: a, config: cfg) != ShotRowHash.hashes(of: b, config: cfg))
        cfg.quantizeBits = 3
        #expect(ShotRowHash.hashes(of: a, config: cfg) == ShotRowHash.hashes(of: b, config: cfg))
    }

    @Test func emptyBitmapHasNoHashes() {
        #expect(ShotRowHash.hashes(of: .empty).isEmpty)
    }
}

@Suite struct ShotOverlapTests {
    private func hashes(_ page: ShotBitmap, _ top: Int, _ h: Int, header: Int = 0, footer: Int = 0) -> [UInt64] {
        ShotRowHash.hashes(of: shotSticky(shotView(page, top: top, height: h), header: header, footer: footer))
    }

    @Test func findsThePlainScrollDistance() {
        let page = shotPage(rows: 800)
        let r = ShotOverlapFinder.find(prev: hashes(page, 0, 200), next: hashes(page, 150, 200))
        guard case .found(let o) = r else { Issue.record("not found"); return }
        #expect(o.shift == 150 && o.overlapRows == 50 && o.stickyTop == 0 && o.stickyBottom == 0 && o.mismatches == 0)
    }

    @Test func identicalFramesMeanNoChange() {
        let page = shotPage(rows: 400)
        #expect(ShotOverlapFinder.find(prev: hashes(page, 100, 200), next: hashes(page, 100, 200)) == .same)
    }

    @Test func unrelatedFramesAreNotFound() {
        let a = shotPage(rows: 300), b = ShotBitmap(width: 24, height: 200) { x, y in (UInt8((y * 7 + 3) & 255), 200, UInt8(x), 255) }
        #expect(ShotOverlapFinder.find(prev: ShotRowHash.hashes(of: a.rows(0..<200)), next: ShotRowHash.hashes(of: b)) == .notFound)
    }

    @Test func detectsAStickyHeader() {
        let page = shotPage(rows: 800)
        let r = ShotOverlapFinder.find(prev: hashes(page, 0, 200, header: 30), next: hashes(page, 120, 200, header: 30))
        guard case .found(let o) = r else { Issue.record("not found"); return }
        #expect(o.shift == 120 && o.stickyTop == 30 && o.stickyBottom == 0)
    }

    @Test func detectsAStickyFooter() {
        let page = shotPage(rows: 800)
        let r = ShotOverlapFinder.find(prev: hashes(page, 0, 200, footer: 24), next: hashes(page, 100, 200, footer: 24))
        guard case .found(let o) = r else { Issue.record("not found"); return }
        #expect(o.shift == 100 && o.stickyBottom == 24)
    }

    @Test func detectsHeaderAndFooterTogether() {
        let page = shotPage(rows: 900)
        let r = ShotOverlapFinder.find(prev: hashes(page, 0, 300, header: 20, footer: 20), next: hashes(page, 200, 300, header: 20, footer: 20))
        guard case .found(let o) = r else { Issue.record("not found"); return }
        #expect(o.shift == 200 && o.stickyTop == 20 && o.stickyBottom == 20)
    }

    @Test func hintPicksTheRightShiftAmongRepeats() {
        var rows = [UInt64]()
        for i in 0..<60 { rows.append(UInt64(1000 + i)) }
        let prev = rows + Array(repeating: 7, count: 40) + (0..<40).map { UInt64(2000 + $0) }
        let next = Array(prev.dropFirst(60)) + (0..<60).map { UInt64(3000 + $0) }
        let r = ShotOverlapFinder.find(prev: prev, next: next, hint: 60)
        guard case .found(let o) = r else { Issue.record("not found"); return }
        #expect(o.shift == 60)
    }

    @Test func blankOverlapDoesNotProduceAFalseMatch() {
        let prev = Array(repeating: UInt64(5), count: 100) + (0..<20).map { UInt64($0) }
        let next = Array(repeating: UInt64(5), count: 100) + (100..<120).map { UInt64($0) }
        #expect(ShotOverlapFinder.find(prev: prev, next: next) == .notFound)
    }

    @Test func toleranceAcceptsAFewNoisyRows() {
        let page = shotPage(rows: 600)
        let prev = hashes(page, 0, 200)
        var next = hashes(page, 100, 200)
        next[10] = 42
        next[50] = 43
        #expect(ShotOverlapFinder.find(prev: prev, next: next) == .notFound)
        var cfg = ShotStitchConfig()
        cfg.mismatchTolerance = 0.05
        guard case .found(let o) = ShotOverlapFinder.find(prev: prev, next: next, config: cfg) else { Issue.record("not found"); return }
        #expect(o.shift == 100 && o.mismatches == 2)
    }

    @Test func minimumOverlapIsRequired() {
        let page = shotPage(rows: 600)
        let r = ShotOverlapFinder.find(prev: hashes(page, 0, 200), next: hashes(page, 195, 200))
        #expect(r == .notFound)
    }

    @Test func differentHeightsAreNotComparable() {
        #expect(ShotOverlapFinder.find(prev: [1, 2, 3], next: [1, 2]) == .notFound)
        #expect(ShotOverlapFinder.find(prev: [], next: []) == .notFound)
    }

    @Test func leadingAndTrailingEqualCounters() {
        #expect(ShotOverlapFinder.leadingEqual([1, 2, 3, 4], [1, 2, 9, 4]) == 2)
        #expect(ShotOverlapFinder.trailingEqual([1, 2, 3, 4], [9, 2, 3, 4]) == 3)
        #expect(ShotOverlapFinder.leadingEqual([], [1]) == 0)
    }
}

@Suite struct ShotStitcherTests {
    private func run(page: ShotBitmap, height: Int, steps: [Int], header: Int = 0, footer: Int = 0, config: ShotStitchConfig = ShotStitchConfig()) -> (ShotStitcher, [ShotStitchEvent]) {
        let st = ShotStitcher(config: config)
        var ev: [ShotStitchEvent] = []
        var top = 0
        ev.append(st.add(shotSticky(shotView(page, top: top, height: height), header: header, footer: footer)))
        for s in steps {
            top = min(top + s, page.height - height)
            ev.append(st.add(shotSticky(shotView(page, top: top, height: height), header: header, footer: footer)))
        }
        return (st, ev)
    }

    @Test func reassemblesAPageScrolledInEqualSteps() {
        let page = shotPage(rows: 1000)
        let (st, ev) = run(page: page, height: 300, steps: [200, 200, 200, 100, 0])
        #expect(st.result == page)
        #expect(ev.last == .reachedEnd && st.finished)
    }

    @Test func reassemblesWithUnevenSteps() {
        let page = shotPage(rows: 900)
        let (st, _) = run(page: page, height: 250, steps: [90, 170, 33, 200, 300, 0])
        #expect(st.result == page)
    }

    @Test func eventsReportAppendedRows() {
        let page = shotPage(rows: 600)
        let (_, ev) = run(page: page, height: 200, steps: [150, 150])
        #expect(ev[0] == .started(height: 200))
        #expect(ev[1] == .appended(rows: 150, total: 350) && ev[2] == .appended(rows: 150, total: 500))
    }

    @Test func stickyHeaderIsKeptOnlyOnce() {
        let page = shotPage(rows: 1000)
        let (st, _) = run(page: page, height: 300, steps: [200, 200, 200, 100, 0], header: 40)
        let r = st.result
        #expect(r.height == 1000)
        var expected = page
        for y in 0..<40 { for x in 0..<page.width { expected.setPixel(x, y, (200, 201, UInt8(x), 255)) } }
        #expect(r == expected)
    }

    @Test func stickyFooterEndsUpAtTheBottomOnce() {
        let page = shotPage(rows: 800)
        let (st, _) = run(page: page, height: 300, steps: [200, 200, 100, 0], footer: 30)
        let r = st.result
        #expect(r.height == 800)
        #expect(r.pixel(3, 799) == (10, 11, 3, 255) && r.pixel(3, 770) == (10, 11, 3, 255))
        #expect(r.pixel(3, 500) == page.pixel(3, 500))
    }

    @Test func pageThatDoesNotScrollStaysOneFrame() {
        let page = shotPage(rows: 300)
        let (st, ev) = run(page: page, height: 300, steps: [100])
        #expect(ev[1] == .reachedEnd && st.result == page && st.frames == 1)
    }

    @Test func finishedStitcherIgnoresMoreFrames() {
        let page = shotPage(rows: 600)
        let (st, _) = run(page: page, height: 300, steps: [100, 0])
        let h = st.totalHeight
        #expect(st.add(shotView(page, top: 300, height: 300)) == .reachedEnd && st.totalHeight == h)
    }

    @Test func mismatchedFrameSizeIsRejected() {
        let st = ShotStitcher()
        st.add(shotPage(rows: 200, width: 24))
        #expect(st.add(shotPage(rows: 200, width: 30)) == .rejected)
        #expect(st.add(shotPage(rows: 150, width: 24)) == .rejected)
        #expect(st.add(.empty) == .rejected)
    }

    @Test func lostOverlapStopsAfterTheConfiguredStreak() {
        let st = ShotStitcher()
        st.add(shotPage(rows: 200))
        let other = ShotBitmap(width: 24, height: 200) { x, y in (UInt8((y * 7 + 3) & 255), 200, UInt8(x), 255) }
        #expect(st.add(other) == .lostOverlap && !st.finished)
        #expect(st.add(other) == .lostOverlap && st.finished)
    }

    @Test func aGoodFrameResetsTheLostStreak() {
        let page = shotPage(rows: 700)
        let st = ShotStitcher()
        st.add(shotView(page, top: 0, height: 200))
        let other = ShotBitmap(width: 24, height: 200) { x, y in (UInt8((y * 7 + 3) & 255), 200, UInt8(x), 255) }
        _ = st.add(other)
        #expect(st.lostStreak == 1)
        _ = st.add(shotView(page, top: 100, height: 200))
        #expect(st.lostStreak == 0 && st.totalHeight == 300)
    }

    @Test func heightLimitStopsAndTrims() {
        var cfg = ShotStitchConfig()
        cfg.maxTotalHeight = 450
        let page = shotPage(rows: 1000)
        let (st, ev) = run(page: page, height: 300, steps: [200], config: cfg)
        #expect(ev.last == .limit && st.totalHeight == 450 && st.finished)
        #expect(st.result == page.rows(0..<450))
    }

    @Test func frameLimitStops() {
        var cfg = ShotStitchConfig()
        cfg.maxFrames = 2
        let page = shotPage(rows: 1000)
        let (_, ev) = run(page: page, height: 300, steps: [100, 100, 100], config: cfg)
        #expect(ev.contains(.limit))
    }

    @Test func scrollbarColumnsCanBeIgnored() {
        let page = shotPage(rows: 600)
        var cfg = ShotStitchConfig()
        cfg.ignoreRightColumns = 4
        let st = ShotStitcher(config: cfg)
        var a = shotView(page, top: 0, height: 200), b = shotView(page, top: 120, height: 200)
        for y in 0..<200 { for x in 20..<24 { a.setPixel(x, y, (UInt8(y), 0, 0, 255)); b.setPixel(x, y, (UInt8(255 - y), 9, 9, 255)) } }
        st.add(a)
        #expect(st.add(b, hint: 120) == .appended(rows: 120, total: 320))
    }

    @Test func noisyFramesStitchWithTheLiveConfiguration() {
        var cfg = ShotStitchConfig()
        cfg.mismatchTolerance = 0.01
        cfg.quantizeBits = 2
        cfg.ignoreRightColumns = 4
        let page = ShotBitmap(width: 24, height: 1200) { x, y in (UInt8((y * 3) & 255), UInt8((y >> 6) & 255), UInt8((x * 5 + y * 29) & 255), 255) }
        let st = ShotStitcher(config: cfg)
        var top = 0
        for step in [0, 300, 300, 300, 0] {
            top = min(top + step, 1200 - 400)
            var f = shotView(page, top: top, height: 400)
            f.setPixel(3, 7, (f.pixel(3, 7).0 &+ 1, 0, 0, 255))
            if top > 0 { for x in 0..<20 { f.setPixel(x, 123, (255, 255, 255, 255)) } }
            let ev = st.add(f, hint: 300)
            if step == 0 && top > 0 { #expect(ev == .reachedEnd) }
        }
        #expect(st.totalHeight == 1200)
        #expect(st.result.height == 1200 && st.finished)
    }

    @Test func finishStopsFurtherWork() {
        let st = ShotStitcher()
        st.add(shotPage(rows: 100))
        st.finish()
        #expect(st.finished && st.add(shotPage(rows: 100)) == .reachedEnd)
    }

    @Test func largePageStitchesQuickly() {
        let page = shotPage(rows: 6000, width: 16)
        let (st, _) = run(page: page, height: 600, steps: Array(repeating: 450, count: 12) + [0])
        #expect(st.result == page)
    }

    @Test func stitchedBitmapConvertsToACGImage() {
        let page = shotPage(rows: 400, width: 10)
        let (st, _) = run(page: page, height: 200, steps: [100, 100, 0])
        let img = st.result.makeImage()!
        #expect(img.width == 10 && img.height == 400)
        #expect(ShotBitmap(image: img)! == page)
    }
}

@Suite struct ShotScrollSessionTests {
    @Test func scrollsUntilTheEndOfThePage() async {
        let page = shotPage(rows: 1500)
        let d = ShotFakeScroll(page: page, height: 400)
        let r = await ShotScrollSession().run(driver: d)
        #expect(r.stop == .reachedEnd && r.bitmap == page)
        #expect(d.scrolled.allSatisfy { $0 == 300 })
    }

    @Test func shortPageStopsImmediately() async {
        let page = shotPage(rows: 400)
        let d = ShotFakeScroll(page: page, height: 400)
        let r = await ShotScrollSession().run(driver: d)
        #expect(r.stop == .reachedEnd && r.frames == 1 && r.bitmap == page)
    }

    @Test func inertiaThatScrollsLessThanAskedStillStitches() async {
        let page = shotPage(rows: 1200)
        let d = ShotFakeScroll(page: page, height: 400)
        d.moveFactor = 0.8
        let r = await ShotScrollSession().run(driver: d)
        #expect(r.stop == .reachedEnd && r.bitmap == page)
    }

    @Test func scrollingMoreThanAskedStillStitchesWithinTheHint() async {
        let page = shotPage(rows: 1400)
        let d = ShotFakeScroll(page: page, height: 400)
        d.moveFactor = 1.15
        let r = await ShotScrollSession().run(driver: d)
        #expect(r.bitmap == page)
    }

    @Test func cancelStopsAndKeepsWhatWasCaptured() async {
        let page = shotPage(rows: 3000)
        let d = ShotFakeScroll(page: page, height: 400)
        let s = ShotScrollSession()
        d.onCapture = { fake in if fake.captures == 3 { s.cancel() } }
        let r = await s.run(driver: d)
        #expect(r.stop == .cancelled && r.frames == 3 && r.bitmap.height == 400 + 300 * 2)
    }

    @Test func captureFailureStopsGracefully() async {
        let page = shotPage(rows: 3000)
        let d = ShotFakeScroll(page: page, height: 400)
        d.failAfter = 2
        let r = await ShotScrollSession().run(driver: d)
        #expect(r.stop == .captureFailed && r.frames == 2)
    }

    @Test func heightLimitEndsTheSession() async {
        var cfg = ShotStitchConfig()
        cfg.maxTotalHeight = 1000
        let d = ShotFakeScroll(page: shotPage(rows: 5000), height: 400)
        let r = await ShotScrollSession(config: cfg).run(driver: d)
        #expect(r.stop == .limit && r.bitmap.height == 1000)
    }

    @Test func progressIsReportedPerFrame() async {
        let d = ShotFakeScroll(page: shotPage(rows: 900), height: 400)
        let s = ShotScrollSession()
        var seen: [(Int, Int)] = []
        s.onProgress = { seen.append(($0, $1)) }
        _ = await s.run(driver: d)
        #expect(seen.first! == (1, 400) && seen.count >= 3 && seen.last!.1 == 900)
    }

    @Test func stepFractionIsClamped() {
        #expect(ShotScrollSession(stepFraction: 5).stepFraction == 0.95)
        #expect(ShotScrollSession(stepFraction: 0).stepFraction == 0.2)
    }

    @Test func pageWithAStickyHeaderStitches() async {
        let page = shotPage(rows: 1300)
        final class Sticky: ShotScrollDriving {
            let inner: ShotFakeScroll
            init(_ i: ShotFakeScroll) { inner = i }
            func captureFrame() async -> ShotBitmap? { await inner.captureFrame().map { shotSticky($0, header: 36) } }
            func scroll(pixels: Int) async { await inner.scroll(pixels: pixels) }
            func settle() async {}
        }
        let r = await ShotScrollSession().run(driver: Sticky(ShotFakeScroll(page: page, height: 400)))
        #expect(r.stop == .reachedEnd && r.bitmap.height == 1300)
    }
}
