import Foundation

public enum LauncherTool: String, CaseIterable, Identifiable, Sendable {
    case colorPicker, screenOcr, scratchpad, cameraPreview, cleaningMode, shelf, clipboard, commandBar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .colorPicker: "Пипетка"
        case .screenOcr: "Текст с экрана"
        case .scratchpad: "Блокнот"
        case .cameraPreview: "Зеркало камеры"
        case .cleaningMode: "Режим уборки"
        case .shelf: "Полка"
        case .clipboard: "История буфера"
        case .commandBar: "Командная строка"
        }
    }

    public var symbol: String {
        switch self {
        case .colorPicker: "eyedropper"
        case .screenOcr: "text.viewfinder"
        case .scratchpad: "note.text"
        case .cameraPreview: "video"
        case .cleaningMode: "sparkles"
        case .shelf: "tray.and.arrow.down"
        case .clipboard: "doc.on.clipboard"
        case .commandBar: "magnifyingglass"
        }
    }

    public var module: ModuleID {
        switch self {
        case .colorPicker: .colorPicker
        case .screenOcr: .screenOcr
        case .scratchpad: .scratchpad
        case .cameraPreview: .cameraPreview
        case .cleaningMode: .cleaningMode
        case .shelf: .shelf
        case .clipboard: .clipboardHistory
        case .commandBar: .commandBar
        }
    }
}

public enum LauncherTarget: Equatable, Hashable, Sendable {
    case tool(LauncherTool)
    case toggle(QuickToggleID)
    case app(String)
    case url(String)
    case script(String)

    public var stored: String {
        switch self {
        case .tool(let t): "tool:\(t.rawValue)"
        case .toggle(let t): "toggle:\(t.rawValue)"
        case .app(let a): "app:\(a)"
        case .url(let u): "url:\(u)"
        case .script(let s): "script:\(s)"
        }
    }

    public init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":") else { return nil }
        let kind = String(stored[..<colon]), value = String(stored[stored.index(after: colon)...])
        switch kind {
        case "tool": guard let t = LauncherTool(rawValue: value) else { return nil }; self = .tool(t)
        case "toggle": guard let t = QuickToggleID(rawValue: value) else { return nil }; self = .toggle(t)
        case "app": guard !value.isEmpty else { return nil }; self = .app(value)
        case "url": guard !value.isEmpty else { return nil }; self = .url(value)
        case "script": guard !value.isEmpty else { return nil }; self = .script(value)
        default: return nil
        }
    }

    public var kindTitle: String {
        switch self {
        case .tool: "Инструмент"
        case .toggle: "Переключатель"
        case .app: "Приложение"
        case .url: "Ссылка"
        case .script: "Скрипт"
        }
    }

    public var defaultSymbol: String {
        switch self {
        case .tool(let t): t.symbol
        case .toggle(let t): t.symbol
        case .app: "app"
        case .url: "link"
        case .script: "terminal"
        }
    }

    public var defaultTitle: String {
        switch self {
        case .tool(let t): t.title
        case .toggle(let t): t.title
        case .app(let a): (a as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        case .url(let u): URL(string: u)?.host ?? u
        case .script(let s): (s as NSString).lastPathComponent
        }
    }
}

public struct LauncherItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var target: LauncherTarget

    public init(id: String = UUID().uuidString, title: String = "", target: LauncherTarget) {
        self.id = id
        self.title = title.isEmpty ? target.defaultTitle : title
        self.target = target
    }

    public var symbol: String { target.defaultSymbol }
}

public enum LauncherCommand: Equatable, Sendable {
    case tool(LauncherTool)
    case toggle(QuickToggleID)
    case openApp(String)
    case openURL(URL)
    case run(executable: String, arguments: [String])
}

public enum LauncherIssue: Error, Equatable, Sendable {
    case emptyValue
    case badURL
    case blockedScheme(String)
    case appNotFound
    case scriptNotFound
    case scriptNotAbsolute
    case scriptUnsupported
    case executionFailed(String)

    public var message: String {
        switch self {
        case .emptyValue: "Пустое значение"
        case .badURL: "Это не похоже на ссылку"
        case .blockedScheme(let s): "Схема «\(s)» запрещена"
        case .appNotFound: "Приложение не найдено"
        case .scriptNotFound: "Файл скрипта не найден"
        case .scriptNotAbsolute: "Нужен полный путь к скрипту"
        case .executionFailed(let m): m.isEmpty ? "Не удалось выполнить" : m
        case .scriptUnsupported: "Неизвестный тип скрипта: нужен .sh, .command, .py, .scpt, .applescript или исполняемый файл"
        }
    }
}

public protocol LauncherFileChecking: AnyObject {
    func fileExists(_ path: String) -> Bool
    func isExecutable(_ path: String) -> Bool
    func appPath(forBundleID id: String) -> String?
}

public enum LauncherResolver {
    public static let blockedSchemes: Set<String> = ["file", "javascript", "data", "vbscript"]

    public static func normalizeURL(_ raw: String) -> Result<URL, LauncherIssue> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.emptyValue) }
        if t.contains(where: { $0.isWhitespace }) { return .failure(.badURL) }
        var candidate = t
        if let colon = t.firstIndex(of: ":"), t[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }), !t[..<colon].isEmpty,
           !(t[t.index(after: colon)...].first?.isNumber ?? false) {
            let scheme = t[..<colon].lowercased()
            if blockedSchemes.contains(scheme) { return .failure(.blockedScheme(scheme)) }
        } else {
            candidate = "https://" + t
        }
        guard let u = URL(string: candidate), let scheme = u.scheme else { return .failure(.badURL) }
        if ["http", "https"].contains(scheme.lowercased()) {
            guard let host = u.host, host.contains(".") || host == "localhost" else { return .failure(.badURL) }
        }
        return .success(u)
    }

    public static func scriptCommand(_ path: String, fs: LauncherFileChecking) -> Result<LauncherCommand, LauncherIssue> {
        guard path.hasPrefix("/") else { return .failure(.scriptNotAbsolute) }
        guard fs.fileExists(path) else { return .failure(.scriptNotFound) }
        switch (path as NSString).pathExtension.lowercased() {
        case "sh", "command", "zsh": return .success(.run(executable: "/bin/zsh", arguments: [path]))
        case "py": return .success(.run(executable: "/usr/bin/python3", arguments: [path]))
        case "scpt", "applescript": return .success(.run(executable: "/usr/bin/osascript", arguments: [path]))
        default:
            return fs.isExecutable(path) ? .success(.run(executable: path, arguments: [])) : .failure(.scriptUnsupported)
        }
    }

    public static func command(for target: LauncherTarget, fs: LauncherFileChecking) -> Result<LauncherCommand, LauncherIssue> {
        switch target {
        case .tool(let t): return .success(.tool(t))
        case .toggle(let t): return .success(.toggle(t))
        case .app(let a):
            let v = a.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return .failure(.emptyValue) }
            if v.hasPrefix("/") { return fs.fileExists(v) && v.hasSuffix(".app") ? .success(.openApp(v)) : .failure(.appNotFound) }
            if let p = fs.appPath(forBundleID: v) { return .success(.openApp(p)) }
            return .failure(.appNotFound)
        case .url(let u):
            return normalizeURL(u).map { .openURL($0) }
        case .script(let s):
            return scriptCommand(s.trimmingCharacters(in: .whitespaces), fs: fs)
        }
    }
}

public enum LauncherDefaults {
    public static let items: [LauncherItem] = [
        LauncherItem(id: "default-colorPicker", target: .tool(.colorPicker)),
        LauncherItem(id: "default-screenOcr", target: .tool(.screenOcr)),
        LauncherItem(id: "default-scratchpad", target: .tool(.scratchpad)),
        LauncherItem(id: "default-cameraPreview", target: .tool(.cameraPreview)),
        LauncherItem(id: "default-darkMode", target: .toggle(.darkMode)),
        LauncherItem(id: "default-cleaningMode", target: .tool(.cleaningMode))
    ]
}

public struct QuickLauncherSettings: Equatable, Sendable {
    public var items = LauncherDefaults.items
    public var closeAfterRun = true
    public var showNumbers = true

    public init() {}

    public static let maxItems = 30

    public var sanitized: QuickLauncherSettings {
        var s = self
        var seen = Set<String>()
        s.items = items.filter { seen.insert($0.id).inserted }
        if s.items.count > Self.maxItems { s.items = Array(s.items.prefix(Self.maxItems)) }
        return s
    }
}

public final class QuickLauncherSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> QuickLauncherSettings {
        var s = QuickLauncherSettings()
        let p = "quickLauncher."
        if let raw = a.strings(p + "items") {
            s.items = raw.compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count == 3, let t = LauncherTarget(stored: parts[2]) else { return nil }
                return LauncherItem(id: parts[0], title: parts[1], target: t)
            }
        }
        s.closeAfterRun = a.bool(p + "closeAfterRun", s.closeAfterRun)
        s.showNumbers = a.bool(p + "showNumbers", s.showNumbers)
        return s.sanitized
    }

    public func save(_ settings: QuickLauncherSettings) {
        let s = settings.sanitized
        let b = QuickLauncherSettings()
        let p = "quickLauncher."
        if s.items == b.items { a.kv.removeObject(forKey: p + "items") }
        else { a.kv.set(s.items.map { "\($0.id)\t\($0.title.replacingOccurrences(of: "\t", with: " "))\t\($0.target.stored)" }, forKey: p + "items") }
        a.put(p + "closeAfterRun", s.closeAfterRun, b.closeAfterRun)
        a.put(p + "showNumbers", s.showNumbers, b.showNumbers)
    }
}

public enum LauncherHotkeys {
    public static let slotCount = 9
    public static let toggle = HotkeySpec(id: "quickLauncher.toggle", title: "Быстрая палитра: открыть", defaultCombo: .none)
    public static let slots: [HotkeySpec] = (1...slotCount).map {
        HotkeySpec(id: "quickLauncher.slot\($0)", title: "Быстрая палитра: пункт \($0)", defaultCombo: .none)
    }
    public static let all = [toggle] + slots
}

public enum LauncherExecResult: Equatable, Sendable {
    case ok
    case failed(String)
}

public protocol LauncherExecuting: AnyObject {
    func execute(_ command: LauncherCommand) -> LauncherExecResult
}

public final class LauncherModel {
    public private(set) var settings: QuickLauncherSettings
    public private(set) var selection = 0
    private let fs: LauncherFileChecking
    private let executor: LauncherExecuting
    private let save: (QuickLauncherSettings) -> Void

    public init(settings: QuickLauncherSettings, fs: LauncherFileChecking, executor: LauncherExecuting, save: @escaping (QuickLauncherSettings) -> Void = { _ in }) {
        self.settings = settings.sanitized
        self.fs = fs
        self.executor = executor
        self.save = save
    }

    public var items: [LauncherItem] { settings.items }

    private func commit() {
        settings = settings.sanitized
        selection = items.isEmpty ? 0 : min(selection, items.count - 1)
        save(settings)
    }

    public func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { selection = 0; return }
        selection = ((selection + delta) % items.count + items.count) % items.count
    }

    public func select(_ index: Int) {
        if items.indices.contains(index) { selection = index }
    }

    public func item(digit: Int) -> LauncherItem? {
        (1...9).contains(digit) && items.indices.contains(digit - 1) ? items[digit - 1] : nil
    }

    @discardableResult
    public func add(_ target: LauncherTarget, title: String = "") -> Result<LauncherItem, LauncherIssue> {
        if items.count >= QuickLauncherSettings.maxItems { return .failure(.emptyValue) }
        var final = target
        if case .url(let raw) = target {
            switch LauncherResolver.normalizeURL(raw) {
            case .success(let u): final = .url(u.absoluteString)
            case .failure(let e): return .failure(e)
            }
        }
        let cmd = LauncherResolver.command(for: final, fs: fs)
        if case .failure(let e) = cmd { return .failure(e) }
        var name = title.trimmingCharacters(in: .whitespaces)
        if name.isEmpty, case .success(.openApp(let path)) = cmd { name = LauncherTarget.app(path).defaultTitle }
        let item = LauncherItem(title: name, target: final)
        settings.items.append(item)
        commit()
        return .success(item)
    }

    public func remove(id: String) {
        settings.items.removeAll { $0.id == id }
        commit()
    }

    public func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        let sel = items[min(selection, items.count - 1)].id
        settings.items.insert(settings.items.remove(at: from), at: to)
        selection = settings.items.firstIndex { $0.id == sel } ?? 0
        commit()
    }

    public func rename(id: String, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        settings.items[i].title = t.isEmpty ? settings.items[i].target.defaultTitle : t
        commit()
    }

    public func resetToDefaults() {
        settings.items = LauncherDefaults.items
        commit()
    }

    public func run(_ item: LauncherItem) -> Result<Void, LauncherIssue> {
        switch LauncherResolver.command(for: item.target, fs: fs) {
        case .failure(let e): return .failure(e)
        case .success(let cmd):
            switch executor.execute(cmd) {
            case .ok: return .success(())
            case .failed(let m): return .failure(.executionFailed(m))
            }
        }
    }

    public func runSelected() -> Result<Void, LauncherIssue>? {
        items.indices.contains(selection) ? run(items[selection]) : nil
    }

    public func runSlot(_ n: Int) -> Result<Void, LauncherIssue>? {
        item(digit: n).map(run)
    }
}
