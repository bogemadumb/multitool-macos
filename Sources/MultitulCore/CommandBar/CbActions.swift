import Foundation

public protocol CbHost: AnyObject {
    func focusWindow(key: Int, pid: Int32) -> Bool
    func open(path: String) -> Bool
    func reveal(path: String)
    func paste(clipID: Int64, copyOnly: Bool) -> Bool
    func copy(_ text: String)
    func paste(_ text: String) -> Bool
    func pressMenu(pid: Int32, path: [String]) -> Bool
    func run(_ command: CbSystemCommand) -> Bool
    func terminate(pid: Int32, name: String, tree: Bool) -> String?
    func quit(pid: Int32)
    func uninstall(appPath: String) -> Bool
    func openSection(_ id: String)
    func refreshRates()
    func shelfAdd(path: String) -> Bool
    func clipboardText() -> String?
}

public enum CbOutcome: Equatable, Sendable {
    case done
    case failed(String)
    case needsConfirmation(String)
}

public final class CbActionRouter {
    private let fs: LauncherFileChecking
    private let launcher: LauncherExecuting
    private let host: CbHost
    private let snippets: CbSnippetSource?
    private let settings: () -> CommandBarSettings
    private let now: () -> Date

    public init(fs: LauncherFileChecking, launcher: LauncherExecuting, host: CbHost, snippets: CbSnippetSource? = nil,
                settings: @escaping () -> CommandBarSettings = { CommandBarSettings() }, now: @escaping () -> Date = Date.init) {
        self.fs = fs
        self.launcher = launcher
        self.host = host
        self.snippets = snippets
        self.settings = settings
        self.now = now
    }

    public static func confirmationText(_ a: CbAction) -> String? {
        switch a {
        case .system(let c) where c.needsConfirmation: "\(c.title)?"
        case .killProcess(_, let name, let tree): tree ? "Завершить «\(name)» вместе с дочерними процессами?" : "Завершить процесс «\(name)»?"
        default: nil
        }
    }

    public func perform(_ action: CbAction, confirmed: Bool = false) -> CbOutcome {
        if !confirmed, let text = Self.confirmationText(action) { return .needsConfirmation(text) }
        switch action {
        case .noop: return .done
        case .openApp(let p): return host.open(path: p) ? .done : .failed("Не удалось открыть приложение")
        case .focusWindow(let k, let pid): return host.focusWindow(key: k, pid: pid) ? .done : .failed("Окно уже закрыто")
        case .openFile(let p): return host.open(path: p) ? .done : .failed("Не удалось открыть файл")
        case .revealFile(let p): host.reveal(path: p); return .done
        case .pasteClip(let id): return host.paste(clipID: id, copyOnly: false) ? .done : .failed("Запись истории не найдена")
        case .copyClip(let id): return host.paste(clipID: id, copyOnly: true) ? .done : .failed("Запись истории не найдена")
        case .copyText(let t): host.copy(t); return .done
        case .pasteText(let t): _ = host.paste(t); return .done
        case .menuItem(let pid, let path): return host.pressMenu(pid: pid, path: path) ? .done : .failed("Пункт меню недоступен")
        case .launcher(let t):
            switch LauncherResolver.command(for: t, fs: fs) {
            case .failure(let e): return .failed(e.message)
            case .success(let c):
                switch launcher.execute(c) {
                case .ok: return .done
                case .failed(let m): return .failed(m.isEmpty ? "Не удалось выполнить" : m)
                }
            }
        case .system(let c): return host.run(c) ? .done : .failed("Команда не выполнилась")
        case .killProcess(let pid, let name, let tree):
            if let err = host.terminate(pid: pid, name: name, tree: tree) { return .failed(err) }
            return .done
        case .quitApp(let pid): host.quit(pid: pid); return .done
        case .uninstallApp(let p): return host.uninstall(appPath: p) ? .done : .failed("Раздел удаления недоступен")
        case .snippet(let id):
            guard let sn = snippets?.snippets().first(where: { $0.id == id }) else { return .failed("Сниппет не найден") }
            let ctx = SnippetContext(now: now(), clipboard: host.clipboardText())
            let text = SnippetTemplate.render(sn.body, context: ctx).text
            snippets?.markUsed(id: id)
            if settings().pasteResults { _ = host.paste(text) } else { host.copy(text) }
            return .done
        case .openSection(let id): host.openSection(id); return .done
        case .refreshRates: host.refreshRates(); return .done
        case .shelfAdd(let p): return host.shelfAdd(path: p) ? .done : .failed("Полка недоступна")
        }
    }
}

public final class CommandBarModel {
    public private(set) var query = ""
    public private(set) var results: [CbResult] = []
    public private(set) var selection = 0
    public private(set) var forced: CbProviderID?
    public private(set) var message = ""
    public var pendingConfirmation: (result: CbResult, action: CbAction, text: String)?

    private let engine: CbEngine
    private let router: CbActionRouter
    private let settings: () -> CommandBarSettings

    public init(engine: CbEngine, router: CbActionRouter, settings: @escaping () -> CommandBarSettings) {
        self.engine = engine
        self.router = router
        self.settings = settings
    }

    public func setQuery(_ q: String) {
        query = q
        message = ""
        pendingConfirmation = nil
        refresh()
    }

    public func refresh() {
        let out = engine.search(query)
        forced = out.forced
        let previous = results.indices.contains(selection) ? results[selection].id : nil
        results = out.results
        if let p = previous, let i = results.firstIndex(where: { $0.id == p }) { selection = i } else { selection = 0 }
    }

    public var selected: CbResult? { results.indices.contains(selection) ? results[selection] : nil }

    public func moveSelection(_ d: Int) {
        guard !results.isEmpty else { selection = 0; return }
        selection = ((selection + d) % results.count + results.count) % results.count
    }

    public func select(_ i: Int) { if results.indices.contains(i) { selection = i } }

    public func result(number: Int) -> CbResult? {
        (1...9).contains(number) && results.indices.contains(number - 1) ? results[number - 1] : nil
    }

    @discardableResult
    public func run(_ r: CbResult, action: CbAction? = nil, confirmed: Bool = false) -> CbOutcome {
        let a = action ?? r.action
        let outcome = router.perform(a, confirmed: confirmed)
        switch outcome {
        case .done:
            message = ""
            pendingConfirmation = nil
            engine.recordUse(r)
        case .failed(let m):
            message = m
            pendingConfirmation = nil
        case .needsConfirmation(let t):
            pendingConfirmation = (r, a, t)
        }
        return outcome
    }

    @discardableResult
    public func runSelected(secondary index: Int? = nil) -> CbOutcome? {
        guard let r = selected else { return nil }
        if let i = index {
            guard r.secondary.indices.contains(i) else { return nil }
            return run(r, action: r.secondary[i].action)
        }
        return run(r)
    }

    @discardableResult
    public func confirmPending() -> CbOutcome? {
        guard let p = pendingConfirmation else { return nil }
        pendingConfirmation = nil
        return run(p.result, action: p.action, confirmed: true)
    }

    public func cancelPending() { pendingConfirmation = nil }

    // A slot hotkey runs the entry assigned to that slot without opening the bar.
    public func runSlot(_ n: Int) -> CbOutcome? {
        guard let e = settings().entry(slot: n) else { return .failed("Пункт \(n) не назначен") }
        let r = CbResult(id: "entry:" + e.target.stored, provider: .entries, title: e.title, action: .launcher(e.target), frecencyKey: "entry:" + e.target.stored)
        return run(r)
    }

    public var shouldCloseAfterRun: Bool { settings().closeAfterRun }
}
