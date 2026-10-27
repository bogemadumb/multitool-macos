import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ShotWindowMathTests {
    @Test func filterKeepsOnlyNormalVisibleWindows() {
        let list = [shotWin(1, 0, 0, 500, 400), shotWin(2, 0, 0, 500, 400, layer: 25), shotWin(3, 0, 0, 20, 20), shotWin(4, 0, 0, 500, 400, pid: 77),
                    ShotWindowInfo(id: 5, frame: CGRect(x: 0, y: 0, width: 300, height: 300), layer: 0, isOnScreen: false)]
        #expect(ShotWindowFilter.selectable(list, excludingPids: [77]).map(\.id) == [1])
    }

    @Test func topmostUsesTheGivenFrontToBackOrder() {
        let a = shotWin(1, 0, 0, 300, 300), b = shotWin(2, 100, 100, 300, 300)
        #expect(ShotWindowFilter.topmost(at: CGPoint(x: 150, y: 150), in: [b, a])?.id == 2)
        #expect(ShotWindowFilter.topmost(at: CGPoint(x: 150, y: 150), in: [a, b])?.id == 1)
        #expect(ShotWindowFilter.topmost(at: CGPoint(x: 900, y: 900), in: [a, b]) == nil)
    }

    @Test func labelCombinesOwnerAndTitle() {
        #expect(ShotWindowFilter.label(shotWin(1, 0, 0, 1, 1, title: "Док", owner: "Pages")) == "Pages — Док")
        #expect(ShotWindowFilter.label(shotWin(1, 0, 0, 1, 1, title: "", owner: "Pages")) == "Pages")
        #expect(ShotWindowFilter.label(ShotWindowInfo(id: 1, ownerName: "", title: "T", frame: .zero)) == "T")
    }

    @Test func planWithoutShadowIsTheWindowFrame() {
        let p = ShotWindowMath.plan(frame: CGRect(x: 100, y: 80, width: 600, height: 400), scale: 2, withShadow: false)
        #expect(p.captureFrame == p.windowFrame && p.pixelWidth == 1200 && p.pixelHeight == 800)
        #expect(p.windowRectInImage == CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test func planWithShadowGrowsByTheInsets() {
        let ins = ShotShadowInsets(top: 10, left: 20, bottom: 40, right: 30)
        let p = ShotWindowMath.plan(frame: CGRect(x: 100, y: 80, width: 600, height: 400), scale: 2, withShadow: true, insets: ins)
        #expect(p.captureFrame == CGRect(x: 80, y: 70, width: 650, height: 450))
        #expect(p.pixelWidth == 1300 && p.pixelHeight == 900)
        #expect(p.windowRectInImage == CGRect(x: 40, y: 20, width: 1200, height: 800))
    }

    @Test func standardInsetsAreSymmetricSides() {
        #expect(ShotShadowInsets.standard.left == ShotShadowInsets.standard.right && ShotShadowInsets.standard.bottom > ShotShadowInsets.standard.top)
        #expect(ShotShadowInsets.none == ShotShadowInsets(top: 0, left: 0, bottom: 0, right: 0))
    }

    @Test func standardizesNegativeFrames() {
        let p = ShotWindowMath.plan(frame: CGRect(x: 100, y: 100, width: -50, height: -20), scale: 1, withShadow: false)
        #expect(p.windowFrame == CGRect(x: 50, y: 80, width: 50, height: 20))
    }

    @Test func scaleComesFromTheDisplayHoldingTheWindowCentre() {
        let w = CGRect(x: 1300, y: 100, width: 400, height: 300)
        #expect(ShotWindowMath.scale(for: w, displays: [shotMain, shotRight]) == 1)
        #expect(ShotWindowMath.scale(for: CGRect(x: 0, y: 0, width: 100, height: 100), displays: [shotMain, shotRight]) == 2)
        #expect(ShotWindowMath.scale(for: .zero, displays: []) == 2)
    }

    @Test func backdropWithoutPaddingIsTheImageItself() {
        let l = ShotBackdropMath.layout(imageSize: CGSize(width: 800, height: 600), paddingPoints: 0, scale: 2, background: .none, cornerRadiusPoints: 12)
        #expect(l.canvas == CGSize(width: 800, height: 600) && l.imageRect == CGRect(x: 0, y: 0, width: 800, height: 600) && !l.hasBackground && l.cornerRadius == 0)
    }

    @Test func backdropPaddingScalesWithRetina() {
        let l = ShotBackdropMath.layout(imageSize: CGSize(width: 800, height: 600), paddingPoints: 40, scale: 2, background: .solid(.white), cornerRadiusPoints: 10)
        #expect(l.canvas == CGSize(width: 960, height: 760) && l.imageRect == CGRect(x: 80, y: 80, width: 800, height: 600))
        #expect(l.hasBackground && l.cornerRadius == 20)
    }

    @Test func backdropPaddingWithoutBackgroundStaysTransparent() {
        let l = ShotBackdropMath.layout(imageSize: CGSize(width: 100, height: 100), paddingPoints: 10, scale: 1, background: .none, cornerRadiusPoints: 10)
        #expect(!l.hasBackground && l.canvas == CGSize(width: 120, height: 120) && l.cornerRadius == 0)
    }

    @Test func cornerRadiusNeverExceedsHalfTheSide() {
        let l = ShotBackdropMath.layout(imageSize: CGSize(width: 40, height: 30), paddingPoints: 5, scale: 1, background: .solid(.black), cornerRadiusPoints: 80)
        #expect(l.cornerRadius == 15)
    }

    @Test func gradientEndpointsFollowTheAngle() {
        let size = CGSize(width: 200, height: 100)
        let down = ShotBackdropMath.gradientEndpoints(angleDegrees: 180, in: size)
        #expect(down.start.y < down.end.y && abs(down.start.x - down.end.x) < 0.001)
        let right = ShotBackdropMath.gradientEndpoints(angleDegrees: 90, in: size)
        #expect(right.start.x < right.end.x && abs(right.start.y - right.end.y) < 0.001)
        let neg = ShotBackdropMath.gradientEndpoints(angleDegrees: -90, in: size)
        #expect(neg.start.x > neg.end.x)
    }

    @Test func watermarkRectSitsInTheChosenCorner() {
        let canvas = CGSize(width: 500, height: 300), text = CGSize(width: 100, height: 20)
        #expect(ShotWatermarkMath.rect(textSize: text, canvas: canvas, corner: .bottomRight) == CGRect(x: 388, y: 268, width: 100, height: 20))
        #expect(ShotWatermarkMath.rect(textSize: text, canvas: canvas, corner: .topLeft) == CGRect(x: 12, y: 12, width: 100, height: 20))
        #expect(ShotWatermarkMath.rect(textSize: text, canvas: CGSize(width: 50, height: 10), corner: .bottomRight).origin == .zero)
    }
}

@Suite struct ShotBitmapTests {
    @Test func initFromImageRoundTrips() {
        let bm = ShotBitmap(width: 6, height: 4) { x, y in (UInt8(x * 40), UInt8(y * 60), 7, 255) }
        let back = ShotBitmap(image: bm.makeImage()!)!
        #expect(back == bm)
    }

    @Test func rowsAndCropSliceTheBytes() {
        let bm = shotPage(rows: 10, width: 4)
        #expect(bm.rows(2..<5).height == 3 && bm.rows(2..<5).pixel(0, 0).0 == 2)
        #expect(bm.rows(8..<40).height == 2)
        let c = bm.cropped(CGRect(x: 1, y: 3, width: 2, height: 2))
        #expect(c.width == 2 && c.height == 2 && c.pixel(0, 0).0 == 3 && c.pixel(1, 1).0 == 4)
        #expect(bm.cropped(CGRect(x: 100, y: 100, width: 5, height: 5)).isEmpty)
    }

    @Test func appendRequiresTheSameWidth() {
        var a = shotPage(rows: 3, width: 4)
        a.append(rows: shotPage(rows: 2, width: 5))
        #expect(a.height == 3)
        a.append(rows: shotPage(rows: 2, width: 4))
        #expect(a.height == 5)
    }

    @Test func pixelateMakesUniformBlocks() {
        var bm = ShotBitmap(width: 8, height: 8) { x, y in (UInt8(x * 30), UInt8(y * 30), 0, 255) }
        bm.pixelate(region: CGRect(x: 0, y: 0, width: 8, height: 8), block: 4)
        for by in 0..<2 { for bx in 0..<2 {
            let first = bm.pixel(bx * 4, by * 4)
            for y in 0..<4 { for x in 0..<4 { #expect(bm.pixel(bx * 4 + x, by * 4 + y) == first) } }
        } }
        #expect(bm.pixel(0, 0) != bm.pixel(4, 0))
    }

    @Test func pixelateAveragesTheBlock() {
        var bm = ShotBitmap(width: 2, height: 2) { x, y in (x == 0 ? 0 : 100, 0, 0, 255) }
        bm.pixelate(region: CGRect(x: 0, y: 0, width: 2, height: 2), block: 2)
        #expect(bm.pixel(0, 0).0 == 50 && bm.pixel(1, 1).0 == 50)
    }

    @Test func pixelateLeavesTheOutsideAlone() {
        let src = shotPage(rows: 12, width: 12)
        var bm = src
        bm.pixelate(region: CGRect(x: 4, y: 4, width: 4, height: 4), block: 4)
        for y in 0..<12 { for x in 0..<12 where !(4..<8).contains(x) || !(4..<8).contains(y) { #expect(bm.pixel(x, y) == src.pixel(x, y)) } }
    }

    @Test func pixelateHandlesRaggedEdgesAndOutOfBoundsRegions() {
        var bm = shotPage(rows: 10, width: 10)
        bm.pixelate(region: CGRect(x: 6, y: 6, width: 50, height: 50), block: 3)
        #expect(bm.pixel(6, 6) == bm.pixel(8, 8) && bm.pixel(9, 6) == bm.pixel(9, 8))
        let before = bm
        bm.pixelate(region: CGRect(x: 100, y: 100, width: 5, height: 5), block: 3)
        #expect(bm == before)
    }

    @Test func blurKeepsAFlatRegionFlat() {
        var bm = ShotBitmap(width: 20, height: 20, color: (80, 120, 160, 255))
        bm.blur(region: CGRect(x: 2, y: 2, width: 16, height: 16), radius: 4)
        #expect(bm.pixel(10, 10) == (80, 120, 160, 255) && bm.pixel(2, 2) == (80, 120, 160, 255))
    }

    @Test func blurSmoothsAHardEdgeInsideTheRegionOnly() {
        var bm = ShotBitmap(width: 40, height: 10) { x, _ in x < 20 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let src = bm
        bm.blur(region: CGRect(x: 10, y: 0, width: 20, height: 10), radius: 3)
        let mid = Int(bm.pixel(19, 5).0), mid2 = Int(bm.pixel(20, 5).0)
        #expect(mid > 0 && mid < 255 && mid2 > 0 && mid2 < 255)
        #expect(bm.pixel(5, 5) == src.pixel(5, 5) && bm.pixel(35, 5) == src.pixel(35, 5))
        #expect(bm.pixel(10, 5).0 == 0 || bm.pixel(10, 5).0 < 40)
    }

    @Test func blurIsSymmetricForASymmetricEdge() {
        var bm = ShotBitmap(width: 21, height: 3) { x, _ in x == 10 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        bm.blur(region: CGRect(x: 0, y: 0, width: 21, height: 3), radius: 2, passes: 1)
        #expect(bm.pixel(8, 1).0 == bm.pixel(12, 1).0 && bm.pixel(9, 1).0 == bm.pixel(11, 1).0)
    }

    @Test func effectMathClampsRegions() {
        #expect(ShotEffectMath.clampRegion(CGRect(x: -5, y: -5, width: 20, height: 20), width: 10, height: 10)! == (0, 0, 10, 10))
        #expect(ShotEffectMath.clampRegion(CGRect(x: 20, y: 20, width: 5, height: 5), width: 10, height: 10) == nil)
        #expect(ShotEffectMath.clampRegion(CGRect(x: 8, y: 8, width: -4, height: -4), width: 10, height: 10)! == (4, 4, 4, 4))
    }

    @Test func blockSizeGrowsWithStrength() {
        let r = CGSize(width: 400, height: 300)
        let a = ShotEffectMath.blockSize(strength: 0, region: r), b = ShotEffectMath.blockSize(strength: 0.5, region: r), c = ShotEffectMath.blockSize(strength: 1, region: r)
        #expect(a == ShotEffectMath.minBlock && a < b && b < c && c <= ShotEffectMath.maxBlock)
        #expect(ShotEffectMath.blockSize(strength: 9, region: CGSize(width: 8, height: 8)) <= 4)
    }

    @Test func blurRadiusStaysInsideTheRegion() {
        #expect(ShotEffectMath.blurRadius(strength: 1, region: CGSize(width: 10, height: 10)) <= 4)
        #expect(ShotEffectMath.blurRadius(strength: 0, region: CGSize(width: 400, height: 400)) == 1)
        #expect(ShotEffectMath.blurRadius(strength: 1, region: CGSize(width: 400, height: 400)) == 30)
    }

    @Test func blocksTileTheRegionExactly() {
        let bl = ShotEffectMath.blocks(region: (10, 20, 10, 7), block: 4)
        #expect(bl.reduce(0) { $0 + $1.w * $1.h } == 70)
        #expect(bl.count == 6 && bl.first! == (10, 20, 4, 4) && bl.last! == (18, 24, 2, 3))
    }
}
