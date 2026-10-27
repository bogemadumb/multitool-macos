import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let two = WndFix.displays([WndFix.clean, WndFix.rightExt])
private let three = WndFix.displays([WndFix.clean, WndFix.leftExt, WndFix.rightExt])

@Suite struct DisplayIndexTests {
    @Test func windowBelongsToTheDisplayWithTheLargestOverlap() {
        let f = CGRect(x: 1600, y: 100, width: 600, height: 400)
        #expect(DisplayMap.index(containing: f, in: two) == 1)
        #expect(DisplayMap.index(containing: CGRect(x: 1000, y: 100, width: 600, height: 400), in: two) == 0)
    }

    @Test func offscreenWindowFallsBackToTheNearestDisplay() {
        #expect(DisplayMap.index(containing: CGRect(x: 9000, y: 100, width: 100, height: 100), in: two) == 1)
        #expect(DisplayMap.index(containing: CGRect(x: -9000, y: 100, width: 100, height: 100), in: three) == 1)
    }

    @Test func noDisplaysGivesNil() {
        #expect(DisplayMap.index(containing: CGRect.zero, in: [WndDisplay]()) == nil)
        #expect(DisplayMap.index(containing: CGPoint.zero, in: [WndDisplay]()) == nil)
    }

    @Test func pointLookupUsesFrames() {
        #expect(DisplayMap.index(containing: CGPoint(x: 10, y: 10), in: two) == 0)
        #expect(DisplayMap.index(containing: CGPoint(x: 2000, y: 10), in: two) == 1)
        #expect(DisplayMap.index(containing: CGPoint(x: -100, y: 10), in: three) == 1)
    }

    @Test func pointOutsideEverythingPicksTheNearest() {
        #expect(DisplayMap.index(containing: CGPoint(x: 9999, y: 9999), in: two) == 1)
    }
}

@Suite struct DisplayOrderTests {
    @Test func orderIsLeftToRight() {
        #expect(DisplayMap.order(three) == [1, 0, 2])
    }

    @Test func equalXIsOrderedTopToBottom() {
        let d = WndFix.displays([WndFix.clean, WndFix.aboveExt])
        #expect(DisplayMap.order(d) == [1, 0])
    }

    @Test func nextAndPreviousWrapAround() {
        #expect(DisplayMap.step(from: 2, by: 1, in: three) == 1)
        #expect(DisplayMap.step(from: 1, by: -1, in: three) == 2)
        #expect(DisplayMap.step(from: 0, by: 1, in: three) == 2)
        #expect(DisplayMap.step(from: 0, by: -1, in: three) == 1)
    }

    @Test func singleDisplayCannotStep() {
        #expect(DisplayMap.step(from: 0, by: 1, in: [two[0]]) == nil)
        #expect(DisplayMap.step(from: 5, by: 1, in: two) == nil)
    }

    @Test func fullCycleVisitsEveryDisplayOnce() {
        var seen: [Int] = [0]
        var i = 0
        for _ in 0..<2 { i = DisplayMap.step(from: i, by: 1, in: three)!; seen.append(i) }
        #expect(Set(seen).count == 3)
        #expect(DisplayMap.step(from: i, by: 1, in: three) == 0)
    }
}

@Suite struct DisplayNeighbourTests {
    @Test func horizontalNeighbours() {
        #expect(DisplayMap.neighbour(of: 0, direction: .right, in: three) == 2)
        #expect(DisplayMap.neighbour(of: 0, direction: .left, in: three) == 1)
        #expect(DisplayMap.neighbour(of: 1, direction: .left, in: three) == nil)
        #expect(DisplayMap.neighbour(of: 2, direction: .right, in: three) == nil)
    }

    @Test func verticalNeighboursUseTopLeftSpace() {
        let d = WndFix.displays([WndFix.clean, WndFix.aboveExt])
        #expect(DisplayMap.neighbour(of: 0, direction: .up, in: d) == 1)
        #expect(DisplayMap.neighbour(of: 1, direction: .down, in: d) == 0)
        #expect(DisplayMap.neighbour(of: 0, direction: .down, in: d) == nil)
    }

    @Test func nearestWinsWhenSeveralLieInTheSameDirection() {
        let a = WndFix.screen(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let b = WndFix.screen(2, CGRect(x: 1000, y: 0, width: 1000, height: 800))
        let c = WndFix.screen(3, CGRect(x: 2000, y: 0, width: 1000, height: 800))
        let d = WndFix.displays([a, b, c])
        #expect(DisplayMap.neighbour(of: 0, direction: .right, in: d) == 1)
        #expect(DisplayMap.neighbour(of: 2, direction: .left, in: d) == 1)
    }

    @Test func tieIsBrokenByTheClosestCentre() {
        let a = WndFix.screen(1, CGRect(x: 0, y: 400, width: 1000, height: 800))
        let up = WndFix.screen(2, CGRect(x: 1000, y: 1200, width: 1000, height: 800))
        let low = WndFix.screen(3, CGRect(x: 1000, y: 0, width: 1000, height: 400))
        let d = WndFix.displays([a, up, low])
        #expect(DisplayMap.neighbour(of: 0, direction: .right, in: d) != nil)
    }

    @Test func invalidIndexGivesNil() {
        #expect(DisplayMap.neighbour(of: 7, direction: .left, in: two) == nil)
    }
}

@Suite struct DisplayTransferTests {
    private let small = WndFix.displays([WndFix.clean])[0]
    private let big = WndFix.displays([WndFix.clean, WndFix.rightExt])[1]

    @Test func aWindowFillingTheSourceFillsTheTarget() {
        let r = DisplayMap.transfer(small.visible, from: small, to: big)
        #expect(r == big.visible)
    }

    @Test func proportionalPlacementScalesPositionAndSize() {
        let f = CGRect(x: 450, y: 24 + 244, width: 900, height: 488)
        let r = DisplayMap.transfer(f, from: small, to: big)
        #expect(abs(r.width - 1280) <= 1)
        #expect(abs(r.minX - (big.visible.minX + 640)) <= 1)
        #expect(r.minY > big.visible.minY)
    }

    @Test func halfWindowStaysAHalfOnTheTarget() {
        let left = CGRect(x: 0, y: 24, width: 900, height: 976)
        let r = DisplayMap.transfer(left, from: small, to: big)
        #expect(r.minX == big.visible.minX)
        #expect(abs(r.width - big.visible.width / 2) <= 1)
        #expect(abs(r.height - big.visible.height) <= 1)
    }

    @Test func largeWindowIsShrunkToASmallerTarget() {
        let f = CGRect(x: 1800, y: -415, width: 2560, height: 1415)
        let r = DisplayMap.transfer(f, from: big, to: small)
        #expect(r == small.visible)
    }

    @Test func offsetWindowIsClampedIntoTheTarget() {
        let f = CGRect(x: 4200, y: 800, width: 400, height: 400)
        let r = DisplayMap.transfer(f, from: big, to: small)
        #expect(small.visible.insetBy(dx: -1, dy: -1).contains(r))
    }

    @Test func gapsShrinkTheFilledTarget() {
        let r = DisplayMap.transfer(small.visible, from: small, to: big, gaps: WindowGaps(window: 0, screen: 10))
        #expect(r == big.visible.insetBy(dx: 10, dy: 10))
    }

    @Test func degenerateSourceDoesNotCrash() {
        let zero = WndDisplay(id: 9, frame: .zero, visible: .zero)
        let r = DisplayMap.transfer(CGRect(x: 5, y: 5, width: 50, height: 50), from: zero, to: small)
        #expect(small.visible.contains(r.origin))
    }
}

@Suite struct CursorDestinationTests {
    @Test func cursorKeepsItsRelativePositionOnTheNextDisplay() {
        let p = CGPoint(x: 900, y: 500)
        let d = DisplayMap.cursorDestination(from: p, displays: two)!
        #expect(two[1].frame.contains(d))
        #expect(abs((d.x - two[1].frame.minX) / two[1].frame.width - 0.5) < 0.01)
    }

    @Test func cursorWrapsToTheFirstDisplayFromTheLast() {
        let d = DisplayMap.cursorDestination(from: CGPoint(x: 2500, y: 0), displays: two)!
        #expect(two[0].frame.contains(d))
    }

    @Test func oneDisplayHasNowhereToGo() {
        #expect(DisplayMap.cursorDestination(from: CGPoint(x: 5, y: 5), displays: [two[0]]) == nil)
    }

    @Test func cursorLandsInsideTheDisplayAtTheEdges() {
        let d = DisplayMap.cursorDestination(from: CGPoint(x: 1799, y: 999), displays: two)!
        #expect(two[1].frame.contains(d))
    }

    @Test func negativeOriginTarget() {
        let d = DisplayMap.cursorDestination(from: CGPoint(x: 10, y: 10), displays: three)!
        #expect(d.x > 1800)
        let back = DisplayMap.cursorDestination(from: CGPoint(x: 3000, y: 10), displays: three)!
        #expect(three[1].frame.contains(back))
    }
}

@Suite struct RepositionTests {
    @Test func visibleWindowIsLeftAlone() {
        let f = CGRect(x: 100, y: 100, width: 500, height: 400)
        #expect(DisplayMap.reposition(f, displays: two) == f)
    }

    @Test func windowOnAnUnpluggedDisplayIsCentredOnTheNearestOne() {
        let f = CGRect(x: -2500, y: 100, width: 500, height: 400)
        let r = DisplayMap.reposition(f, displays: [two[0]])
        #expect(two[0].visible.contains(r))
        #expect(r.size == f.size)
    }

    @Test func oversizedWindowIsShrunk() {
        let r = DisplayMap.reposition(CGRect(x: 0, y: 0, width: 6000, height: 6000), displays: [two[0]])
        #expect(r.width <= two[0].visible.width && r.height <= two[0].visible.height)
    }
}
