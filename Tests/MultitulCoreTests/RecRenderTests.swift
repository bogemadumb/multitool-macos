import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import MultitulCore

private let ctx = CIContext(options: [.useSoftwareRenderer: true])

private func solid(_ w: Int, _ h: Int, _ f: @escaping (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
    let bmp = ShotBitmap(width: w, height: h) { x, y in let c = f(x, y); return (c.0, c.1, c.2, 255) }
    return CIImage(cgImage: bmp.makeImage()!)
}

private func render(_ source: CIImage, _ size: CGSize, _ doc: RecEditDocument, t: Double = 1, log: RecInputLog? = nil) -> ShotBitmap {
    let params = RecFrameParamsBuilder.make(document: doc, log: log, outputTime: t)
    let out = RecFrameRenderer().compose(source: source, sourcePixels: size, params: params)
    let cg = ctx.createCGImage(out, from: CGRect(origin: .zero, size: params.layout.canvas))!
    return ShotBitmap(image: cg)!
}

private func isRed(_ c: (UInt8, UInt8, UInt8, UInt8)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
private func isGreen(_ c: (UInt8, UInt8, UInt8, UInt8)) -> Bool { c.1 > 200 && c.0 < 60 && c.2 < 60 }
private func isBlue(_ c: (UInt8, UInt8, UInt8, UInt8)) -> Bool { c.2 > 200 && c.0 < 60 && c.1 < 60 }

private func document(_ w: Int, _ h: Int, scale: Double = 1) -> RecEditDocument {
    RecEditDocument(source: RecSourceInfo(width: w, height: h, duration: 10, fps: 30, scale: scale))
}

@Suite struct RecRendererTests {
    private let size = CGSize(width: 200, height: 100)

    private func halves() -> CIImage { solid(200, 100) { x, _ in x < 100 ? (255, 0, 0) : (0, 255, 0) } }

    @Test func plainDocumentReproducesTheSource() {
        let out = render(halves(), size, document(200, 100))
        #expect(out.width == 200 && out.height == 100)
        #expect(isRed(out.pixel(20, 50)) && isGreen(out.pixel(180, 50)))
    }

    @Test func verticalOrientationIsPreserved() {
        let src = solid(200, 100) { _, y in y < 50 ? (255, 0, 0) : (0, 0, 255) }
        let out = render(src, size, document(200, 100))
        #expect(isRed(out.pixel(100, 10)) && isBlue(out.pixel(100, 90)))
    }

    @Test func cropShowsOnlyTheChosenRegion() {
        var d = document(200, 100)
        d.crop = RecNormRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let out = render(halves(), size, d)
        #expect(out.width == 100 && out.height == 100 && isGreen(out.pixel(50, 50)) && isGreen(out.pixel(2, 2)))
    }

    @Test func paddingShowsTheBackground() {
        var d = document(200, 100)
        d.style.padding = 10
        d.style.background = "solid:#0000FF"
        let out = render(halves(), size, d)
        #expect(out.width == 220 && out.height == 120)
        #expect(isBlue(out.pixel(3, 3)) && isBlue(out.pixel(216, 116)))
        #expect(isRed(out.pixel(50, 60)) && isGreen(out.pixel(170, 60)))
    }

    @Test func contentIsPlacedInsideThePadding() {
        var d = document(200, 100)
        d.style.padding = 10
        d.style.background = "solid:#0000FF"
        d.style.shadow = false
        let out = render(halves(), size, d)
        #expect(isBlue(out.pixel(9, 60)) && isRed(out.pixel(11, 60)) && isBlue(out.pixel(100, 9)) && !isBlue(out.pixel(100, 11)))
    }

    @Test func roundedCornersRevealTheBackground() {
        var d = document(200, 100)
        d.style.padding = 10
        d.style.corner = 30
        d.style.background = "solid:#0000FF"
        d.style.shadow = false
        let out = render(halves(), size, d)
        #expect(isBlue(out.pixel(11, 11)) && isRed(out.pixel(60, 60)) && isRed(out.pixel(30, 12)))
    }

    @Test func cornersWithoutPaddingAreRoundedToo() {
        var d = document(200, 100)
        d.style.corner = 40
        d.style.background = "solid:#0000FF"
        let out = render(halves(), size, d)
        #expect(out.pixel(1, 1).3 > 0 && !isRed(out.pixel(1, 1)) && isRed(out.pixel(40, 50)))
    }

    @Test func zoomMagnifiesTheTargetArea() {
        var d = document(200, 100)
        d.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 0, holdStart: 0.5, holdEnd: 9, end: 9.5, level: 2, path: [RecZoomPoint(t: 0.5, cx: 0.25, cy: 0.5)])])
        let out = render(halves(), size, d, t: 5)
        #expect(isRed(out.pixel(20, 50)) && isRed(out.pixel(180, 50)) && out.width == 200)
        let out2 = render(halves(), size, document(200, 100), t: 5)
        #expect(isGreen(out2.pixel(180, 50)))
    }

    @Test func zoomOnTheRightShowsTheGreenHalf() {
        var d = document(200, 100)
        d.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 0, holdStart: 0.5, holdEnd: 9, end: 9.5, level: 2, path: [RecZoomPoint(t: 0.5, cx: 0.9, cy: 0.5)])])
        let out = render(halves(), size, d, t: 5)
        #expect(isGreen(out.pixel(100, 50)) && isGreen(out.pixel(5, 50)))
    }

    @Test func blurMixesNeighbouringColors() {
        var d = document(200, 100)
        _ = d.addBlur(rect: RecNormRect(x: 0.4, y: 0.2, w: 0.2, h: 0.6), from: 0, to: 10, strength: 1)
        let out = render(halves(), size, d)
        let mid = out.pixel(100, 50)
        #expect(!isRed(mid) && !isGreen(mid) && mid.0 > 20 && mid.1 > 20)
        #expect(isRed(out.pixel(40, 50)) && isGreen(out.pixel(160, 50)))
    }

    @Test func pixelateMakesBlocks() {
        let src = solid(200, 100) { x, y in (x + y) % 20 < 10 ? (255, 0, 0) : (0, 0, 255) }
        var d = document(200, 100)
        _ = d.addBlur(rect: RecNormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), from: 0, to: 10, strength: 0.5, pixelate: true)
        let out = render(src, size, d)
        let a = out.pixel(100, 50), b = out.pixel(101, 50)
        #expect(a == b)
    }

    @Test func blurOutsideItsTimeIsNotApplied() {
        var d = document(200, 100)
        _ = d.addBlur(rect: RecNormRect(x: 0.4, y: 0.2, w: 0.2, h: 0.6), from: 5, to: 10, strength: 1)
        let out = render(halves(), size, d, t: 1)
        #expect(isRed(out.pixel(98, 50)) && isGreen(out.pixel(102, 50)))
    }

    @Test func clickRippleIsDrawnAroundTheClick() {
        let src = solid(200, 100) { _, _ in (0, 0, 0) }
        var d = document(200, 100)
        d.style.clickColor = "#FFFF00"
        let log = RecInputLog(events: [RecInputEvent(t: 1, kind: .down, x: 0.5, y: 0.5)])
        let out = render(src, size, d, t: 1.2, log: log)
        var lit = 0
        for y in 0..<100 { for x in 0..<200 where out.pixel(x, y).0 > 60 { lit += 1 } }
        #expect(lit > 40)
        let far = out.pixel(5, 5)
        #expect(far.0 < 10 && far.1 < 10)
    }

    @Test func noRippleWithoutALogOrOutsideItsLifetime() {
        let src = solid(200, 100) { _, _ in (0, 0, 0) }
        let d = document(200, 100)
        let none = render(src, size, d, t: 1.2)
        let log = RecInputLog(events: [RecInputEvent(t: 1, kind: .down, x: 0.5, y: 0.5)])
        let late = render(src, size, d, t: 3, log: log)
        #expect(none.bytes == late.bytes)
    }

    @Test func gradientBackgroundVariesAcrossTheCanvas() {
        var d = document(200, 100)
        d.style.padding = 30
        d.style.shadow = false
        d.style.background = "gradient:#FF0000:#0000FF:90"
        let out = render(halves(), size, d)
        let l = out.pixel(3, 60), r = out.pixel(out.width - 4, 60)
        #expect(l.0 > r.0 && r.2 > l.2)
    }

    @Test func rendererReusesItsBackdropAcrossFrames() {
        var d = document(200, 100)
        d.style.padding = 10
        d.style.background = "solid:#0000FF"
        let r = RecFrameRenderer()
        let p1 = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1)
        let p2 = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 2)
        let a = r.backdrop(for: p1), b = r.backdrop(for: p2)
        #expect(a != nil && a === b)
    }
}
