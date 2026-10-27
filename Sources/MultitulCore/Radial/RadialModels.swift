import CoreGraphics
import Foundation

public indirect enum RadialAction: Equatable, Sendable {
    case target(LauncherTarget)
    case file(String)
    case keys(KeyCombo)
    case submenu([RadialItem])

    public var kindTitle: String {
        switch self {
        case .target(let t): t.kindTitle
        case .file: "Файл или папка"
        case .keys: "Сочетание клавиш"
        case .submenu: "Подменю"
        }
    }
}

public struct RadialItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var action: RadialAction

    public init(id: String = UUID().uuidString, title: String, symbol: String? = nil, action: RadialAction) {
        self.id = id
        self.title = title
        self.action = action
        switch action {
        case .target(let t): self.symbol = symbol ?? t.defaultSymbol
        case .file: self.symbol = symbol ?? "doc"
        case .keys: self.symbol = symbol ?? "keyboard"
        case .submenu: self.symbol = symbol ?? "ellipsis.circle"
        }
    }

    public var isSubmenu: Bool { if case .submenu = action { return true } else { return false } }

    public var children: [RadialItem] { if case .submenu(let c) = action { return c } else { return [] } }

    public var detail: String {
        switch action {
        case .target(let t):
            switch t {
            case .app(let v), .url(let v), .script(let v): return t.kindTitle + " · " + CbText.abbreviatedPath(v)
            default: return t.kindTitle
            }
        case .file(let p): return "Файл · " + CbText.abbreviatedPath(p)
        case .keys(let k): return "Сочетание · " + k.display
        case .submenu(let c): return "Подменю · пунктов: \(c.count)"
        }
    }
}

public struct RadialProfile: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var items: [RadialItem]
    public var bundleIDs: [String]

    public init(id: String = UUID().uuidString, name: String, items: [RadialItem] = [], bundleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.items = items
        self.bundleIDs = bundleIDs
    }
}

public struct RadialTriggerConfig: Equatable, Sendable {
    public static let defaultHotkey = KeyCombo(keyCode: Keys.space, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd)
    public static let buttonChoices = [2, 3, 4, 5, 6]

    public var hotkeyEnabled = true
    public var hotkey = RadialTriggerConfig.defaultHotkey
    public var mouseButton: Int?
    public var fourFingerTap = false

    public init() {}

    public static func buttonTitle(_ n: Int) -> String {
        switch n {
        case 2: "Средняя кнопка"
        case 3: "Боковая «назад»"
        case 4: "Боковая «вперёд»"
        default: "Кнопка \(n + 1)"
        }
    }
}

public struct RadialSettings: Equatable, Sendable {
    public static let maxItems = 12
    public static let maxDepth = 3
    public static let maxProfiles = 8
    public static let stickyRange = 100...1000
    public static let innerRange = 18.0...70.0
    public static let ringRange = 90.0...260.0

    public var profiles: [RadialProfile] = [RadialDefaults.mainProfile]
    public var activeProfileID = RadialDefaults.mainProfile.id
    public var trigger = RadialTriggerConfig()
    public var stickyMs = 250
    public var innerRadius = 34.0
    public var ringRadius = 150.0
    public var showTitles = true
    public var switchByApp = true

    public init() {}

    public var activeProfile: RadialProfile { profiles.first { $0.id == activeProfileID } ?? profiles.first ?? RadialDefaults.mainProfile }

    public func profile(forBundleID id: String?) -> RadialProfile {
        guard switchByApp, let id, let p = profiles.first(where: { $0.bundleIDs.contains(id) }) else { return activeProfile }
        return p
    }

    public var geometry: RadialGeometry {
        var g = RadialGeometry()
        g.innerRadius = innerRadius
        g.outerRadius = ringRadius
        return g
    }

    static func trimmed(_ items: [RadialItem], depth: Int) -> [RadialItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.prefix(maxItems).map { item in
            guard case .submenu(let c) = item.action else { return item }
            var it = item
            it.action = .submenu(depth >= maxDepth ? [] : trimmed(c, depth: depth + 1))
            return it
        }
    }

    public var sanitized: RadialSettings {
        var s = self
        var ids = Set<String>()
        s.profiles = profiles.filter { ids.insert($0.id).inserted }.prefix(Self.maxProfiles).map { p in
            var p = p
            p.items = Self.trimmed(p.items, depth: 1)
            p.name = p.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Профиль" : p.name
            return p
        }
        if s.profiles.isEmpty { s.profiles = [RadialDefaults.mainProfile] }
        if !s.profiles.contains(where: { $0.id == s.activeProfileID }) { s.activeProfileID = s.profiles[0].id }
        s.stickyMs = ToolsClamp.int(stickyMs, Self.stickyRange)
        s.innerRadius = ToolsClamp.double(innerRadius, Self.innerRange)
        s.ringRadius = ToolsClamp.double(max(ringRadius, innerRadius + 50), Self.ringRange)
        if let b = s.trigger.mouseButton, !RadialTriggerConfig.buttonChoices.contains(b) { s.trigger.mouseButton = nil }
        if s.trigger.hotkey.isNone || s.trigger.hotkey.modifiers & (KeyCombo.cmd | KeyCombo.opt | KeyCombo.ctrl) == 0 { s.trigger.hotkey = RadialTriggerConfig.defaultHotkey }
        return s
    }
}

public enum RadialDefaults {
    public static let mainProfile = RadialProfile(id: "main", name: "Основной", items: [
        RadialItem(id: "main-scratchpad", title: "Блокнот", action: .target(.tool(.scratchpad))),
        RadialItem(id: "main-colorPicker", title: "Пипетка", action: .target(.tool(.colorPicker))),
        RadialItem(id: "main-screenOcr", title: "Текст с экрана", action: .target(.tool(.screenOcr))),
        RadialItem(id: "main-darkMode", title: "Тёмная тема", action: .target(.toggle(.darkMode))),
        RadialItem(id: "main-lock", title: "Блокировка", action: .target(.toggle(.lockScreen))),
        RadialItem(id: "main-commandBar", title: "Командная строка", action: .target(.tool(.commandBar))),
        RadialItem(id: "main-mission", title: "Mission Control", symbol: "rectangle.3.group", action: .keys(KeyCombo(keyCode: Keys.up, modifiers: KeyCombo.ctrl))),
        RadialItem(id: "main-expose", title: "Окна приложения", symbol: "square.stack.3d.down.right", action: .keys(KeyCombo(keyCode: Keys.down, modifiers: KeyCombo.ctrl)))
    ])
}

public enum RadialCommand: Equatable, Sendable {
    case launcher(LauncherCommand)
    case openPath(String)
    case keys(KeyCombo)
}

public enum RadialResolver {
    public static func resolve(_ item: RadialItem, fs: LauncherFileChecking) -> Result<RadialCommand, LauncherIssue> {
        switch item.action {
        case .target(let t): return LauncherResolver.command(for: t, fs: fs).map { .launcher($0) }
        case .file(let p):
            let v = p.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return .failure(.emptyValue) }
            guard v.hasPrefix("/") else { return .failure(.scriptNotAbsolute) }
            return fs.fileExists(v) ? .success(.openPath(v)) : .failure(.scriptNotFound)
        case .keys(let k):
            return k.isNone ? .failure(.emptyValue) : .success(.keys(k))
        case .submenu: return .failure(.emptyValue)
        }
    }
}
