import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ShotGeometryTests {
    @Test func cocoaAndDesktopAreMirrorImages() {
        let cocoa = CGRect(x: 100, y: 700, width: 300, height: 200)
        let desktop = ShotSpace.cocoaToDesktop(cocoa, primaryHeight: 900)
        #expect(desktop == CGRect(x: 100, y: 0, width: 300, height: 200))
        #expect(ShotSpace.desktopToCocoa(desktop, primaryHeight: 900) == cocoa)
        #expect(ShotSpace.cocoaToDesktop(CGPoint(x: 10, y: 890), primaryHeight: 900) == CGPoint(x: 10, y: 10))
    }

    @Test func displayBuiltFromACocoaFrameOfASecondaryScreenAbovePrimary() {
        let d = ShotDisplay(id: 9, cocoaFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080), scale: 1, primaryHeight: 900)
        #expect(d.frame == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func pixelSizeFollowsScale() {
        #expect(shotMain.pixelSize == CGSize(width: 2880, height: 1800))
        #expect(shotRight.pixelSize == CGSize(width: 1920, height: 1080))
        #expect(ShotDisplay(id: 1, frame: .zero, scale: 0.2).scale == 1)
    }

    @Test func boundsUnionAllDisplays() {
        #expect(ShotSpace.bounds([shotMain, shotRight, shotLeft]) == CGRect(x: -1280, y: 0, width: 1280 + 1440 + 1920, height: 1080))
        #expect(ShotSpace.bounds([]) == .zero)
    }

    @Test func displayContainingPointOrNearest() {
        let all = [shotMain, shotRight, shotLeft]
        #expect(ShotSpace.display(containing: CGPoint(x: 10, y: 10), in: all)?.id == 1)
        #expect(ShotSpace.display(containing: CGPoint(x: 1500, y: 500), in: all)?.id == 2)
        #expect(ShotSpace.display(containing: CGPoint(x: -5, y: 500), in: all)?.id == 3)
        #expect(ShotSpace.display(containing: CGPoint(x: -5, y: 50), in: all)?.id == 1)
        #expect(ShotSpace.display(containing: CGPoint(x: 5000, y: 5000), in: all)?.id == 2)
        #expect(ShotSpace.display(containing: .zero, in: []) == nil)
    }

    @Test func clampAndRectHelpers() {
        #expect(ShotSpace.clamp(CGPoint(x: -5, y: 2000), to: shotMain.frame) == CGPoint(x: 0, y: 900))
        #expect(ShotSpace.rect(from: CGPoint(x: 5, y: 9), to: CGPoint(x: 1, y: 3)) == CGRect(x: 1, y: 3, width: 4, height: 6))
        #expect(ShotSpace.moved(CGRect(x: 90, y: 90, width: 20, height: 20), inside: CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 80, y: 80, width: 20, height: 20))
        #expect(ShotSpace.moved(CGRect(x: -10, y: -10, width: 20, height: 20), inside: CGRect(x: 0, y: 0, width: 100, height: 100)).origin == .zero)
    }

    @Test func singleRetinaDisplayPlan() {
        let p = ShotAreaMath.plan(for: CGRect(x: 100, y: 50, width: 300, height: 200), displays: [shotMain])
        #expect(p.slices.count == 1 && p.outputScale == 2 && p.pixelWidth == 600 && p.pixelHeight == 400)
        let s = p.slices[0]
        #expect(s.sourcePixelRect == CGRect(x: 200, y: 100, width: 600, height: 400))
        #expect(s.localPointRect == CGRect(x: 100, y: 50, width: 300, height: 200))
        #expect(s.destPixelRect == CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    @Test func fractionalPointsRoundToTheDisplayPixelGrid() {
        let p = ShotAreaMath.plan(for: CGRect(x: 10.25, y: 20.75, width: 100.5, height: 50.5), displays: [shotMain])
        let s = p.slices[0]
        #expect(s.sourcePixelRect.width == p.slices[0].destPixelRect.width && s.sourcePixelRect.height == s.destPixelRect.height)
        #expect(s.sourcePixelRect.minX == 21 && s.sourcePixelRect.minY == 42)
    }

    @Test func areaOutsideEveryDisplayIsEmpty() {
        let p = ShotAreaMath.plan(for: CGRect(x: 9000, y: 9000, width: 50, height: 50), displays: [shotMain])
        #expect(p.isEmpty && p.slices.isEmpty)
    }

    @Test func areaPartlyOffscreenIsCropped() {
        let p = ShotAreaMath.plan(for: CGRect(x: 1400, y: 800, width: 200, height: 200), displays: [shotMain])
        #expect(p.slices.count == 1)
        #expect(p.rect == CGRect(x: 1400, y: 800, width: 40, height: 100))
        #expect(p.pixelWidth == 80 && p.pixelHeight == 200)
        #expect(p.slices[0].sourcePixelRect == CGRect(x: 2800, y: 1600, width: 80, height: 200))
    }

    @Test func areaSpanningTwoDisplaysWithMixedScale() {
        let p = ShotAreaMath.plan(for: CGRect(x: 1340, y: 100, width: 200, height: 100), displays: [shotMain, shotRight])
        #expect(p.spansSeveralDisplays && p.outputScale == 2)
        #expect(p.pixelWidth == 400 && p.pixelHeight == 200)
        let a = p.slices.first { $0.displayID == 1 }!, b = p.slices.first { $0.displayID == 2 }!
        #expect(a.sourcePixelRect == CGRect(x: 2680, y: 200, width: 200, height: 200))
        #expect(a.destPixelRect == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(b.sourcePixelRect == CGRect(x: 0, y: 100, width: 100, height: 100))
        #expect(b.destPixelRect == CGRect(x: 200, y: 0, width: 200, height: 200))
    }

    @Test func displayWithNegativeOriginAndOffset() {
        let p = ShotAreaMath.plan(for: CGRect(x: -300, y: 200, width: 100, height: 50), displays: [shotMain, shotLeft])
        #expect(p.slices.count == 1 && p.slices[0].displayID == 3)
        #expect(p.slices[0].localPointRect == CGRect(x: 980, y: 100, width: 100, height: 50))
        #expect(p.slices[0].sourcePixelRect == CGRect(x: 980, y: 100, width: 100, height: 50))
    }

    @Test func selectionOnADisplayAboveThePrimaryOne() {
        let above = shotDisplay(7, 0, -1080, 1920, 1080, scale: 1)
        let p = ShotAreaMath.plan(for: CGRect(x: 10, y: -100, width: 100, height: 50), displays: [shotMain, above])
        #expect(p.slices.count == 1 && p.slices[0].displayID == 7)
        #expect(p.slices[0].sourcePixelRect == CGRect(x: 10, y: 980, width: 100, height: 50))
    }

    @Test func downscaleToOneForcesUnitScale() {
        let p = ShotAreaMath.plan(for: CGRect(x: 0, y: 0, width: 300, height: 200), displays: [shotMain], downscaleToOne: true)
        #expect(p.outputScale == 1 && p.pixelWidth == 300 && p.pixelHeight == 200)
        #expect(p.slices[0].sourcePixelRect.width == 600 && p.slices[0].destPixelRect.width == 300)
    }

    @Test func fullDisplayAndAllDisplays() {
        let f = ShotAreaMath.fullDisplay(shotMain)
        #expect(f.pixelWidth == 2880 && f.pixelHeight == 1800 && f.slices[0].sourcePixelRect == CGRect(x: 0, y: 0, width: 2880, height: 1800))
        let all = ShotAreaMath.allDisplays([shotMain, shotRight])
        #expect(all.slices.count == 2 && all.pixelWidth == (1440 + 1920) * 2 && all.pixelHeight == 2160)
        let b = all.slices.first { $0.displayID == 2 }!
        #expect(b.destPixelRect.minX == 2880 && b.destPixelRect.width == 3840 && b.sourcePixelRect.width == 1920)
    }

    @Test func pixelRectForPointRect() {
        let r = ShotAreaMath.pixelRect(forPointRect: CGRect(x: 10, y: 10, width: 5.5, height: 5), in: shotMain)
        #expect(r == CGRect(x: 20, y: 20, width: 11, height: 10))
        #expect(ShotAreaMath.pixelRect(forPointRect: CGRect(x: 5000, y: 5000, width: 5, height: 5), in: shotMain) == .zero)
    }

    @Test func compositorStitchesTwoDisplays() {
        let p = ShotAreaMath.plan(for: CGRect(x: 1430, y: 0, width: 20, height: 10), displays: [shotMain, shotRight])
        let red = shotImage(2880, 1800, (255, 0, 0, 255)), green = shotImage(1920, 1080, (0, 255, 0, 255))
        let img = ShotCompositor.compose(plan: p, sources: [1: ShotSourceImage(image: red), 2: ShotSourceImage(image: green)])!
        #expect(img.width == 40 && img.height == 20)
        let bm = ShotBitmap(image: img)!
        #expect(bm.pixel(2, 2).0 == 255 && bm.pixel(2, 2).1 == 0)
        #expect(bm.pixel(37, 2).1 == 255 && bm.pixel(37, 2).0 == 0)
    }

    @Test func compositorHonoursSourceOrigins() {
        let p = ShotAreaMath.plan(for: CGRect(x: 100, y: 100, width: 50, height: 50), displays: [shotMain])
        let slice = shotImage(100, 100, (0, 0, 255, 255))
        let img = ShotCompositor.compose(plan: p, sources: [1: ShotSourceImage(image: slice, originPixel: p.slices[0].sourcePixelRect.origin)])!
        #expect(img.width == 100 && img.height == 100)
        #expect(ShotBitmap(image: img)!.pixel(50, 50).2 == 255)
    }

    @Test func compositorReturnsNilWithoutSources() {
        let p = ShotAreaMath.plan(for: CGRect(x: 0, y: 0, width: 50, height: 50), displays: [shotMain])
        #expect(ShotCompositor.compose(plan: p, sources: [:]) == nil)
        #expect(ShotCompositor.compose(plan: ShotAreaMath.plan(for: CGRect(x: 9999, y: 0, width: 5, height: 5), displays: [shotMain]), sources: [:]) == nil)
    }

    @Test func compositorKeepsOrientation() {
        let top = ShotBitmap(width: 40, height: 40) { _, y in y < 20 ? (255, 0, 0, 255) : (0, 0, 255, 255) }.makeImage()!
        let p = ShotAreaMath.plan(for: CGRect(x: 0, y: 0, width: 20, height: 20), displays: [shotDisplay(1, 0, 0, 20, 20, scale: 2)])
        let out = ShotBitmap(image: ShotCompositor.compose(plan: p, sources: [1: ShotSourceImage(image: top)])!)!
        #expect(out.pixel(5, 5).0 == 255 && out.pixel(5, 35).2 == 255)
    }
}
