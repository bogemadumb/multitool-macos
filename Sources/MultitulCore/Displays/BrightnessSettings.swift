import Foundation

public struct BrightnessSettings: Equatable, Sendable {
    public var followCursor = true
    public var interceptKeys = false
    public var fineAlways = false
    public var showOSD = true
    public var keyboardKeys = true
    public var softwareFloorPercent = 8

    public init() {}

    public var softwareFloor: Double { Double(min(max(softwareFloorPercent, 0), 50)) / 100 }
}

public enum BrightnessHotkeys {
    public static let displayDown = HotkeySpec(id: "brightness.displayDown", title: "Яркость экрана: меньше", defaultCombo: .none)
    public static let displayUp = HotkeySpec(id: "brightness.displayUp", title: "Яркость экрана: больше", defaultCombo: .none)
    public static let keyboardDown = HotkeySpec(id: "brightness.keyboardDown", title: "Подсветка клавиатуры: меньше", defaultCombo: .none)
    public static let keyboardUp = HotkeySpec(id: "brightness.keyboardUp", title: "Подсветка клавиатуры: больше", defaultCombo: .none)
    public static let all = [displayDown, displayUp, keyboardDown, keyboardUp]
}

public final class BrightnessStore {
    static let followKey = "brightness.followCursor"
    static let interceptKey = "brightness.interceptKeys"
    static let fineKey = "brightness.fineAlways"
    static let osdKey = "brightness.osd"
    static let keyboardKeysKey = "brightness.keyboardKeys"
    static let floorKey = "brightness.softwareFloor"
    static let keyboardLastKey = "brightness.keyboard.last"
    static let prefix = "brightness."

    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func loadSettings() -> BrightnessSettings {
        var s = BrightnessSettings()
        if let v = defaults.object(forKey: Self.followKey) as? Bool { s.followCursor = v }
        if let v = defaults.object(forKey: Self.interceptKey) as? Bool { s.interceptKeys = v }
        if let v = defaults.object(forKey: Self.fineKey) as? Bool { s.fineAlways = v }
        if let v = defaults.object(forKey: Self.osdKey) as? Bool { s.showOSD = v }
        if let v = defaults.object(forKey: Self.keyboardKeysKey) as? Bool { s.keyboardKeys = v }
        if let v = defaults.object(forKey: Self.floorKey) as? Int { s.softwareFloorPercent = v }
        return s
    }

    public func saveSettings(_ s: BrightnessSettings) {
        let base = BrightnessSettings()
        func put<T: Equatable>(_ key: String, _ v: T, _ d: T) { if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) } }
        put(Self.followKey, s.followCursor, base.followCursor)
        put(Self.interceptKey, s.interceptKeys, base.interceptKeys)
        put(Self.fineKey, s.fineAlways, base.fineAlways)
        put(Self.osdKey, s.showOSD, base.showOSD)
        put(Self.keyboardKeysKey, s.keyboardKeys, base.keyboardKeys)
        put(Self.floorKey, s.softwareFloorPercent, base.softwareFloorPercent)
    }

    static func valueKey(_ id: String) -> String { "brightness.value.\(id)" }
    static func contrastKey(_ id: String) -> String { "brightness.contrast.\(id)" }
    static func softwareKey(_ id: String) -> String { "brightness.forceSoftware.\(id)" }

    public func value(for id: String) -> Double? {
        (defaults.object(forKey: Self.valueKey(id)) as? Double).map(BrightnessStep.clamp)
    }

    public func setValue(_ v: Double, for id: String) { defaults.set(BrightnessStep.clamp(v), forKey: Self.valueKey(id)) }

    public func contrast(for id: String) -> Double? {
        (defaults.object(forKey: Self.contrastKey(id)) as? Double).map(BrightnessStep.clamp)
    }

    public func setContrast(_ v: Double, for id: String) { defaults.set(BrightnessStep.clamp(v), forKey: Self.contrastKey(id)) }

    public func forceSoftware(for id: String) -> Bool { defaults.bool(forKey: Self.softwareKey(id)) }

    public func setForceSoftware(_ on: Bool, for id: String) {
        if on { defaults.set(true, forKey: Self.softwareKey(id)) } else { defaults.removeObject(forKey: Self.softwareKey(id)) }
    }

    public var keyboardLast: Double? {
        get { (defaults.object(forKey: Self.keyboardLastKey) as? Double).map(BrightnessStep.clamp) }
        set { if let v = newValue { defaults.set(BrightnessStep.clamp(v), forKey: Self.keyboardLastKey) } else { defaults.removeObject(forKey: Self.keyboardLastKey) } }
    }

    public func forget(id: String) {
        for k in [Self.valueKey(id), Self.contrastKey(id), Self.softwareKey(id)] { defaults.removeObject(forKey: k) }
    }
}
