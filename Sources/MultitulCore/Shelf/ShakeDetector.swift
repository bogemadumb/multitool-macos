import Foundation

public struct ShakeConfig: Equatable, Sendable {
    public var reversals: Int
    public var minLeg: Double
    public var reverseSlack: Double
    public var window: TimeInterval
    public var cooldown: TimeInterval
    public var jitter: Double
    public var maxGap: TimeInterval

    public init(reversals: Int, minLeg: Double, reverseSlack: Double, window: TimeInterval, cooldown: TimeInterval = 1.5, jitter: Double = 3, maxGap: TimeInterval = 0.35) {
        self.reversals = reversals
        self.minLeg = minLeg
        self.reverseSlack = reverseSlack
        self.window = window
        self.cooldown = cooldown
        self.jitter = jitter
        self.maxGap = maxGap
    }

    public static func preset(_ s: ShakeSensitivity) -> ShakeConfig {
        switch s {
        case .low: ShakeConfig(reversals: 4, minLeg: 140, reverseSlack: 36, window: 1.1)
        case .medium: ShakeConfig(reversals: 3, minLeg: 100, reverseSlack: 28, window: 0.9)
        case .high: ShakeConfig(reversals: 2, minLeg: 70, reverseSlack: 20, window: 0.8)
        }
    }
}

struct ShakeAxis {
    private var direction = 0
    private var legStart = 0.0
    private var extreme = 0.0
    private var reversalTimes: [TimeInterval] = []
    private var anchor: Double?

    mutating func reset() {
        direction = 0
        reversalTimes = []
        anchor = nil
    }

    mutating func feed(_ v: Double, at t: TimeInterval, config c: ShakeConfig) -> Bool {
        reversalTimes.removeAll { t - $0 > c.window }
        guard let a = anchor else {
            anchor = v
            legStart = v
            extreme = v
            return false
        }
        if direction == 0 {
            if abs(v - a) >= c.jitter {
                direction = v > a ? 1 : -1
                legStart = a
                extreme = v
            }
            return false
        }
        let d = Double(direction)
        if (v - extreme) * d > 0 {
            extreme = v
            return false
        }
        guard (extreme - v) * d >= c.reverseSlack else { return false }
        if abs(extreme - legStart) >= c.minLeg {
            reversalTimes.append(t)
        } else {
            reversalTimes = []
        }
        direction = -direction
        legStart = extreme
        extreme = v
        return reversalTimes.count >= c.reversals
    }
}

public struct ShakeDetector: Sendable {
    public var config: ShakeConfig
    private var x = ShakeAxis()
    private var y = ShakeAxis()
    private var lastTime: TimeInterval?
    private var cooldownUntil: TimeInterval = -.infinity

    public init(config: ShakeConfig = .preset(.medium)) { self.config = config }

    public init(sensitivity: ShakeSensitivity) { self.config = .preset(sensitivity) }

    public mutating func reset() {
        x.reset()
        y.reset()
        lastTime = nil
    }

    public mutating func feed(x px: Double, y py: Double, at t: TimeInterval) -> Bool {
        if let last = lastTime, t - last > config.maxGap || t < last {
            x.reset()
            y.reset()
        }
        lastTime = t
        let hx = x.feed(px, at: t, config: config)
        let hy = y.feed(py, at: t, config: config)
        guard hx || hy else { return false }
        x.reset()
        y.reset()
        if t < cooldownUntil { return false }
        cooldownUntil = t + config.cooldown
        return true
    }
}
