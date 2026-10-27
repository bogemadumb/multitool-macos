import Foundation

public final class ShelfSettingsStore {
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    private func bool(_ key: String, _ d: Bool) -> Bool { (defaults.object(forKey: key) as? Bool) ?? d }

    public func load() -> ShelfSettings {
        var s = ShelfSettings()
        s.closeAfterDrop = bool("shelf.closeAfterDrop", s.closeAfterDrop)
        s.deleteAfterDrop = bool("shelf.deleteAfterDrop", s.deleteAfterDrop)
        s.shakeEnabled = bool("shelf.shakeEnabled", s.shakeEnabled)
        if let v = defaults.string(forKey: "shelf.shakeSensitivity"), let x = ShakeSensitivity(rawValue: v) { s.shakeSensitivity = x }
        if let a = defaults.array(forKey: "shelf.excludedApps") as? [String] { s.excludedApps = a }
        s.menuBarIcon = bool("shelf.menuBarIcon", s.menuBarIcon)
        s.menuBarDrop = bool("shelf.menuBarDrop", s.menuBarDrop)
        if let v = defaults.string(forKey: "shelf.placement"), let x = ShelfPlacementMode(rawValue: v) { s.placement = x }
        s.autoHideEmpty = bool("shelf.autoHideEmpty", s.autoHideEmpty)
        return s.sanitized
    }

    public func save(_ settings: ShelfSettings) {
        let s = settings.sanitized
        let b = ShelfSettings()
        put("shelf.closeAfterDrop", s.closeAfterDrop, b.closeAfterDrop)
        put("shelf.deleteAfterDrop", s.deleteAfterDrop, b.deleteAfterDrop)
        put("shelf.shakeEnabled", s.shakeEnabled, b.shakeEnabled)
        put("shelf.shakeSensitivity", s.shakeSensitivity.rawValue, b.shakeSensitivity.rawValue)
        if s.excludedApps == b.excludedApps { defaults.removeObject(forKey: "shelf.excludedApps") } else { defaults.set(s.excludedApps, forKey: "shelf.excludedApps") }
        put("shelf.menuBarIcon", s.menuBarIcon, b.menuBarIcon)
        put("shelf.menuBarDrop", s.menuBarDrop, b.menuBarDrop)
        put("shelf.placement", s.placement.rawValue, b.placement.rawValue)
        put("shelf.autoHideEmpty", s.autoHideEmpty, b.autoHideEmpty)
    }
}
