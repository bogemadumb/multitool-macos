import Foundation

public enum TodayTone: Equatable, Sendable { case good, warn, bad, neutral }

public struct TodayAttentionItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let section: String
    public let tone: TodayTone
}

public struct TodayInput: Sendable {
    public var vpnEnabled = false
    public var vpnState: VpnState?
    public var diskFreeBytes: UInt64?
    public var diskTotalBytes: UInt64?
    public var batteryPercent: Int?
    public var batteryOnAC = false
    public var warnings: [String] = []
    public var blockedModules = 0

    public init() {}
}

public enum TodayLogic {
    public static func diskTone(free: UInt64, total: UInt64) -> TodayTone {
        let gb = Double(free) / 1_073_741_824
        let frac = total == 0 ? 1 : Double(free) / Double(total)
        if gb < 10 || frac < 0.05 { return .bad }
        if gb < 30 || frac < 0.15 { return .warn }
        return .good
    }

    public static func batteryTone(percent: Int?, onAC: Bool) -> TodayTone {
        guard let p = percent else { return .neutral }
        if onAC { return .good }
        if p <= 10 { return .bad }
        if p <= 20 { return .warn }
        return .good
    }

    public static func vpnTone(_ s: VpnState) -> TodayTone {
        switch s.tone {
        case .green: .good
        case .yellow: .warn
        case .red: .bad
        case .grey: .neutral
        }
    }

    public static func attention(_ x: TodayInput, maxWarnings: Int = 3) -> [TodayAttentionItem] {
        var out: [TodayAttentionItem] = []
        for (n, w) in x.warnings.prefix(maxWarnings).enumerated() {
            out.append(TodayAttentionItem(id: "guard\(n)", text: "Сторож: " + w, section: "guard", tone: .warn))
        }
        if x.warnings.count > maxWarnings {
            out.append(TodayAttentionItem(id: "guardMore", text: "Сторож: ещё \(x.warnings.count - maxWarnings)", section: "guard", tone: .warn))
        }
        if x.vpnEnabled, let s = x.vpnState, vpnTone(s) == .bad || s == .degraded {
            out.append(TodayAttentionItem(id: "vpn", text: "VPN: " + s.title.lowercased(), section: "net", tone: vpnTone(s)))
        }
        if let f = x.diskFreeBytes, let t = x.diskTotalBytes, diskTone(free: f, total: t) != .good {
            let gb = Double(f) / 1_073_741_824
            out.append(TodayAttentionItem(id: "disk", text: "Диск: свободно \(String(format: "%.1f", gb).replacingOccurrences(of: ".", with: ",")) ГБ", section: "storage", tone: diskTone(free: f, total: t)))
        }
        if batteryTone(percent: x.batteryPercent, onAC: x.batteryOnAC) != .good, let p = x.batteryPercent {
            out.append(TodayAttentionItem(id: "battery", text: "Батарея: \(p)%", section: "energy", tone: batteryTone(percent: p, onAC: x.batteryOnAC)))
        }
        if x.blockedModules > 0 {
            out.append(TodayAttentionItem(id: "perm", text: "Не хватает прав для модулей: \(x.blockedModules)", section: "perm", tone: .warn))
        }
        return out
    }
}
