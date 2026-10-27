import Foundation
import CoreGraphics

// Angles are degrees, 0 is straight up, growing clockwise; y grows downward (screen coordinates).
public struct RadialGeometry: Equatable, Sendable {
    public var innerRadius = 34.0
    public var outerRadius = 150.0
    public var cancelRadius: Double?
    public var hysteresisDegrees = 5.0

    public init() {}

    public func sectorWidth(count: Int) -> Double { count > 0 ? 360.0 / Double(count) : 360 }

    public func centerAngle(index: Int, count: Int) -> Double { Double(index) * sectorWidth(count: count) }

    public func span(index: Int, count: Int) -> (start: Double, end: Double) {
        let c = centerAngle(index: index, count: count), h = sectorWidth(count: count) / 2
        return (c - h, c + h)
    }

    public static func angle(dx: Double, dy: Double) -> Double {
        var a = atan2(dx, -dy) * 180 / .pi
        if a < 0 { a += 360 }
        return a >= 360 ? 0 : a
    }

    public func radius(dx: Double, dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }

    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    public func sector(dx: Double, dy: Double, count: Int) -> Int {
        let a = Self.angle(dx: dx, dy: dy)
        let w = sectorWidth(count: count)
        return Int(((a + w / 2) / w).rounded(.down)) % count
    }

    public func index(dx: Double, dy: Double, count: Int, current: Int? = nil) -> Int? {
        guard count > 0 else { return nil }
        let r = radius(dx: dx, dy: dy)
        if r < innerRadius { return nil }
        if let c = cancelRadius, r > c { return nil }
        let candidate = sector(dx: dx, dy: dy, count: count)
        guard let cur = current, cur != candidate, cur >= 0, cur < count else { return candidate }
        let a = Self.angle(dx: dx, dy: dy)
        let toCurrent = Self.angularDistance(a, centerAngle(index: cur, count: count))
        let limit = sectorWidth(count: count) / 2 + hysteresisDegrees
        return toCurrent <= limit && count > 2 ? cur : candidate
    }

    public func offset(index: Int, count: Int, radius: Double) -> (dx: Double, dy: Double) {
        let a = centerAngle(index: index, count: count) * .pi / 180
        return (sin(a) * radius, -cos(a) * radius)
    }

    public var labelRadius: Double { (innerRadius + outerRadius) / 2 }
}

public enum RadialPlacement {
    // Keeps the whole wheel on the screen; the pointer may end up off-centre when the wheel was pushed away from an edge.
    public static func center(pointer: CGPoint, radius: Double, in frame: CGRect) -> CGPoint {
        let r = CGFloat(radius)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ mid: CGFloat) -> CGFloat { lo > hi ? mid : min(max(v, lo), hi) }
        return CGPoint(x: clamp(pointer.x, frame.minX + r, frame.maxX - r, frame.midX), y: clamp(pointer.y, frame.minY + r, frame.maxY - r, frame.midY))
    }
}

public final class FourFingerTapDetector {
    public static let maxDuration: TimeInterval = 0.3
    public static let moveLimit: Float = 0.06
    public static let cooldown: TimeInterval = 0.4

    private struct Candidate {
        var start: TimeInterval
        var x: Float
        var y: Float
        var maxFingers: Int
        var moved: Float = 0
    }

    private var candidate: Candidate?
    private var lastTap: TimeInterval = -1000
    private let lock = NSLock()

    public init() {}

    public func reset() { lock.withLock { candidate = nil } }

    public func ingest(_ f: TouchFrame) -> Bool {
        lock.withLock {
            if var c = candidate {
                if f.fingers > 0 {
                    c.maxFingers = max(c.maxFingers, f.fingers)
                    c.moved = max(c.moved, abs(f.x - c.x), abs(f.y - c.y))
                    candidate = f.time - c.start > Self.maxDuration ? nil : c
                    return false
                }
                candidate = nil
                let fast = f.time - c.start <= Self.maxDuration
                let cooled = f.time - lastTap >= Self.cooldown || f.time < lastTap
                guard c.maxFingers == 4, c.moved <= Self.moveLimit, fast, cooled else { return false }
                lastTap = f.time
                return true
            }
            if f.fingers == 4 { candidate = Candidate(start: f.time, x: f.x, y: f.y, maxFingers: 4) }
            return false
        }
    }
}
