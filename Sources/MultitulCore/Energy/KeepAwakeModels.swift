import Foundation

public enum KeepAwakeIconKind: String, CaseIterable, Sendable {
    case cup, eye, moon, bolt, sun

    public var title: String {
        switch self {
        case .cup: "Чашка"
        case .eye: "Глаз"
        case .moon: "Луна"
        case .bolt: "Молния"
        case .sun: "Солнце"
        }
    }

    public var symbolOn: String {
        switch self {
        case .cup: "cup.and.saucer.fill"
        case .eye: "eye.fill"
        case .moon: "moon.fill"
        case .bolt: "bolt.fill"
        case .sun: "sun.max.fill"
        }
    }

    public var symbolOff: String {
        switch self {
        case .cup: "cup.and.saucer"
        case .eye: "eye"
        case .moon: "moon"
        case .bolt: "bolt"
        case .sun: "sun.max"
        }
    }
}

public enum KeepAwakeIconTint: String, CaseIterable, Sendable {
    case none, orange, green, blue, purple, pink

    public var title: String {
        switch self {
        case .none: "Системный"
        case .orange: "Оранжевый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .pink: "Розовый"
        }
    }
}

public enum KeepAwakeMatch: String, CaseIterable, Sendable {
    case any, all

    public var title: String { self == .any ? "Любое условие" : "Все условия" }
}

public struct KeepAwakeSettings: Equatable, Sendable {
    public var autoStart = false
    public var defaultMinutes = 0
    public var allowDisplaySleep = false
    public var batteryLimitPercent = 20
    public var showRemaining = true
    public var jiggleEnabled = false
    public var jiggleMinutes = 5
    public var dimOnLidClosed = true
    public var notifyOnEnd = true
    public var lidMaxHours = 12
    public var autoExternalDisplay = false
    public var autoOnPower = false
    public var autoApps = false
    public var autoAppBundleIDs: [String] = []
    public var match: KeepAwakeMatch = .any
    public var iconKind: KeepAwakeIconKind = .cup
    public var iconTint: KeepAwakeIconTint = .none

    public init() {}

    public static let presetMinutes = [15, 30, 60, 120, 240, 480]
    public static let jiggleChoices = [1, 2, 5, 10, 15]
    public static let batteryChoices = [0, 10, 15, 20, 30, 40, 50]
    public static let lidLimitChoices = [0, 2, 4, 8, 12, 24]

    public var sanitized: KeepAwakeSettings {
        var s = self
        s.defaultMinutes = max(0, min(s.defaultMinutes, 24 * 60))
        s.batteryLimitPercent = max(0, min(s.batteryLimitPercent, 90))
        s.jiggleMinutes = max(1, min(s.jiggleMinutes, 60))
        s.lidMaxHours = max(0, min(s.lidMaxHours, 72))
        var seen = Set<String>()
        s.autoAppBundleIDs = s.autoAppBundleIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return s
    }

    public var automationEnabled: Bool {
        autoExternalDisplay || autoOnPower || (autoApps && !autoAppBundleIDs.isEmpty)
    }
}

public enum KeepAwakeHotkeys {
    public static let toggle = HotkeySpec(id: "keepAwake.toggle", title: "Keep Awake: включить / выключить", defaultCombo: .none)
}

public final class KeepAwakeStore {
    static let prefix = "keepAwake."
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> KeepAwakeSettings {
        var s = KeepAwakeSettings()
        func bool(_ k: String, _ set: (Bool) -> Void) { if let v = defaults.object(forKey: Self.prefix + k) as? Bool { set(v) } }
        func int(_ k: String, _ set: (Int) -> Void) { if let v = defaults.object(forKey: Self.prefix + k) as? Int { set(v) } }
        bool("autoStart") { s.autoStart = $0 }
        int("defaultMinutes") { s.defaultMinutes = $0 }
        bool("allowDisplaySleep") { s.allowDisplaySleep = $0 }
        int("batteryLimit") { s.batteryLimitPercent = $0 }
        bool("showRemaining") { s.showRemaining = $0 }
        bool("jiggle") { s.jiggleEnabled = $0 }
        int("jiggleMinutes") { s.jiggleMinutes = $0 }
        bool("dimOnLidClosed") { s.dimOnLidClosed = $0 }
        bool("notifyOnEnd") { s.notifyOnEnd = $0 }
        int("lidMaxHours") { s.lidMaxHours = $0 }
        bool("autoExternalDisplay") { s.autoExternalDisplay = $0 }
        bool("autoOnPower") { s.autoOnPower = $0 }
        bool("autoApps") { s.autoApps = $0 }
        if let v = defaults.stringArray(forKey: Self.prefix + "autoAppBundleIDs") { s.autoAppBundleIDs = v }
        if let v = defaults.string(forKey: Self.prefix + "match"), let m = KeepAwakeMatch(rawValue: v) { s.match = m }
        if let v = defaults.string(forKey: Self.prefix + "iconKind"), let m = KeepAwakeIconKind(rawValue: v) { s.iconKind = m }
        if let v = defaults.string(forKey: Self.prefix + "iconTint"), let m = KeepAwakeIconTint(rawValue: v) { s.iconTint = m }
        return s.sanitized
    }

    public func save(_ settings: KeepAwakeSettings) {
        let s = settings.sanitized
        let base = KeepAwakeSettings()
        func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
            if v == d { defaults.removeObject(forKey: Self.prefix + key) } else { defaults.set(v, forKey: Self.prefix + key) }
        }
        put("autoStart", s.autoStart, base.autoStart)
        put("defaultMinutes", s.defaultMinutes, base.defaultMinutes)
        put("allowDisplaySleep", s.allowDisplaySleep, base.allowDisplaySleep)
        put("batteryLimit", s.batteryLimitPercent, base.batteryLimitPercent)
        put("showRemaining", s.showRemaining, base.showRemaining)
        put("jiggle", s.jiggleEnabled, base.jiggleEnabled)
        put("jiggleMinutes", s.jiggleMinutes, base.jiggleMinutes)
        put("dimOnLidClosed", s.dimOnLidClosed, base.dimOnLidClosed)
        put("notifyOnEnd", s.notifyOnEnd, base.notifyOnEnd)
        put("lidMaxHours", s.lidMaxHours, base.lidMaxHours)
        put("autoExternalDisplay", s.autoExternalDisplay, base.autoExternalDisplay)
        put("autoOnPower", s.autoOnPower, base.autoOnPower)
        put("autoApps", s.autoApps, base.autoApps)
        put("autoAppBundleIDs", s.autoAppBundleIDs, base.autoAppBundleIDs)
        put("match", s.match.rawValue, base.match.rawValue)
        put("iconKind", s.iconKind.rawValue, base.iconKind.rawValue)
        put("iconTint", s.iconTint.rawValue, base.iconTint.rawValue)
    }
}

public enum KeepAwakeEnd: Equatable, Sendable {
    case never
    case at(Date)
    case appQuits(bundleID: String)
}

public struct KeepAwakeSession: Equatable, Sendable {
    public var start: Date
    public var end: KeepAwakeEnd
    public var closedLid: Bool

    public init(start: Date, end: KeepAwakeEnd, closedLid: Bool = false) {
        self.start = start
        self.end = end
        self.closedLid = closedLid
    }

    public static func minutes(_ m: Int, from now: Date, closedLid: Bool = false) -> KeepAwakeSession {
        KeepAwakeSession(start: now, end: m > 0 ? .at(now.addingTimeInterval(Double(m) * 60)) : .never, closedLid: closedLid)
    }

    public func remaining(at now: Date) -> TimeInterval? {
        if case .at(let d) = end { return max(0, d.timeIntervalSince(now)) }
        return nil
    }
}

public struct KeepAwakeInputs: Equatable, Sendable {
    public var now: Date
    public var battery: BatteryReading?
    public var runningApps: Set<String>
    public var externalDisplays: Int
    public var lidClosed: Bool

    public init(now: Date, battery: BatteryReading? = nil, runningApps: Set<String> = [], externalDisplays: Int = 0, lidClosed: Bool = false) {
        self.now = now
        self.battery = battery
        self.runningApps = runningApps
        self.externalDisplays = externalDisplays
        self.lidClosed = lidClosed
    }
}

public enum KeepAwakeEndReason: Equatable, Sendable {
    case timerExpired, appQuit, batteryLow, lidLimit
}

public enum KeepAwakeNotice: Equatable, Sendable {
    case ended(KeepAwakeEndReason)
    case batteryTooLow(percent: Int, limit: Int)
    case lidUnavailable(String)
    case lidRestoreFailed(String)

    public var text: String {
        switch self {
        case .ended(.timerExpired): "Время вышло, Mac снова может засыпать."
        case .ended(.appQuit): "Приложение закрыто, Mac снова может засыпать."
        case .ended(.batteryLow): "Заряд упал ниже порога, Keep Awake выключен."
        case .ended(.lidLimit): "Предел времени с закрытой крышкой, Keep Awake выключен."
        case .batteryTooLow(let p, let l): "Заряд \(p)% ниже порога \(l)%: Keep Awake не включён."
        case .lidUnavailable(let m): "Закрытая крышка недоступна: \(m)"
        case .lidRestoreFailed(let m): "Не удалось вернуть сон при закрытой крышке: \(m). Будет повторено при следующем запуске."
        }
    }
}

public enum KeepAwakeAction: Equatable, Sendable {
    case holdAssertion(displayToo: Bool)
    case releaseAssertion
    case setClosedLid(Bool)
    case dimBuiltin(Bool)
    case jiggle
    case notify(KeepAwakeNotice)
}
