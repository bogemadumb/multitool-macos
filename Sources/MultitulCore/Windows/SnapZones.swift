import Foundation
import CoreGraphics

public enum SnapZone: String, CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Левый верхний угол"
        case .top: "Верхний край"
        case .topRight: "Правый верхний угол"
        case .left: "Левый край"
        case .right: "Правый край"
        case .bottomLeft: "Левый нижний угол"
        case .bottom: "Нижний край"
        case .bottomRight: "Правый нижний угол"
        }
    }

    public var defaultAction: WindowLayoutAction {
        switch self {
        case .topLeft: .topLeft
        case .top: .maximize
        case .topRight: .topRight
        case .left: .leftHalf
        case .right: .rightHalf
        case .bottomLeft: .bottomLeft
        case .bottom: .bottomHalf
        case .bottomRight: .bottomRight
        }
    }

    public var isHorizontalEdge: Bool { self == .top || self == .bottom }
    public var isVerticalEdge: Bool { self == .left || self == .right }
    public var maximumParts: Int { isHorizontalEdge || isVerticalEdge ? SnapZoneLayout.maximumParts : 1 }
}

public struct SnapZoneLayout: Equatable, Sendable {
    public static let maximumParts = 4
    private var changed: [SnapZone: [WindowLayoutAction]] = [:]

    public init() {}

    public init(storageValue: String?) {
        for entry in (storageValue ?? "").split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let zone = SnapZone(rawValue: pair[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let names = pair[1].split(separator: "+", omittingEmptySubsequences: false)
            let actions = names.compactMap { WindowLayoutAction(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            guard actions.count == names.count, Self.accepts(actions, for: zone) else { continue }
            set(actions, for: zone)
        }
    }

    public var storageValue: String {
        SnapZone.allCases.compactMap { z in changed[z].map { z.rawValue + "=" + $0.map(\.rawValue).joined(separator: "+") } }.joined(separator: ",")
    }

    public var isDefault: Bool { changed.isEmpty }

    public func actions(for zone: SnapZone) -> [WindowLayoutAction] { changed[zone] ?? [zone.defaultAction] }

    public func action(for zone: SnapZone, along fraction: CGFloat) -> WindowLayoutAction {
        let list = actions(for: zone)
        let p = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return list[min(Int(p * CGFloat(list.count)), list.count - 1)]
    }

    public mutating func setAction(_ action: WindowLayoutAction, for zone: SnapZone, part: Int) {
        var list = actions(for: zone)
        guard list.indices.contains(part) else { return }
        list[part] = action
        guard Self.accepts(list, for: zone) else { return }
        set(list, for: zone)
    }

    public mutating func setPartCount(_ count: Int, for zone: SnapZone) {
        guard count != actions(for: zone).count, count >= 1, count <= zone.maximumParts else { return }
        let rowsAcross: [[WindowLayoutAction]] = [
            [.leftHalf, .rightHalf],
            [.leftThird, .centerThird, .rightThird],
            [.leftQuarter, .leftMiddleQuarter, .rightMiddleQuarter, .rightQuarter]
        ]
        let rowsDown: [[WindowLayoutAction]] = [
            [.topHalf, .bottomHalf],
            [.topThird, .middleThird, .bottomThird],
            [.topQuarter, .upperMiddleQuarter, .lowerMiddleQuarter, .bottomQuarter]
        ]
        let table = zone.isHorizontalEdge ? rowsAcross : rowsDown
        let parts = count == 1 ? [zone.defaultAction] : table[count - 2]
        set(parts, for: zone)
    }

    public mutating func reset() { changed.removeAll() }

    private mutating func set(_ actions: [WindowLayoutAction], for zone: SnapZone) {
        changed[zone] = actions == [zone.defaultAction] ? nil : actions
    }

    private static func accepts(_ actions: [WindowLayoutAction], for zone: SnapZone) -> Bool {
        !actions.isEmpty && actions.count <= zone.maximumParts && actions.allSatisfy { WindowLayoutAction.snapTargets.contains($0) }
    }
}

public struct SnapTarget: Equatable, Sendable {
    public var zone: SnapZone
    public var action: WindowLayoutAction
    public var displayIndex: Int
    public var frame: CGRect
}

public struct PointerTrail: Sendable {
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    public static let window: TimeInterval = 0.12

    public init() {}

    public mutating func add(_ p: CGPoint, at t: TimeInterval) {
        samples.append((p, t))
        samples.removeAll { t - $0.time > Self.window * 3 }
    }

    public mutating func reset() { samples.removeAll() }

    public func velocity(at now: TimeInterval) -> CGVector {
        let recent = samples.filter { now - $0.time <= Self.window }
        guard let first = recent.first, let last = recent.last, last.time - first.time > 0.004 else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }
}

public enum DragClassification: Equatable, Sendable {
    case waiting, moving, resizing, unrelated
}

public enum SnapZoneResolver {
    public static let crossingSpeed: CGFloat = 400
    public static let movementThreshold: CGFloat = 2
    public static let sizeTolerance: CGFloat = 2

    public static func horizontalCorner(for frame: CGRect) -> CGFloat { min(max(frame.width * 0.18, 96), 180) }
    public static func verticalCorner(for frame: CGRect) -> CGFloat { min(max(frame.height * 0.18, 80), 160) }

    public static func classify(initial: CGRect, current: CGRect, pointerStart: CGPoint, pointerNow: CGPoint) -> DragClassification {
        let sizeChanged = abs(current.width - initial.width) > sizeTolerance || abs(current.height - initial.height) > sizeTolerance
        if sizeChanged {
            let sharesX = abs(initial.minX - current.minX) <= sizeTolerance || abs(initial.maxX - current.maxX) <= sizeTolerance
            let sharesY = abs(initial.minY - current.minY) <= sizeTolerance || abs(initial.maxY - current.maxY) <= sizeTolerance
            if sharesX && sharesY { return .resizing }
        }
        let wd = CGPoint(x: current.minX - initial.minX, y: current.minY - initial.minY)
        let pd = CGPoint(x: pointerNow.x - pointerStart.x, y: pointerNow.y - pointerStart.y)
        let wDist = hypot(wd.x, wd.y)
        guard wDist > movementThreshold else { return .waiting }
        let pDist = hypot(pd.x, pd.y)
        guard pDist > movementThreshold else { return .unrelated }
        let alignment = (wd.x * pd.x + wd.y * pd.y) / (wDist * pDist)
        let ratio = wDist / pDist
        return alignment >= 0.6 && ratio >= 0.2 && ratio <= 1.8 ? .moving : .unrelated
    }

    public static func startsOnResizeHandle(_ p: CGPoint, frame: CGRect) -> Bool {
        let corner: CGFloat = 12
        let edge: CGFloat = 5
        guard p.x >= frame.minX - corner, p.x <= frame.maxX + corner, p.y >= frame.minY - corner, p.y <= frame.maxY + corner else { return false }
        let nearX = abs(p.x - frame.minX) <= corner || abs(p.x - frame.maxX) <= corner
        let nearY = abs(p.y - frame.minY) <= corner || abs(p.y - frame.maxY) <= corner
        let onEdge = abs(p.x - frame.minX) <= edge || abs(p.x - frame.maxX) <= edge || abs(p.y - frame.minY) <= edge || abs(p.y - frame.maxY) <= edge
        return onEdge || (nearX && nearY)
    }

    public static func zone(at p: CGPoint, in display: WndDisplay, displays: [WndDisplay], velocity: CGVector, distance: CGFloat) -> SnapZone? {
        let f = display.frame
        guard f.width > 0, f.height > 0, p.x >= f.minX - distance, p.x <= f.maxX + distance, p.y >= f.minY - distance, p.y <= f.maxY + distance else { return nil }
        let slowX = abs(velocity.dx) <= crossingSpeed
        let slowY = abs(velocity.dy) <= crossingSpeed
        func seam(_ probe: CGPoint) -> Bool { displays.contains { $0 != display && $0.frame.contains(probe) } }
        let nearLeft = p.x <= f.minX + distance && (slowX || !seam(CGPoint(x: f.minX - 2, y: p.y)))
        let nearRight = p.x >= f.maxX - distance && (slowX || !seam(CGPoint(x: f.maxX + 2, y: p.y)))
        let nearTop = p.y <= f.minY + distance && (slowY || !seam(CGPoint(x: p.x, y: f.minY - 2)))
        let nearBottom = p.y >= f.maxY - distance && (slowY || !seam(CGPoint(x: p.x, y: f.maxY + 2)))
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }
        let hc = horizontalCorner(for: f)
        let vc = verticalCorner(for: f)
        if nearTop {
            if p.x <= f.minX + hc { return .topLeft }
            if p.x >= f.maxX - hc { return .topRight }
            return .top
        }
        if nearBottom {
            if p.x <= f.minX + hc { return .bottomLeft }
            if p.x >= f.maxX - hc { return .bottomRight }
            return .bottom
        }
        if nearLeft {
            if p.y <= f.minY + vc { return .topLeft }
            if p.y >= f.maxY - vc { return .bottomLeft }
            return .left
        }
        if p.y <= f.minY + vc { return .topRight }
        if p.y >= f.maxY - vc { return .bottomRight }
        return .right
    }

    public static func resolve(at p: CGPoint, displays: [WndDisplay], velocity: CGVector = .zero, settings: WindowLayoutSettings) -> SnapTarget? {
        guard !displays.isEmpty else { return nil }
        let distance = CGFloat(settings.edge.sanitized.distance)
        let order = displays.indices.sorted {
            let a = DisplayMap.distanceSquared(p, displays[$0].frame)
            let b = DisplayMap.distanceSquared(p, displays[$1].frame)
            return a != b ? a < b : $0 < $1
        }
        for i in order {
            let d = displays[i]
            guard let z = zone(at: p, in: d, displays: displays, velocity: velocity, distance: distance) else { continue }
            guard settings.edge.enabledZones.contains(z) else { return nil }
            let f = d.frame
            var along: CGFloat = 0
            if z.isHorizontalEdge {
                let hc = horizontalCorner(for: f)
                along = (p.x - f.minX - hc) / max(f.width - 2 * hc, 1)
            } else if z.isVerticalEdge {
                let vc = verticalCorner(for: f)
                along = (p.y - f.minY - vc) / max(f.height - 2 * vc, 1)
            }
            let action = settings.edge.layout.action(for: z, along: along)
            guard let frame = WindowGeometry.rect(for: action, current: d.visible, visible: d.visible, gaps: settings.gaps, marginPercent: settings.marginPercent, custom: settings.customRect(for: action)) else { return nil }
            return SnapTarget(zone: z, action: action, displayIndex: i, frame: frame)
        }
        return nil
    }
}

public enum SystemTilingProbe {
    static let keys = ["EnableTilingByEdgeDrag", "EnableTilingOptionAccelerator", "EnableTopTilingByEdgeDrag"]

    public static func isEnabled(valueFor: (String) -> Bool?, displaysSpan: Bool = false) -> Bool {
        if displaysSpan { return false }
        return keys.contains { valueFor($0) ?? true }
    }
}
