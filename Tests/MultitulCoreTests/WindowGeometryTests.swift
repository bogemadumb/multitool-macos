import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func vis(_ s: WndScreen) -> CGRect { WndFix.displays([s])[0].visible }
private func rect(_ a: WindowLayoutAction, _ s: WndScreen = WndFix.clean, gaps: WindowGaps = .none, margin: Double = 5, current: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300), custom: FractionRect? = nil) -> CGRect {
    WindowGeometry.rect(for: a, current: current, visible: vis(s), gaps: gaps, marginPercent: margin, custom: custom)!
}

@Suite struct ScreenSpaceTests {
    @Test func flipRectRoundTrips() {
        let r = CGRect(x: 10, y: 40, width: 300, height: 200)
        let f = ScreenSpace.flip(r, primaryHeight: 1000)
        #expect(f == CGRect(x: 10, y: 760, width: 300, height: 200))
        #expect(ScreenSpace.flip(f, primaryHeight: 1000) == r)
    }

    @Test func flipPointMatchesRectCorner() {
        #expect(ScreenSpace.flip(CGPoint(x: 5, y: 100), primaryHeight: 1000) == CGPoint(x: 5, y: 900))
    }

    @Test func primaryHeightUsesScreenAtOrigin() {
        #expect(ScreenSpace.primaryHeight([WndFix.leftExt, WndFix.clean]) == 1000)
        #expect(ScreenSpace.primaryHeight([WndFix.clean, WndFix.leftExt]) == 1000)
    }

    @Test func primaryHeightFallsBackToFirstScreenWithoutOrigin() {
        #expect(ScreenSpace.primaryHeight([WndFix.leftExt]) == 1080)
        #expect(ScreenSpace.primaryHeight([]) == 0)
    }

    @Test func menuBarBecomesTopInset() {
        let d = WndFix.displays([WndFix.clean])[0]
        #expect(d.frame == CGRect(x: 0, y: 0, width: 1800, height: 1000))
        #expect(d.visible == CGRect(x: 0, y: 24, width: 1800, height: 976))
    }

    @Test func dockAtBottomShrinksVisibleHeightFromBelow() {
        #expect(vis(WndFix.cleanDockBottom) == CGRect(x: 0, y: 24, width: 1800, height: 906))
    }

    @Test func notchMenuBarIsThirtyEightPoints() {
        let d = WndFix.displays([WndFix.notch])[0]
        #expect(d.visible.minY == 38)
        #expect(d.visible.height == 1069)
    }

    @Test func externalToTheLeftKeepsNegativeX() {
        let d = WndFix.displays([WndFix.clean, WndFix.leftExt])
        #expect(d[1].frame == CGRect(x: -1920, y: -80, width: 1920, height: 1080))
        #expect(d[1].visible == CGRect(x: -1920, y: -55, width: 1920, height: 1055))
    }

    @Test func externalAbovePrimaryHasNegativeTopLeftY() {
        let d = WndFix.displays([WndFix.clean, WndFix.aboveExt])
        #expect(d[1].frame.minY == -1080)
        #expect(d[1].frame.maxY == 0)
    }

    @Test func tallerExternalToTheRightStartsAboveTheOrigin() {
        let d = WndFix.displays([WndFix.clean, WndFix.rightExt])
        #expect(d[1].frame == CGRect(x: 1800, y: -440, width: 2560, height: 1440))
        #expect(d[1].visible.minY == -415)
    }
}

@Suite struct WindowGeometryRectTests {
    @Test func leftAndRightHalves() {
        #expect(rect(.leftHalf) == CGRect(x: 0, y: 24, width: 900, height: 976))
        #expect(rect(.rightHalf) == CGRect(x: 900, y: 24, width: 900, height: 976))
    }

    @Test func topAndBottomHalvesAreBelowTheMenuBar() {
        #expect(rect(.topHalf) == CGRect(x: 0, y: 24, width: 1800, height: 488))
        #expect(rect(.bottomHalf) == CGRect(x: 0, y: 512, width: 1800, height: 488))
    }

    @Test func centerHalf() {
        #expect(rect(.centerHalf) == CGRect(x: 450, y: 24, width: 900, height: 976))
    }

    @Test func thirds() {
        #expect(rect(.leftThird) == CGRect(x: 0, y: 24, width: 600, height: 976))
        #expect(rect(.centerThird) == CGRect(x: 600, y: 24, width: 600, height: 976))
        #expect(rect(.rightThird) == CGRect(x: 1200, y: 24, width: 600, height: 976))
    }

    @Test func verticalThirdsShareEdges() {
        let t = rect(.topThird), m = rect(.middleThird), b = rect(.bottomThird)
        #expect(t.maxY == m.minY && m.maxY == b.minY)
        #expect(t.minY == 24 && b.maxY == 1000)
    }

    @Test func twoThirds() {
        #expect(rect(.leftTwoThirds) == CGRect(x: 0, y: 24, width: 1200, height: 976))
        #expect(rect(.rightTwoThirds) == CGRect(x: 600, y: 24, width: 1200, height: 976))
        #expect(rect(.centerTwoThirds) == CGRect(x: 300, y: 24, width: 1200, height: 976))
    }

    @Test func verticalTwoThirds() {
        let t = rect(.topTwoThirds), b = rect(.bottomTwoThirds)
        #expect(t.minY == 24 && b.maxY == 1000)
        #expect(t.height == b.height)
    }

    @Test func cornerQuarters() {
        #expect(rect(.topLeft) == CGRect(x: 0, y: 24, width: 900, height: 488))
        #expect(rect(.topRight) == CGRect(x: 900, y: 24, width: 900, height: 488))
        #expect(rect(.bottomLeft) == CGRect(x: 0, y: 512, width: 900, height: 488))
        #expect(rect(.bottomRight) == CGRect(x: 900, y: 512, width: 900, height: 488))
    }

    @Test func columnQuarters() {
        let cols = [WindowLayoutAction.leftQuarter, .leftMiddleQuarter, .rightMiddleQuarter, .rightQuarter].map { rect($0) }
        #expect(cols.map(\.minX) == [0, 450, 900, 1350])
        #expect(cols.allSatisfy { $0.width == 450 && $0.height == 976 })
    }

    @Test func rowQuarters() {
        let rows = [WindowLayoutAction.topQuarter, .upperMiddleQuarter, .lowerMiddleQuarter, .bottomQuarter].map { rect($0) }
        #expect(rows.map(\.minY) == [24, 268, 512, 756])
        #expect(rows.allSatisfy { $0.height == 244 && $0.width == 1800 })
    }

    @Test func sixths() {
        #expect(rect(.topLeftSixth) == CGRect(x: 0, y: 24, width: 600, height: 488))
        #expect(rect(.topCenterSixth) == CGRect(x: 600, y: 24, width: 600, height: 488))
        #expect(rect(.bottomRightSixth) == CGRect(x: 1200, y: 512, width: 600, height: 488))
    }

    @Test func maximizeIsTheWholeVisibleArea() {
        #expect(rect(.maximize) == vis(WndFix.clean))
        #expect(rect(.maximize, WndFix.cleanDockLeft) == CGRect(x: 80, y: 24, width: 1720, height: 976))
        #expect(rect(.maximize, WndFix.cleanDockRight) == CGRect(x: 0, y: 24, width: 1720, height: 976))
        #expect(rect(.maximize, WndFix.cleanDockBottom) == CGRect(x: 0, y: 24, width: 1800, height: 906))
    }

    @Test func notchScreenKeepsWindowsBelowTheNotchBar() {
        #expect(rect(.maximize, WndFix.notch).minY == 38)
        #expect(rect(.leftHalf, WndFix.notch).width == 855)
    }

    @Test func dockOnTheLeftShiftsHalves() {
        #expect(rect(.leftHalf, WndFix.cleanDockLeft) == CGRect(x: 80, y: 24, width: 860, height: 976))
        #expect(rect(.rightHalf, WndFix.cleanDockLeft) == CGRect(x: 940, y: 24, width: 860, height: 976))
    }

    @Test func dockOnTheBottomShortensBottomHalf() {
        let top = rect(.topHalf, WndFix.cleanDockBottom), bottom = rect(.bottomHalf, WndFix.cleanDockBottom)
        #expect(bottom.maxY == 930)
        #expect(top.maxY == bottom.minY)
    }

    @Test func thirdsOnAnOddWidthTileWithoutGapsOrOverlap() {
        let a = rect(.leftThird, WndFix.cleanDockLeft), b = rect(.centerThird, WndFix.cleanDockLeft), c = rect(.rightThird, WndFix.cleanDockLeft)
        #expect(a.maxX == b.minX && b.maxX == c.minX)
        #expect(a.minX == 80 && c.maxX == 1800)
    }

    @Test func marginMaximizeInsetsEachEdgeByPercent() {
        let r = rect(.marginMaximize, margin: 5)
        #expect(r == CGRect(x: 90, y: 73, width: 1620, height: 878))
    }

    @Test func marginIsClampedToRange() {
        #expect(rect(.marginMaximize, margin: 80) == rect(.marginMaximize, margin: 25))
        #expect(rect(.marginMaximize, margin: -3) == vis(WndFix.clean))
    }

    @Test func centerKeepsSizeAndCentersInVisibleArea() {
        let r = rect(.center, current: CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(r == CGRect(x: 600, y: 312, width: 600, height: 400))
    }

    @Test func centerShrinksAWindowLargerThanTheScreen() {
        let r = rect(.center, current: CGRect(x: 0, y: 0, width: 5000, height: 4000))
        #expect(r == vis(WndFix.clean))
    }

    @Test func nonRectangularActionsHaveNoRect() {
        for a in [WindowLayoutAction.restore, .nextDisplay, .previousDisplay] {
            #expect(WindowGeometry.rect(for: a, current: .zero, visible: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        }
    }

    @Test func customLayoutUsesItsFraction() {
        let r = rect(.custom1, custom: FractionRect(x: 0.25, y: 0, w: 0.5, h: 0.5))
        #expect(r == CGRect(x: 450, y: 24, width: 900, height: 488))
        #expect(WindowGeometry.rect(for: .custom2, current: .zero, visible: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
    }

    @Test func negativeOriginDisplayGeometry() {
        let d = WndFix.displays([WndFix.clean, WndFix.leftExt])[1]
        let r = WindowGeometry.rect(for: .leftHalf, current: .zero, visible: d.visible)!
        #expect(r == CGRect(x: -1920, y: -55, width: 960, height: 1055))
        let m = WindowGeometry.rect(for: .maximize, current: .zero, visible: d.visible)!
        #expect(m == d.visible)
    }

    @Test func displayAbovePrimaryGeometry() {
        let d = WndFix.displays([WndFix.clean, WndFix.aboveExt])[1]
        let r = WindowGeometry.rect(for: .bottomHalf, current: .zero, visible: d.visible)!
        #expect(r.maxY == d.visible.maxY)
        #expect(r.minY < 0)
    }

    @Test func everyFractionalActionStaysInsideEveryScreen() {
        for s in WndFix.allSingles + [WndFix.leftExt, WndFix.rightExt, WndFix.aboveExt] {
            let v = WndFix.displays([s])[0].visible
            for a in WindowLayoutAction.snapTargets {
                guard let r = WindowGeometry.rect(for: a, current: v, visible: v, custom: a.customSlot != nil ? FractionRect(x: 0.2, y: 0.2, w: 0.5, h: 0.5) : nil) else { continue }
                #expect(r.width >= 1 && r.height >= 1)
                #expect(v.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(a) on \(s.id)")
            }
        }
    }

    @Test func complementaryHalvesCoverTheAreaExactly() {
        for s in WndFix.allSingles {
            let v = vis(s)
            let l = rect(.leftHalf, s), r = rect(.rightHalf, s), t = rect(.topHalf, s), b = rect(.bottomHalf, s)
            #expect(l.width + r.width == v.width && l.maxX == r.minX)
            #expect(t.height + b.height == v.height && t.maxY == b.minY)
        }
    }

    @Test func quartersAndSixthsSumToTheArea() {
        for s in WndFix.allSingles {
            let v = vis(s)
            let q = [WindowLayoutAction.topLeft, .topRight, .bottomLeft, .bottomRight].map { rect($0, s) }
            let x = [WindowLayoutAction.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth].map { rect($0, s) }
            #expect(q.reduce(0) { $0 + $1.width * $1.height } == v.width * v.height)
            #expect(x.reduce(0) { $0 + $1.width * $1.height } == v.width * v.height)
        }
    }
}

@Suite struct WindowGapTests {
    @Test func windowGapSeparatesNeighbours() {
        let g = WindowGaps(window: 20, screen: 0)
        let l = rect(.leftHalf, gaps: g), r = rect(.rightHalf, gaps: g)
        #expect(r.minX - l.maxX == 20)
        #expect(l.minX == 0 && r.maxX == 1800)
    }

    @Test func windowGapDoesNotShrinkOuterEdges() {
        let g = WindowGaps(window: 20, screen: 0)
        let m = rect(.maximize, gaps: g)
        #expect(m == vis(WndFix.clean))
    }

    @Test func screenGapInsetsEveryOuterEdge() {
        let g = WindowGaps(window: 0, screen: 16)
        #expect(rect(.maximize, gaps: g) == CGRect(x: 16, y: 40, width: 1768, height: 944))
        #expect(rect(.leftHalf, gaps: g).minX == 16)
        #expect(rect(.rightHalf, gaps: g).maxX == 1784)
    }

    @Test func bothGapsCombine() {
        let g = WindowGaps(window: 10, screen: 20)
        let l = rect(.leftHalf, gaps: g), r = rect(.rightHalf, gaps: g)
        #expect(l.minX == 20 && r.maxX == 1780)
        #expect(r.minX - l.maxX == 10)
    }

    @Test func middleThirdLosesHalfAGapOnBothSides() {
        let g = WindowGaps(window: 20, screen: 0)
        let a = rect(.leftThird, gaps: g), b = rect(.centerThird, gaps: g), c = rect(.rightThird, gaps: g)
        #expect(b.minX - a.maxX == 20 && c.minX - b.maxX == 20)
        #expect(a.minX == 0 && c.maxX == 1800)
    }

    @Test func gapsApplyVerticallyToo() {
        let g = WindowGaps(window: 12, screen: 0)
        let t = rect(.topHalf, gaps: g), b = rect(.bottomHalf, gaps: g)
        #expect(b.minY - t.maxY == 12)
    }

    @Test func gapsAreSanitized() {
        #expect(WindowGaps(window: -5, screen: 999).sanitized == WindowGaps(window: 0, screen: 128))
    }

    @Test func absurdScreenGapFallsBackToTheVisibleArea() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(WindowGeometry.usableArea(tiny, gaps: WindowGaps(window: 0, screen: 128)) == tiny)
    }

    @Test func cornerQuartersKeepTheGapOnInnerEdgesOnly() {
        let g = WindowGaps(window: 10, screen: 0)
        let tl = rect(.topLeft, gaps: g), br = rect(.bottomRight, gaps: g)
        #expect(tl.minX == 0 && tl.minY == 24)
        #expect(br.maxX == 1800 && br.maxY == 1000)
        #expect(br.minX - tl.maxX == 10)
    }
}

@Suite struct FractionRectTests {
    @Test func sanitizedKeepsTheRectInsideTheUnitSquare() {
        let r = FractionRect(x: 0.9, y: -1, w: 0.5, h: 5).sanitized
        #expect(r.x == 0.5 && r.y == 0 && r.w == 0.5 && r.h == 1)
    }

    @Test func sanitizedFixesNonFiniteAndTinySides() {
        let r = FractionRect(x: .nan, y: .infinity, w: 0, h: .nan).sanitized
        #expect(r.w == FractionRect.minSide && r.h == FractionRect.minSide)
        #expect(r.x.isFinite && r.y.isFinite)
    }

    @Test func storedRoundTrips() {
        let r = FractionRect(x: 0.1234, y: 0.25, w: 0.25, h: 0.75)
        #expect(FractionRect(stored: r.stored) == r)
    }

    @Test func badStoredStringIsRejected() {
        #expect(FractionRect(stored: "1,2,3") == nil)
        #expect(FractionRect(stored: "a,b,c,d") == nil)
    }
}

@Suite struct MinimumSizeTests {
    private let area = CGRect(x: 0, y: 24, width: 1800, height: 976)

    @Test func fittingGrowsALeftWindowToTheRight() {
        let r = WindowGeometry.fitting(CGRect(x: 0, y: 24, width: 300, height: 976), minSize: CGSize(width: 500, height: 100), in: area)
        #expect(r == CGRect(x: 0, y: 24, width: 500, height: 976))
    }

    @Test func fittingGrowsARightWindowToTheLeft() {
        let r = WindowGeometry.fitting(CGRect(x: 1500, y: 24, width: 300, height: 976), minSize: CGSize(width: 500, height: 100), in: area)
        #expect(r == CGRect(x: 1300, y: 24, width: 500, height: 976))
    }

    @Test func fittingGrowsACenteredWindowSymmetrically() {
        let r = WindowGeometry.fitting(CGRect(x: 600, y: 24, width: 600, height: 976), minSize: CGSize(width: 800, height: 100), in: area)
        #expect(r == CGRect(x: 500, y: 24, width: 800, height: 976))
    }

    @Test func fittingNeverExceedsTheArea() {
        let r = WindowGeometry.fitting(CGRect(x: 0, y: 24, width: 300, height: 300), minSize: CGSize(width: 5000, height: 5000), in: area)
        #expect(r == area)
    }

    @Test func fittingBottomAnchorGrowsUpwards() {
        let r = WindowGeometry.fitting(CGRect(x: 0, y: 800, width: 900, height: 200), minSize: CGSize(width: 100, height: 400), in: area)
        #expect(r.maxY == 1000 && r.height == 400)
    }

    @Test func fittingLeavesBigEnoughWindowsAlone() {
        let w = CGRect(x: 100, y: 100, width: 700, height: 500)
        #expect(WindowGeometry.fitting(w, minSize: CGSize(width: 200, height: 200), in: area) == w)
    }

    @Test func settleCentersASmallerFixedSizeWindowInItsCell() {
        let target = CGRect(x: 0, y: 24, width: 900, height: 976)
        let r = WindowGeometry.settle(target: target, actualSize: CGSize(width: 400, height: 300), area: area)
        #expect(r == CGRect(x: 250, y: 362, width: 400, height: 300))
    }

    @Test func settleAnchorsAnOversizedWindowToTheCellEdge() {
        let target = CGRect(x: 1350, y: 24, width: 450, height: 976)
        let r = WindowGeometry.settle(target: target, actualSize: CGSize(width: 700, height: 976), area: area)
        #expect(r.maxX == 1800 && r.width == 700)
    }

    @Test func settleKeepsTheWindowInsideTheArea() {
        let target = CGRect(x: 0, y: 24, width: 450, height: 976)
        let r = WindowGeometry.settle(target: target, actualSize: CGSize(width: 9000, height: 976), area: area)
        #expect(r.minX == 0 && r.width == 1800)
    }

    @Test func clampPullsAWindowBackIntoTheArea() {
        let r = WindowGeometry.clamp(CGRect(x: 1700, y: -50, width: 400, height: 300), into: area)
        #expect(r == CGRect(x: 1400, y: 24, width: 400, height: 300))
    }

    @Test func approxEqualUsesTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(WindowGeometry.approxEqual(a, a.offsetBy(dx: 8, dy: 0)))
        #expect(!WindowGeometry.approxEqual(a, a.offsetBy(dx: 9, dy: 0)))
        #expect(WindowGeometry.approxSize(CGSize(width: 10, height: 10), CGSize(width: 11, height: 9)))
    }
}
