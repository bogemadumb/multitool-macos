import Foundation

public struct FanHysteresis: Equatable, Sendable {
    public private(set) var anchor: Double?

    public init() {}

    // Rises are followed at once; a fall is followed only after it exceeds the band.
    public mutating func filter(_ temp: Double, band: Double) -> Double {
        guard let a = anchor else {
            anchor = temp
            return temp
        }
        if temp >= a || a - temp >= max(band, 0) { anchor = temp }
        return anchor ?? temp
    }

    public mutating func reset() { anchor = nil }
}

public enum FanRamp {
    // up/down in rpm per second; 0 means unlimited.
    public static func step(current: Double, target: Double, dt: Double, up: Int, down: Int) -> Double {
        guard current.isFinite, target.isFinite else { return target.isFinite ? target : current }
        if target == current { return target }
        let limit = target > current ? up : down
        guard limit > 0 else { return target }
        let room = Double(limit) * max(dt, 0)
        return target > current ? min(target, current + room) : max(target, current - room)
    }
}

public enum FanSensors {
    public static func values(_ t: FanThermal, source: FanSensorSource) -> [Double] {
        let all: [Double]
        switch source {
        case .cpu: all = t.cpu
        case .gpu: all = t.gpu
        case .soc: all = t.cpu + t.gpu
        }
        return all.filter(TemperatureSelector.plausible)
    }

    public static func aggregate(_ t: FanThermal, source: FanSensorSource, how: FanAggregate) -> Double? {
        let v = values(t, source: source)
        guard !v.isEmpty else { return nil }
        switch how {
        case .average: return v.reduce(0, +) / Double(v.count)
        case .hottest: return v.max()
        }
    }
}

public enum FanPolicy {
    public static let nominalTick = 2.0
    public static let minWriteDelta = 30.0
    public static let refreshInterval = 15.0
    public static let restoreRetryInterval = 5.0
    public static let sensorLossLimit = 3
    public static let fanReadLossLimit = 3
    public static let maxReclaims = 5
    public static let watchdogTimeout = 20.0
    public static let seriousThermalState = 2

    public static func validBounds(min: Double, max: Double) -> Bool {
        min.isFinite && max.isFinite && min >= 0 && max > min && max <= 10000
    }

    public static func rpm(percent: Double, fan: FanInfo) -> Double {
        let p = Swift.min(Swift.max(percent, 0), 100)
        return fan.minRpm + (fan.maxRpm - fan.minRpm) * p / 100
    }

    // Never below the fan minimum, never above its maximum; zero only for a fan whose minimum is zero.
    public static func clamp(_ rpm: Double, fan: FanInfo) -> Double {
        guard rpm.isFinite else { return fan.minRpm }
        if rpm <= 0 { return fan.canStop ? 0 : fan.minRpm }
        return Swift.min(Swift.max(rpm, fan.minRpm), fan.maxRpm)
    }

    public static func shouldWrite(last: Double?, new: Double, since: TimeInterval?) -> Bool {
        guard let last, let since else { return true }
        return abs(new - last) >= minWriteDelta || since >= refreshInterval
    }
}
