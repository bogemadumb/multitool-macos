import Foundation

public enum VpnFormat {
    public static func duration(_ sec: TimeInterval) -> String {
        let m = max(0, Int(sec / 60))
        if m < 1 { return "меньше минуты" }
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(mm) мин" }
        return "\(mm) мин"
    }

    public static func span(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec.rounded()))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return s % 60 == 0 || s >= 600 ? "\(s / 60) мин" : "\(s / 60) мин \(s % 60) с" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }

    public static func rate(_ bps: Double) -> (value: String, unit: String) {
        if bps >= 100_000 {
            return (String(format: "%.1f", bps / 1_000_000).replacingOccurrences(of: ".", with: ","), "МБ/с")
        }
        return (String(Int((bps / 1000).rounded())), "КБ/с")
    }

    public static func bytes(_ b: Double) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = b, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let f = i == 0 ? String(Int(v)) : String(format: v < 10 ? "%.1f" : "%.0f", v).replacingOccurrences(of: ".", with: ",")
        return "\(f) \(units[i])"
    }

    public static func ping(_ ms: Int?) -> (value: String, unit: String) {
        guard let ms else { return ("—", "") }
        return (String(ms), "мс")
    }

    public static func speed(_ bps: Double) -> String {
        if bps <= 0 { return "0" }
        if bps >= 100_000 { return String(format: "%.1f МБ/с", bps / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if bps >= 1000 { return "\(Int((bps / 1000).rounded())) КБ/с" }
        return "\(Int(bps)) Б/с"
    }

    public static func age(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        if s < 86400 { return "\(s / 3600) ч" }
        return "\(s / 86400) д"
    }
}

public enum VpnMode: String, CaseIterable, Sendable {
    case rule = "Rule"
    case global = "Global"
    case direct = "Direct"

    public var label: String {
        switch self {
        case .rule: "Умный"
        case .global: "Всё через VPS"
        case .direct: "Напрямую"
        }
    }

    public var longName: String {
        switch self {
        case .rule: "умный режим"
        case .global: "всё через VPS"
        case .direct: "напрямую"
        }
    }

    public static func name(of raw: String) -> String { VpnMode(rawValue: raw)?.longName ?? raw }
}
