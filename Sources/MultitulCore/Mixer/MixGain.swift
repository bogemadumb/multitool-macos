import Foundation

public enum MixGain {
    public static let floorDb: Double = -120
    public static let defaultMaxBoost: Double = 4
    public static let allowedMaxBoosts: [Double] = [1, 2, 3, 4]
    public static let coarseStep: Double = 0.05
    public static let fineStep: Double = 0.01
    public static let magnet: Double = 0.025

    public static func dbToLinear(_ db: Double) -> Double {
        guard db.isFinite else { return db > 0 ? .infinity : 0 }
        return db <= floorDb ? 0 : pow(10, db / 20)
    }

    public static func linearToDb(_ gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return floorDb }
        return max(floorDb, 20 * log10(gain))
    }

    public static func clampVolume(_ v: Double, maxBoost: Double = defaultMaxBoost) -> Double {
        guard v.isFinite else { return 1 }
        return min(max(v, 0), clampBoost(maxBoost))
    }

    public static func clampBoost(_ b: Double) -> Double {
        guard b.isFinite else { return defaultMaxBoost }
        return min(max(b, 1), defaultMaxBoost)
    }

    public static func percent(_ volume: Double) -> Int { Int((volume * 100).rounded()) }

    public static func volume(percent: Int, maxBoost: Double = defaultMaxBoost) -> Double {
        clampVolume(Double(percent) / 100, maxBoost: maxBoost)
    }

    public static func step(_ volume: Double, up: Bool, fine: Bool, maxBoost: Double = defaultMaxBoost) -> Double {
        let size = fine ? fineStep : coarseStep
        let q = volume / size
        let onGrid = abs(q - q.rounded()) < 1e-6
        let n = up ? (onGrid ? q.rounded() + 1 : q.rounded(.up)) : (onGrid ? q.rounded() - 1 : q.rounded(.down))
        return clampVolume((n * size * 1000).rounded() / 1000, maxBoost: maxBoost)
    }

    // Slider values near 100% stick to it, so unity is easy to hit.
    public static func snapped(_ v: Double, maxBoost: Double = defaultMaxBoost) -> Double {
        let c = clampVolume(v, maxBoost: maxBoost)
        return abs(c - 1) <= magnet ? 1 : c
    }

    public static func label(_ volume: Double) -> String { "\(percent(volume))%" }

    public static func dbLabel(_ volume: Double) -> String {
        guard volume > 0 else { return "−∞ дБ" }
        let db = linearToDb(volume)
        if abs(db) < 0.05 { return "0 дБ" }
        let text = String(format: "%.1f", abs(db))
        return (db < 0 ? "−" : "+") + text + " дБ"
    }
}

public enum MixDenormal {
    public static let threshold: Float = 1e-30
    public static let thresholdDouble: Double = 1e-280

    @inline(__always) public static func flush(_ x: Float) -> Float { abs(x) < threshold ? 0 : x }
    @inline(__always) public static func flush(_ x: Double) -> Double { abs(x) < thresholdDouble ? 0 : x }
}

// Linear ramp to a new target: no steps in the gain, so no zipper noise.
public struct MixSmoother: Equatable, Sendable {
    public private(set) var target: Float
    public private(set) var rampSamples: Int
    private var current: Double
    private var step: Double = 0
    private var remaining = 0

    public init(value: Float = 1, sampleRate: Double = 48_000, rampSeconds: Double = 0.02) {
        current = Double(value)
        target = value
        rampSamples = Self.samples(sampleRate: sampleRate, seconds: rampSeconds)
    }

    public var value: Float { Float(current) }

    public static func samples(sampleRate: Double, seconds: Double) -> Int {
        guard sampleRate.isFinite, seconds.isFinite, sampleRate > 0, seconds > 0 else { return 1 }
        return max(1, Int((sampleRate * seconds).rounded()))
    }

    public mutating func configure(sampleRate: Double, rampSeconds: Double) {
        rampSamples = Self.samples(sampleRate: sampleRate, seconds: rampSeconds)
        if remaining > 0 { setTarget(target) }
    }

    public var isRamping: Bool { remaining > 0 }

    public mutating func jump(to v: Float) {
        current = Double(v)
        target = v
        remaining = 0
        step = 0
    }

    public mutating func setTarget(_ t: Float) {
        guard t.isFinite else { return }
        target = t
        if Double(t) == current { remaining = 0; step = 0; return }
        remaining = rampSamples
        step = (Double(t) - current) / Double(rampSamples)
    }

    @inline(__always) public mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            current = remaining == 0 ? Double(target) : current + step
        }
        return Float(current)
    }
}
