import Foundation
import CoreGraphics

public enum RecCropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

public enum RecCropMath {
    static func pixelRatio(_ r: RecNormRect, _ s: CGSize) -> Double { (r.w * Double(s.width)) / max(r.h * Double(s.height), 0.0001) }

    // largest rect of the given pixel aspect that fits inside `rect`, centered in it
    public static func fit(aspect: RecAspect, in rect: RecNormRect, source: CGSize) -> RecNormRect {
        guard let ratio = aspect.ratio, source.width > 0, source.height > 0 else { return rect.sanitized }
        let r = rect.sanitized
        let availW = r.w * Double(source.width), availH = r.h * Double(source.height)
        var w = availW, h = availW / ratio
        if h > availH {
            h = availH
            w = h * ratio
        }
        let nw = w / Double(source.width), nh = h / Double(source.height)
        return RecNormRect(x: r.x + (r.w - nw) / 2, y: r.y + (r.h - nh) / 2, w: nw, h: nh).sanitized
    }

    public static func moved(_ r: RecNormRect, dx: Double, dy: Double) -> RecNormRect {
        RecNormRect(x: min(max(r.x + dx, 0), 1 - r.w), y: min(max(r.y + dy, 0), 1 - r.h), w: r.w, h: r.h)
    }

    public static func resized(_ r: RecNormRect, handle: RecCropHandle, to p: (x: Double, y: Double), aspect: RecAspect, source: CGSize) -> RecNormRect {
        let minS = RecNormRect.minSide
        var left = r.x, right = r.x + r.w, top = r.y, bottom = r.y + r.h
        let px = min(max(p.x, 0), 1), py = min(max(p.y, 0), 1)
        if handle.movesLeft { left = min(px, right - minS) }
        if handle.movesRight { right = max(px, left + minS) }
        if handle.movesTop { top = min(py, bottom - minS) }
        if handle.movesBottom { bottom = max(py, top + minS) }
        guard let ratio = aspect.ratio, source.width > 0, source.height > 0 else {
            return RecNormRect(x: left, y: top, w: right - left, h: bottom - top).sanitized
        }
        var w = right - left, h = bottom - top
        let horizontalOnly = (handle == .left || handle == .right)
        let verticalOnly = (handle == .top || handle == .bottom)
        let hFromW: (Double) -> Double = { $0 * Double(source.width) / (ratio * Double(source.height)) }
        let wFromH: (Double) -> Double = { $0 * ratio * Double(source.height) / Double(source.width) }
        if horizontalOnly || (!verticalOnly && abs(w - r.w) >= abs(h - r.h)) { h = hFromW(w) } else { w = wFromH(h) }
        // keep the opposite edge fixed
        var nx = handle.movesLeft ? right - w : left
        var ny = handle.movesTop ? bottom - h : top
        if horizontalOnly { ny = r.y + (r.h - h) / 2 }
        if verticalOnly { nx = r.x + (r.w - w) / 2 }
        var out = RecNormRect(x: nx, y: ny, w: w, h: h)
        let over = max(out.w, out.h)
        if over > 1 {
            let f = 1 / over
            out.w *= f
            out.h *= f
            out.x = handle.movesLeft ? right - out.w : out.x
            out.y = handle.movesTop ? bottom - out.h : out.y
        }
        out.x = min(max(out.x, 0), 1 - out.w)
        out.y = min(max(out.y, 0), 1 - out.h)
        return out
    }

    public static func pixelRect(crop: RecNormRect, source: CGSize) -> CGRect {
        let c = crop.sanitized
        let x = Int((c.x * Double(source.width)).rounded()) & ~1
        let y = Int((c.y * Double(source.height)).rounded()) & ~1
        var w = Int((c.w * Double(source.width)).rounded()) & ~1
        var h = Int((c.h * Double(source.height)).rounded()) & ~1
        w = max(min(w, Int(source.width) - x), 2)
        h = max(min(h, Int(source.height) - y), 2)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

public struct RecFrameLayout: Equatable, Sendable {
    public var canvas: CGSize
    public var sourceRect: CGRect
    public var destRect: CGRect
    public var cornerRadius: Double
    public var shadow: Bool
    public var sourceSize: CGSize

    public var scaleX: Double { destRect.width / max(sourceRect.width, 1) }
    public var scaleY: Double { destRect.height / max(sourceRect.height, 1) }

    public func map(normalized p: CGPoint) -> CGPoint? {
        let sx = Double(p.x) * Double(sourceSize.width), sy = Double(p.y) * Double(sourceSize.height)
        guard sx >= Double(sourceRect.minX), sx <= Double(sourceRect.maxX), sy >= Double(sourceRect.minY), sy <= Double(sourceRect.maxY) else { return nil }
        return CGPoint(x: Double(destRect.minX) + (sx - Double(sourceRect.minX)) * scaleX, y: Double(destRect.minY) + (sy - Double(sourceRect.minY)) * scaleY)
    }

    public func map(rect n: RecNormRect) -> CGRect? {
        let px = CGRect(x: n.x * Double(sourceSize.width), y: n.y * Double(sourceSize.height), width: n.w * Double(sourceSize.width), height: n.h * Double(sourceSize.height))
        let visible = px.intersection(sourceRect)
        guard !visible.isNull, visible.width > 0.5, visible.height > 0.5 else { return nil }
        return CGRect(x: Double(destRect.minX) + Double(visible.minX - sourceRect.minX) * scaleX, y: Double(destRect.minY) + Double(visible.minY - sourceRect.minY) * scaleY,
                      width: Double(visible.width) * scaleX, height: Double(visible.height) * scaleY)
    }
}

public enum RecLayoutMath {
    public static func canvasSize(source: RecSourceInfo, crop: RecNormRect, style: RecFrameStyle, maxLongSide: Int? = nil) -> CGSize {
        let c = RecCropMath.pixelRect(crop: crop, source: source.size)
        let pad = Double(style.padding) * source.scale
        var w = Double(c.width) + 2 * pad, h = Double(c.height) + 2 * pad
        if let cap = maxLongSide, cap > 0, max(w, h) > Double(cap) {
            let f = Double(cap) / max(w, h)
            w *= f
            h *= f
        }
        return CGSize(width: RecGeometry.even(w), height: RecGeometry.even(h))
    }

    public static func layout(source: RecSourceInfo, crop: RecNormRect, style raw: RecFrameStyle, zoom: RecZoomSample = .identity, maxLongSide: Int? = nil) -> RecFrameLayout {
        let style = raw.sanitized
        let cropPx = RecCropMath.pixelRect(crop: crop, source: source.size)
        let canvas = canvasSize(source: source, crop: crop, style: style, maxLongSide: maxLongSide)
        let baseW = Double(cropPx.width) + 2 * Double(style.padding) * source.scale
        let k = Double(canvas.width) / max(baseW, 1)
        let pad = Double(style.padding) * source.scale * k
        let dest = CGRect(x: pad, y: pad, width: max(Double(canvas.width) - 2 * pad, 2), height: max(Double(canvas.height) - 2 * pad, 2))
        let view = RecZoomMath.viewRect(scale: zoom.scale, cx: zoom.cx, cy: zoom.cy)
        let src = CGRect(x: cropPx.minX + view.minX * cropPx.width, y: cropPx.minY + view.minY * cropPx.height, width: view.width * cropPx.width, height: view.height * cropPx.height)
        let radius = min(Double(style.corner) * source.scale * k, min(dest.width, dest.height) / 2)
        return RecFrameLayout(canvas: canvas, sourceRect: src, destRect: dest, cornerRadius: max(radius, 0), shadow: style.padding > 0 && style.shadow, sourceSize: source.size)
    }
}
