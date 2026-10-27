import Foundation

public enum CPUMath {
    public static func load(prev: CPUTicks, cur: CPUTicks) -> CPULoad {
        let u = Double(cur.user &- prev.user)
        let n = Double(cur.nice &- prev.nice)
        let s = Double(cur.system &- prev.system)
        let i = Double(cur.idle &- prev.idle)
        let total = u + n + s + i
        guard total > 0 else { return .zero }
        return CPULoad(total: (u + n + s) / total, user: (u + n) / total, system: s / total)
    }

    public static func loads(prev: [CPUTicks], cur: [CPUTicks]) -> [CPULoad] {
        guard prev.count == cur.count else { return [] }
        return zip(prev, cur).map { load(prev: $0, cur: $1) }
    }

    public static func average(_ loads: [CPULoad]) -> CPULoad {
        guard !loads.isEmpty else { return .zero }
        let n = Double(loads.count)
        return CPULoad(total: loads.map(\.total).reduce(0, +) / n,
                       user: loads.map(\.user).reduce(0, +) / n,
                       system: loads.map(\.system).reduce(0, +) / n)
    }
}

public enum RateMath {
    public static func rate(prev: UInt64, cur: UInt64, dt: Double) -> Double {
        guard dt > 0, cur >= prev else { return 0 }
        return Double(cur - prev) / dt
    }

    public static func delta32(prev: UInt32, cur: UInt32) -> UInt64 {
        UInt64(cur &- prev)
    }
}

public struct CounterRate {
    private var prev: [String: UInt64] = [:]
    private var prevAt: TimeInterval?

    public init() {}

    public mutating func update(_ counters: [String: UInt64], at now: TimeInterval) -> [String: Double] {
        defer { prev = counters; prevAt = now }
        guard let at = prevAt, now > at else { return [:] }
        let dt = now - at
        var out: [String: Double] = [:]
        for (k, v) in counters {
            guard let p = prev[k] else { out[k] = 0; continue }
            out[k] = RateMath.rate(prev: p, cur: v, dt: dt)
        }
        return out
    }
}

public enum MemoryMath {
    public static func compose(_ p: VMPages, totalBytes: UInt64) -> MemoryComposition {
        let ps = p.pageSize
        let app = p.anonymous >= p.purgeable ? p.anonymous - p.purgeable : 0
        let cached = p.fileBacked + p.purgeable
        return MemoryComposition(totalBytes: totalBytes, appBytes: app * ps, wiredBytes: p.wired * ps,
                                 compressedBytes: p.compressor * ps, cachedBytes: cached * ps, freeBytes: p.free * ps)
    }
}

public enum Downsample {
    public static func bucketRanges(count: Int, maxPoints: Int) -> [Range<Int>] {
        guard count > 0, maxPoints > 0 else { return [] }
        guard count > maxPoints else { return (0..<count).map { $0..<($0 + 1) } }
        return (0..<maxPoints).map { i in (i * count / maxPoints)..<((i + 1) * count / maxPoints) }
    }

    public static func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

    public static func drainRate(_ pts: [(ts: Int64, pct: Int, onAC: Bool)], minSpanSec: Int64 = 600) -> Double? {
        var seg: [(ts: Int64, pct: Int, onAC: Bool)] = []
        for p in pts.reversed() {
            if p.onAC { break }
            seg.append(p)
        }
        seg.reverse()
        guard let first = seg.first, let last = seg.last, last.ts - first.ts >= minSpanSec else { return nil }
        let rate = Double(first.pct - last.pct) / Double(last.ts - first.ts) * 3600
        return rate >= 0 ? (rate * 10).rounded() / 10 : nil
    }
}

public struct MetricHistory: Equatable, Sendable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 120) { self.capacity = max(2, capacity) }

    public mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var last: Double? { values.last }
    public var maxValue: Double { values.max() ?? 0 }
}

public struct NamedHistory: Sendable {
    public private(set) var byMetric: [String: MetricHistory] = [:]
    public let capacity: Int
    public init(capacity: Int = 120) { self.capacity = capacity }

    public mutating func append(_ key: String, _ v: Double) {
        byMetric[key, default: MetricHistory(capacity: capacity)].append(v)
    }

    public func values(_ key: String) -> [Double] { byMetric[key]?.values ?? [] }
}

public enum SysFormat {
    private static func scaled(_ v: Double, base: Double, units: [String]) -> String {
        var x = max(v, 0)
        var i = 0
        while x >= base && i < units.count - 1 { x /= base; i += 1 }
        let s = x >= 100 || i == 0 ? String(format: "%.0f", x) : (x >= 10 ? String(format: "%.1f", x) : String(format: "%.2f", x))
        return s.replacingOccurrences(of: ".", with: ",") + " " + units[i]
    }

    public static func bytes(_ v: Double) -> String { scaled(v, base: 1024, units: ["Б", "КБ", "МБ", "ГБ", "ТБ"]) }
    public static func diskBytes(_ v: Double) -> String { scaled(v, base: 1000, units: ["Б", "КБ", "МБ", "ГБ", "ТБ"]) }
    public static func rate(_ bps: Double) -> String { scaled(bps, base: 1024, units: ["Б/с", "КБ/с", "МБ/с", "ГБ/с"]) }

    public static func rateShort(_ bps: Double) -> String {
        var x = max(bps, 0)
        let units = ["Б", "К", "М", "Г"]
        var i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        let s = x >= 10 || i == 0 ? String(format: "%.0f", x) : String(format: "%.1f", x)
        return s.replacingOccurrences(of: ".", with: ",") + units[i]
    }

    public static func percent(_ fraction: Double) -> String { String(format: "%.0f", min(max(fraction, 0), 1) * 100) }

    public static func temperature(_ c: Double) -> String { String(format: "%.0f°", c) }

    public static func duration(_ s: TimeInterval) -> String {
        let t = Int(max(s, 0))
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(t) с"
    }

    public static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
    }
}
