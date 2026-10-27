import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func doc() -> AnnotationDocument { AnnotationDocument(canvasWidth: 800, canvasHeight: 600) }

private func item(_ kind: AnnotationKind, _ pts: [CGPoint], width: Double = 4, filled: Bool = false) -> AnnotationItem {
    AnnotationItem(id: 1, kind: kind, points: pts, style: AnnotationStyle(color: .red, strokeWidth: width, filled: filled))
}

@Suite struct AnnotationDocumentTests {
    @Test func addAssignsGrowingIds() {
        var d = doc()
        let a = d.add(.rectangle, points: [pt(0, 0), pt(10, 10)])
        let b = d.add(.line, points: [pt(0, 0), pt(10, 10)])
        #expect(a == 1 && b == 2 && d.nextID == 3 && d.item(2)?.kind == .line)
    }

    @Test func stepsAreNumberedInOrder() {
        var d = doc()
        let a = d.add(.step, points: [pt(10, 10)]), b = d.add(.step, points: [pt(40, 10)]), c = d.add(.step, points: [pt(70, 10)])
        #expect([a, b, c].map { d.item($0)!.number } == [1, 2, 3])
        #expect(d.nextStepNumber == 4)
    }

    @Test func removingAStepRenumbersTheRest() {
        var d = doc()
        let a = d.add(.step, points: [pt(10, 10)]), _ = d.add(.step, points: [pt(40, 10)]), c = d.add(.step, points: [pt(70, 10)])
        d.remove([a])
        #expect(d.items.map(\.number) == [1, 2] && d.item(c)?.number == 2)
    }

    @Test func removingOtherItemsLeavesStepNumbers() {
        var d = doc()
        let r = d.add(.rectangle, points: [pt(0, 0), pt(5, 5)])
        _ = d.add(.step, points: [pt(10, 10)])
        d.remove([r])
        #expect(d.items.count == 1 && d.items[0].number == 1)
    }

    @Test func renderOrderPutsEffectsFirstAndTextLast() {
        var d = doc()
        d.add(.text, points: [pt(1, 1)], text: "t")
        d.add(.arrow, points: [pt(0, 0), pt(9, 9)])
        d.add(.blur, points: [pt(0, 0), pt(9, 9)])
        d.add(.step, points: [pt(3, 3)])
        d.add(.highlighter, points: [pt(0, 0), pt(9, 9)])
        d.add(.pixelate, points: [pt(0, 0), pt(9, 9)])
        d.add(.rectangle, points: [pt(0, 0), pt(9, 9)])
        #expect(d.renderOrder.map(\.kind) == [.blur, .pixelate, .highlighter, .arrow, .rectangle, .step, .text])
    }

    @Test func renderOrderKeepsInsertionOrderInsideALayer() {
        var d = doc()
        let a = d.add(.rectangle, points: [pt(0, 0), pt(9, 9)]), b = d.add(.arrow, points: [pt(0, 0), pt(9, 9)]), c = d.add(.ellipse, points: [pt(0, 0), pt(9, 9)])
        #expect(d.renderOrder.map(\.id) == [a, b, c])
        d.bringToFront(a)
        #expect(d.renderOrder.map(\.id) == [b, c, a])
        d.sendToBack(a)
        #expect(d.items.map(\.id) == [a, b, c])
    }

    @Test func hitTestReturnsTheTopmostItem() {
        var d = doc()
        let under = d.add(.rectangle, points: [pt(10, 10), pt(200, 200)], style: AnnotationStyle(filled: true))
        let over = d.add(.ellipse, points: [pt(50, 50), pt(150, 150)], style: AnnotationStyle(filled: true))
        #expect(d.hitTest(pt(100, 100)) == over)
        #expect(d.hitTest(pt(20, 20)) == under)
        #expect(d.hitTest(pt(500, 500)) == nil)
    }

    @Test func effectsLoseHitTestsToShapesAboveThem() {
        var d = doc()
        let blur = d.add(.blur, points: [pt(0, 0), pt(100, 100)])
        let arrow = d.add(.line, points: [pt(0, 50), pt(100, 50)])
        #expect(d.hitTest(pt(50, 50)) == arrow)
        #expect(d.hitTest(pt(50, 10)) == blur)
    }

    @Test func jsonRoundTripKeepsEverything() throws {
        var d = doc()
        d.add(.arrow, points: [pt(1.5, 2.5), pt(30, 40)], style: AnnotationStyle(color: .blue, strokeWidth: 7))
        d.add(.text, points: [pt(5, 5)], style: AnnotationStyle(fontSize: 40), text: "Привет, мир", boxSize: CGSize(width: 120, height: 48))
        d.add(.pen, points: [pt(1, 1), pt(2, 3), pt(5, 8)])
        d.add(.step, points: [pt(9, 9)])
        d.add(.pixelate, points: [pt(0, 0), pt(50, 60)], style: AnnotationStyle(strength: 0.3))
        d.crop = CGRect(x: 10, y: 20, width: 300, height: 200)
        let data = try d.json()
        #expect(try AnnotationDocument.decode(data) == d)
    }

    @Test func jsonKeysAndEnumValuesAreAscii() throws {
        var d = doc()
        d.add(.text, points: [pt(5, 5)], text: "Текст")
        let s = String(decoding: try d.json(), as: UTF8.self)
        let outside = s.unicodeScalars.filter { !$0.isASCII }.map(String.init).joined()
        #expect(outside == "Текст")
        #expect(s.contains("\"kind\":\"text\"") && s.contains("\"version\":1"))
    }

    @Test func jsonIsDeterministic() throws {
        var d = doc()
        d.add(.rectangle, points: [pt(0, 0), pt(9, 9)])
        #expect(try d.json() == d.json())
    }

    @Test func decodeRejectsNewerVersionsAndGarbage() throws {
        var d = doc()
        d.version = 99
        let data = try d.json()
        #expect(throws: (any Error).self) { try AnnotationDocument.decode(data) }
        #expect(throws: (any Error).self) { try AnnotationDocument.decode(Data("nope".utf8)) }
    }

    @Test func effectiveCropIsClampedAndIgnoredWhenFull() {
        var d = doc()
        d.crop = CGRect(x: -20, y: -20, width: 500, height: 400)
        #expect(d.effectiveCrop == CGRect(x: 0, y: 0, width: 480, height: 380))
        d.crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(d.effectiveCrop == nil)
        d.crop = CGRect(x: 900, y: 900, width: 10, height: 10)
        #expect(d.effectiveCrop == nil)
        d.crop = nil
        #expect(d.effectiveCrop == nil && d.isEmpty)
    }

    @Test func updateReplacesByIdOnly() {
        var d = doc()
        let a = d.add(.rectangle, points: [pt(0, 0), pt(9, 9)])
        var it = d.item(a)!
        it.points = [pt(1, 1), pt(5, 5)]
        d.update(it)
        d.update(AnnotationItem(id: 77, kind: .line, points: []))
        #expect(d.items.count == 1 && d.item(a)?.points[0] == pt(1, 1))
    }

    @Test func styleIsSanitizedOnAdd() {
        var d = doc()
        let id = d.add(.line, points: [pt(0, 0), pt(1, 1)], style: AnnotationStyle(strokeWidth: 999, fontSize: 1, strength: 5))
        let s = d.item(id)!.style
        #expect(s.strokeWidth == 40 && s.fontSize == 8 && s.strength == 1)
    }
}

@Suite struct AnnotationHitTests {
    @Test func segmentHitsNearTheLineOnly() {
        let l = item(.line, [pt(0, 0), pt(100, 0)])
        #expect(AnnotationHit.test(l, at: pt(50, 5)))
        #expect(!AnnotationHit.test(l, at: pt(50, 20)))
        #expect(AnnotationHit.test(l, at: pt(-4, 0)) && !AnnotationHit.test(l, at: pt(-30, 0)))
    }

    @Test func thickerLinesAreEasierToHit() {
        #expect(!AnnotationHit.test(item(.line, [pt(0, 0), pt(100, 0)], width: 2), at: pt(50, 10)))
        #expect(AnnotationHit.test(item(.line, [pt(0, 0), pt(100, 0)], width: 20), at: pt(50, 10)))
    }

    @Test func degenerateSegmentActsLikeAPoint() {
        let l = item(.line, [pt(10, 10), pt(10, 10)])
        #expect(AnnotationHit.test(l, at: pt(12, 12)) && !AnnotationHit.test(l, at: pt(40, 40)))
    }

    @Test func arrowHeadIsHittable() {
        let a = item(.arrow, [pt(0, 0), pt(200, 0)], width: 6)
        let s = ShotArrowGeometry.shape(from: pt(0, 0), to: pt(200, 0), width: 6)
        #expect(AnnotationHit.test(a, at: CGPoint(x: s.left.x, y: s.left.y - 1)) || AnnotationHit.test(a, at: pt(190, 5)))
        #expect(AnnotationHit.test(a, at: pt(100, 0)))
    }

    @Test func rectangleOutlineVersusFilled() {
        let outline = item(.rectangle, [pt(10, 10), pt(110, 110)]), filled = item(.rectangle, [pt(10, 10), pt(110, 110)], filled: true)
        #expect(!AnnotationHit.test(outline, at: pt(60, 60)))
        #expect(AnnotationHit.test(outline, at: pt(10, 60)) && AnnotationHit.test(outline, at: pt(60, 12)))
        #expect(AnnotationHit.test(filled, at: pt(60, 60)))
        #expect(!AnnotationHit.test(filled, at: pt(300, 300)))
    }

    @Test func rectangleAcceptsReversedCorners() {
        let r = item(.rectangle, [pt(110, 110), pt(10, 10)])
        #expect(AnnotationHit.test(r, at: pt(10, 60)))
    }

    @Test func ellipseOutlineVersusFilled() {
        let outline = item(.ellipse, [pt(0, 0), pt(200, 100)]), filled = item(.ellipse, [pt(0, 0), pt(200, 100)], filled: true)
        #expect(AnnotationHit.test(outline, at: pt(0, 50)) && AnnotationHit.test(outline, at: pt(100, 0)))
        #expect(!AnnotationHit.test(outline, at: pt(100, 50)))
        #expect(AnnotationHit.test(filled, at: pt(100, 50)))
        #expect(!AnnotationHit.test(filled, at: pt(2, 2)))
    }

    @Test func blurRegionIsHitInside() {
        let b = item(.blur, [pt(10, 10), pt(100, 100)])
        #expect(AnnotationHit.test(b, at: pt(50, 50)) && !AnnotationHit.test(b, at: pt(200, 200)))
    }

    @Test func penFollowsItsPath() {
        let p = item(.pen, [pt(0, 0), pt(50, 0), pt(50, 50)])
        #expect(AnnotationHit.test(p, at: pt(25, 2)) && AnnotationHit.test(p, at: pt(52, 25)))
        #expect(!AnnotationHit.test(p, at: pt(10, 40)))
    }

    @Test func highlighterIsWiderThanThePen() {
        let h = item(.highlighter, [pt(0, 0), pt(100, 0)])
        #expect(AnnotationHit.test(h, at: pt(50, 12)))
        #expect(!AnnotationHit.test(item(.pen, [pt(0, 0), pt(100, 0)]), at: pt(50, 20)))
    }

    @Test func singlePointPenIsHittable() {
        #expect(AnnotationHit.test(item(.pen, [pt(10, 10)]), at: pt(12, 10)))
    }

    @Test func textUsesItsBox() {
        var t = AnnotationItem(id: 1, kind: .text, points: [pt(100, 100)], style: AnnotationStyle(fontSize: 20), text: "Hello")
        t.boxSize = CGSize(width: 80, height: 24)
        #expect(AnnotationHit.test(t, at: pt(140, 110)) && !AnnotationHit.test(t, at: pt(300, 300)))
        #expect(t.bounds == CGRect(x: 100, y: 100, width: 80, height: 24))
    }

    @Test func textWithoutAMeasuredBoxFallsBackToAnEstimate() {
        let t = AnnotationItem(id: 1, kind: .text, points: [pt(0, 0)], style: AnnotationStyle(fontSize: 20), text: "ab\ncdef")
        let s = ShotTextEstimate.size("ab\ncdef", fontSize: 20)
        #expect(t.bounds.size == s && s.height > 40 && s.width > 40)
    }

    @Test func stepBadgeIsRound() {
        let s = item(.step, [pt(100, 100)])
        #expect(AnnotationHit.test(s, at: pt(110, 100)) && !AnnotationHit.test(s, at: pt(130, 130)))
        #expect(s.bounds.width == CGFloat(s.stepRadius) * 2)
    }

    @Test func boundsIncludeTheStroke() {
        let r = item(.rectangle, [pt(10, 10), pt(50, 50)], width: 10)
        #expect(r.bounds == CGRect(x: 5, y: 5, width: 50, height: 50))
        #expect(item(.blur, [pt(10, 10), pt(50, 50)], width: 10).bounds == CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(item(.line, [pt(0, 0)]).bounds.isNull)
    }

    @Test func handlesExistForSegmentsAndBoxes() {
        #expect(AnnotationHit.handles(of: item(.arrow, [pt(0, 0), pt(9, 9)])).map(\.kind) == [.start, .end])
        #expect(AnnotationHit.handles(of: item(.rectangle, [pt(0, 0), pt(9, 9)])).count == 4)
        #expect(AnnotationHit.handles(of: item(.pen, [pt(0, 0), pt(9, 9)])).isEmpty)
        #expect(AnnotationHit.handles(of: item(.text, [pt(0, 0)])).isEmpty)
    }

    @Test func handleHitUsesARadius() {
        let r = item(.rectangle, [pt(10, 10), pt(110, 110)])
        #expect(AnnotationHit.hitHandle(of: r, at: pt(13, 12))?.kind == .topLeft)
        #expect(AnnotationHit.hitHandle(of: r, at: pt(108, 111))?.kind == .bottomRight)
        #expect(AnnotationHit.hitHandle(of: r, at: pt(60, 60)) == nil)
    }

    @Test func resizingABoxKeepsTheOppositeCorner() {
        let r = item(.rectangle, [pt(10, 10), pt(110, 110)])
        let a = AnnotationHit.resized(r, handle: .bottomRight, to: pt(200, 150))
        #expect(AnnotationItem.rect(a.points[0], a.points[1]) == CGRect(x: 10, y: 10, width: 190, height: 140))
        let b = AnnotationHit.resized(r, handle: .topLeft, to: pt(60, 40))
        #expect(AnnotationItem.rect(b.points[0], b.points[1]) == CGRect(x: 60, y: 40, width: 50, height: 70))
        let flipped = AnnotationHit.resized(r, handle: .bottomRight, to: pt(0, 0))
        #expect(AnnotationItem.rect(flipped.points[0], flipped.points[1]) == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func resizingASegmentMovesOneEnd() {
        let a = item(.arrow, [pt(0, 0), pt(50, 50)])
        #expect(AnnotationHit.resized(a, handle: .end, to: pt(80, 10)).points == [pt(0, 0), pt(80, 10)])
        #expect(AnnotationHit.resized(a, handle: .start, to: pt(5, 5)).points == [pt(5, 5), pt(50, 50)])
    }

    @Test func squareLockWhileResizing() {
        let r = item(.rectangle, [pt(10, 10), pt(110, 110)])
        let s = AnnotationHit.resized(r, handle: .bottomRight, to: pt(210, 150), lockSquare: true)
        let rect = AnnotationItem.rect(s.points[0], s.points[1])
        #expect(rect.width == rect.height && rect.width == 200)
    }

    @Test func angleSnapGoesToFortyFiveDegreeSteps() {
        let p = AnnotationHit.snapAngle(from: pt(0, 0), to: pt(100, 10))
        #expect(abs(p.y) < 0.001 && abs(p.x - hypot(100, 10)) < 0.001)
        let d = AnnotationHit.snapAngle(from: pt(0, 0), to: pt(60, 70))
        #expect(abs(d.x - d.y) < 0.001)
        #expect(AnnotationHit.snapAngle(from: pt(5, 5), to: pt(5, 5)) == pt(5, 5))
    }

    @Test func movedShiftsEveryPoint() {
        let m = item(.pen, [pt(0, 0), pt(5, 5)]).moved(by: pt(10, -2))
        #expect(m.points == [pt(10, -2), pt(15, 3)])
    }

    @Test func arrowGeometryHeadIsSymmetricAroundTheAxis() {
        let s = ShotArrowGeometry.shape(from: pt(0, 0), to: pt(100, 0), width: 5)
        #expect(s.tip == pt(100, 0) && abs(s.left.x - s.right.x) < 0.001 && abs(s.left.y + s.right.y) < 0.001)
        #expect(s.shaftEnd.x < s.tip.x && s.left.x < s.tip.x)
    }

    @Test func shortArrowsShrinkTheirHead() {
        let s = ShotArrowGeometry.shape(from: pt(0, 0), to: pt(10, 0), width: 8)
        #expect(s.left.x >= 0 && abs(s.left.y) <= 6)
        let z = ShotArrowGeometry.shape(from: pt(5, 5), to: pt(5, 5), width: 8)
        #expect(z.tip == z.left && z.left == z.right)
    }

    @Test func geometryHelpers() {
        #expect(ShotGeometryMath.distance(pt(5, 5), toSegment: pt(0, 0), pt(10, 0)) == 5)
        #expect(ShotGeometryMath.distance(pt(-3, 4), toSegment: pt(0, 0), pt(10, 0)) == 5)
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(ShotGeometryMath.distanceToRectBorder(pt(5, 2), r) == 2 && ShotGeometryMath.distanceToRectBorder(pt(13, 14), r) == 5)
        #expect(ShotGeometryMath.ellipseValue(pt(5, 5), r) == 0 && abs(ShotGeometryMath.ellipseValue(pt(10, 5), r) - 1) < 1e-9)
    }
}
