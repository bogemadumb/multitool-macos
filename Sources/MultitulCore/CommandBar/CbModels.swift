import Foundation

public enum CbProviderID: String, CaseIterable, Identifiable, Sendable {
    case calculator, units, apps, windows, commands, entries, scripts, quicklinks, web, files, clipboard, snippets, menu, emoji, processes, uninstall

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calculator: "Калькулятор"
        case .units: "Единицы и валюты"
        case .apps: "Приложения"
        case .windows: "Окна"
        case .commands: "Команды"
        case .entries: "Мои пункты"
        case .scripts: "Скрипты"
        case .quicklinks: "Быстрые ссылки"
        case .web: "Поиск в сети"
        case .files: "Файлы"
        case .clipboard: "История буфера"
        case .snippets: "Сниппеты"
        case .menu: "Меню приложения"
        case .emoji: "Эмодзи"
        case .processes: "Процессы"
        case .uninstall: "Удаление приложений"
        }
    }

    public var symbol: String {
        switch self {
        case .calculator: "plus.forwardslash.minus"
        case .units: "arrow.left.arrow.right"
        case .apps: "app"
        case .windows: "macwindow"
        case .commands: "command"
        case .entries: "star"
        case .scripts: "terminal"
        case .quicklinks: "link"
        case .web: "magnifyingglass"
        case .files: "doc"
        case .clipboard: "doc.on.clipboard"
        case .snippets: "text.badge.plus"
        case .menu: "filemenu.and.selection"
        case .emoji: "face.smiling"
        case .processes: "xmark.octagon"
        case .uninstall: "trash"
        }
    }

    // Multiplies the match score, so an app beats a file with the same quality of match.
    public var weight: Double {
        switch self {
        case .calculator, .units: 1
        case .apps: 1
        case .commands: 0.95
        case .entries: 0.97
        case .windows: 0.92
        case .scripts: 0.9
        case .quicklinks: 0.9
        case .snippets: 0.8
        case .menu: 0.75
        case .files: 0.7
        case .emoji: 0.7
        case .clipboard: 0.65
        case .processes: 0.6
        case .uninstall: 1
        case .web: 0.1
        }
    }

    public var globalByDefault: Bool {
        switch self {
        case .uninstall: false
        default: true
        }
    }

    // Shortest query that lets this provider join the unprefixed search.
    public var globalMinLength: Int {
        switch self {
        case .files: 3
        case .clipboard: 2
        case .menu: 2
        case .emoji: 3
        case .processes: 3
        case .snippets: 2
        case .windows: 1
        default: 1
        }
    }

    // Slowest providers only answer in the unprefixed search when the match is already good.
    public var globalMinScore: Double {
        switch self {
        case .emoji: 74
        case .processes: 74
        case .menu: 60
        case .clipboard: 45
        case .files: 45
        default: 0
        }
    }
}

public enum CbSystemCommand: String, CaseIterable, Identifiable, Sendable {
    case sleep, restart, shutDown, logOut, systemSettings, activityMonitor, openTrash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sleep: "Сон"
        case .restart: "Перезагрузить Мак"
        case .shutDown: "Выключить Мак"
        case .logOut: "Выйти из учётной записи"
        case .systemSettings: "Системные настройки"
        case .activityMonitor: "Мониторинг системы"
        case .openTrash: "Открыть Корзину"
        }
    }

    public var symbol: String {
        switch self {
        case .sleep: "moon.zzz"
        case .restart: "arrow.clockwise.circle"
        case .shutDown: "power"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .systemSettings: "gearshape"
        case .activityMonitor: "chart.bar"
        case .openTrash: "trash"
        }
    }

    public var keywords: [String] {
        switch self {
        case .sleep: ["sleep", "сон", "спящий режим", "усыпить"]
        case .restart: ["restart", "reboot", "перезагрузка", "перезагрузить"]
        case .shutDown: ["shut down", "shutdown", "power off", "выключить", "выключение"]
        case .logOut: ["log out", "logout", "sign out", "выйти", "выход", "разлогиниться"]
        case .systemSettings: ["system settings", "preferences", "settings", "настройки", "системные настройки"]
        case .activityMonitor: ["activity monitor", "task manager", "мониторинг", "диспетчер задач", "процессы"]
        case .openTrash: ["trash", "bin", "корзина", "открыть корзину"]
        }
    }

    public var needsConfirmation: Bool { self == .restart || self == .shutDown || self == .logOut }
}

public enum CbAction: Equatable, Sendable {
    case openApp(String)
    case focusWindow(key: Int, pid: Int32)
    case openFile(String)
    case revealFile(String)
    case pasteClip(Int64)
    case copyClip(Int64)
    case copyText(String)
    case pasteText(String)
    case menuItem(pid: Int32, path: [String])
    case launcher(LauncherTarget)
    case system(CbSystemCommand)
    case killProcess(pid: Int32, name: String, tree: Bool)
    case quitApp(pid: Int32)
    case uninstallApp(String)
    case snippet(Int64)
    case openSection(String)
    case refreshRates
    case shelfAdd(String)
    case noop

    public var needsConfirmation: Bool {
        switch self {
        case .system(let c): c.needsConfirmation
        case .killProcess: true
        default: false
        }
    }

    public var key: String {
        switch self {
        case .openApp(let p): "openApp:\(p)"
        case .focusWindow(let k, let pid): "focusWindow:\(pid):\(k)"
        case .openFile(let p): "openFile:\(p)"
        case .revealFile(let p): "revealFile:\(p)"
        case .pasteClip(let i): "pasteClip:\(i)"
        case .copyClip(let i): "copyClip:\(i)"
        case .copyText(let t): "copyText:\(t)"
        case .pasteText(let t): "pasteText:\(t)"
        case .menuItem(let pid, let p): "menuItem:\(pid):\(p.joined(separator: "/"))"
        case .launcher(let t): t.stored.hasPrefix("app:") ? "openApp:" + t.stored.dropFirst(4) : "launcher:\(t.stored)"
        case .system(let c): "system:\(c.rawValue)"
        case .killProcess(let pid, _, let tree): "kill:\(pid):\(tree)"
        case .quitApp(let pid): "quit:\(pid)"
        case .uninstallApp(let p): "uninstall:\(p)"
        case .snippet(let i): "snippet:\(i)"
        case .openSection(let s): "section:\(s)"
        case .refreshRates: "refreshRates"
        case .shelfAdd(let p): "shelfAdd:\(p)"
        case .noop: "noop"
        }
    }
}

public struct CbSecondary: Equatable, Sendable {
    public var title: String
    public var symbol: String
    public var action: CbAction

    public init(title: String, symbol: String, action: CbAction) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

public struct CbResult: Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: CbProviderID
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var iconPath: String?
    public var trailing: String
    public var action: CbAction
    public var secondary: [CbSecondary]
    public var frecencyKey: String?
    public var score: Double

    public init(id: String, provider: CbProviderID, title: String, subtitle: String = "", symbol: String? = nil, iconPath: String? = nil, trailing: String = "",
                action: CbAction, secondary: [CbSecondary] = [], frecencyKey: String? = nil, score: Double = 0) {
        self.id = id
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol ?? provider.symbol
        self.iconPath = iconPath
        self.trailing = trailing
        self.action = action
        self.secondary = secondary
        self.frecencyKey = frecencyKey
        self.score = score
    }
}

public struct CbCandidate: Sendable {
    public var result: CbResult
    public var keys: [FuzzyKey]
    public var fixedScore: Double?
    // The provider scored the match itself; the engine still applies the provider weight and frecency like for a fuzzy score.
    public var scoredByProvider = false

    public init(_ result: CbResult, keys: [FuzzyKey] = [], fixedScore: Double? = nil, scoredByProvider: Bool = false) {
        self.result = result
        self.keys = keys
        self.fixedScore = fixedScore
        self.scoredByProvider = scoredByProvider
    }

    public init(_ result: CbResult, names: [String], fixedScore: Double? = nil) {
        self.init(result, keys: names.map { FuzzyKey($0) }, fixedScore: fixedScore)
    }
}

public struct CbQuery: Equatable, Sendable {
    public var raw: String
    public var text: String
    public var forced: CbProviderID?
    public var fuzzy: FuzzyQuery

    public init(raw: String, text: String, forced: CbProviderID?) {
        self.raw = raw
        self.text = text
        self.forced = forced
        fuzzy = FuzzyQuery(text)
    }

    public var isEmpty: Bool { text.isEmpty }

    public static func parse(_ raw: String) -> CbQuery {
        let t = CbTriggers.parse(raw)
        return CbQuery(raw: raw, text: t.text, forced: t.provider)
    }
}

public protocol CbProvider: AnyObject {
    var id: CbProviderID { get }
    func candidates(for q: CbQuery) -> [CbCandidate]
}

public enum CbTriggers {
    static let words: [(CbProviderID, [String])] = [
        (.windows, ["win", "w", "окно", "окна"]),
        (.files, ["f", "file", "files", "файл", "файлы"]),
        (.clipboard, ["clip", "буфер", "буф"]),
        (.menu, ["menu", "меню"]),
        (.emoji, ["emoji", "эмодзи", "смайл"]),
        (.snippets, ["snip", "сниппет", "шаблон"]),
        (.processes, ["kill", "proc", "убить", "завершить", "процесс"]),
        (.uninstall, ["rm", "uninstall", "удалить", "удали", "деинсталлировать"]),
        (.commands, ["cmd", "команда", "сис"]),
        (.scripts, ["run", "script", "скрипт"]),
        (.apps, ["app", "апп", "прил"])
    ]

    static let symbols: [(Character, CbProviderID)] = [("=", .calculator), (">", .commands), (":", .emoji), ("?", .web)]

    public static func parse(_ raw: String) -> (provider: CbProviderID?, text: String) {
        let trimmedLeading = String(raw.drop(while: { $0.isWhitespace }))
        guard let first = trimmedLeading.first else { return (nil, "") }
        for (ch, id) in symbols where first == ch {
            return (id, String(trimmedLeading.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        guard let space = trimmedLeading.firstIndex(where: { $0.isWhitespace }) else { return (nil, trimmedLeading.trimmingCharacters(in: .whitespaces)) }
        let head = trimmedLeading[..<space].lowercased()
        let tail = String(trimmedLeading[space...]).trimmingCharacters(in: .whitespaces)
        for (id, ws) in words where ws.contains(head) {
            return (id, tail)
        }
        return (nil, trimmedLeading.trimmingCharacters(in: .whitespaces))
    }
}
