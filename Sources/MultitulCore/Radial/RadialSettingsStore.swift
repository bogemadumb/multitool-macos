import Foundation

public final class RadialSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    struct ItemDTO: Codable, Equatable {
        var id: String
        var title: String
        var symbol: String
        var kind: String
        var value: String
        var children: [ItemDTO]?
    }

    struct ProfileDTO: Codable, Equatable {
        var id: String
        var name: String
        var items: [ItemDTO]
        var bundleIDs: [String]
    }

    static func dto(_ i: RadialItem) -> ItemDTO {
        switch i.action {
        case .target(let t): return ItemDTO(id: i.id, title: i.title, symbol: i.symbol, kind: "target", value: t.stored, children: nil)
        case .file(let p): return ItemDTO(id: i.id, title: i.title, symbol: i.symbol, kind: "file", value: p, children: nil)
        case .keys(let k): return ItemDTO(id: i.id, title: i.title, symbol: i.symbol, kind: "keys", value: k.stored, children: nil)
        case .submenu(let c): return ItemDTO(id: i.id, title: i.title, symbol: i.symbol, kind: "submenu", value: "", children: c.map(dto))
        }
    }

    static func item(_ d: ItemDTO) -> RadialItem? {
        switch d.kind {
        case "target": return LauncherTarget(stored: d.value).map { RadialItem(id: d.id, title: d.title, symbol: d.symbol, action: .target($0)) }
        case "file": return d.value.isEmpty ? nil : RadialItem(id: d.id, title: d.title, symbol: d.symbol, action: .file(d.value))
        case "keys": return KeyCombo(stored: d.value).map { RadialItem(id: d.id, title: d.title, symbol: d.symbol, action: .keys($0)) }
        case "submenu": return RadialItem(id: d.id, title: d.title, symbol: d.symbol, action: .submenu((d.children ?? []).compactMap(item)))
        default: return nil
        }
    }

    public static func encode(_ profiles: [RadialProfile]) -> String? {
        let dtos = profiles.map { ProfileDTO(id: $0.id, name: $0.name, items: $0.items.map(dto), bundleIDs: $0.bundleIDs) }
        guard let d = try? JSONEncoder().encode(dtos) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func decode(_ json: String) -> [RadialProfile]? {
        guard let d = json.data(using: .utf8), let dtos = try? JSONDecoder().decode([ProfileDTO].self, from: d) else { return nil }
        return dtos.map { RadialProfile(id: $0.id, name: $0.name, items: $0.items.compactMap(item), bundleIDs: $0.bundleIDs) }
    }

    public func load() -> RadialSettings {
        var s = RadialSettings()
        let p = "radialMenu."
        if let json = a.string(p + "profiles"), let profiles = Self.decode(json), !profiles.isEmpty { s.profiles = profiles }
        s.activeProfileID = a.string(p + "activeProfile") ?? s.profiles[0].id
        s.trigger.hotkeyEnabled = a.bool(p + "hotkeyEnabled", s.trigger.hotkeyEnabled)
        if let raw = a.string(p + "hotkey"), let k = KeyCombo(stored: raw) { s.trigger.hotkey = k }
        if let b = a.kv.object(forKey: p + "mouseButton") as? Int { s.trigger.mouseButton = b }
        s.trigger.fourFingerTap = a.bool(p + "fourFingerTap", s.trigger.fourFingerTap)
        s.stickyMs = a.int(p + "stickyMs", s.stickyMs)
        s.innerRadius = a.double(p + "innerRadius", s.innerRadius)
        s.ringRadius = a.double(p + "ringRadius", s.ringRadius)
        s.showTitles = a.bool(p + "showTitles", s.showTitles)
        s.switchByApp = a.bool(p + "switchByApp", s.switchByApp)
        return s.sanitized
    }

    public func save(_ settings: RadialSettings) {
        let s = settings.sanitized
        let b = RadialSettings()
        let p = "radialMenu."
        if s.profiles == b.profiles { a.kv.removeObject(forKey: p + "profiles") }
        else if let j = Self.encode(s.profiles) { a.kv.set(j, forKey: p + "profiles") }
        a.put(p + "activeProfile", s.activeProfileID, b.activeProfileID)
        a.put(p + "hotkeyEnabled", s.trigger.hotkeyEnabled, b.trigger.hotkeyEnabled)
        if s.trigger.hotkey == b.trigger.hotkey { a.kv.removeObject(forKey: p + "hotkey") } else { a.kv.set(s.trigger.hotkey.stored, forKey: p + "hotkey") }
        if let m = s.trigger.mouseButton { a.kv.set(m, forKey: p + "mouseButton") } else { a.kv.removeObject(forKey: p + "mouseButton") }
        a.put(p + "fourFingerTap", s.trigger.fourFingerTap, b.trigger.fourFingerTap)
        a.put(p + "stickyMs", s.stickyMs, b.stickyMs)
        a.put(p + "innerRadius", s.innerRadius, b.innerRadius)
        a.put(p + "ringRadius", s.ringRadius, b.ringRadius)
        a.put(p + "showTitles", s.showTitles, b.showTitles)
        a.put(p + "switchByApp", s.switchByApp, b.switchByApp)
    }
}
