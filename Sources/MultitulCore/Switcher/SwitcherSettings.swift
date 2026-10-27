import Foundation
import CoreGraphics

public enum SwitcherLayout: String, CaseIterable, Sendable {
    case windows, icons, simple

    public var title: String {
        switch self {
        case .windows: "Окна с превью"
        case .icons: "Значки приложений"
        case .simple: "Простой список"
        }
    }

    public var needsScreenRecording: Bool { self == .windows }
}

public enum MinimizedPlacement: String, CaseIterable, Sendable {
    case normal, end, hidden

    public var title: String {
        switch self {
        case .normal: "Как обычные"
        case .end: "В конце списка"
        case .hidden: "Не показывать"
        }
    }
}

public enum SwitcherScreenPlacement: String, CaseIterable, Sendable {
    case pointer, menuBar, activeWindow

    public var title: String {
        switch self {
        case .pointer: "Где курсор"
        case .menuBar: "Где строка меню"
        case .activeWindow: "Где активное окно"
        }
    }
}

public enum WindowlessApps: String, CaseIterable, Sendable {
    case off, finder, all

    public var title: String {
        switch self {
        case .off: "Не показывать"
        case .finder: "Только Finder"
        case .all: "Все приложения"
        }
    }
}

public enum AppRuleBehavior: String, CaseIterable, Sendable {
    case showWithoutWindows, windowsOnly, hidden

    public var title: String {
        switch self {
        case .showWithoutWindows: "Показывать и без окон"
        case .windowsOnly: "Только с окнами"
        case .hidden: "Никогда не показывать"
        }
    }
}

public enum PreviewSize: String, CaseIterable, Sendable {
    case small, normal, large, xlarge

    public var title: String {
        switch self {
        case .small: "Мелкие"
        case .normal: "Обычные"
        case .large: "Крупные"
        case .xlarge: "Огромные"
        }
    }

    public var thumbWidth: CGFloat {
        switch self {
        case .small: 150
        case .normal: 200
        case .large: 250
        case .xlarge: 300
        }
    }
}

public enum DockPreviewOrder: String, CaseIterable, Sendable {
    case lastUse, creation

    public var title: String {
        switch self {
        case .lastUse: "По последнему использованию"
        case .creation: "По порядку создания"
        }
    }
}

public struct AppRules: Equatable, Sendable {
    public private(set) var map: [String: AppRuleBehavior]

    public init(_ map: [String: AppRuleBehavior] = [:]) { self.map = map }

    public subscript(bundleID: String?) -> AppRuleBehavior? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let exact = map[bundleID] { return exact }
        for (k, v) in map where k.hasSuffix("*") && bundleID.hasPrefix(String(k.dropLast())) { return v }
        return nil
    }

    public var isEmpty: Bool { map.isEmpty }
    public var sortedKeys: [String] { map.keys.sorted() }

    public mutating func set(_ bundleID: String, _ behavior: AppRuleBehavior?) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        map[id] = behavior
    }

    public var stored: [String] { sortedKeys.compactMap { k in map[k].map { "\(k)|\($0.rawValue)" } } }

    public init(stored: [String]) {
        var m: [String: AppRuleBehavior] = [:]
        for line in stored {
            let p = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2, !p[0].isEmpty, let b = AppRuleBehavior(rawValue: p[1]) else { continue }
            m[p[0]] = b
        }
        self.map = m
    }
}

public struct SwitchFilter: Equatable, Sendable {
    public var currentSpaceOnly = false
    public var currentDisplayOnly = false
    public var showFullscreen = true
    public var minimized = MinimizedPlacement.normal
    public var hiddenLikeMinimized = false
    public var mergeWindows = false
    public var windowless = WindowlessApps.all
    public var rules = AppRules()
    public var previewExcluded = AppExceptionList()
    public var ownPID: Int32 = 0
    public var minSide: CGFloat = 40
    public init() {}
}

public struct SwitcherSettings: Equatable, Sendable {
    public static let delayRange = 0...1000
    public static let defaultDelay = 100
    public static let columnsRange = 2...10
    public static let systemAppsTrigger = KeyCombo(keyCode: Keys.tab, modifiers: KeyCombo.cmd)
    public static let systemWindowsTrigger = KeyCombo(keyCode: Keys.backtick, modifiers: KeyCombo.cmd)
    public static let customAppsTrigger = KeyCombo(keyCode: Keys.tab, modifiers: KeyCombo.opt)
    public static let customWindowsTrigger = KeyCombo(keyCode: Keys.backtick, modifiers: KeyCombo.opt)

    public var layout = SwitcherLayout.windows
    public var takeOverSystem = true
    public var appsTrigger = SwitcherSettings.customAppsTrigger
    public var windowsTrigger = SwitcherSettings.customWindowsTrigger
    public var appearanceDelayMs = SwitcherSettings.defaultDelay
    public var maxColumns = 0
    public var instantSelection = false
    public var searchPin = true
    public var showShortcutHints = true
    public var mergeWindows = false
    public var showFullscreen = true
    public var minimized = MinimizedPlacement.normal
    public var hiddenLikeMinimized = false
    public var screenPlacement = SwitcherScreenPlacement.pointer
    public var currentDisplayOnly = false
    public var currentSpaceOnly = false
    public var windowless = WindowlessApps.all
    public var rules = AppRules()
    public var previewSize = PreviewSize.normal
    public var minimalPreviews = false
    public var previewExcluded = AppExceptionList()
    public init() {}

    public var effectiveAppsTrigger: KeyCombo { takeOverSystem ? Self.systemAppsTrigger : appsTrigger }
    public var effectiveWindowsTrigger: KeyCombo { takeOverSystem ? Self.systemWindowsTrigger : windowsTrigger }
    public var effectiveWindowless: WindowlessApps { takeOverSystem ? .all : windowless }

    public static func isUsableTrigger(_ c: KeyCombo) -> Bool {
        !c.isNone && c.modifiers & (KeyCombo.cmd | KeyCombo.opt | KeyCombo.ctrl) != 0 && c.keyCode != Keys.escape
    }

    public var sanitized: SwitcherSettings {
        var s = self
        s.appearanceDelayMs = min(max(appearanceDelayMs, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        s.maxColumns = maxColumns <= 0 ? 0 : min(max(maxColumns, Self.columnsRange.lowerBound), Self.columnsRange.upperBound)
        if !Self.isUsableTrigger(s.appsTrigger) { s.appsTrigger = Self.customAppsTrigger }
        if !Self.isUsableTrigger(s.windowsTrigger) { s.windowsTrigger = Self.customWindowsTrigger }
        if s.appsTrigger == s.windowsTrigger { s.windowsTrigger = Self.customWindowsTrigger; s.appsTrigger = Self.customAppsTrigger }
        return s
    }

    public func filter(ownPID: Int32) -> SwitchFilter {
        var f = SwitchFilter()
        f.currentSpaceOnly = currentSpaceOnly
        f.currentDisplayOnly = currentDisplayOnly
        f.showFullscreen = showFullscreen
        f.minimized = minimized
        f.hiddenLikeMinimized = hiddenLikeMinimized
        f.mergeWindows = mergeWindows || layout == .icons
        f.windowless = effectiveWindowless
        f.rules = rules
        f.previewExcluded = previewExcluded
        f.ownPID = ownPID
        return f
    }

    public var reservedCombos: [KeyCombo] { [effectiveAppsTrigger, effectiveWindowsTrigger] }
}

public struct DockPreviewSettings: Equatable, Sendable {
    public static let openDelayRange = 0...1500
    public static let defaultOpenDelay = 250
    public static let closeDelayRange = 100...1000
    public static let defaultCloseDelay = 300
    public static let opacityRange = 30...100
    public static let defaultOpacity = 90

    public var openDelayMs = DockPreviewSettings.defaultOpenDelay
    public var closeDelayMs = DockPreviewSettings.defaultCloseDelay
    public var opacityPercent = DockPreviewSettings.defaultOpacity
    public var currentSpaceOnly = false
    public var order = DockPreviewOrder.lastUse
    public var quitAppOnClose = false
    public var middleClickCloses = true
    public var showMinimized = true
    public var showTitles = true
    public var previewSize = PreviewSize.normal
    public var minimalPreviews = false
    public var exceptions = AppExceptionList()
    public var previewExcluded = AppExceptionList()
    public init() {}

    public var sanitized: DockPreviewSettings {
        var s = self
        s.openDelayMs = min(max(openDelayMs, Self.openDelayRange.lowerBound), Self.openDelayRange.upperBound)
        s.closeDelayMs = min(max(closeDelayMs, Self.closeDelayRange.lowerBound), Self.closeDelayRange.upperBound)
        s.opacityPercent = min(max(opacityPercent, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        return s
    }

    public var opacity: Double { Double(sanitized.opacityPercent) / 100 }

    public func filter(ownPID: Int32) -> SwitchFilter {
        var f = SwitchFilter()
        f.currentSpaceOnly = currentSpaceOnly
        f.showFullscreen = true
        f.minimized = showMinimized ? .normal : .hidden
        f.windowless = .off
        f.previewExcluded = previewExcluded
        f.ownPID = ownPID
        return f
    }
}

public final class SwitcherSettingsStore {
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    private func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
        if v == d { kv.removeObject(forKey: key) } else { kv.set(v, forKey: key) }
    }

    private func bool(_ key: String, _ d: Bool) -> Bool { (kv.object(forKey: key) as? Bool) ?? d }
    private func int(_ key: String, _ d: Int) -> Int { (kv.object(forKey: key) as? Int) ?? d }
    private func string(_ key: String) -> String? { kv.object(forKey: key) as? String }
    private func raw<T: RawRepresentable>(_ key: String, _ d: T) -> T where T.RawValue == String { string(key).flatMap(T.init(rawValue:)) ?? d }
    private func combo(_ key: String, _ d: KeyCombo) -> KeyCombo { string(key).flatMap(KeyCombo.init(stored:)) ?? d }
    private func list(_ key: String) -> AppExceptionList { AppExceptionList((kv.object(forKey: key) as? [String]) ?? []) }

    private func putList(_ key: String, _ l: AppExceptionList) {
        if l.isEmpty { kv.removeObject(forKey: key) } else { kv.set(l.entries, forKey: key) }
    }

    public func loadSwitcher() -> SwitcherSettings {
        var s = SwitcherSettings()
        let p = "windowSwitcher."
        s.layout = raw(p + "layout", s.layout)
        s.takeOverSystem = bool(p + "takeOver", s.takeOverSystem)
        s.appsTrigger = combo(p + "appsTrigger", s.appsTrigger)
        s.windowsTrigger = combo(p + "windowsTrigger", s.windowsTrigger)
        s.appearanceDelayMs = int(p + "delayMs", s.appearanceDelayMs)
        s.maxColumns = int(p + "maxColumns", s.maxColumns)
        s.instantSelection = bool(p + "instant", s.instantSelection)
        s.searchPin = bool(p + "searchPin", s.searchPin)
        s.showShortcutHints = bool(p + "hints", s.showShortcutHints)
        s.mergeWindows = bool(p + "merge", s.mergeWindows)
        s.showFullscreen = bool(p + "fullscreen", s.showFullscreen)
        s.minimized = raw(p + "minimized", s.minimized)
        s.hiddenLikeMinimized = bool(p + "hiddenLikeMinimized", s.hiddenLikeMinimized)
        s.screenPlacement = raw(p + "screen", s.screenPlacement)
        s.currentDisplayOnly = bool(p + "displayOnly", s.currentDisplayOnly)
        s.currentSpaceOnly = bool(p + "spaceOnly", s.currentSpaceOnly)
        s.windowless = raw(p + "windowless", s.windowless)
        s.rules = AppRules(stored: (kv.object(forKey: p + "rules") as? [String]) ?? [])
        s.previewSize = raw(p + "previewSize", s.previewSize)
        s.minimalPreviews = bool(p + "minimal", s.minimalPreviews)
        s.previewExcluded = list(p + "previewExcluded")
        return s.sanitized
    }

    public func saveSwitcher(_ settings: SwitcherSettings) {
        let s = settings.sanitized
        let b = SwitcherSettings()
        let p = "windowSwitcher."
        put(p + "layout", s.layout.rawValue, b.layout.rawValue)
        put(p + "takeOver", s.takeOverSystem, b.takeOverSystem)
        put(p + "appsTrigger", s.appsTrigger.stored, b.appsTrigger.stored)
        put(p + "windowsTrigger", s.windowsTrigger.stored, b.windowsTrigger.stored)
        put(p + "delayMs", s.appearanceDelayMs, b.appearanceDelayMs)
        put(p + "maxColumns", s.maxColumns, b.maxColumns)
        put(p + "instant", s.instantSelection, b.instantSelection)
        put(p + "searchPin", s.searchPin, b.searchPin)
        put(p + "hints", s.showShortcutHints, b.showShortcutHints)
        put(p + "merge", s.mergeWindows, b.mergeWindows)
        put(p + "fullscreen", s.showFullscreen, b.showFullscreen)
        put(p + "minimized", s.minimized.rawValue, b.minimized.rawValue)
        put(p + "hiddenLikeMinimized", s.hiddenLikeMinimized, b.hiddenLikeMinimized)
        put(p + "screen", s.screenPlacement.rawValue, b.screenPlacement.rawValue)
        put(p + "displayOnly", s.currentDisplayOnly, b.currentDisplayOnly)
        put(p + "spaceOnly", s.currentSpaceOnly, b.currentSpaceOnly)
        put(p + "windowless", s.windowless.rawValue, b.windowless.rawValue)
        if s.rules.isEmpty { kv.removeObject(forKey: p + "rules") } else { kv.set(s.rules.stored, forKey: p + "rules") }
        put(p + "previewSize", s.previewSize.rawValue, b.previewSize.rawValue)
        put(p + "minimal", s.minimalPreviews, b.minimalPreviews)
        putList(p + "previewExcluded", s.previewExcluded)
    }

    public func loadDockPreview() -> DockPreviewSettings {
        var s = DockPreviewSettings()
        let p = "dockPreview."
        s.openDelayMs = int(p + "openDelayMs", s.openDelayMs)
        s.closeDelayMs = int(p + "closeDelayMs", s.closeDelayMs)
        s.opacityPercent = int(p + "opacity", s.opacityPercent)
        s.currentSpaceOnly = bool(p + "spaceOnly", s.currentSpaceOnly)
        s.order = raw(p + "order", s.order)
        s.quitAppOnClose = bool(p + "quitOnClose", s.quitAppOnClose)
        s.middleClickCloses = bool(p + "middleClick", s.middleClickCloses)
        s.showMinimized = bool(p + "showMinimized", s.showMinimized)
        s.showTitles = bool(p + "titles", s.showTitles)
        s.previewSize = raw(p + "previewSize", s.previewSize)
        s.minimalPreviews = bool(p + "minimal", s.minimalPreviews)
        s.exceptions = list(p + "exceptions")
        s.previewExcluded = list(p + "previewExcluded")
        return s.sanitized
    }

    public func saveDockPreview(_ settings: DockPreviewSettings) {
        let s = settings.sanitized
        let b = DockPreviewSettings()
        let p = "dockPreview."
        put(p + "openDelayMs", s.openDelayMs, b.openDelayMs)
        put(p + "closeDelayMs", s.closeDelayMs, b.closeDelayMs)
        put(p + "opacity", s.opacityPercent, b.opacityPercent)
        put(p + "spaceOnly", s.currentSpaceOnly, b.currentSpaceOnly)
        put(p + "order", s.order.rawValue, b.order.rawValue)
        put(p + "quitOnClose", s.quitAppOnClose, b.quitAppOnClose)
        put(p + "middleClick", s.middleClickCloses, b.middleClickCloses)
        put(p + "showMinimized", s.showMinimized, b.showMinimized)
        put(p + "titles", s.showTitles, b.showTitles)
        put(p + "previewSize", s.previewSize.rawValue, b.previewSize.rawValue)
        put(p + "minimal", s.minimalPreviews, b.minimalPreviews)
        putList(p + "exceptions", s.exceptions)
        putList(p + "previewExcluded", s.previewExcluded)
    }
}
