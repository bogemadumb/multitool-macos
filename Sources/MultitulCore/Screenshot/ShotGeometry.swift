import Foundation
import CoreGraphics

public struct ShotDisplay: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = max(scale, 1)
    }

    public var pixelSize: CGSize {
        CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
    }

    public init(id: UInt32, cocoaFrame: CGRect, scale: CGFloat, primaryHeight: CGFloat) {
        self.init(id: id, frame: ShotSpace.cocoaToDesktop(cocoaFrame, primaryHeight: primaryHeight), scale: scale)
    }
}

public enum ShotSpace {
    public static func cocoaToDesktop(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func desktopToCocoa(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        cocoaToDesktop(r, primaryHeight: primaryHeight)
    }

    public static func cocoaToDesktop(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func desktopToCocoa(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        cocoaToDesktop(p, primaryHeight: primaryHeight)
    }

    public static func bounds(_ displays: [ShotDisplay]) -> CGRect {
        guard var u = displays.first?.frame else { return .zero }
        for d in displays.dropFirst() { u = u.union(d.frame) }
        return u
    }

    public static func display(containing p: CGPoint, in displays: [ShotDisplay]) -> ShotDisplay? {
        if let d = displays.first(where: { $0.frame.contains(p) }) { return d }
        return displays.min { distance($0.frame, p) < distance($1.frame, p) }
    }

    public static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func moved(_ r: CGRect, inside bounds: CGRect) -> CGRect {
        var o = r.origin
        o.x = min(max(o.x, bounds.minX), max(bounds.maxX - r.width, bounds.minX))
        o.y = min(max(o.y, bounds.minY), max(bounds.maxY - r.height, bounds.minY))
        return CGRect(origin: o, size: r.size)
    }
}

public struct ShotSlice: Equatable, Sendable {
    public var displayID: UInt32
    public var pointRect: CGRect
    public var localPointRect: CGRect
    public var sourcePixelRect: CGRect
    public var destPixelRect: CGRect
    public var displayScale: CGFloat
}

public struct ShotAreaPlan: Equatable, Sendable {
    public var rect: CGRect
    public var outputScale: CGFloat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var slices: [ShotSlice]

    public var isEmpty: Bool { slices.isEmpty || pixelWidth <= 0 || pixelHeight <= 0 }
    public var spansSeveralDisplays: Bool { slices.count > 1 }
}

public enum ShotAreaMath {
    public static let minSide: CGFloat = 1

    public static func plan(for rect: CGRect, displays: [ShotDisplay], downscaleToOne: Bool = false) -> ShotAreaPlan {
        let r = rect.standardized
        var hits: [(ShotDisplay, CGRect)] = []
        for d in displays {
            let i = r.intersection(d.frame)
            if !i.isNull, i.width >= minSide / 8, i.height >= minSide / 8 { hits.append((d, i)) }
        }
        guard !hits.isEmpty else { return ShotAreaPlan(rect: r, outputScale: 1, pixelWidth: 0, pixelHeight: 0, slices: []) }
        let scale: CGFloat = downscaleToOne ? 1 : (hits.map { $0.0.scale }.max() ?? 1)
        let covered = hits.dropFirst().reduce(hits[0].1) { $0.union($1.1) }
        let pw = Int((covered.width * scale).rounded())
        let ph = Int((covered.height * scale).rounded())
        var slices: [ShotSlice] = []
        for (d, i) in hits {
            let local = CGRect(x: i.minX - d.frame.minX, y: i.minY - d.frame.minY, width: i.width, height: i.height)
            let px = d.pixelSize
            let sw = min((local.width * d.scale).rounded(), px.width)
            let sh = min((local.height * d.scale).rounded(), px.height)
            let minX = min(max((local.minX * d.scale).rounded(), 0), px.width - sw)
            let minY = min(max((local.minY * d.scale).rounded(), 0), px.height - sh)
            let src = CGRect(x: minX, y: minY, width: max(sw, 0), height: max(sh, 0))
            let dest = CGRect(x: ((i.minX - covered.minX) * scale).rounded(), y: ((i.minY - covered.minY) * scale).rounded(),
                              width: (i.width * scale).rounded(), height: (i.height * scale).rounded())
            slices.append(ShotSlice(displayID: d.id, pointRect: i, localPointRect: local, sourcePixelRect: src, destPixelRect: dest, displayScale: d.scale))
        }
        return ShotAreaPlan(rect: covered, outputScale: scale, pixelWidth: pw, pixelHeight: ph, slices: slices)
    }

    public static func fullDisplay(_ d: ShotDisplay, downscaleToOne: Bool = false) -> ShotAreaPlan {
        plan(for: d.frame, displays: [d], downscaleToOne: downscaleToOne)
    }

    public static func allDisplays(_ displays: [ShotDisplay], downscaleToOne: Bool = false) -> ShotAreaPlan {
        plan(for: ShotSpace.bounds(displays), displays: displays, downscaleToOne: downscaleToOne)
    }

    public static func displayUnderCursor(_ cursor: CGPoint, displays: [ShotDisplay]) -> ShotDisplay? {
        ShotSpace.display(containing: cursor, in: displays)
    }

    public static func pixelRect(forPointRect r: CGRect, in d: ShotDisplay) -> CGRect {
        let local = r.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        let x0 = (local.minX * d.scale).rounded(.down), y0 = (local.minY * d.scale).rounded(.down)
        let x1 = (local.maxX * d.scale).rounded(.up), y1 = (local.maxY * d.scale).rounded(.up)
        let px = d.pixelSize
        let rr = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(CGRect(origin: .zero, size: px))
        return rr.isNull ? .zero : rr
    }
}

public struct ShotSourceImage {
    public var image: CGImage
    public var originPixel: CGPoint

    public init(image: CGImage, originPixel: CGPoint = .zero) {
        self.image = image
        self.originPixel = originPixel
    }
}

public enum ShotCompositor {
    public static func compose(plan: ShotAreaPlan, sources: [UInt32: ShotSourceImage]) -> CGImage? {
        guard !plan.isEmpty, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: plan.pixelWidth, height: plan.pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        var drew = false
        for s in plan.slices {
            guard let src = sources[s.displayID] else { continue }
            let sx = s.sourcePixelRect.minX - src.originPixel.x
            let sy = s.sourcePixelRect.minY - src.originPixel.y
            let want = CGRect(x: sx, y: sy, width: s.sourcePixelRect.width, height: s.sourcePixelRect.height)
            let have = CGRect(x: 0, y: 0, width: src.image.width, height: src.image.height)
            let crop = want.intersection(have).integral
            guard !crop.isNull, crop.width > 0, crop.height > 0, let piece = src.image.cropping(to: crop) else { continue }
            let kx = s.destPixelRect.width / max(want.width, 1)
            let ky = s.destPixelRect.height / max(want.height, 1)
            let destX = s.destPixelRect.minX + (crop.minX - want.minX) * kx
            let destYTop = s.destPixelRect.minY + (crop.minY - want.minY) * ky
            let dw = crop.width * kx, dh = crop.height * ky
            let flippedY = CGFloat(plan.pixelHeight) - destYTop - dh
            ctx.draw(piece, in: CGRect(x: destX, y: flippedY, width: dw, height: dh))
            drew = true
        }
        return drew ? ctx.makeImage() : nil
    }
}
