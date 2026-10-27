import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func base(_ w: Int = 120, _ h: Int = 80, _ c: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)) -> CGImage { ShotBitmap(width: w, height: h, color: c).makeImage()! }

private func bm(_ i: CGImage?) -> ShotBitmap { ShotBitmap(image: i!)! }

@Suite struct ShotRenderTests {
    @Test func emptyDocumentReturnsTheSamePixels() {
        let img = base()
        let out = ShotRenderer.render(base: img, document: AnnotationDocument(canvasWidth: 120, canvasHeight: 80))
        #expect(bm(out) == bm(img))
    }

    @Test func filledRectangleCoversExactlyItsArea() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.rectangle, points: [pt(20, 10), pt(60, 40)], style: AnnotationStyle(color: ShotColor(255, 0, 0), strokeWidth: 2, filled: true))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(30, 20) == (255, 0, 0, 255) && b.pixel(59, 39) == (255, 0, 0, 255))
        #expect(b.pixel(10, 20) == (255, 255, 255, 255) && b.pixel(30, 60) == (255, 255, 255, 255) && b.pixel(70, 20) == (255, 255, 255, 255))
    }

    @Test func topLeftOriginIsRespected() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.rectangle, points: [pt(0, 0), pt(10, 10)], style: AnnotationStyle(color: ShotColor(0, 0, 255), filled: true))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(2, 2).2 == 255 && b.pixel(2, 2).0 == 0)
        #expect(b.pixel(2, 77) == (255, 255, 255, 255))
    }

    @Test func outlineLeavesTheInsideUntouched() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.rectangle, points: [pt(20, 10), pt(100, 70)], style: AnnotationStyle(color: ShotColor(0, 128, 0), strokeWidth: 4))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(60, 40) == (255, 255, 255, 255))
        #expect(b.pixel(20, 40).1 > 100 && b.pixel(20, 40).0 < 150)
    }

    @Test func lineAndArrowDrawSomething() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.line, points: [pt(10, 20), pt(110, 20)], style: AnnotationStyle(color: ShotColor(255, 0, 0), strokeWidth: 6))
        d.add(.arrow, points: [pt(10, 60), pt(110, 60)], style: AnnotationStyle(color: ShotColor(0, 0, 255), strokeWidth: 6))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(60, 20).0 == 255 && b.pixel(60, 20).1 < 60)
        #expect(b.pixel(60, 60).2 == 255 && b.pixel(60, 60).0 < 60)
        #expect(b.pixel(105, 60).2 == 255)
        #expect(b.pixel(60, 40) == (255, 255, 255, 255))
    }

    @Test func ellipseFillsItsCentreButNotTheCorners() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.ellipse, points: [pt(10, 10), pt(110, 70)], style: AnnotationStyle(color: ShotColor(0, 0, 0), filled: true))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(60, 40) == (0, 0, 0, 255) && b.pixel(11, 11) == (255, 255, 255, 255))
    }

    @Test func highlighterKeepsTheBackgroundVisible() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.highlighter, points: [pt(10, 40), pt(110, 40)], style: AnnotationStyle(color: ShotColor(255, 214, 10, 102), strokeWidth: 4))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        let p = b.pixel(60, 40)
        #expect(p.0 == 255 && p.2 > 100 && p.2 < 255)
    }

    @Test func stepBadgeDrawsADiscWithANumber() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.add(.step, points: [pt(60, 40)], style: AnnotationStyle(color: ShotColor(255, 0, 0), strokeWidth: 4))
        let b = bm(ShotRenderer.render(base: base(), document: d))
        #expect(b.pixel(48, 40) == (255, 0, 0, 255) || b.pixel(48, 40).0 == 255)
        var whites = 0
        for y in 30..<50 { for x in 52..<68 where b.pixel(x, y).1 > 200 { whites += 1 } }
        #expect(whites > 5)
    }

    @Test func textLeavesInkInsideItsBox() {
        var d = AnnotationDocument(canvasWidth: 200, canvasHeight: 80)
        let size = ShotTextMetrics.measure("Hello", 30)
        d.add(.text, points: [pt(10, 10)], style: AnnotationStyle(color: ShotColor(0, 0, 0), fontSize: 30), text: "Hello", boxSize: size)
        let b = bm(ShotRenderer.render(base: base(200, 80), document: d))
        var ink = 0, outside = 0
        for y in 0..<80 { for x in 0..<200 where b.pixel(x, y).0 < 128 {
            if CGRect(x: 10, y: 10, width: size.width, height: size.height).insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) { ink += 1 } else { outside += 1 }
        } }
        #expect(ink > 40 && outside == 0)
    }

    @Test func textMetricsGrowWithSizeAndLines() {
        let a = ShotTextMetrics.measure("abc", 20), b = ShotTextMetrics.measure("abc", 40), c = ShotTextMetrics.measure("abc\nabc", 20)
        #expect(b.width > a.width * 1.5 && c.height > a.height * 1.8 && c.width == a.width)
        #expect(ShotTextMetrics.measure("", 20).height > 0 && ShotTextMetrics.lineHeight(20) > 20)
    }

    @Test func pixelateEffectUsesTheBasePixels() {
        let img = ShotBitmap(width: 64, height: 64) { x, y in ((x + y) % 2 == 0 ? 0 : 255, 0, 0, 255) }.makeImage()!
        var d = AnnotationDocument(canvasWidth: 64, canvasHeight: 64)
        d.add(.pixelate, points: [pt(0, 0), pt(32, 32)], style: AnnotationStyle(strength: 0.2))
        let b = bm(ShotRenderer.render(base: img, document: d))
        #expect(b.pixel(1, 1) == b.pixel(2, 2) || abs(Int(b.pixel(1, 1).0) - Int(b.pixel(0, 0).0)) < 130)
        let orig = bm(img)
        #expect(b.pixel(50, 50) == orig.pixel(50, 50) && b.pixel(33, 5) == orig.pixel(33, 5))
        #expect(b.pixel(1, 0) != orig.pixel(1, 0) || b.pixel(0, 0) != orig.pixel(0, 0))
    }

    @Test func blurEffectSoftensTheRegionOnly() {
        let img = ShotBitmap(width: 64, height: 64) { x, _ in x < 32 ? (0, 0, 0, 255) : (255, 255, 255, 255) }.makeImage()!
        var d = AnnotationDocument(canvasWidth: 64, canvasHeight: 64)
        d.add(.blur, points: [pt(16, 0), pt(48, 64)], style: AnnotationStyle(strength: 0.3))
        let b = bm(ShotRenderer.render(base: img, document: d))
        let mid = b.pixel(32, 32).0
        #expect(mid > 20 && mid < 235 && b.pixel(5, 32).0 == 0 && b.pixel(60, 32).0 == 255)
    }

    @Test func annotationsDrawOverTheBlur() {
        let img = base(64, 64, (200, 200, 200, 255))
        var d = AnnotationDocument(canvasWidth: 64, canvasHeight: 64)
        d.add(.rectangle, points: [pt(10, 10), pt(30, 30)], style: AnnotationStyle(color: ShotColor(255, 0, 0), filled: true))
        d.add(.blur, points: [pt(0, 0), pt(64, 64)], style: AnnotationStyle(strength: 1))
        let b = bm(ShotRenderer.render(base: img, document: d))
        #expect(b.pixel(20, 20) == (255, 0, 0, 255))
    }

    @Test func cropReducesTheOutputSize() {
        var d = AnnotationDocument(canvasWidth: 120, canvasHeight: 80)
        d.crop = CGRect(x: 10, y: 20, width: 60, height: 30)
        #expect(ShotRenderer.render(base: base(), document: d)!.width == 60 && ShotRenderer.render(base: base(), document: d)!.height == 30)
        let full = ShotRenderer.render(base: base(), document: d, applyCrop: false)!
        #expect(full.width == 120 && full.height == 80)
    }

    @Test func cropKeepsTheRightPixels() {
        let img = ShotBitmap(width: 100, height: 100) { x, y in (UInt8(x), UInt8(y), 0, 255) }.makeImage()!
        var d = AnnotationDocument(canvasWidth: 100, canvasHeight: 100)
        d.crop = CGRect(x: 30, y: 40, width: 20, height: 20)
        let b = bm(ShotRenderer.render(base: img, document: d))
        #expect(b.pixel(0, 0).0 == 30 && b.pixel(0, 0).1 == 40 && b.pixel(19, 19).0 == 49)
    }

    @Test func documentScalesWhenTheBaseIsLargerThanTheCanvas() {
        var d = AnnotationDocument(canvasWidth: 60, canvasHeight: 40)
        d.add(.rectangle, points: [pt(0, 0), pt(30, 20)], style: AnnotationStyle(color: ShotColor(255, 0, 0), filled: true))
        let b = bm(ShotRenderer.render(base: base(120, 80), document: d))
        #expect(b.pixel(50, 30) == (255, 0, 0, 255) && b.pixel(70, 30) == (255, 255, 255, 255))
    }

    @Test func composeWithoutAnythingReturnsTheInput() {
        let img = base()
        let out = ShotRenderer.compose(img, padding: 0, scale: 2, background: .none, cornerRadius: 0, watermark: ShotWatermark())
        #expect(out === img)
    }

    @Test func composeAddsPaddingAndABackground() {
        let img = base(100, 60, (255, 0, 0, 255))
        let out = bm(ShotRenderer.compose(img, padding: 10, scale: 2, background: .solid(ShotColor(0, 0, 255)), cornerRadius: 0, watermark: ShotWatermark()))
        #expect(out.width == 140 && out.height == 100)
        #expect(out.pixel(2, 2) == (0, 0, 255, 255) && out.pixel(70, 50) == (255, 0, 0, 255))
    }

    @Test func gradientBackgroundGoesFromOneColourToTheOther() {
        let img = base(40, 40, (255, 255, 255, 255))
        let out = bm(ShotRenderer.compose(img, padding: 30, scale: 1, background: .gradient(ShotColor(255, 0, 0), ShotColor(0, 0, 255), angle: 90), cornerRadius: 0, watermark: ShotWatermark()))
        #expect(out.pixel(1, 35).0 > out.pixel(98, 35).0 && out.pixel(1, 35).2 < out.pixel(98, 35).2)
    }

    @Test func transparentPaddingStaysTransparent() {
        let out = bm(ShotRenderer.compose(base(40, 40), padding: 5, scale: 1, background: .none, cornerRadius: 0, watermark: ShotWatermark()))
        #expect(out.width == 50 && out.pixel(1, 1).3 == 0 && out.pixel(25, 25).3 == 255)
    }

    @Test func roundedCornersCutTheImage() {
        let img = base(100, 100, (255, 0, 0, 255))
        let out = bm(ShotRenderer.compose(img, padding: 20, scale: 1, background: .solid(ShotColor(255, 255, 255)), cornerRadius: 30, watermark: ShotWatermark()))
        #expect(out.pixel(21, 21).0 > 200 && out.pixel(21, 21).1 > 150)
        #expect(out.pixel(70, 70) == (255, 0, 0, 255))
    }

    @Test func watermarkIsDrawnInTheChosenCorner() {
        var w = ShotWatermark()
        w.enabled = true; w.text = "WWWW"; w.corner = .bottomRight; w.opacity = 1; w.fontSize = 20
        let out = bm(ShotRenderer.compose(base(300, 150, (0, 0, 0, 255)), padding: 0, scale: 1, background: .none, cornerRadius: 0, watermark: w))
        var inRight = 0, inLeft = 0
        for y in 100..<150 { for x in 0..<300 where out.pixel(x, y).0 > 128 { if x > 150 { inRight += 1 } else { inLeft += 1 } } }
        #expect(inRight > 30 && inLeft == 0)
    }

    @Test func downscaleHalvesTheSize() {
        let img = base(200, 100)
        let d = ShotRenderer.downscaled(img, factor: 0.5)!
        #expect(d.width == 100 && d.height == 50)
        #expect(ShotRenderer.downscaled(img, factor: 1) === img)
    }
}
