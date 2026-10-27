import Foundation

public enum IslAccKind: String, Sendable, CaseIterable {
    case airpods, headphones, speaker, keyboard, mouse, trackpad, gamepad, other

    public var symbol: String {
        switch self {
        case .airpods: "airpodspro"
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gamepad: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    public var title: String {
        switch self {
        case .airpods: "AirPods"
        case .headphones: "Наушники"
        case .speaker: "Колонка"
        case .keyboard: "Клавиатура"
        case .mouse: "Мышь"
        case .trackpad: "Трекпад"
        case .gamepad: "Геймпад"
        case .other: "Устройство"
        }
    }
}

public struct IslAccBattery: Equatable, Sendable {
    public var main: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.main = main
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    public var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }

    // The weakest part that is actually worn or used; the charging case does not count.
    public var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    public var headline: Int? {
        if let m = main { return m }
        let sides = [left, right].compactMap { $0 }
        return sides.min() ?? caseLevel
    }
}

public struct IslAccDevice: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: IslAccKind
    public var connected: Bool
    public var battery: IslAccBattery

    public init(id: String, name: String, kind: IslAccKind = .other, connected: Bool = true, battery: IslAccBattery = IslAccBattery()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connected = connected
        self.battery = battery
    }
}

public protocol IslAccProviding: AnyObject {
    func devices() -> [IslAccDevice]
}

public struct IslAccSettings: Equatable, Sendable {
    public static let thresholdRange = 5...50
    public var lowThreshold = 20
    public var notifyConnect = true
    public var notifyLow = true
    public var showInHeader = true
    public var hiddenDevices = Set<String>()

    public init() {}

    public var sanitized: IslAccSettings {
        var s = self
        s.lowThreshold = ToolsClamp.int(lowThreshold, Self.thresholdRange)
        s.hiddenDevices = hiddenDevices.filter { !$0.isEmpty && $0.count <= 100 }
        return s
    }
}

public final class IslAccSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.accessories."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslAccSettings {
        var s = IslAccSettings()
        let p = Self.prefix
        s.lowThreshold = a.int(p + "lowThreshold", s.lowThreshold)
        s.notifyConnect = a.bool(p + "notifyConnect", s.notifyConnect)
        s.notifyLow = a.bool(p + "notifyLow", s.notifyLow)
        s.showInHeader = a.bool(p + "showInHeader", s.showInHeader)
        s.hiddenDevices = Set(a.strings(p + "hiddenDevices") ?? [])
        return s.sanitized
    }

    public func save(_ settings: IslAccSettings) {
        let s = settings.sanitized
        let b = IslAccSettings()
        let p = Self.prefix
        a.put(p + "lowThreshold", s.lowThreshold, b.lowThreshold)
        a.put(p + "notifyConnect", s.notifyConnect, b.notifyConnect)
        a.put(p + "notifyLow", s.notifyLow, b.notifyLow)
        a.put(p + "showInHeader", s.showInHeader, b.showInHeader)
        if s.hiddenDevices.isEmpty { a.kv.removeObject(forKey: p + "hiddenDevices") } else { a.kv.set(s.hiddenDevices.sorted(), forKey: p + "hiddenDevices") }
    }
}

public enum IslAccParser {
    public static func normalizeAddress(_ s: String) -> String {
        let hex = s.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return s.lowercased().trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(String(hex[i..<j]))
            i = j
        }
        return out.joined(separator: ":")
    }

    // 85, 85.0, "85%", a Double strictly between 0 and 1 is a fraction; anything outside 0...100 is rejected.
    public static func percent(_ any: Any?) -> Int? {
        switch any {
        case let n as Int:
            return (0...100).contains(n) ? n : nil
        case let d as Double:
            if d > 0, d < 1 { return Int((d * 100).rounded()) }
            return (0...100).contains(d) ? Int(d.rounded()) : nil
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let v = Double(t) else { return nil }
            return (0...100).contains(v) ? Int(v.rounded()) : nil
        case let n as NSNumber:
            return percent(n.doubleValue)
        default:
            return nil
        }
    }

    public static func battery(_ d: [String: Any]) -> IslAccBattery {
        func first(_ keys: [String]) -> Int? { keys.lazy.compactMap { percent(d[$0]) }.first }
        return IslAccBattery(main: first(["device_batteryLevelMain", "BatteryPercent", "batteryPercentSingle", "BatteryPercentCombined"]),
                             left: first(["device_batteryLevelLeft", "BatteryPercentLeft", "batteryPercentLeft"]),
                             right: first(["device_batteryLevelRight", "BatteryPercentRight", "batteryPercentRight"]),
                             caseLevel: first(["device_batteryLevelCase", "BatteryPercentCase", "batteryPercentCase"]))
    }

    public static func kind(minorType: String?, name: String, productID: String? = nil) -> IslAccKind {
        let m = (minorType ?? "").lowercased()
        let n = name.lowercased()
        if n.contains("airpods") || n.contains("beats") && m.contains("headphone") { return .airpods }
        switch m {
        case "keyboard": return .keyboard
        case "mouse": return .mouse
        case "trackpad": return .trackpad
        case "gamepad", "game controller", "joystick": return .gamepad
        case "headphones", "headset", "headphone": return .headphones
        case "speaker", "loudspeaker": return .speaker
        default: break
        }
        if n.contains("keyboard") || n.contains("клавиатур") { return .keyboard }
        if n.contains("trackpad") || n.contains("трекпад") { return .trackpad }
        if n.contains("mouse") || n.contains("мыш") { return .mouse }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return .gamepad }
        if n.contains("headphone") || n.contains("buds") || n.contains("наушник") { return .headphones }
        if n.contains("speaker") || n.contains("колонк") || n.contains("homepod") { return .speaker }
        return .other
    }

    public static func fromSystemProfiler(_ data: Data) -> [IslAccDevice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let top = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        var out: [IslAccDevice] = []
        var seen = Set<String>()
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in (top[key] as? [[String: Any]]) ?? [] {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let address = (props["device_address"] as? String).map(normalizeAddress) ?? name.lowercased()
                    guard seen.insert(address).inserted else { continue }
                    let b = connected ? battery(props) : IslAccBattery()
                    out.append(IslAccDevice(id: address, name: name, kind: kind(minorType: props["device_minorType"] as? String, name: name), connected: connected, battery: b))
                }
            }
        }
        return out.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}

public enum IslAccEvent: Equatable, Sendable {
    case connected(IslAccDevice)
    case disconnected(IslAccDevice)
    case lowBattery(IslAccDevice, level: Int)
}

public struct IslAccTracker: Sendable {
    public private(set) var known: [String: IslAccDevice] = [:]
    private var warned = Set<String>()
    private var primed = false
    public var rearmMargin = 5

    public init() {}

    public mutating func update(_ devices: [IslAccDevice], settings: IslAccSettings) -> [IslAccEvent] {
        var events: [IslAccEvent] = []
        var next: [String: IslAccDevice] = [:]
        for d in devices where !settings.hiddenDevices.contains(d.id) { next[d.id] = d }
        if primed {
            for id in next.keys.sorted() {
                guard let d = next[id] else { continue }
                let was = known[id]?.connected ?? false
                if d.connected, !was { events.append(.connected(d)) }
            }
            for id in known.keys.sorted() {
                guard let old = known[id], old.connected else { continue }
                if next[id]?.connected != true { events.append(.disconnected(old)) }
            }
        }
        for id in next.keys.sorted() {
            guard let d = next[id], d.connected, let level = d.battery.lowest else {
                if let d = next[id], !d.connected { warned.remove(id) }
                continue
            }
            if level <= settings.lowThreshold {
                if !warned.contains(id) {
                    warned.insert(id)
                    events.append(.lowBattery(d, level: level))
                }
            } else if level >= settings.lowThreshold + rearmMargin {
                warned.remove(id)
            }
        }
        known = next
        primed = true
        return events
    }

    public mutating func reset() {
        known = [:]
        warned = []
        primed = false
    }
}

public enum IslAccActivityFactory {
    public static let connectLifetime: TimeInterval = 5
    public static let lowLifetime: TimeInterval = 7

    public static func activity(for event: IslAccEvent, now: Date) -> IslActivity? {
        switch event {
        case .connected(let d):
            let level = d.battery.headline.map { " · \($0)%" } ?? ""
            return IslActivity(id: "acc." + d.id, section: IslSectionIDs.accessories, priority: IslPriority.accessory, startedAt: now,
                               expiresAt: now.addingTimeInterval(connectLifetime), peeks: true, token: "conn|\(Int(now.timeIntervalSince1970))", title: d.name + level)
        case .lowBattery(let d, let level):
            return IslActivity(id: "acc.low." + d.id, section: IslSectionIDs.accessories, priority: IslPriority.accessory, startedAt: now,
                               expiresAt: now.addingTimeInterval(lowLifetime), peeks: true, token: "low|\(level)", title: "\(d.name): заряд \(level)%")
        case .disconnected:
            return nil
        }
    }
}

public enum IslAccFormat {
    public static func batteryLine(_ b: IslAccBattery) -> String {
        var parts: [String] = []
        if let m = b.main { parts.append("\(m)%") }
        if let l = b.left { parts.append("Л \(l)%") }
        if let r = b.right { parts.append("П \(r)%") }
        if let c = b.caseLevel { parts.append("кейс \(c)%") }
        return parts.joined(separator: " · ")
    }

    public static func batterySymbol(_ percent: Int?) -> String {
        guard let p = percent else { return "battery.0" }
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
