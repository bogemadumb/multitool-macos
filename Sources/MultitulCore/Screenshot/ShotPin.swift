import Foundation
import CoreGraphics

public enum ShotPinCorner: Equatable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct ShotPinState: Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var recordID: Int64?
    public var frame: CGRect
    public var imagePointSize: CGSize
    public var opacity: Double
    public var clickThrough: Bool
    public var hidden: Bool

    public var aspect: CGFloat { imagePointSize.height > 0 ? imagePointSize.width / imagePointSize.height : 1 }
    public var zoom: Double { imagePointSize.width > 0 ? Double(frame.width / imagePointSize.width) : 1 }
}

public enum ShotPinMath {
    public static let minSide: CGFloat = 48
    public static let opacityRange = 0.1...1.0
    public static let opacityStep = 0.1
    public static let zoomRange = 0.1...8.0

    public static func clampOpacity(_ o: Double) -> Double { min(max(o, opacityRange.lowerBound), opacityRange.upperBound) }

    public static func steppedOpacity(_ o: Double, up: Bool) -> Double {
        let v = ((o + (up ? opacityStep : -opacityStep)) * 10).rounded() / 10
        return clampOpacity(v)
    }

    public static func initialFrame(pointSize: CGSize, preferredOrigin: CGPoint?, visible: CGRect, maxFraction: CGFloat = 0.6) -> CGRect {
        var w = max(pointSize.width, 1), h = max(pointSize.height, 1)
        let k = min(1, visible.width * maxFraction / w, visible.height * maxFraction / h)
        w *= k
        h *= k
        w = max(w, min(minSide, visible.width))
        h = max(h, min(minSide, visible.height))
        let origin = preferredOrigin ?? CGPoint(x: visible.midX - w / 2, y: visible.midY - h / 2)
        return fit(CGRect(origin: origin, size: CGSize(width: w, height: h)), in: visible)
    }

    public static func fit(_ r: CGRect, in area: CGRect) -> CGRect {
        var o = r.origin
        o.x = min(max(o.x, area.minX), max(area.maxX - r.width, area.minX))
        o.y = min(max(o.y, area.minY), max(area.maxY - r.height, area.minY))
        return CGRect(origin: o, size: r.size)
    }

    public static func cascaded(_ r: CGRect, index: Int, step: CGFloat = 24, in area: CGRect) -> CGRect {
        let n = CGFloat(index % 8)
        return fit(r.offsetBy(dx: n * step, dy: -n * step), in: area)
    }

    public static func resized(_ frame: CGRect, corner: ShotPinCorner, to p: CGPoint, aspect: CGFloat, lockAspect: Bool, maxSize: CGSize? = nil) -> CGRect {
        let fixed: CGPoint
        switch corner {
        case .topLeft: fixed = CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight: fixed = CGPoint(x: frame.minX, y: frame.minY)
        case .bottomLeft: fixed = CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight: fixed = CGPoint(x: frame.minX, y: frame.maxY)
        }
        let sx: CGFloat = p.x >= fixed.x ? 1 : -1
        let sy: CGFloat = p.y >= fixed.y ? 1 : -1
        var w = max(abs(p.x - fixed.x), minSide)
        var h = max(abs(p.y - fixed.y), minSide)
        if lockAspect, aspect > 0 {
            if w / h > aspect { h = w / aspect } else { w = h * aspect }
            if h < minSide { h = minSide; w = h * aspect }
            if w < minSide { w = minSide; h = w / aspect }
        }
        if let m = maxSize {
            let k = min(1, m.width / w, m.height / h)
            w *= k
            h *= k
        }
        return CGRect(x: sx > 0 ? fixed.x : fixed.x - w, y: sy > 0 ? fixed.y : fixed.y - h, width: w, height: h)
    }

    public static func zoomed(_ frame: CGRect, factor: CGFloat, around anchor: CGPoint, imagePointSize: CGSize, maxSize: CGSize? = nil) -> CGRect {
        guard factor > 0, imagePointSize.width > 0 else { return frame }
        var w = frame.width * factor
        let lo = imagePointSize.width * CGFloat(zoomRange.lowerBound), hi = imagePointSize.width * CGFloat(zoomRange.upperBound)
        w = min(max(w, max(lo, minSide)), hi)
        var h = w * frame.height / frame.width
        if let m = maxSize, w > m.width || h > m.height {
            let k = min(m.width / w, m.height / h)
            w *= k
            h *= k
        }
        let kx = (anchor.x - frame.minX) / frame.width
        let ky = (anchor.y - frame.minY) / frame.height
        return CGRect(x: anchor.x - kx * w, y: anchor.y - ky * h, width: w, height: h)
    }

    public static func keepReachable(_ frame: CGRect, in area: CGRect, grip: CGFloat = 40) -> CGRect {
        var o = frame.origin
        o.x = min(max(o.x, area.minX - frame.width + grip), area.maxX - grip)
        o.y = min(max(o.y, area.minY - frame.height + grip), area.maxY - grip)
        return CGRect(origin: o, size: frame.size)
    }
}

public final class ShotPinBoard {
    public static let defaultLimit = 24
    public private(set) var pins: [ShotPinState] = []
    public private(set) var allHidden = false
    public let limit: Int
    private var nextID = 1

    public init(limit: Int = ShotPinBoard.defaultLimit) { self.limit = max(limit, 1) }

    public var count: Int { pins.count }
    public func pin(_ id: Int) -> ShotPinState? { pins.first { $0.id == id } }
    public var visiblePins: [ShotPinState] { pins.filter { !$0.hidden && !allHidden } }

    @discardableResult
    public func add(title: String, recordID: Int64?, imagePointSize: CGSize, visible: CGRect, preferredOrigin: CGPoint? = nil) -> (id: Int, evicted: Int?) {
        var evicted: Int?
        if pins.count >= limit { evicted = pins.removeFirst().id }
        let base = ShotPinMath.initialFrame(pointSize: imagePointSize, preferredOrigin: preferredOrigin, visible: visible)
        let frame = preferredOrigin == nil ? ShotPinMath.cascaded(base, index: pins.count, in: visible) : base
        let id = nextID
        nextID += 1
        pins.append(ShotPinState(id: id, title: title, recordID: recordID, frame: frame, imagePointSize: imagePointSize, opacity: 1, clickThrough: false, hidden: false))
        allHidden = false
        return (id, evicted)
    }

    public func remove(_ id: Int) { pins.removeAll { $0.id == id } }
    public func removeAll() { pins.removeAll() }

    public func update(_ id: Int, _ change: (inout ShotPinState) -> Void) {
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        change(&pins[i])
    }

    public func setFrame(_ id: Int, _ frame: CGRect) { update(id) { $0.frame = frame } }
    public func setOpacity(_ id: Int, _ o: Double) { update(id) { $0.opacity = ShotPinMath.clampOpacity(o) } }
    public func stepOpacity(_ id: Int, up: Bool) { update(id) { $0.opacity = ShotPinMath.steppedOpacity($0.opacity, up: up) } }
    public func setClickThrough(_ id: Int, _ on: Bool) { update(id) { $0.clickThrough = on } }
    public func toggleClickThrough(_ id: Int) { update(id) { $0.clickThrough.toggle() } }

    public func bringToFront(_ id: Int) {
        guard let i = pins.firstIndex(where: { $0.id == id }), i != pins.count - 1 else { return }
        pins.append(pins.remove(at: i))
    }

    public func toggleAllHidden() { allHidden.toggle() }
    public func setAllHidden(_ h: Bool) { allHidden = h }

    public func setAllClickThrough(_ on: Bool) {
        for i in pins.indices { pins[i].clickThrough = on }
    }

    public var clickThroughCount: Int { pins.filter(\.clickThrough).count }
}
