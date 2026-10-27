import Foundation

public struct IslEqSettings: Equatable, Sendable {
    public static let barsRange = 3...16
    public static let sensitivityRange: ClosedRange<Double> = 0.5...3

    public var compactBars = 4
    public var expandedBars = 12
    public var sensitivity = 1.0
    public var showInMusic = true

    public init() {}

    public var sanitized: IslEqSettings {
        var s = self
        s.compactBars = ToolsClamp.int(compactBars, Self.barsRange)
        s.expandedBars = ToolsClamp.int(expandedBars, Self.barsRange)
        s.sensitivity = IslSettings.clamp(sensitivity, Self.sensitivityRange)
        return s
    }
}

public final class IslEqSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.liveEq."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslEqSettings {
        var s = IslEqSettings()
        let p = Self.prefix
        s.compactBars = a.int(p + "compactBars", s.compactBars)
        s.expandedBars = a.int(p + "expandedBars", s.expandedBars)
        s.sensitivity = a.double(p + "sensitivity", s.sensitivity)
        s.showInMusic = a.bool(p + "showInMusic", s.showInMusic)
        return s.sanitized
    }

    public func save(_ settings: IslEqSettings) {
        let s = settings.sanitized
        let b = IslEqSettings()
        let p = Self.prefix
        a.put(p + "compactBars", s.compactBars, b.compactBars)
        a.put(p + "expandedBars", s.expandedBars, b.expandedBars)
        a.put(p + "sensitivity", s.sensitivity, b.sensitivity)
        a.put(p + "showInMusic", s.showInMusic, b.showInMusic)
    }
}

public enum IslEqMapper {
    // Log-spaced analyser bands in, `count` bars out; shrinking keeps peaks visible, growing interpolates.
    public static func resample(_ bands: [Float], to count: Int) -> [Float] {
        let n = bands.count
        guard count > 0 else { return [] }
        guard n > 0 else { return Array(repeating: 0, count: count) }
        if n == count { return bands.map(clean) }
        if n > count {
            return (0..<count).map { i in
                let lo = i * n / count
                let hi = max((i + 1) * n / count, lo + 1)
                let slice = bands[lo..<min(hi, n)].map(clean)
                let mx = slice.max() ?? 0
                let mean = slice.reduce(0, +) / Float(slice.count)
                return 0.6 * mx + 0.4 * mean
            }
        }
        return (0..<count).map { i in
            let pos = count == 1 ? 0 : Float(i) * Float(n - 1) / Float(count - 1)
            let lo = Int(pos.rounded(.down))
            let hi = min(lo + 1, n - 1)
            let f = pos - Float(lo)
            return clean(bands[lo]) * (1 - f) + clean(bands[hi]) * f
        }
    }

    static func clean(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

    public static func shaped(_ v: Float, gain: Float, floor: Float = 0.04) -> Float {
        let c = clean(v)
        guard c > floor else { return 0 }
        return min(max((c - floor) / (1 - floor) * gain, 0), 1)
    }
}

public struct IslEqSmoother: Equatable, Sendable {
    public private(set) var values: [Float]
    public var attack: Double = 0.04
    public var release: Double = 0.22

    public init(count: Int = 0) { values = Array(repeating: 0, count: max(count, 0)) }

    public var peak: Float { values.max() ?? 0 }

    public mutating func resize(_ count: Int) {
        let n = max(count, 0)
        if values.count == n { return }
        values = (0..<n).map { $0 < values.count ? values[$0] : 0 }
    }

    // Exponential approach; an empty input decays the bars to zero.
    @discardableResult
    public mutating func step(_ input: [Float], dt: Double) -> [Float] {
        let d = min(max(dt, 0), 0.5)
        for i in values.indices {
            let target: Float = i < input.count ? IslEqMapper.clean(input[i]) : 0
            let tau = target > values[i] ? attack : release
            let k = Float(1 - exp(-d / max(tau, 0.001)))
            values[i] += (target - values[i]) * k
            if values[i] < 0.002 { values[i] = 0 }
        }
        return values
    }

    public mutating func reset() { values = values.map { _ in 0 } }
}

public enum IslEqSource {
    // The mixer keys apps by bundle id; helper processes collapse into the parent, so fall back to a prefix match.
    public static func key(forBundle bundle: String?, available: Set<String>) -> String? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if available.contains(b) { return b }
        return available.sorted().first { $0.hasPrefix(b + ".") || b.hasPrefix($0 + ".") }
    }
}

public struct IslEqFeed: Equatable, Sendable {
    public static let liveTimeout: TimeInterval = 1.5
    public private(set) var lastData: Date?
    public private(set) var smoother = IslEqSmoother()
    public var gain: Float = 1

    public init() {}

    public var values: [Float] { smoother.values }

    public mutating func update(bands: [Float]?, bars: Int, now: Date, dt: Double) {
        smoother.resize(bars)
        if let bands, !bands.isEmpty {
            lastData = now
            smoother.step(IslEqMapper.resample(bands, to: bars).map { IslEqMapper.shaped($0, gain: gain) }, dt: dt)
        } else {
            smoother.step([], dt: dt)
        }
    }

    public func isLive(at now: Date) -> Bool {
        guard let l = lastData else { return false }
        return now.timeIntervalSince(l) <= Self.liveTimeout
    }
}
