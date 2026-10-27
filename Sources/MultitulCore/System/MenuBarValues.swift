import Foundation

public enum HistoryKey {
    public static let cpu = "cpu"
    public static let gpu = "gpu"
    public static let memory = "memory"
    public static let netDown = "netDown"
    public static let netUp = "netUp"
    public static let diskRead = "diskRead"
    public static let diskWrite = "diskWrite"
    public static let diskIO = "diskIO"
    public static let tempCPU = "tempCPU"
    public static let tempGPU = "tempGPU"
    public static let battery = "battery"
    public static let powerW = "powerW"
}

public enum MenuLevel: Int, Comparable, Sendable {
    case normal, warn, critical
    public static func < (a: MenuLevel, b: MenuLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct MenuBarValue: Equatable, Sendable {
    public var metric: SystemMetric
    public var caption: String
    public var text: String
    public var lines: [String]
    public var fraction: Double?
    public var level: MenuLevel
    public var series: [Double]
}

public enum MenuBarValues {
    static func highIsBad(_ f: Double) -> MenuLevel { f >= 0.95 ? .critical : (f >= 0.8 ? .warn : .normal) }

    static func compactDisk(_ bytes: Double) -> String {
        if bytes >= 1e12 { return String(format: "%.1f", bytes / 1e12).replacingOccurrences(of: ".", with: ",") + "ТБ" }
        if bytes >= 1e9 { return String(format: "%.0f", bytes / 1e9) + "ГБ" }
        return String(format: "%.0f", bytes / 1e6) + "МБ"
    }

    static func normalized(_ values: [Double], by scale: Double) -> [Double] {
        guard scale > 0 else { return values.map { _ in 0 } }
        return values.map { min(max($0 / scale, 0), 1) }
    }

    public static func make(_ metric: SystemMetric, snapshot s: LiveSnapshot, history h: NamedHistory, uploadFirst: Bool = false) -> MenuBarValue {
        var v = MenuBarValue(metric: metric, caption: metric.shortTitle, text: "—", lines: [], fraction: nil, level: .normal, series: [])
        switch metric {
        case .cpu:
            v.series = normalized(h.values(HistoryKey.cpu), by: 100)
            if let c = s.cpu {
                v.fraction = c.total
                v.text = SysFormat.percent(c.total) + "%"
                v.level = highIsBad(c.total)
            }
        case .gpu:
            v.series = normalized(h.values(HistoryKey.gpu), by: 100)
            if let g = s.gpu {
                v.fraction = g.utilization
                v.text = SysFormat.percent(g.utilization) + "%"
                v.level = highIsBad(g.utilization)
            }
        case .memory:
            v.series = normalized(h.values(HistoryKey.memory), by: 100)
            if let m = s.memory {
                v.fraction = m.composition.usedFraction
                v.text = SysFormat.percent(m.composition.usedFraction) + "%"
                v.level = m.pressure == .critical ? .critical : (m.pressure == .warning ? .warn : highIsBad(m.composition.usedFraction))
            }
        case .network:
            let down = h.values(HistoryKey.netDown)
            let up = h.values(HistoryKey.netUp)
            v.series = normalized(down, by: max(down.max() ?? 0, up.max() ?? 0, 1024))
            if let n = s.network {
                let d = "↓" + SysFormat.rateShort(n.downBps)
                let u = "↑" + SysFormat.rateShort(n.upBps)
                v.lines = uploadFirst ? [u, d] : [d, u]
                v.text = v.lines[0]
                v.fraction = min((n.downBps + n.upBps) / (10 * 1024 * 1024), 1)
            }
        case .disk:
            v.series = normalized(h.values(HistoryKey.diskIO), by: max(h.values(HistoryKey.diskIO).max() ?? 0, 1024 * 1024))
            if let vol = s.disk?.volumes.first(where: { $0.path == "/" }) ?? s.disk?.volumes.first {
                v.fraction = vol.usedFraction
                v.text = compactDisk(Double(vol.freeBytes))
                v.level = vol.freeFraction < 0.08 ? .critical : (vol.freeFraction < 0.15 ? .warn : .normal)
            }
        case .power:
            v.series = normalized(h.values(HistoryKey.battery), by: 100)
            if let b = s.battery, b.hasBattery, let p = b.percent {
                v.fraction = Double(p) / 100
                v.text = (b.isCharging ? "⚡" : "") + "\(p)%"
                v.level = b.onAC || b.isCharging ? .normal : (p <= 10 ? .critical : (p <= 20 ? .warn : .normal))
            } else if s.battery != nil {
                v.text = "сеть"
            }
        case .devices:
            v.text = "\(s.devices.count)"
        }
        if v.lines.isEmpty { v.lines = [v.text] }
        return v
    }
}

public struct SpeedTestResult: Equatable, Sendable {
    public var downMbps: Double
    public var upMbps: Double
    public var rttMs: Double?
}

public extension SystemParsers {
    static func networkQuality(_ text: String) -> SpeedTestResult? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let dl = RegistryParsers.double(obj["dl_throughput"]), let ul = RegistryParsers.double(obj["ul_throughput"]) else { return nil }
        return SpeedTestResult(downMbps: dl / 1_000_000, upMbps: ul / 1_000_000, rttMs: RegistryParsers.double(obj["base_rtt"]))
    }
}
