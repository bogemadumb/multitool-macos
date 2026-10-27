import Foundation
import CoreGraphics

public enum RecInputKind: String, Codable, Sendable {
    case move = "m"
    case down = "d"
    case up = "u"
    case scroll = "s"
}

public enum RecButton: Int, Codable, Sendable {
    case left = 0, right = 1, other = 2
}

public struct RecInputEvent: Equatable, Codable, Sendable {
    public var t: Double
    public var kind: RecInputKind
    public var x: Double
    public var y: Double
    public var button: RecButton
    public var inside: Bool

    public init(t: Double, kind: RecInputKind, x: Double, y: Double, button: RecButton = .left, inside: Bool = true) {
        self.t = t
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.inside = inside
    }

    enum CodingKeys: String, CodingKey { case t, k, x, y, b, i }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        kind = try c.decode(RecInputKind.self, forKey: .k)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        button = (try c.decodeIfPresent(Int.self, forKey: .b)).flatMap(RecButton.init(rawValue:)) ?? .left
        inside = try c.decodeIfPresent(Bool.self, forKey: .i) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode((t * 1000).rounded() / 1000, forKey: .t)
        try c.encode(kind, forKey: .k)
        try c.encode((x * 10000).rounded() / 10000, forKey: .x)
        try c.encode((y * 10000).rounded() / 10000, forKey: .y)
        if button != .left { try c.encode(button.rawValue, forKey: .b) }
        if !inside { try c.encode(false, forKey: .i) }
    }
}

public struct RecInputMapper: Equatable, Sendable {
    public var captureRect: CGRect

    public init(captureRect: CGRect) { self.captureRect = captureRect.standardized }

    public func normalize(_ p: CGPoint) -> (x: Double, y: Double, inside: Bool)? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        let nx = Double((p.x - captureRect.minX) / captureRect.width)
        let ny = Double((p.y - captureRect.minY) / captureRect.height)
        let inside = nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1
        return (min(max(nx, 0), 1), min(max(ny, 0), 1), inside)
    }
}

public struct RecRipple: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var progress: Double
    public var button: RecButton
}

public struct RecInputLog: Equatable, Codable, Sendable {
    public static let version = 1
    public static let maxEvents = 400_000
    public static let moveInterval = 1.0 / 30
    public static let moveDistance = 0.0012

    public private(set) var events: [RecInputEvent] = []
    public var duration: Double = 0

    public init() {}

    public init(events: [RecInputEvent], duration: Double = 0) {
        self.events = events.sorted { $0.t < $1.t }
        self.duration = duration > 0 ? duration : (self.events.last?.t ?? 0)
    }

    public var isEmpty: Bool { events.isEmpty }
    public var clicks: [RecInputEvent] { events.filter { $0.kind == .down && $0.inside } }
    public var moves: [RecInputEvent] { events.filter { $0.kind == .move || $0.kind == .down || $0.kind == .up } }

    @discardableResult
    public mutating func append(_ e: RecInputEvent) -> Bool {
        guard events.count < Self.maxEvents, e.t.isFinite, e.t >= 0 else { return false }
        if let last = events.last {
            if e.t < last.t - 0.0005 { return false }
            if e.kind == .move {
                let dt = e.t - last.t
                let d = hypot(e.x - last.x, e.y - last.y)
                if dt < Self.moveInterval || d < Self.moveDistance { return false }
            }
        }
        events.append(e)
        duration = max(duration, e.t)
        return true
    }

    public func cursor(at t: Double) -> (x: Double, y: Double)? {
        let pts = events.filter { $0.kind != .scroll }
        guard !pts.isEmpty else { return nil }
        var lo = 0, hi = pts.count - 1
        if t <= pts[0].t { return (pts[0].x, pts[0].y) }
        if t >= pts[hi].t { return (pts[hi].x, pts[hi].y) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if pts[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = pts[lo], b = pts[hi]
        let span = b.t - a.t
        let k = span > 0 ? (t - a.t) / span : 0
        return (a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
    }

    public func ripples(at t: Double, lifetime: Double = 0.6) -> [RecRipple] {
        guard lifetime > 0, !events.isEmpty else { return [] }
        let from = t - lifetime
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].t <= from { lo = mid + 1 } else { hi = mid }
        }
        var out: [RecRipple] = []
        var i = lo
        while i < events.count, events[i].t <= t {
            let e = events[i]
            if e.kind == .down, e.inside { out.append(RecRipple(x: e.x, y: e.y, progress: (t - e.t) / lifetime, button: e.button)) }
            i += 1
        }
        return out
    }

    public func trimmed(to range: ClosedRange<Double>) -> RecInputLog {
        RecInputLog(events: events.filter { range.contains($0.t) }.map { var e = $0; e.t -= range.lowerBound; return e }, duration: range.upperBound - range.lowerBound)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(Envelope(v: Self.version, d: duration, e: events))
    }

    public static func decode(_ data: Data) throws -> RecInputLog {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return RecInputLog(events: env.e, duration: env.d)
    }

    private struct Envelope: Codable {
        var v: Int
        var d: Double
        var e: [RecInputEvent]
    }
}
