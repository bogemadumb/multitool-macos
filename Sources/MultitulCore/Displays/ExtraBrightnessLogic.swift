import Foundation

public struct XdrScreenInfo: Equatable, Sendable {
    public var isBuiltin: Bool
    public var potentialEDR: Double
    public var modelIdentifier: String

    public init(isBuiltin: Bool, potentialEDR: Double, modelIdentifier: String) {
        self.isBuiltin = isBuiltin
        self.potentialEDR = potentialEDR
        self.modelIdentifier = modelIdentifier
    }
}

public enum XdrUnavailableReason: Equatable, Sendable {
    case notBuiltin
    case noHeadroom
    case nonXdrModel

    public var text: String {
        switch self {
        case .notBuiltin: "недоступно на этом экране: подходит только встроенный XDR-дисплей"
        case .noHeadroom: "недоступно на этом экране: у него нет запаса HDR"
        case .nonXdrModel: "недоступно на этом экране: это не XDR-дисплей (Liquid Retina без mini-LED)"
        }
    }
}

public enum XdrAvailability: Equatable, Sendable {
    case available(maxGain: Double)
    case unavailable(XdrUnavailableReason)

    public var isAvailable: Bool { if case .available = self { true } else { false } }
}

public enum ExtraBrightnessLogic {
    public static let minHeadroom = 1.5
    public static let gainCeiling = 1.6

    // MacBook Air panels are not XDR even where macOS reports some EDR potential.
    static let airIdentifiers: Set<String> = ["Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13"]

    public static func isKnownNonXdr(modelIdentifier id: String) -> Bool {
        id.hasPrefix("MacBookAir") || id.hasPrefix("Macmini") || id.hasPrefix("iMac") || airIdentifiers.contains(id)
    }

    public static func availability(_ s: XdrScreenInfo) -> XdrAvailability {
        guard s.isBuiltin else { return .unavailable(.notBuiltin) }
        if isKnownNonXdr(modelIdentifier: s.modelIdentifier) { return .unavailable(.nonXdrModel) }
        guard s.potentialEDR.isFinite, s.potentialEDR >= minHeadroom else { return .unavailable(.noHeadroom) }
        return .available(maxGain: min(s.potentialEDR, gainCeiling))
    }

    // level 0 = no boost (gain 1), level 1 = the full allowed headroom.
    public static func gain(level: Double, maxGain: Double) -> Double {
        let l = BrightnessStep.clamp(level)
        let top = max(maxGain, 1)
        return 1 + l * (top - 1)
    }

    // The multiply factor never exceeds the headroom macOS actually grants right now.
    public static func effectiveFactor(target: Double, currentEDR: Double) -> Double {
        guard target.isFinite, currentEDR.isFinite else { return 1 }
        return max(1, min(target, currentEDR))
    }

    // One smoothing step per tick so a wobbling grant does not flash the screen.
    public static func ramp(current: Double, target: Double, step: Double = 0.04) -> Double {
        if abs(target - current) <= step { return target }
        return current + (target > current ? step : -step)
    }

    public static func shouldBoost(enabled: Bool, available: Bool, onBattery: Bool, autoOffOnBattery: Bool, lowPower: Bool) -> Bool {
        guard enabled, available else { return false }
        if autoOffOnBattery && (onBattery || lowPower) { return false }
        return true
    }
}

public struct ExtraBrightnessSettings: Equatable, Sendable {
    public var level = 0.5
    public var autoOffOnBattery = true

    public init() {}

    static let levelKey = "extraBrightness.level"
    static let batteryKey = "extraBrightness.autoOffOnBattery"

    public static func load(_ d: KeyValueStoring = UserDefaults.standard) -> ExtraBrightnessSettings {
        var s = ExtraBrightnessSettings()
        if let v = d.object(forKey: levelKey) as? Double { s.level = BrightnessStep.clamp(v) }
        if let v = d.object(forKey: batteryKey) as? Bool { s.autoOffOnBattery = v }
        return s
    }

    public func save(to d: KeyValueStoring = UserDefaults.standard) {
        let base = ExtraBrightnessSettings()
        func put<T: Equatable>(_ key: String, _ v: T, _ b: T) { if v == b { d.removeObject(forKey: key) } else { d.set(v, forKey: key) } }
        put(Self.levelKey, level, base.level)
        put(Self.batteryKey, autoOffOnBattery, base.autoOffOnBattery)
    }
}
