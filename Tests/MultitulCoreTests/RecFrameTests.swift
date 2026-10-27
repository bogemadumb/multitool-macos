import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let src = CGSize(width: 2880, height: 1800)
private let info = RecSourceInfo(width: 2880, height: 1800, duration: 60, fps: 30, scale: 2)

private func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }

@Suite struct RecCropMathTests {
    @Test func wideAspectFitsInsideTheFullFrame() {
        let r = RecCropMath.fit(aspect: .wide, in: .full, source: src)
        #expect(near(r.w, 1) && near(r.h, 0.9) && near(r.y, 0.05) && near(r.x, 0))
    }

    @Test func squareAspectIsCentered() {
        let r = RecCropMath.fit(aspect: .square, in: .full, source: src)
        #expect(near(r.w, 0.625) && near(r.h, 1) && near(r.x, 0.1875))
    }

    @Test func fittedRectHasTheRequestedPixelRatio() {
        for a in RecAspect.allCases {
            guard let ratio = a.ratio else { continue }
            let r = RecCropMath.fit(aspect: a, in: .full, source: src)
            #expect(near((r.w * 2880) / (r.h * 1800), ratio, 0.005))
        }
    }

    @Test func freeAspectKeepsTheRect() {
        let r = RecNormRect(x: 0.1, y: 0.2, w: 0.5, h: 0.4)
        #expect(RecCropMath.fit(aspect: .free, in: r, source: src) == r)
    }

    @Test func fitInsideSmallerRect() {
        let r = RecCropMath.fit(aspect: .square, in: RecNormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.6), source: src)
        #expect(r.x >= 0.2 - 1e-9 && r.y >= 0.2 - 1e-9 && r.x + r.w <= 0.6 + 1e-9 && r.y + r.h <= 0.8 + 1e-9)
    }

    @Test func movedIsClampedToTheFrame() {
        let r = RecCropMath.moved(RecNormRect(x: 0.5, y: 0.5, w: 0.4, h: 0.4), dx: 0.9, dy: -2)
        #expect(near(r.x, 0.6) && near(r.y, 0))
    }

    @Test func freeCornerResize() {
        let r = RecCropMath.resized(RecNormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), handle: .bottomRight, to: (0.9, 0.8), aspect: .free, source: src)
        #expect(near(r.x, 0.2) && near(r.y, 0.2) && near(r.w, 0.7) && near(r.h, 0.6))
    }

    @Test func topLeftResizeKeepsTheOppositeCorner() {
        let r = RecCropMath.resized(RecNormRect(x: 0.4, y: 0.4, w: 0.4, h: 0.4), handle: .topLeft, to: (0.1, 0.2), aspect: .free, source: src)
        #expect(near(r.x, 0.1) && near(r.y, 0.2) && near(r.x + r.w, 0.8) && near(r.y + r.h, 0.8))
    }

    @Test func resizeCannotInvertOrCollapse() {
        let r = RecCropMath.resized(RecNormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), handle: .bottomRight, to: (0.0, 0.0), aspect: .free, source: src)
        #expect(r.w >= RecNormRect.minSide - 1e-9 && r.h >= RecNormRect.minSide - 1e-9 && r.x == 0.2)
    }

    @Test func edgeResizeChangesOnlyOneSide() {
        let r = RecCropMath.resized(RecNormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), handle: .right, to: (0.8, 0.5), aspect: .free, source: src)
        #expect(near(r.x, 0.2) && near(r.w, 0.6) && near(r.h, 0.4) && near(r.y, 0.2))
    }

    @Test func aspectLockedCornerResize() {
        let sq = CGSize(width: 1000, height: 1000)
        let r = RecCropMath.resized(RecNormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), handle: .bottomRight, to: (0.9, 0.3), aspect: .square, source: sq)
        #expect(near(r.w, r.h) && near(r.x, 0.2) && near(r.y, 0.2))
    }

    @Test func aspectLockedResizeStaysInsideTheFrame() {
        for h in RecCropHandle.allCases {
            let r = RecCropMath.resized(RecNormRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4), handle: h, to: (1.4, -0.4), aspect: .wide, source: src)
            #expect(r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.w <= 1 + 1e-9 && r.y + r.h <= 1 + 1e-9)
        }
    }

    @Test func pixelRectIsEvenAligned() {
        let p = RecCropMath.pixelRect(crop: RecNormRect(x: 0.1003, y: 0.1007, w: 0.5, h: 0.5), source: src)
        #expect(Int(p.minX) % 2 == 0 && Int(p.minY) % 2 == 0 && Int(p.width) % 2 == 0 && Int(p.height) % 2 == 0)
        #expect(p.maxX <= 2880 && p.maxY <= 1800)
    }

    @Test func pixelRectOfFullCropIsTheSource() {
        #expect(RecCropMath.pixelRect(crop: .full, source: src) == CGRect(x: 0, y: 0, width: 2880, height: 1800))
    }

    @Test func pixelRectNeverCollapses() {
        let p = RecCropMath.pixelRect(crop: RecNormRect(x: 0.99, y: 0.99, w: 0.04, h: 0.04), source: CGSize(width: 100, height: 100))
        #expect(p.width >= 2 && p.height >= 2 && p.maxX <= 100 && p.maxY <= 100)
    }
}

@Suite struct RecLayoutMathTests {
    @Test func plainCanvasEqualsTheCropSize() {
        #expect(RecLayoutMath.canvasSize(source: info, crop: .full, style: RecFrameStyle()) == CGSize(width: 2880, height: 1800))
        #expect(RecLayoutMath.canvasSize(source: info, crop: RecNormRect(x: 0, y: 0, w: 0.5, h: 0.5), style: RecFrameStyle()) == CGSize(width: 1440, height: 900))
    }

    @Test func paddingIsInPointsTimesScale() {
        var st = RecFrameStyle()
        st.padding = 32
        #expect(RecLayoutMath.canvasSize(source: info, crop: .full, style: st) == CGSize(width: 2880 + 128, height: 1800 + 128))
    }

    @Test func maxLongSideScalesTheWholeCanvas() {
        var st = RecFrameStyle()
        st.padding = 32
        let c = RecLayoutMath.canvasSize(source: info, crop: .full, style: st, maxLongSide: 1280)
        #expect(c.width == 1280 && Int(c.height) % 2 == 0 && abs(Double(c.height) / 1280 - 1928.0 / 3008) < 0.003)
    }

    @Test func capLargerThanCanvasChangesNothing() {
        #expect(RecLayoutMath.canvasSize(source: info, crop: .full, style: RecFrameStyle(), maxLongSide: 9000) == CGSize(width: 2880, height: 1800))
    }

    @Test func plainLayoutFillsTheCanvas() {
        let l = RecLayoutMath.layout(source: info, crop: .full, style: RecFrameStyle())
        #expect(l.destRect == CGRect(x: 0, y: 0, width: 2880, height: 1800) && l.sourceRect == l.destRect && !l.shadow && l.cornerRadius == 0)
    }

    @Test func paddedLayoutInsetsTheContent() {
        var st = RecFrameStyle()
        st.padding = 20
        st.corner = 10
        let l = RecLayoutMath.layout(source: info, crop: .full, style: st)
        #expect(near(Double(l.destRect.minX), 40) && near(Double(l.destRect.width), 2880) && l.shadow && near(l.cornerRadius, 20))
    }

    @Test func shadowCanBeTurnedOff() {
        var st = RecFrameStyle()
        st.padding = 20
        st.shadow = false
        #expect(!RecLayoutMath.layout(source: info, crop: .full, style: st).shadow)
    }

    @Test func cornerRadiusIsCappedByHalfTheSmallSide() {
        var st = RecFrameStyle()
        st.padding = 0
        st.corner = 120
        let l = RecLayoutMath.layout(source: info, crop: RecNormRect(x: 0, y: 0, w: 0.04, h: 0.04), style: st)
        #expect(l.cornerRadius <= Double(min(l.destRect.width, l.destRect.height)) / 2 + 1e-9)
    }

    @Test func zoomNarrowsTheSourceRegion() {
        let l = RecLayoutMath.layout(source: info, crop: .full, style: RecFrameStyle(), zoom: RecZoomSample(scale: 2, cx: 0.5, cy: 0.5))
        #expect(l.sourceRect == CGRect(x: 720, y: 450, width: 1440, height: 900) && l.destRect.width == 2880)
        #expect(near(l.scaleX, 2) && near(l.scaleY, 2))
    }

    @Test func zoomIsRelativeToTheCrop() {
        let crop = RecNormRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)
        let l = RecLayoutMath.layout(source: info, crop: crop, style: RecFrameStyle(), zoom: RecZoomSample(scale: 2, cx: 0.5, cy: 0.5))
        #expect(l.sourceRect == CGRect(x: 1440 + 360, y: 900 + 225, width: 720, height: 450))
    }

    @Test func croppedLayoutSourceRegionMatchesThePixelCrop() {
        let l = RecLayoutMath.layout(source: info, crop: RecNormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), style: RecFrameStyle())
        #expect(l.sourceRect == CGRect(x: 720, y: 450, width: 1440, height: 900) && l.canvas == CGSize(width: 1440, height: 900))
    }

    @Test func pointMappingInsideAndOutsideTheView() {
        let l = RecLayoutMath.layout(source: info, crop: .full, style: RecFrameStyle(), zoom: RecZoomSample(scale: 2, cx: 0.5, cy: 0.5))
        let c = l.map(normalized: CGPoint(x: 0.5, y: 0.5))!
        #expect(near(Double(c.x), 1440) && near(Double(c.y), 900))
        #expect(l.map(normalized: CGPoint(x: 0.05, y: 0.5)) == nil)
    }

    @Test func rectMappingClipsToTheVisibleRegion() {
        let l = RecLayoutMath.layout(source: info, crop: .full, style: RecFrameStyle(), zoom: RecZoomSample(scale: 2, cx: 0.5, cy: 0.5))
        let r = l.map(rect: RecNormRect(x: 0.2, y: 0.4, w: 0.2, h: 0.2))!
        #expect(near(Double(r.minX), 0) && near(Double(r.width), (0.4 - 0.25) * 2880 * 2))
        #expect(l.map(rect: RecNormRect(x: 0.0, y: 0.0, w: 0.1, h: 0.1)) == nil)
    }

    @Test func paddedMappingAddsTheOffset() {
        var st = RecFrameStyle()
        st.padding = 20
        let l = RecLayoutMath.layout(source: info, crop: .full, style: st)
        let p = l.map(normalized: CGPoint(x: 0, y: 0))!
        #expect(near(Double(p.x), 40) && near(Double(p.y), 40))
    }

    @Test func layoutSourceSizeIsRememberedForMapping() {
        #expect(RecLayoutMath.layout(source: info, crop: .full, style: RecFrameStyle()).sourceSize == src)
    }
}

@Suite struct RecFrameParamsTests {
    private func document() -> RecEditDocument { RecEditDocument(source: info) }

    @Test func identityDocumentGivesIdentityParams() {
        let p = RecFrameParamsBuilder.make(document: document(), log: nil, outputTime: 5)
        #expect(p.zoom.isIdentity && p.blurs.isEmpty && p.ripples.isEmpty && p.sourceTime == 5 && p.layout.canvas == src)
    }

    @Test func outputTimeMapsThroughTheTimeline() {
        var d = document()
        d.timeline.cut(from: 5, to: 8)
        #expect(near(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 5).sourceTime, 8))
        d.timeline.setSpeed(from: 20, to: 40, speed: 2)
        #expect(near(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 20).sourceTime, 26))
    }

    @Test func zoomIsEvaluatedOnSourceTime() {
        var d = document()
        d.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 8, holdStart: 9, holdEnd: 12, end: 13, level: 2, path: [RecZoomPoint(t: 9, cx: 0.5, cy: 0.5)])])
        d.timeline.cut(from: 0, to: 6)
        let p = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 4)
        #expect(near(p.sourceTime, 10) && near(p.zoom.scale, 2))
        let q = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1)
        #expect(q.zoom.scale < 2)
    }

    @Test func disabledZoomIsIgnored() {
        var d = document()
        d.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 0, holdStart: 1, holdEnd: 12, end: 13, level: 2, path: [RecZoomPoint(t: 1, cx: 0.5, cy: 0.5)])])
        d.zoomEnabled = false
        #expect(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 5).zoom.isIdentity)
    }

    @Test func blurIsDrawnOnlyWhileActive() {
        var d = document()
        _ = d.addBlur(rect: RecNormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.2), from: 10, to: 20)
        #expect(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 5).blurs.isEmpty)
        let p = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 15)
        #expect(p.blurs.count == 1 && near(Double(p.blurs[0].rect.minX), 576) && near(Double(p.blurs[0].rect.width), 864))
    }

    @Test func blurFollowsTheCut() {
        var d = document()
        _ = d.addBlur(rect: RecNormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.2), from: 10, to: 20)
        d.timeline.cut(from: 0, to: 12)
        #expect(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1).blurs.count == 1)
        #expect(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 9).blurs.isEmpty)
    }

    @Test func clickRipplesComeFromTheLog() {
        var d = document()
        d.style.highlightClicks = true
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.5, y: 0.5)])
        let p = RecFrameParamsBuilder.make(document: d, log: log, outputTime: 10.3)
        #expect(p.ripples.count == 1 && near(Double(p.ripples[0].center.x), 1440) && p.ripples[0].alpha > 0.4 && p.ripples[0].alpha < 0.6)
        #expect(RecFrameParamsBuilder.make(document: d, log: log, outputTime: 12).ripples.isEmpty)
    }

    @Test func ripplesCanBeSwitchedOff() {
        var d = document()
        d.style.highlightClicks = false
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.5, y: 0.5)])
        #expect(RecFrameParamsBuilder.make(document: d, log: log, outputTime: 10.2).ripples.isEmpty)
    }

    @Test func rippleGrowsOverTime() {
        let d = document()
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.5, y: 0.5)])
        let a = RecFrameParamsBuilder.make(document: d, log: log, outputTime: 10.1).ripples[0]
        let b = RecFrameParamsBuilder.make(document: d, log: log, outputTime: 10.4).ripples[0]
        #expect(b.radius > a.radius && b.alpha < a.alpha)
    }

    @Test func rippleOutsideTheZoomedViewIsSkipped() {
        var d = document()
        d.zoom = RecZoomTimeline(spans: [RecZoomSpan(start: 0, holdStart: 1, holdEnd: 40, end: 41, level: 3, path: [RecZoomPoint(t: 1, cx: 0.8, cy: 0.5)])])
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.05, y: 0.5)])
        #expect(RecFrameParamsBuilder.make(document: d, log: log, outputTime: 10.1).ripples.isEmpty)
    }

    @Test func canvasOverrideRescalesTheDestination() {
        var d = document()
        d.style.padding = 20
        let big = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1)
        let small = RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1, canvas: CGSize(width: big.layout.canvas.width / 2, height: big.layout.canvas.height / 2))
        #expect(near(Double(small.layout.destRect.minX), Double(big.layout.destRect.minX) / 2) && small.layout.canvas.width == big.layout.canvas.width / 2)
    }

    @Test func backgroundIsCarriedFromTheStyle() {
        var d = document()
        d.style.background = "solid:#112233"
        #expect(RecFrameParamsBuilder.make(document: d, log: nil, outputTime: 1).background == .solid(ShotColor(0x11, 0x22, 0x33)))
    }
}
