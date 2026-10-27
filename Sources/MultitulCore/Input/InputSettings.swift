import Foundation
import CoreGraphics

public enum ScrollModifierKey: String, CaseIterable, Sendable {
    case shift, option, control, command

    public var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        }
    }

    public var title: String {
        switch self {
        case .shift: "Shift"
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        }
    }

    public var glyph: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }
}

public struct AppExceptionList: Equatable, Sendable {
    public var entries: [String]

    public init(_ entries: [String] = []) { self.entries = Self.clean(entries) }

    public var isEmpty: Bool { entries.isEmpty }

    public func contains(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return entries.contains { e in e.hasSuffix("*") ? bundleID.hasPrefix(String(e.dropLast())) : e == bundleID }
    }

    public mutating func add(_ bundleID: String) { entries = Self.clean(entries + [bundleID]) }

    public mutating func remove(_ bundleID: String) { entries.removeAll { $0 == bundleID } }

    static func clean(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public struct ScrollInverterSettings: Equatable, Sendable {
    public var vertical = true
    public var horizontal = false
    public var exceptions = AppExceptionList()
    public init() {}
    public var isActive: Bool { vertical || horizontal }
}

public struct HorizontalScrollSettings: Equatable, Sendable {
    public var modifier = ScrollModifierKey.shift
    public var exceptions = AppExceptionList()
    public init() {}
}

public struct LinearScrollSettings: Equatable, Sendable {
    public static let linesRange = 1...10
    public static let defaultLines = 3
    public var linesPerNotch = LinearScrollSettings.defaultLines
    public var exceptions = AppExceptionList()
    public init() {}

    public var sanitized: LinearScrollSettings {
        var s = self
        s.linesPerNotch = min(max(linesPerNotch, Self.linesRange.lowerBound), Self.linesRange.upperBound)
        return s
    }
}

public struct SmoothScrollSettings: Equatable, Sendable {
    public static let stepRange = 10...120
    public static let defaultStep = 40
    public static let responseRange = 0...100
    public static let defaultResponse = 65
    public static let coastRange = 0...100
    public static let defaultCoast = 0

    public static let suggestedExceptions: [String] = [
        "org.blenderfoundation.blender", "com.maxon.cinema4d", "com.autodesk.*", "com.adobe.Photoshop", "com.adobe.illustrator",
        "com.bohemiancoding.sketch3", "com.figma.Desktop", "com.seriflabs.*", "com.unity3d.*"
    ]

    public var step = SmoothScrollSettings.defaultStep
    public var response = SmoothScrollSettings.defaultResponse
    public var coast = SmoothScrollSettings.defaultCoast
    public var exceptions = AppExceptionList(SmoothScrollSettings.suggestedExceptions)
    public init() {}

    public var sanitized: SmoothScrollSettings {
        var s = self
        s.step = min(max(step, Self.stepRange.lowerBound), Self.stepRange.upperBound)
        s.response = min(max(response, Self.responseRange.lowerBound), Self.responseRange.upperBound)
        s.coast = min(max(coast, Self.coastRange.lowerBound), Self.coastRange.upperBound)
        return s
    }
}

public struct ClickDebounceSettings: Equatable, Sendable {
    public static let windowRange = 5...120
    public static let defaultWindow = 25
    public var windowMs = ClickDebounceSettings.defaultWindow
    public var left = true
    public var right = true
    public var middle = true
    public init() {}

    public var sanitized: ClickDebounceSettings {
        var s = self
        s.windowMs = min(max(windowMs, Self.windowRange.lowerBound), Self.windowRange.upperBound)
        return s
    }

    public func covers(button: Int64) -> Bool {
        switch button {
        case 0: left
        case 1: right
        case 2: middle
        default: false
        }
    }
}

public struct KeyDebounceSettings: Equatable, Sendable {
    public static let windowRange = 0...500
    public static let defaultWindow = 30
    public var globalWindowMs = KeyDebounceSettings.defaultWindow
    public var keyWindows: [Int64: Int] = [:]
    public var ignoredApps = AppExceptionList()
    public init() {}

    public var sanitized: KeyDebounceSettings {
        var s = self
        s.globalWindowMs = Self.clamp(globalWindowMs)
        s.keyWindows = keyWindows.mapValues(Self.clamp)
        return s
    }

    static func clamp(_ v: Int) -> Int { min(max(v, windowRange.lowerBound), windowRange.upperBound) }

    public func windowMs(for keyCode: Int64) -> Int { keyWindows[keyCode] ?? globalWindowMs }

    public static func encode(_ windows: [Int64: Int]) -> String {
        windows.sorted { $0.key < $1.key }.map { "\($0.key):\(clamp($0.value))" }.joined(separator: ",")
    }

    public static func decode(_ raw: String) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for part in raw.split(separator: ",") {
            let p = part.split(separator: ":")
            guard p.count == 2, let k = Int64(p[0]), let v = Int(p[1]) else { continue }
            out[k] = clamp(v)
        }
        return out
    }
}

public struct FocusFollowsSettings: Equatable, Sendable {
    public static let delayRange = 100...3000
    public static let defaultDelay = 250
    public var delayMs = FocusFollowsSettings.defaultDelay
    public var raise = true
    public var waitForStop = true
    public var exceptions = AppExceptionList()
    public init() {}

    public var sanitized: FocusFollowsSettings {
        var s = self
        s.delayMs = min(max(delayMs, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        return s
    }
}

public struct MouseAccelerationSettings: Equatable, Sendable {
    public var disabled = true
    public init() {}
}

public final class InputSettingsStore {
    let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    func bool(_ key: String, _ d: Bool) -> Bool { (defaults.object(forKey: key) as? Bool) ?? d }
    func int(_ key: String, _ d: Int) -> Int { (defaults.object(forKey: key) as? Int) ?? d }

    func list(_ key: String, _ d: AppExceptionList) -> AppExceptionList {
        guard let a = defaults.array(forKey: key) as? [String] else { return d }
        return AppExceptionList(a)
    }

    func putList(_ key: String, _ l: AppExceptionList, _ d: AppExceptionList) {
        if l == d { defaults.removeObject(forKey: key) } else { defaults.set(l.entries, forKey: key) }
    }

    public func loadInverter() -> ScrollInverterSettings {
        var s = ScrollInverterSettings()
        s.vertical = bool("input.inverter.vertical", s.vertical)
        s.horizontal = bool("input.inverter.horizontal", s.horizontal)
        s.exceptions = list("input.inverter.exceptions", s.exceptions)
        return s
    }

    public func saveInverter(_ s: ScrollInverterSettings) {
        let b = ScrollInverterSettings()
        put("input.inverter.vertical", s.vertical, b.vertical)
        put("input.inverter.horizontal", s.horizontal, b.horizontal)
        putList("input.inverter.exceptions", s.exceptions, b.exceptions)
    }

    public func loadHorizontal() -> HorizontalScrollSettings {
        var s = HorizontalScrollSettings()
        if let v = defaults.string(forKey: "input.horizontal.modifier"), let m = ScrollModifierKey(rawValue: v) { s.modifier = m }
        s.exceptions = list("input.horizontal.exceptions", s.exceptions)
        return s
    }

    public func saveHorizontal(_ s: HorizontalScrollSettings) {
        let b = HorizontalScrollSettings()
        put("input.horizontal.modifier", s.modifier.rawValue, b.modifier.rawValue)
        putList("input.horizontal.exceptions", s.exceptions, b.exceptions)
    }

    public func loadLinear() -> LinearScrollSettings {
        var s = LinearScrollSettings()
        s.linesPerNotch = int("input.linear.lines", s.linesPerNotch)
        s.exceptions = list("input.linear.exceptions", s.exceptions)
        return s.sanitized
    }

    public func saveLinear(_ settings: LinearScrollSettings) {
        let s = settings.sanitized
        let b = LinearScrollSettings()
        put("input.linear.lines", s.linesPerNotch, b.linesPerNotch)
        putList("input.linear.exceptions", s.exceptions, b.exceptions)
    }

    public func loadSmooth() -> SmoothScrollSettings {
        var s = SmoothScrollSettings()
        s.step = int("input.smooth.step", s.step)
        s.response = int("input.smooth.response", s.response)
        s.coast = int("input.smooth.coast", s.coast)
        s.exceptions = list("input.smooth.exceptions", s.exceptions)
        return s.sanitized
    }

    public func saveSmooth(_ settings: SmoothScrollSettings) {
        let s = settings.sanitized
        let b = SmoothScrollSettings()
        put("input.smooth.step", s.step, b.step)
        put("input.smooth.response", s.response, b.response)
        put("input.smooth.coast", s.coast, b.coast)
        putList("input.smooth.exceptions", s.exceptions, b.exceptions)
    }

    public func loadClick() -> ClickDebounceSettings {
        var s = ClickDebounceSettings()
        s.windowMs = int("input.click.windowMs", s.windowMs)
        s.left = bool("input.click.left", s.left)
        s.right = bool("input.click.right", s.right)
        s.middle = bool("input.click.middle", s.middle)
        return s.sanitized
    }

    public func saveClick(_ settings: ClickDebounceSettings) {
        let s = settings.sanitized
        let b = ClickDebounceSettings()
        put("input.click.windowMs", s.windowMs, b.windowMs)
        put("input.click.left", s.left, b.left)
        put("input.click.right", s.right, b.right)
        put("input.click.middle", s.middle, b.middle)
    }

    public func loadKeys() -> KeyDebounceSettings {
        var s = KeyDebounceSettings()
        s.globalWindowMs = int("input.keys.windowMs", s.globalWindowMs)
        s.keyWindows = KeyDebounceSettings.decode(defaults.string(forKey: "input.keys.perKey") ?? "")
        s.ignoredApps = list("input.keys.ignoredApps", s.ignoredApps)
        return s.sanitized
    }

    public func saveKeys(_ settings: KeyDebounceSettings) {
        let s = settings.sanitized
        let b = KeyDebounceSettings()
        put("input.keys.windowMs", s.globalWindowMs, b.globalWindowMs)
        if s.keyWindows.isEmpty { defaults.removeObject(forKey: "input.keys.perKey") } else { defaults.set(KeyDebounceSettings.encode(s.keyWindows), forKey: "input.keys.perKey") }
        putList("input.keys.ignoredApps", s.ignoredApps, b.ignoredApps)
    }

    public func loadFocus() -> FocusFollowsSettings {
        var s = FocusFollowsSettings()
        s.delayMs = int("input.focus.delayMs", s.delayMs)
        s.raise = bool("input.focus.raise", s.raise)
        s.waitForStop = bool("input.focus.waitForStop", s.waitForStop)
        s.exceptions = list("input.focus.exceptions", s.exceptions)
        return s.sanitized
    }

    public func saveFocus(_ settings: FocusFollowsSettings) {
        let s = settings.sanitized
        let b = FocusFollowsSettings()
        put("input.focus.delayMs", s.delayMs, b.delayMs)
        put("input.focus.raise", s.raise, b.raise)
        put("input.focus.waitForStop", s.waitForStop, b.waitForStop)
        putList("input.focus.exceptions", s.exceptions, b.exceptions)
    }
}
