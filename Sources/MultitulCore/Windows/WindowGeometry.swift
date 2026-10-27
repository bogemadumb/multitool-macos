import Foundation
import CoreGraphics

public struct WndScreen: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var visible: CGRect

    public init(id: UInt32, frame: CGRect, visible: CGRect) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

public struct WndDisplay: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var visible: CGRect

    public init(id: UInt32, frame: CGRect, visible: CGRect) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

public enum ScreenSpace {
    public static func primaryHeight(_ screens: [WndScreen]) -> CGFloat {
        (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    public static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func flip(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func displays(from screens: [WndScreen]) -> [WndDisplay] {
        let h = primaryHeight(screens)
        return screens.map { WndDisplay(id: $0.id, frame: flip($0.frame, primaryHeight: h), visible: flip($0.visible, primaryHeight: h)) }
    }
}

public enum WindowGeometry {
    public static let frameTolerance: CGFloat = 8
    static let edgeEpsilon = 1e-6

    public static func usableArea(_ visible: CGRect, gaps: WindowGaps) -> CGRect {
        let g = CGFloat(gaps.sanitized.screen)
        let r = visible.insetBy(dx: g, dy: g)
        return r.width >= 1 && r.height >= 1 ? r : visible
    }

    public static func rect(_ f: FractionRect, in visible: CGRect, gaps: WindowGaps) -> CGRect {
        let area = usableArea(visible, gaps: gaps)
        let half = CGFloat(gaps.sanitized.window) / 2
        var minX = area.minX + CGFloat(f.x) * area.width
        var maxX = area.minX + CGFloat(f.x + f.w) * area.width
        var minY = area.minY + CGFloat(f.y) * area.height
        var maxY = area.minY + CGFloat(f.y + f.h) * area.height
        if f.x > edgeEpsilon { minX += half }
        if f.x + f.w < 1 - edgeEpsilon { maxX -= half }
        if f.y > edgeEpsilon { minY += half }
        if f.y + f.h < 1 - edgeEpsilon { maxY -= half }
        return snapped(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    public static func rect(for action: WindowLayoutAction, current: CGRect, visible: CGRect, gaps: WindowGaps = .none, marginPercent: Double = 5, custom: FractionRect? = nil) -> CGRect? {
        switch action {
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        case .center:
            let area = usableArea(visible, gaps: gaps)
            let w = min(current.width, area.width)
            let h = min(current.height, area.height)
            return snapped(minX: area.midX - w / 2, minY: area.midY - h / 2, maxX: area.midX + w / 2, maxY: area.midY + h / 2)
        case .marginMaximize:
            let area = usableArea(visible, gaps: gaps)
            let p = CGFloat(min(max(marginPercent, WindowLayoutSettings.marginRange.lowerBound), WindowLayoutSettings.marginRange.upperBound)) / 100
            let r = area.insetBy(dx: area.width * p, dy: area.height * p)
            return snapped(minX: r.minX, minY: r.minY, maxX: r.maxX, maxY: r.maxY)
        default:
            if let slot = action.customSlot {
                guard let c = custom, slot > 0 else { return nil }
                return rect(c.sanitized, in: visible, gaps: gaps)
            }
            guard let f = action.fraction else { return nil }
            return rect(f, in: visible, gaps: gaps)
        }
    }

    static func snapped(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) -> CGRect {
        let x0 = minX.rounded()
        let y0 = minY.rounded()
        return CGRect(x: x0, y: y0, width: max(maxX.rounded() - x0, 1), height: max(maxY.rounded() - y0, 1))
    }

    public static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = frameTolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    public static func approxSize(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 1.5) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func axisOrigin(targetMin: CGFloat, targetMax: CGFloat, actual: CGFloat, areaMin: CGFloat, areaMax: CGFloat) -> CGFloat {
        let length = targetMax - targetMin
        var o: CGFloat
        if actual <= length + 0.5 {
            o = targetMin + (length - actual) / 2
        } else {
            let atMin = targetMin <= areaMin + 0.5
            let atMax = targetMax >= areaMax - 0.5
            if atMin && !atMax { o = targetMin }
            else if atMax && !atMin { o = targetMax - actual }
            else { o = (targetMin + targetMax) / 2 - actual / 2 }
        }
        if actual >= areaMax - areaMin { return areaMin }
        o = min(max(o, areaMin), areaMax - actual)
        return o.rounded()
    }

    public static func settle(target: CGRect, actualSize: CGSize, area: CGRect) -> CGRect {
        let w = min(actualSize.width, area.width)
        let h = min(actualSize.height, area.height)
        let x = axisOrigin(targetMin: target.minX, targetMax: target.maxX, actual: w, areaMin: area.minX, areaMax: area.maxX)
        let y = axisOrigin(targetMin: target.minY, targetMax: target.maxY, actual: h, areaMin: area.minY, areaMax: area.maxY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    public static func fitting(_ rect: CGRect, minSize: CGSize, in area: CGRect) -> CGRect {
        let w = min(max(rect.width, minSize.width), area.width)
        let h = min(max(rect.height, minSize.height), area.height)
        func origin(_ lo: CGFloat, _ hi: CGFloat, _ len: CGFloat, _ aLo: CGFloat, _ aHi: CGFloat) -> CGFloat {
            let atMin = lo <= aLo + 0.5
            let atMax = hi >= aHi - 0.5
            var o: CGFloat
            if atMin && !atMax { o = lo }
            else if atMax && !atMin { o = hi - len }
            else { o = (lo + hi) / 2 - len / 2 }
            o = min(max(o, aLo), max(aHi - len, aLo))
            return o.rounded()
        }
        return CGRect(x: origin(rect.minX, rect.maxX, w, area.minX, area.maxX), y: origin(rect.minY, rect.maxY, h, area.minY, area.maxY), width: w, height: h)
    }

    public static func clamp(_ rect: CGRect, into area: CGRect) -> CGRect {
        let w = min(rect.width, area.width)
        let h = min(rect.height, area.height)
        let x = min(max(rect.minX, area.minX), area.maxX - w)
        let y = min(max(rect.minY, area.minY), area.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }
}

public enum DisplayDirection: Sendable {
    case left, right, up, down
}

public enum DisplayMap {
    public static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    public static func index(containing frame: CGRect, in displays: [WndDisplay]) -> Int? {
        guard !displays.isEmpty else { return nil }
        var best: (Int, CGFloat)?
        for (i, d) in displays.enumerated() {
            let a = overlapArea(frame, d.frame)
            if a > 0, a > (best?.1 ?? 0) { best = (i, a) }
        }
        if let best { return best.0 }
        return nearestIndex(to: CGPoint(x: frame.midX, y: frame.midY), in: displays)
    }

    public static func index(containing point: CGPoint, in displays: [WndDisplay]) -> Int? {
        if let i = displays.firstIndex(where: { $0.frame.contains(point) }) { return i }
        return nearestIndex(to: point, in: displays)
    }

    static func nearestIndex(to p: CGPoint, in displays: [WndDisplay]) -> Int? {
        displays.indices.min { distanceSquared(p, displays[$0].frame) < distanceSquared(p, displays[$1].frame) }
    }

    static func distanceSquared(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    public static func order(_ displays: [WndDisplay]) -> [Int] {
        displays.indices.sorted {
            let a = displays[$0].frame
            let b = displays[$1].frame
            if a.minX != b.minX { return a.minX < b.minX }
            if a.minY != b.minY { return a.minY < b.minY }
            return $0 < $1
        }
    }

    public static func step(from index: Int, by delta: Int, in displays: [WndDisplay]) -> Int? {
        guard displays.count > 1, displays.indices.contains(index) else { return nil }
        let o = order(displays)
        guard let pos = o.firstIndex(of: index) else { return nil }
        return o[((pos + delta) % o.count + o.count) % o.count]
    }

    public static func neighbour(of index: Int, direction: DisplayDirection, in displays: [WndDisplay]) -> Int? {
        guard displays.indices.contains(index) else { return nil }
        let cur = displays[index].frame
        let tol: CGFloat = 1
        let candidates = displays.indices.filter { j in
            guard j != index else { return false }
            let f = displays[j].frame
            switch direction {
            case .left: return f.maxX <= cur.minX + tol
            case .right: return f.minX >= cur.maxX - tol
            case .up: return f.maxY <= cur.minY + tol
            case .down: return f.minY >= cur.maxY - tol
            }
        }
        func gap(_ j: Int) -> CGFloat {
            let f = displays[j].frame
            switch direction {
            case .left: return cur.minX - f.maxX
            case .right: return f.minX - cur.maxX
            case .up: return cur.minY - f.maxY
            case .down: return f.minY - cur.maxY
            }
        }
        func offset(_ j: Int) -> CGFloat {
            let f = displays[j].frame
            switch direction {
            case .left, .right: return abs(f.midY - cur.midY)
            case .up, .down: return abs(f.midX - cur.midX)
            }
        }
        return candidates.min { a, b in
            let ga = gap(a), gb = gap(b)
            if abs(ga - gb) > tol { return ga < gb }
            if offset(a) != offset(b) { return offset(a) < offset(b) }
            return a < b
        }
    }

    public static func fillsArea(_ frame: CGRect, area: CGRect, tolerance: CGFloat = WindowGeometry.frameTolerance) -> Bool {
        WindowGeometry.approxEqual(frame, area, tolerance: tolerance)
    }

    public static func transfer(_ frame: CGRect, from source: WndDisplay, to target: WndDisplay, gaps: WindowGaps = .none) -> CGRect {
        let sArea = source.visible
        let tArea = WindowGeometry.usableArea(target.visible, gaps: gaps)
        if fillsArea(frame, area: sArea) || fillsArea(frame, area: WindowGeometry.usableArea(sArea, gaps: gaps)) {
            return WindowGeometry.snapped(minX: tArea.minX, minY: tArea.minY, maxX: tArea.maxX, maxY: tArea.maxY)
        }
        guard sArea.width > 0, sArea.height > 0 else { return WindowGeometry.clamp(frame, into: tArea) }
        let rx = (frame.minX - sArea.minX) / sArea.width
        let ry = (frame.minY - sArea.minY) / sArea.height
        let rw = frame.width / sArea.width
        let rh = frame.height / sArea.height
        let w = min(max(rw * tArea.width, 1), tArea.width)
        let h = min(max(rh * tArea.height, 1), tArea.height)
        let r = CGRect(x: tArea.minX + rx * tArea.width, y: tArea.minY + ry * tArea.height, width: w, height: h)
        return WindowGeometry.clamp(r, into: tArea)
    }

    public static func cursorDestination(from pointer: CGPoint, displays: [WndDisplay]) -> CGPoint? {
        guard let cur = index(containing: pointer, in: displays), let next = step(from: cur, by: 1, in: displays) else { return nil }
        let src = displays[cur].frame
        let dst = displays[next].frame
        guard src.width > 0, src.height > 0 else { return CGPoint(x: dst.midX, y: dst.midY) }
        let rx = min(max((pointer.x - src.minX) / src.width, 0), 1)
        let ry = min(max((pointer.y - src.minY) / src.height, 0), 1)
        return CGPoint(x: (dst.minX + rx * (dst.width - 1)).rounded(), y: (dst.minY + ry * (dst.height - 1)).rounded())
    }

    public static func reposition(_ frame: CGRect, displays: [WndDisplay], minVisibleFraction: CGFloat = 0.2) -> CGRect {
        guard let idx = index(containing: frame, in: displays) else { return frame }
        let area = displays[idx].visible
        let visibleArea = overlapArea(frame, area)
        if frame.width * frame.height > 0, visibleArea / (frame.width * frame.height) >= minVisibleFraction, frame.width <= area.width + 1, frame.height <= area.height + 1 {
            return frame
        }
        let w = min(frame.width, area.width)
        let h = min(frame.height, area.height)
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }
}
