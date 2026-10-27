import Foundation

public enum DetectorKind: String, CaseIterable, Sendable {
    case cpuHog = "cpu_hog"
    case memPressure = "mem_pressure"
    case swap
    case memLeak = "mem_leak"
    case batteryDrain = "battery_drain"
    case diskLow = "disk_low"
    case thermal

    public var title: String {
        switch self {
        case .cpuHog: "Процесс грузит процессор"
        case .memPressure: "Давление памяти"
        case .swap: "Большой своп"
        case .memLeak: "Утечка памяти"
        case .batteryDrain: "Батарея садится в простое"
        case .diskLow: "Мало места на диске"
        case .thermal: "Перегрев"
        }
    }

    public var summary: String {
        switch self {
        case .cpuHog: "Больше 80% ЦП дольше 5 минут, пока ты не за компьютером"
        case .memPressure: "Давление памяти выше нормы два замера подряд"
        case .swap: "Своп больше 4 ГБ"
        case .memLeak: "Процесс набрал больше 2 ГБ за час почти без спадов"
        case .batteryDrain: "Заряд падает быстрее 10% в час в простое"
        case .diskLow: "Свободно меньше 10 ГБ"
        case .thermal: "Система в состоянии «серьёзно» или «критично» две минуты"
        }
    }

    public var isPerProcess: Bool { self == .cpuHog || self == .memLeak }
}

public struct StorozhThresholds: Codable, Equatable, Sendable {
    public var cpuHogPercent = 80.0
    public var cpuHogWindowSec = 300
    public var cpuHogIdleSec = 180
    public var swapMb = 4096
    public var memLeakMb = 2048
    public var memLeakWindowMin = 60
    public var memLeakUpShare = 0.8
    public var batteryIdleSec = 600
    public var batteryDrainPerHour = 10.0
    public var cooldownMin = 30
    public var repeatCount = 3
    public var repeatWindowMin = 120
    public var snapshotKeep = 50
    public var diskLowGb = 10.0
    public var thermalSec = 120

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StorozhThresholds()
        cpuHogPercent = try c.decodeIfPresent(Double.self, forKey: .cpuHogPercent) ?? d.cpuHogPercent
        cpuHogWindowSec = try c.decodeIfPresent(Int.self, forKey: .cpuHogWindowSec) ?? d.cpuHogWindowSec
        cpuHogIdleSec = try c.decodeIfPresent(Int.self, forKey: .cpuHogIdleSec) ?? d.cpuHogIdleSec
        swapMb = try c.decodeIfPresent(Int.self, forKey: .swapMb) ?? d.swapMb
        memLeakMb = try c.decodeIfPresent(Int.self, forKey: .memLeakMb) ?? d.memLeakMb
        memLeakWindowMin = try c.decodeIfPresent(Int.self, forKey: .memLeakWindowMin) ?? d.memLeakWindowMin
        memLeakUpShare = try c.decodeIfPresent(Double.self, forKey: .memLeakUpShare) ?? d.memLeakUpShare
        batteryIdleSec = try c.decodeIfPresent(Int.self, forKey: .batteryIdleSec) ?? d.batteryIdleSec
        batteryDrainPerHour = try c.decodeIfPresent(Double.self, forKey: .batteryDrainPerHour) ?? d.batteryDrainPerHour
        cooldownMin = try c.decodeIfPresent(Int.self, forKey: .cooldownMin) ?? d.cooldownMin
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? d.repeatCount
        repeatWindowMin = try c.decodeIfPresent(Int.self, forKey: .repeatWindowMin) ?? d.repeatWindowMin
        snapshotKeep = try c.decodeIfPresent(Int.self, forKey: .snapshotKeep) ?? d.snapshotKeep
        diskLowGb = try c.decodeIfPresent(Double.self, forKey: .diskLowGb) ?? d.diskLowGb
        thermalSec = try c.decodeIfPresent(Int.self, forKey: .thermalSec) ?? d.thermalSec
    }
}

// One editable number of StorozhThresholds with its limits; the UI draws a stepper from this table.
public enum ThresholdField: String, CaseIterable, Sendable {
    case cpuHogPercent, cpuHogWindowSec, cpuHogIdleSec
    case swapMb
    case memLeakMb, memLeakWindowMin, memLeakUpShare
    case batteryIdleSec, batteryDrainPerHour
    case diskLowGb
    case thermalSec
    case cooldownMin, repeatCount, repeatWindowMin, snapshotKeep

    public var detector: DetectorKind? {
        switch self {
        case .cpuHogPercent, .cpuHogWindowSec, .cpuHogIdleSec: .cpuHog
        case .swapMb: .swap
        case .memLeakMb, .memLeakWindowMin, .memLeakUpShare: .memLeak
        case .batteryIdleSec, .batteryDrainPerHour: .batteryDrain
        case .diskLowGb: .diskLow
        case .thermalSec: .thermal
        case .cooldownMin, .repeatCount, .repeatWindowMin, .snapshotKeep: nil
        }
    }

    public var title: String {
        switch self {
        case .cpuHogPercent: "Порог загрузки процессора"
        case .cpuHogWindowSec: "Окно наблюдения"
        case .cpuHogIdleSec: "Простой до проверки"
        case .swapMb: "Порог свопа"
        case .memLeakMb: "Прирост памяти"
        case .memLeakWindowMin: "Окно наблюдения"
        case .memLeakUpShare: "Доля замеров с ростом"
        case .batteryIdleSec: "Простой до проверки"
        case .batteryDrainPerHour: "Расход заряда"
        case .diskLowGb: "Минимум свободного места"
        case .thermalSec: "Длительность перегрева"
        case .cooldownMin: "Пауза между повторами"
        case .repeatCount: "Повторов до «перезапуск не помогает»"
        case .repeatWindowMin: "Окно подсчёта повторов"
        case .snapshotKeep: "Снимков хранить"
        }
    }

    public var unit: String {
        switch self {
        case .cpuHogPercent: "%"
        case .cpuHogWindowSec, .cpuHogIdleSec, .batteryIdleSec, .thermalSec: "с"
        case .swapMb, .memLeakMb: "МБ"
        case .memLeakWindowMin, .cooldownMin, .repeatWindowMin: "мин"
        case .memLeakUpShare: "доля"
        case .batteryDrainPerHour: "%/ч"
        case .diskLowGb: "ГБ"
        case .repeatCount, .snapshotKeep: "шт."
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .cpuHogPercent: 10...100
        case .cpuHogWindowSec: 60...3600
        case .cpuHogIdleSec: 0...3600
        case .swapMb: 512...65536
        case .memLeakMb: 256...32768
        case .memLeakWindowMin: 10...360
        case .memLeakUpShare: 0.3...1
        case .batteryIdleSec: 60...3600
        case .batteryDrainPerHour: 2...60
        case .diskLowGb: 1...200
        case .thermalSec: 30...1800
        case .cooldownMin: 1...720
        case .repeatCount: 2...20
        case .repeatWindowMin: 10...1440
        case .snapshotKeep: 5...500
        }
    }

    public var step: Double {
        switch self {
        case .cpuHogPercent, .batteryDrainPerHour, .repeatCount: 1
        case .cpuHogWindowSec, .cpuHogIdleSec, .batteryIdleSec, .thermalSec: 30
        case .swapMb, .memLeakMb: 256
        case .memLeakWindowMin, .cooldownMin, .repeatWindowMin: 5
        case .memLeakUpShare: 0.05
        case .diskLowGb: 1
        case .snapshotKeep: 5
        }
    }

    public var isInteger: Bool { self != .cpuHogPercent && self != .memLeakUpShare && self != .batteryDrainPerHour && self != .diskLowGb }

    public func value(in t: StorozhThresholds) -> Double {
        switch self {
        case .cpuHogPercent: t.cpuHogPercent
        case .cpuHogWindowSec: Double(t.cpuHogWindowSec)
        case .cpuHogIdleSec: Double(t.cpuHogIdleSec)
        case .swapMb: Double(t.swapMb)
        case .memLeakMb: Double(t.memLeakMb)
        case .memLeakWindowMin: Double(t.memLeakWindowMin)
        case .memLeakUpShare: t.memLeakUpShare
        case .batteryIdleSec: Double(t.batteryIdleSec)
        case .batteryDrainPerHour: t.batteryDrainPerHour
        case .diskLowGb: t.diskLowGb
        case .thermalSec: Double(t.thermalSec)
        case .cooldownMin: Double(t.cooldownMin)
        case .repeatCount: Double(t.repeatCount)
        case .repeatWindowMin: Double(t.repeatWindowMin)
        case .snapshotKeep: Double(t.snapshotKeep)
        }
    }

    public func clamp(_ v: Double) -> Double {
        let c = min(max(v, range.lowerBound), range.upperBound)
        return isInteger ? c.rounded() : (c * 100).rounded() / 100
    }

    public func set(_ v: Double, in t: inout StorozhThresholds) {
        let c = clamp(v)
        switch self {
        case .cpuHogPercent: t.cpuHogPercent = c
        case .cpuHogWindowSec: t.cpuHogWindowSec = Int(c)
        case .cpuHogIdleSec: t.cpuHogIdleSec = Int(c)
        case .swapMb: t.swapMb = Int(c)
        case .memLeakMb: t.memLeakMb = Int(c)
        case .memLeakWindowMin: t.memLeakWindowMin = Int(c)
        case .memLeakUpShare: t.memLeakUpShare = c
        case .batteryIdleSec: t.batteryIdleSec = Int(c)
        case .batteryDrainPerHour: t.batteryDrainPerHour = c
        case .diskLowGb: t.diskLowGb = c
        case .thermalSec: t.thermalSec = Int(c)
        case .cooldownMin: t.cooldownMin = Int(c)
        case .repeatCount: t.repeatCount = Int(c)
        case .repeatWindowMin: t.repeatWindowMin = Int(c)
        case .snapshotKeep: t.snapshotKeep = Int(c)
        }
    }
}

public enum StorozhList: String, CaseIterable, Sendable {
    case whitelist, untouchable, ignore

    public var title: String {
        switch self {
        case .whitelist: "Белый список"
        case .untouchable: "Неприкасаемые"
        case .ignore: "Игнор"
        }
    }

    public var subtitle: String {
        switch self {
        case .whitelist: "Перезапускаются молча: SIGTERM, через 5 с SIGKILL, затем open -b"
        case .untouchable: "Никогда не трогаются. Встроенные записи удалить нельзя"
        case .ignore: "Детектор их не замечает"
        }
    }
}

public struct StorozhLists: Equatable, Sendable {
    public var whitelist: [String]
    public var untouchable: [String]
    public var ignore: [String]

    public static let defaultWhitelist = ["Telegram", "Code Helper*", "Google Chrome Helper*", "node", "npm", "uvx", "vite"]
    public static let defaultUntouchable = ["WindowServer", "kernel_task", "sing-box", "xray", "VPNMonitor", "claude", "Storozh", "Multitul",
                                            "pid<200", "path:/System/", "path:/usr/libexec/"]

    public static let builtinUntouchable = [
        "WindowServer", "kernel_task", "sing-box", "xray", "VPNMonitor", "Storozh", "Multitul", "multitul-ctl",
        "claude", "claude*", "Claude*", "codex*", "Codex*",
        "pid<200", "path:/System/", "path:/usr/libexec/",
        "pathhas:/.local/share/claude/", "pathhas:/anthropic.claude-code", "pathhas:/@anthropic-ai/claude-code",
        "pathhas:/openai.chatgpt", "pathhas:/Claude.app/", "pathhas:/Codex.app/",
        "pathhas:/VPNMonitor.app/", "pathhas:/Storozh.app/", "pathhas:/Multitul.app/", "pathhas:/sing-box", "pathhas:/xray",
        "pathhas:playwright",
    ]

    public init(whitelist: [String] = StorozhLists.defaultWhitelist, untouchable: [String] = StorozhLists.defaultUntouchable, ignore: [String] = []) {
        self.whitelist = whitelist
        self.untouchable = untouchable
        self.ignore = ignore
    }

    public var effectiveUntouchable: [String] {
        var out = untouchable
        for e in StorozhLists.builtinUntouchable where !out.contains(e) { out.append(e) }
        return out
    }

    public func entries(_ list: StorozhList) -> [String] {
        switch list {
        case .whitelist: whitelist
        case .untouchable: untouchable
        case .ignore: ignore
        }
    }

    public static func isBuiltin(_ entry: String) -> Bool { builtinUntouchable.contains(entry) }
}

public struct StorozhSettings: Equatable, Sendable {
    public var thresholds = StorozhThresholds()
    public var disabledKinds: Set<String> = []
    public var pausedUntil = 0.0

    public init() {}

    public func isPaused(at now: Double) -> Bool { pausedUntil > now }
    public func isEnabled(_ kind: String) -> Bool { !disabledKinds.contains(kind) }
}

public enum PausePreset: Sendable { case hour, morning, off }

public func pauseUntil(_ p: PausePreset, now: Date = Date(), calendar: Calendar = .current) -> Double {
    switch p {
    case .off: return 0
    case .hour: return now.timeIntervalSince1970 + 3600
    case .morning:
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, second: 0), matchingPolicy: .nextTime)
        return (next ?? now.addingTimeInterval(3600)).timeIntervalSince1970
    }
}

public enum StorozhIconLevel: Equatable, Sendable { case normal, warn, crit }

public struct StorozhIconState: Equatable, Sendable {
    public var level: StorozhIconLevel
    public var paused: Bool

    public init(level: StorozhIconLevel, paused: Bool) {
        self.level = level
        self.paused = paused
    }

    public static func compute(openCount: Int, pressure: Int?, pausedUntil: Double, now: Double) -> StorozhIconState {
        let level: StorozhIconLevel = (pressure ?? 0) >= 4 ? .crit : (openCount > 0 ? .warn : .normal)
        return StorozhIconState(level: level, paused: pausedUntil > now)
    }
}
