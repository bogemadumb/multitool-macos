import Foundation
import CoreGraphics

public struct ResizeEdges: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = ResizeEdges(rawValue: 1)
    public static let right = ResizeEdges(rawValue: 2)
    public static let top = ResizeEdges(rawValue: 4)
    public static let bottom = ResizeEdges(rawValue: 8)
}

public enum GestureMath {
    public static let minimumSide: CGFloat = 120

    public static func moved(_ original: CGRect, from start: CGPoint, to now: CGPoint) -> CGRect {
        CGRect(x: original.minX + now.x - start.x, y: original.minY + now.y - start.y, width: original.width, height: original.height)
    }

    public static func edges(at p: CGPoint, in frame: CGRect) -> ResizeEdges {
        guard frame.width > 0, frame.height > 0 else { return [.right, .bottom] }
        var e: ResizeEdges = []
        let fx = (p.x - frame.minX) / frame.width
        let fy = (p.y - frame.minY) / frame.height
        if fx < 1.0 / 3 { e.insert(.left) } else if fx > 2.0 / 3 { e.insert(.right) }
        if fy < 1.0 / 3 { e.insert(.top) } else if fy > 2.0 / 3 { e.insert(.bottom) }
        if e.isEmpty {
            e.insert(fx < 0.5 ? .left : .right)
            e.insert(fy < 0.5 ? .top : .bottom)
        }
        return e
    }

    public static func resized(_ original: CGRect, edges: ResizeEdges, from start: CGPoint, to now: CGPoint, minSize: CGSize = CGSize(width: minimumSide, height: minimumSide)) -> CGRect {
        let dx = now.x - start.x
        let dy = now.y - start.y
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
        if edges.contains(.left) { minX = min(minX + dx, maxX - minSize.width) }
        if edges.contains(.right) { maxX = max(maxX + dx, minX + minSize.width) }
        if edges.contains(.top) { minY = min(minY + dy, maxY - minSize.height) }
        if edges.contains(.bottom) { maxY = max(maxY + dy, minY + minSize.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func modifiersMatch(_ flags: CGEventFlags, required: GestureModifiers) -> Bool {
        !required.isEmpty && GestureModifiers(flags: flags) == required
    }
}

public final class ModifierDragSession {
    public enum Kind: Equatable { case move, resize(ResizeEdges) }

    public let window: WndWindow
    public let kind: Kind
    private let original: CGRect
    private let start: CGPoint
    private let driver: WindowDriving
    private(set) public var lastFrame: CGRect

    public init?(driver: WindowDriving, at p: CGPoint, flags: CGEventFlags, settings: GestureSettings, raise: Bool) {
        guard settings.enabled, settings.isValid else { return nil }
        let isResize = GestureMath.modifiersMatch(flags, required: settings.resize)
        guard isResize || GestureMath.modifiersMatch(flags, required: settings.move) else { return nil }
        guard let w = driver.window(at: p), driver.isManageable(w), let f = driver.frame(of: w) else { return nil }
        self.driver = driver
        window = w
        original = f
        start = p
        lastFrame = f
        kind = isResize ? .resize(GestureMath.edges(at: p, in: f)) : .move
        if raise { driver.raise(w) }
    }

    @discardableResult
    public func update(to p: CGPoint) -> CGRect {
        let next: CGRect
        switch kind {
        case .move: next = GestureMath.moved(original, from: start, to: p)
        case .resize(let e): next = GestureMath.resized(original, edges: e, from: start, to: p)
        }
        guard next != lastFrame else { return next }
        if driver.setFrame(next, of: window) { lastFrame = next }
        return next
    }
}

public enum RingGesture {
    public static let activationDistance: CGFloat = 28

    public static func action(from origin: CGPoint, to p: CGPoint, activation: CGFloat = activationDistance) -> WindowLayoutAction? {
        let dx = p.x - origin.x
        let dy = origin.y - p.y
        guard hypot(dx, dy) >= activation else { return nil }
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        switch deg {
        case 337.5..., ..<22.5: return .rightHalf
        case 22.5..<67.5: return .topRight
        case 67.5..<112.5: return .topHalf
        case 112.5..<157.5: return .topLeft
        case 157.5..<202.5: return .leftHalf
        case 202.5..<247.5: return .bottomLeft
        case 247.5..<292.5: return .bottomHalf
        default: return .bottomRight
        }
    }
}

public final class RingSession {
    public private(set) var origin: CGPoint
    public private(set) var action: WindowLayoutAction?
    public private(set) var cancelled = false
    public let window: WndWindow?

    public init(origin: CGPoint, window: WndWindow?) {
        self.origin = origin
        self.window = window
    }

    @discardableResult
    public func update(to p: CGPoint) -> WindowLayoutAction? {
        guard !cancelled else { return nil }
        action = RingGesture.action(from: origin, to: p)
        return action
    }

    public func forceMaximize() {
        guard !cancelled else { return }
        action = .maximize
    }

    public func cancel() {
        cancelled = true
        action = nil
    }

    public func finish() -> WindowLayoutAction? { cancelled ? nil : action }
}
