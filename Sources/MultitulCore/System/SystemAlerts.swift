import Foundation

public enum AlertKind: String, CaseIterable, Sendable {
    case cpu, temperature, batteryTemperature, memory, disk, battery

    public var title: String {
        switch self {
        case .cpu: "Устойчивая нагрузка CPU"
        case .temperature: "Высокая температура процессора"
        case .batteryTemperature: "Высокая температура батареи"
        case .memory: "Критическая память"
        case .disk: "Мало места на диске"
        case .battery: "Низкий заряд батареи"
        }
    }
}

public struct AlertSettings: Equatable, Sendable {
    public var enabled: Set<AlertKind> = []
    public var cpuThreshold = 0.9
    public var sustainSeconds: TimeInterval = 12
    public var temperatureThreshold = 90.0
    public var batteryTemperatureThreshold = 40.0
    public var diskFreePercent = 10.0
    public var batteryPercent = 15
    public var cooldownMinutes = 30

    public init() {}

    public static func key(_ kind: AlertKind) -> String { "monitor.alert.\(kind.rawValue)" }

    public static func load(from d: KeyValueStoring = UserDefaults.standard) -> AlertSettings {
        var s = AlertSettings()
        for k in AlertKind.allCases where d.bool(forKey: key(k)) { s.enabled.insert(k) }
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        if d.object(forKey: "monitor.alert.cpuThreshold") != nil { s.cpuThreshold = clamp(d.double(forKey: "monitor.alert.cpuThreshold"), 0.5...1) }
        if d.object(forKey: "monitor.alert.temperatureThreshold") != nil { s.temperatureThreshold = clamp(d.double(forKey: "monitor.alert.temperatureThreshold"), 70...105) }
        if d.object(forKey: "monitor.alert.batteryTemperatureThreshold") != nil { s.batteryTemperatureThreshold = clamp(d.double(forKey: "monitor.alert.batteryTemperatureThreshold"), 30...50) }
        if d.object(forKey: "monitor.alert.diskFreePercent") != nil { s.diskFreePercent = clamp(d.double(forKey: "monitor.alert.diskFreePercent"), 2...30) }
        if d.object(forKey: "monitor.alert.batteryPercent") != nil { s.batteryPercent = Int(clamp(Double(d.integer(forKey: "monitor.alert.batteryPercent")), 5...50)) }
        if d.object(forKey: "monitor.alert.cooldownMinutes") != nil { s.cooldownMinutes = Int(clamp(Double(d.integer(forKey: "monitor.alert.cooldownMinutes")), 1...720)) }
        return s
    }
}

public struct SustainedGate {
    private var since: Date?

    public init() {}

    public mutating func reset() { since = nil }

    public mutating func shouldAlert(value: Double?, threshold: Double, now: Date, sustain: TimeInterval) -> Bool {
        guard let value, value >= threshold else {
            since = nil
            return false
        }
        if since == nil { since = now }
        return now.timeIntervalSince(since!) >= sustain
    }
}

public struct AlertCooldown {
    private var last: [AlertKind: Date] = [:]

    public init() {}

    public mutating func allow(_ kind: AlertKind, now: Date, cooldown: TimeInterval) -> Bool {
        if let p = last[kind], now.timeIntervalSince(p) < cooldown { return false }
        last[kind] = now
        return true
    }

    public mutating func reset() { last.removeAll() }
}

public struct SystemAlert: Equatable, Sendable {
    public var kind: AlertKind
    public var title: String
    public var body: String
}

public final class AlertEngine {
    public var settings: AlertSettings
    private var cpuGate = SustainedGate()
    private var tempGate = SustainedGate()
    private var battTempGate = SustainedGate()
    private var cooldown = AlertCooldown()

    public init(settings: AlertSettings = AlertSettings()) { self.settings = settings }

    public func evaluate(_ s: LiveSnapshot, now: Date = Date()) -> [SystemAlert] {
        var fired: [SystemAlert] = []
        let cd = TimeInterval(settings.cooldownMinutes * 60)

        func emit(_ kind: AlertKind, _ title: String, _ body: String) {
            if cooldown.allow(kind, now: now, cooldown: cd) { fired.append(SystemAlert(kind: kind, title: title, body: body)) }
        }

        if settings.enabled.contains(.cpu) {
            if cpuGate.shouldAlert(value: s.cpu?.total, threshold: settings.cpuThreshold, now: now, sustain: settings.sustainSeconds) {
                emit(.cpu, "Процессор перегружен", "Загрузка выше \(Int(settings.cpuThreshold * 100))% держится дольше \(Int(settings.sustainSeconds)) с")
            }
        } else { cpuGate.reset() }

        if settings.enabled.contains(.temperature) {
            if tempGate.shouldAlert(value: s.temps.cpu, threshold: settings.temperatureThreshold, now: now, sustain: settings.sustainSeconds),
               let t = s.temps.cpu {
                emit(.temperature, "Процессор горячий", "Температура \(SysFormat.temperature(t)), порог \(SysFormat.temperature(settings.temperatureThreshold))")
            }
        } else { tempGate.reset() }

        if settings.enabled.contains(.batteryTemperature) {
            let t = s.temps.battery ?? s.battery?.temperatureC
            if battTempGate.shouldAlert(value: t, threshold: settings.batteryTemperatureThreshold, now: now, sustain: settings.sustainSeconds), let t {
                emit(.batteryTemperature, "Батарея горячая", "Температура \(SysFormat.temperature(t)), порог \(SysFormat.temperature(settings.batteryTemperatureThreshold))")
            }
        } else { battTempGate.reset() }

        if settings.enabled.contains(.memory), s.memory?.pressure == .critical {
            emit(.memory, "Память на пределе", "Давление памяти критическое: система сжимает и сбрасывает в своп")
        }

        if settings.enabled.contains(.disk), let v = lowDisk(s) {
            emit(.disk, "Мало места на диске", "На «\(v.name)» свободно \(SysFormat.diskBytes(Double(v.freeBytes))) (\(Int(v.freeFraction * 100))%), порог \(Int(settings.diskFreePercent))%")
        }

        if settings.enabled.contains(.battery), let b = s.battery, b.hasBattery, !b.onAC, !b.isCharging,
           let p = b.percent, p <= settings.batteryPercent {
            emit(.battery, "Батарея садится", "Заряд \(p)%, порог \(settings.batteryPercent)%")
        }
        return fired
    }

    func lowDisk(_ s: LiveSnapshot) -> DiskVolume? {
        s.disk?.volumes.first { $0.isInternal && $0.totalBytes >= 10_000_000_000 && $0.freeFraction * 100 < settings.diskFreePercent }
    }
}
