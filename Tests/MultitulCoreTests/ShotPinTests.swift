import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

@Suite struct ShotPinMathTests {
    @Test func opacityIsClampedAndStepped() {
        #expect(ShotPinMath.clampOpacity(0) == 0.1 && ShotPinMath.clampOpacity(7) == 1)
        #expect(ShotPinMath.steppedOpacity(1, up: false) == 0.9 && ShotPinMath.steppedOpacity(1, up: true) == 1)
        #expect(ShotPinMath.steppedOpacity(0.1, up: false) == 0.1 && ShotPinMath.steppedOpacity(0.55, up: true) == 0.7)
    }

    @Test func smallImagesKeepTheirSizeAndCentre() {
        let f = ShotPinMath.initialFrame(pointSize: CGSize(width: 300, height: 200), preferredOrigin: nil, visible: visible)
        #expect(f.size == CGSize(width: 300, height: 200) && f.midX == visible.midX && f.midY == visible.midY)
    }

    @Test func bigImagesAreShrunkToTheScreenFraction() {
        let f = ShotPinMath.initialFrame(pointSize: CGSize(width: 4000, height: 2000), preferredOrigin: nil, visible: visible)
        #expect(f.width <= visible.width * 0.6 + 0.001 && f.height <= visible.height * 0.6 + 0.001)
        #expect(abs(f.width / f.height - 2) < 0.001)
    }

    @Test func preferredOriginIsKeptButClampedOnScreen() {
        let f = ShotPinMath.initialFrame(pointSize: CGSize(width: 300, height: 200), preferredOrigin: CGPoint(x: 100, y: 300), visible: visible)
        #expect(f.origin == CGPoint(x: 100, y: 300))
        let g = ShotPinMath.initialFrame(pointSize: CGSize(width: 300, height: 200), preferredOrigin: CGPoint(x: 1400, y: 880), visible: visible)
        #expect(g.maxX <= visible.maxX && g.maxY <= visible.maxY)
    }

    @Test func fitMovesIntoTheArea() {
        #expect(ShotPinMath.fit(CGRect(x: -50, y: -50, width: 100, height: 100), in: CGRect(x: 0, y: 0, width: 500, height: 500)).origin == .zero)
        #expect(ShotPinMath.fit(CGRect(x: 0, y: 0, width: 900, height: 100), in: CGRect(x: 0, y: 0, width: 500, height: 500)).origin.x == 0)
    }

    @Test func cascadeOffsetsEachNewPinAndWrapsAround() {
        let base = CGRect(x: 500, y: 500, width: 100, height: 100)
        let a = ShotPinMath.cascaded(base, index: 1, in: visible), b = ShotPinMath.cascaded(base, index: 2, in: visible)
        #expect(a.origin == CGPoint(x: 524, y: 476) && b.origin == CGPoint(x: 548, y: 452))
        #expect(ShotPinMath.cascaded(base, index: 8, in: visible) == base)
    }

    @Test func resizeFromBottomRightKeepsTheTopLeft() {
        let f = CGRect(x: 100, y: 100, width: 200, height: 100)
        let r = ShotPinMath.resized(f, corner: .topRight, to: CGPoint(x: 500, y: 400), aspect: 2, lockAspect: false)
        #expect(r == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func resizeWithAspectLock() {
        let f = CGRect(x: 100, y: 100, width: 200, height: 100)
        let r = ShotPinMath.resized(f, corner: .topRight, to: CGPoint(x: 500, y: 250), aspect: 2, lockAspect: true)
        #expect(abs(r.width / r.height - 2) < 0.001 && r.origin == CGPoint(x: 100, y: 100) && r.width == 400)
    }

    @Test func resizeFromTheOtherCornersAnchorsTheOpposite() {
        let f = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bl = ShotPinMath.resized(f, corner: .bottomLeft, to: CGPoint(x: 50, y: 60), aspect: 2, lockAspect: false)
        #expect(bl.maxX == 300 && bl.maxY == 200 && bl.minX == 50 && bl.minY == 60)
        let tl = ShotPinMath.resized(f, corner: .topLeft, to: CGPoint(x: 150, y: 300), aspect: 2, lockAspect: false)
        #expect(tl.maxX == 300 && tl.minY == 100 && tl.minX == 150 && tl.maxY == 300)
        let br = ShotPinMath.resized(f, corner: .bottomRight, to: CGPoint(x: 400, y: 50), aspect: 2, lockAspect: false)
        #expect(br.minX == 100 && br.maxY == 200 && br.minY == 50 && br.maxX == 400)
    }

    @Test func resizeNeverGoesBelowTheMinimum() {
        let f = CGRect(x: 100, y: 100, width: 200, height: 100)
        let r = ShotPinMath.resized(f, corner: .topRight, to: CGPoint(x: 101, y: 101), aspect: 2, lockAspect: false)
        #expect(r.width == ShotPinMath.minSide && r.height == ShotPinMath.minSide)
        let l = ShotPinMath.resized(f, corner: .topRight, to: CGPoint(x: 101, y: 101), aspect: 2, lockAspect: true)
        #expect(l.height >= ShotPinMath.minSide && l.width >= ShotPinMath.minSide)
    }

    @Test func resizeRespectsAMaximum() {
        let f = CGRect(x: 0, y: 0, width: 200, height: 100)
        let r = ShotPinMath.resized(f, corner: .topRight, to: CGPoint(x: 5000, y: 2500), aspect: 2, lockAspect: true, maxSize: CGSize(width: 1000, height: 800))
        #expect(r.width <= 1000 && r.height <= 800 && abs(r.width / r.height - 2) < 0.001)
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        let f = CGRect(x: 100, y: 100, width: 400, height: 200)
        let anchor = CGPoint(x: 300, y: 150)
        let z = ShotPinMath.zoomed(f, factor: 1.5, around: anchor, imagePointSize: CGSize(width: 400, height: 200))
        #expect(z.width == 600 && z.height == 300)
        let kx = (anchor.x - f.minX) / f.width, ky = (anchor.y - f.minY) / f.height
        #expect(abs((z.minX + kx * z.width) - anchor.x) < 0.001 && abs((z.minY + ky * z.height) - anchor.y) < 0.001)
    }

    @Test func zoomIsLimitedByTheRange() {
        let f = CGRect(x: 0, y: 0, width: 400, height: 200)
        let big = ShotPinMath.zoomed(f, factor: 100, around: .zero, imagePointSize: CGSize(width: 400, height: 200))
        #expect(big.width == 3200)
        let small = ShotPinMath.zoomed(f, factor: 0.001, around: .zero, imagePointSize: CGSize(width: 400, height: 200))
        #expect(small.width == 48 || small.width == 40)
        #expect(ShotPinMath.zoomed(f, factor: 0, around: .zero, imagePointSize: CGSize(width: 400, height: 200)) == f)
    }

    @Test func zoomCanBeCappedByTheScreen() {
        let f = CGRect(x: 0, y: 0, width: 400, height: 200)
        let z = ShotPinMath.zoomed(f, factor: 10, around: .zero, imagePointSize: CGSize(width: 400, height: 200), maxSize: CGSize(width: 1000, height: 800))
        #expect(z.width <= 1000 && z.height <= 800 && abs(z.width / z.height - 2) < 0.001)
    }

    @Test func reachableKeepsAGripOnScreen() {
        let f = CGRect(x: -5000, y: 3000, width: 300, height: 200)
        let r = ShotPinMath.keepReachable(f, in: visible)
        #expect(r.maxX >= 40 && r.minY <= visible.maxY - 40)
        #expect(ShotPinMath.keepReachable(CGRect(x: 100, y: 100, width: 100, height: 100), in: visible) == CGRect(x: 100, y: 100, width: 100, height: 100))
    }
}

@Suite struct ShotPinBoardTests {
    private func board(_ limit: Int = 24) -> ShotPinBoard { ShotPinBoard(limit: limit) }
    private func add(_ b: ShotPinBoard, _ t: String = "p", origin: CGPoint? = nil) -> Int {
        b.add(title: t, recordID: nil, imagePointSize: CGSize(width: 300, height: 200), visible: visible, preferredOrigin: origin).id
    }

    @Test func addAssignsIdsAndCascades() {
        let b = board()
        let a = add(b), c = add(b)
        #expect(a == 1 && c == 2 && b.count == 2)
        #expect(b.pin(a)!.frame != b.pin(c)!.frame)
    }

    @Test func explicitOriginIsNotCascaded() {
        let b = board()
        _ = add(b, origin: CGPoint(x: 50, y: 100))
        let id = add(b, origin: CGPoint(x: 50, y: 100))
        #expect(b.pin(id)!.frame.origin == CGPoint(x: 50, y: 100))
    }

    @Test func limitEvictsTheOldest() {
        let b = board(2)
        let a = add(b)
        _ = add(b)
        let r = b.add(title: "n", recordID: 5, imagePointSize: CGSize(width: 10, height: 10), visible: visible)
        #expect(r.evicted == a && b.count == 2 && b.pin(a) == nil && b.pin(r.id)?.recordID == 5)
    }

    @Test func opacityAndClickThrough() {
        let b = board()
        let id = add(b)
        b.setOpacity(id, 0.05)
        #expect(b.pin(id)!.opacity == 0.1)
        b.stepOpacity(id, up: true)
        #expect(b.pin(id)!.opacity == 0.2)
        b.toggleClickThrough(id)
        #expect(b.pin(id)!.clickThrough && b.clickThroughCount == 1)
        b.setAllClickThrough(false)
        #expect(!b.pin(id)!.clickThrough && b.clickThroughCount == 0)
    }

    @Test func bringToFrontReorders() {
        let b = board()
        let a = add(b), c = add(b), d = add(b)
        b.bringToFront(a)
        #expect(b.pins.map(\.id) == [c, d, a])
        b.bringToFront(a)
        #expect(b.pins.map(\.id) == [c, d, a])
    }

    @Test func hidingAllIsReversible() {
        let b = board()
        let a = add(b), c = add(b)
        b.update(c) { $0.hidden = true }
        #expect(b.visiblePins.map(\.id) == [a])
        b.toggleAllHidden()
        #expect(b.visiblePins.isEmpty && b.allHidden)
        b.toggleAllHidden()
        #expect(b.visiblePins.map(\.id) == [a])
    }

    @Test func addingAfterHideAllShowsEverything() {
        let b = board()
        _ = add(b)
        b.setAllHidden(true)
        _ = add(b)
        #expect(!b.allHidden && b.visiblePins.count == 2)
    }

    @Test func removeAndRemoveAll() {
        let b = board()
        let a = add(b), c = add(b)
        b.remove(a)
        #expect(b.pins.map(\.id) == [c])
        b.removeAll()
        #expect(b.count == 0)
        b.remove(77)
        b.setFrame(77, .zero)
    }

    @Test func zoomIsTheFrameOverTheImageSize() {
        let b = board()
        let id = add(b)
        b.setFrame(id, CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(b.pin(id)!.zoom == 2 && b.pin(id)!.aspect == 1.5)
    }
}

@Suite struct ShotOverlayTests {
    @Test func actionsDependOnWhetherTheFileIsSaved() {
        #expect(ShotOverlayLogic.actions(saved: false, uploadConfigured: false) == [.copy, .save, .edit, .pin, .share, .delete, .close])
        #expect(ShotOverlayLogic.actions(saved: true, uploadConfigured: true) == [.copy, .edit, .pin, .link, .share, .delete, .close])
    }

    @Test func everyCatalogActionIsPresentSomewhere() {
        let all = Set(ShotOverlayLogic.actions(saved: false, uploadConfigured: true))
        for a in [ShotOverlayAction.copy, .save, .edit, .pin, .share, .delete, .link] { #expect(all.contains(a)) }
        #expect(ShotOverlayAction.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func thumbnailKeepsTheAspectAndNeverUpscales() {
        let t = ShotOverlayLogic.thumbnailSize(pixel: CGSize(width: 2000, height: 1000))
        #expect(t.width == 220 && t.height == 110)
        let tall = ShotOverlayLogic.thumbnailSize(pixel: CGSize(width: 500, height: 2000))
        #expect(tall.height <= 165 && tall.width >= 80)
        #expect(ShotOverlayLogic.thumbnailSize(pixel: CGSize(width: 100, height: 100)).width == 100)
        #expect(ShotOverlayLogic.thumbnailSize(pixel: .zero).width == 220)
    }

    @Test func slotsStackFromTheChosenCorner() {
        let size = CGSize(width: 200, height: 100)
        let br0 = ShotOverlayLogic.frame(slot: 0, corner: .bottomRight, visible: visible, size: size)
        let br1 = ShotOverlayLogic.frame(slot: 1, corner: .bottomRight, visible: visible, size: size)
        #expect(br0.maxX == visible.maxX - 16 && br0.minY == visible.minY + 16 && br1.minY == br0.maxY + 10)
        let tl1 = ShotOverlayLogic.frame(slot: 1, corner: .topLeft, visible: visible, size: size)
        #expect(tl1.minX == 16 && tl1.maxY == visible.maxY - 16 - 110)
    }

    @Test func stackEvictsTheOldestBeyondTheLimit() {
        var s = ShotOverlayStack(limit: 2)
        let p1 = s.push(1), p2 = s.push(2), p3 = s.push(3)
        #expect(p1 == nil && p2 == nil && p3 == 1 && s.ids == [3, 2])
        #expect(s.slot(of: 2) == 1)
        s.remove(3)
        #expect(s.ids == [2] && s.slot(of: 3) == nil)
    }

    @Test func pushingAnExistingIdMovesItToTheFront() {
        var s = ShotOverlayStack(limit: 3)
        s.push(1); s.push(2)
        let evicted = s.push(1)
        #expect(evicted == nil && s.ids == [1, 2])
    }

    @Test func timerExpiresAfterItsDuration() {
        var t = ShotOverlayTimer(seconds: 3)
        let a = t.tick(1), b = t.tick(1), c = t.tick(1.1)
        #expect(!a && !b && c)
    }

    @Test func hoverPausesTheTimerAndGivesAGraceOnLeave() {
        var t = ShotOverlayTimer(seconds: 4)
        _ = t.tick(3.5)
        t.setHover(true)
        let frozen = t.tick(100)
        #expect(!frozen && t.paused)
        t.setHover(false)
        #expect(t.remaining >= 2)
        let early = t.tick(1.5), late = t.tick(1)
        #expect(!early && late)
    }

    @Test func zeroSecondsMeansSticky() {
        var t = ShotOverlayTimer(seconds: 0)
        let expired = t.tick(10000)
        #expect(t.isSticky && !expired && t.fraction == 1)
        #expect(ShotOverlayTimer(seconds: -5).isSticky)
    }

    @Test func fractionShrinks() {
        var t = ShotOverlayTimer(seconds: 10)
        _ = t.tick(2.5)
        #expect(t.fraction == 0.75)
    }

    @Test func countdownCounts() {
        var c = ShotCountdown(seconds: 3)
        #expect(c.isRunning)
        let a = c.tick(), b = c.tick(), d = c.tick()
        #expect(!a && !b && d && !c.isRunning)
    }

    @Test func countdownCanBeCancelled() {
        var c = ShotCountdown(seconds: 3)
        _ = c.tick()
        c.cancel()
        let after = c.tick()
        #expect(!after && !c.isRunning && c.remaining == 2)
        var zero = ShotCountdown(seconds: 0)
        let fired = zero.tick()
        #expect(fired)
    }
}
