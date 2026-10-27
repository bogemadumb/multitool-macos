import Foundation

public protocol IslLevelsDriving: AnyObject {
    func outputVolume() -> Float?
    func setOutputVolume(_ value: Float) -> Bool
    func isMuted() -> Bool?
    func setMuted(_ on: Bool) -> Bool
}

public enum IslLevelsMath {
    public static let step = 1.0 / 16
    public static let fineStep = 1.0 / 64

    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    public static func stepped(_ v: Double, up: Bool, fine: Bool) -> Double {
        let s = fine ? fineStep : step
        let n = clamp(v) / s
        let aligned = abs(n - n.rounded()) < 1e-6
        let base = aligned ? n.rounded() : (up ? floor(n) : ceil(n))
        return clamp((base + (up ? 1 : -1)) * s)
    }

    public static func percent(_ v: Double) -> Int { Int((clamp(v) * 100).rounded()) }

    public static func volumeSymbol(_ v: Double, muted: Bool) -> String {
        if muted || v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    public static func brightnessSymbol(_ v: Double) -> String { v < 0.35 ? "sun.min.fill" : "sun.max.fill" }

    public static func hudActivity(kind: String, section: IslSectionID, value: Double, now: Date, lifetime: TimeInterval = 1.6) -> IslActivity {
        IslActivity(id: "hud." + kind, section: section, priority: IslPriority.levelsHud, startedAt: now, expiresAt: now.addingTimeInterval(lifetime),
                    peeks: false, token: String(percent(value)), title: "\(percent(value))%")
    }
}

public struct IslLevelsChangeFilter: Sendable {
    private var last: Double?
    private var suppressUntil = Date.distantPast
    public var epsilon = 0.004

    public init() {}

    public mutating func noteLocalChange(until: Date) { suppressUntil = until }

    public mutating func externalChange(_ v: Double, now: Date) -> Bool {
        defer { last = v }
        guard let l = last else { return false }
        guard now >= suppressUntil else { return false }
        return abs(l - v) > epsilon
    }

    public mutating func reset() { last = nil }
}

public enum IslStatsFormat {
    public static func line(cpu: Double?, memoryUsed: Double?, down: Double?, up: Double?) -> String {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(SysFormat.percent(cpu))%") }
        if let memoryUsed { parts.append("RAM \(SysFormat.percent(memoryUsed))%") }
        if let down { parts.append("↓ \(SysFormat.rateShort(down))") }
        if let up { parts.append("↑ \(SysFormat.rateShort(up))") }
        return parts.joined(separator: "  ")
    }

    public static func batteryText(percent: Int?, charging: Bool, onAC: Bool, minutes: Int?) -> String {
        guard let percent else { return "Нет батареи" }
        var s = "\(percent)%"
        if charging { s += ", заряжается" } else if onAC { s += ", от сети" }
        if let minutes, minutes > 0, !onAC { s += ", ещё \(SysFormat.minutes(minutes))" }
        return s
    }
}

public enum IslTimeFormat {
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(max(seconds, 0).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func remaining(_ seconds: TimeInterval) -> String { "−" + clock(seconds) }
}
