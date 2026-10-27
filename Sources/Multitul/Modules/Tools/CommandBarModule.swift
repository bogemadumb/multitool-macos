import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class URLSessionRatesFetcher: CurrencyRatesFetching {
    static let url = URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!

    func fetch() async throws -> CurrencyRateTable {
        var req = URLRequest(url: Self.url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CurrencyFetchError.badResponse }
        guard let t = CbrDailyParser.parse(data) else { throw CurrencyFetchError.empty }
        return t
    }
}

final class LiveCbClipSource: CbClipSource {
    private func store() -> ClipStore? { MainActor.assumeIsolated { ClipboardController.shared.store } }

    func recent(limit: Int) -> [ClipItem] { store().map { ClipStoreCbSource(store: $0).recent(limit: limit) } ?? [] }

    func search(_ text: String, limit: Int) -> [ClipItem] { store().map { ClipStoreCbSource(store: $0).search(text, limit: limit) } ?? [] }
}

final class LiveCbSnippetSource: CbSnippetSource {
    private var source: SnippetStoreCbSource?
    private let enabled: () -> Bool

    init(enabled: @escaping () -> Bool) { self.enabled = enabled }

    private func ensure() -> SnippetStoreCbSource? {
        if source == nil, let s = try? SnippetStore.open() { source = SnippetStoreCbSource(store: s) }
        return source
    }

    func snippets() -> [Snippet] { enabled() ? (ensure()?.snippets() ?? []) : [] }

    func markUsed(id: Int64) { ensure()?.markUsed(id: id) }
}

final class CommandBarHost: CbHost {
    func focusWindow(key: Int, pid: Int32) -> Bool {
        MainActor.assumeIsolated {
            let shared = SwitcherShared.shared
            let entries = SwitcherCbWindowSource(source: shared.source).windows()
            guard let e = entries.first(where: { $0.window?.key == key && $0.pid == pid }) else { return false }
            shared.actor.activate(e)
            return true
        }
    }

    func open(path: String) -> Bool { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func reveal(path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func paste(clipID: Int64, copyOnly: Bool) -> Bool {
        MainActor.assumeIsolated {
            let c = ClipboardController.shared
            guard let store = c.store, let engine = c.engine, let item = try? store.item(id: clipID) else { return false }
            let reps = (try? store.reps(id: clipID)) ?? []
            engine.paste([(item, reps)], plain: false, target: ClipServices.shared.lastExternal, copyOnly: copyOnly)
            try? store.touch(id: clipID)
            return true
        }
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func paste(_ text: String) -> Bool {
        MainActor.assumeIsolated {
            let s = ClipServices.shared
            s.pasteboard.write([PasteboardItemData(text: text)])
            s.acknowledge()
            guard s.keys.canSend else { return false }
            if let t = s.lastExternal { s.activator.activate(t) }
            s.scheduler.after(0.15) { _ = s.keys.sendCommandV() }
            return true
        }
    }

    func pressMenu(pid: Int32, path: [String]) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate()
        return AXMenuReader.press(pid: pid, path: path)
    }

    private func osascript(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    func run(_ command: CbSystemCommand) -> Bool {
        let open = "\u{00AB}event "
        let close = "\u{00BB}"
        switch command {
        case .sleep:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            do { try p.run() } catch { return false }
            return true
        case .restart: return osascript("tell application \"loginwindow\" to " + open + "aevtrrst" + close)
        case .shutDown: return osascript("tell application \"loginwindow\" to " + open + "aevtrsdn" + close)
        case .logOut: return osascript("tell application \"loginwindow\" to " + open + "aevtlogo" + close)
        case .systemSettings: return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .activityMonitor: return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .openTrash: return NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        }
    }

    func terminate(pid: Int32, name: String, tree: Bool) -> String? {
        Task.detached {
            let procs = ProcessCatalog.live()
            guard let p = procs.first(where: { $0.pid == pid && $0.name == name }) else {
                await MainActor.run { HUD.show("Процесса «\(name)» уже нет") }
                return
            }
            let svc = ProcessGuardLists.service()
            let out = tree ? svc.killTree(p) : svc.forceQuit(p)
            await MainActor.run { HUD.show(out.status == "done" ? "«\(name)» завершён" : "Не вышло: \(out.note)") }
        }
        return nil
    }

    func quit(pid: Int32) { NSRunningApplication(processIdentifier: pid)?.terminate() }

    func uninstall(appPath: String) -> Bool { MainActor.assumeIsolated { UninstallRouter.shared.request(appPath) } }

    func openSection(_ id: String) { MainActor.assumeIsolated { AppController.shared.openSection(id) } }

    func refreshRates() { MainActor.assumeIsolated { CommandBarController.shared.refreshRates(force: true) } }

    func shelfAdd(path: String) -> Bool {
        MainActor.assumeIsolated {
            guard let svc = ShelfController.shared.service else { return false }
            _ = svc.addPaths([path], source: "Командная строка")
            return true
        }
    }

    func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }
}

@MainActor
final class CommandBarController: ObservableObject {
    static let shared = CommandBarController()

    @Published private(set) var settings = CommandBarSettings()
    @Published private(set) var results: [CbResult] = []
    @Published private(set) var selection = 0
    @Published private(set) var message = ""
    @Published private(set) var confirmText: String?
    @Published private(set) var isShown = false
    @Published private(set) var showActions = false
    @Published private(set) var forced: CbProviderID?
    @Published private(set) var ratesNote = ""
    @Published var query = ""

    let settingsStore = CommandBarSettingsStore()
    let apps = SystemCbAppSource()
    let menu = AXMenuReader()
    let files = SpotlightFileSearcher()
    let processes = SystemCbProcessSource()
    private(set) lazy var ratesService = CurrencyRatesService(fetcher: URLSessionRatesFetcher(), store: KVCurrencyRatesStore())

    private var model: CommandBarModel?
    private var filesProvider: CbFilesProvider?
    private var frecency: FrecencyIndex?
    private var panel: CommandBarPanel?
    private var running = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var targetApp: AppIdentity?
    private var refreshing = false
    private var searchSerial = 0

    func isEnabled(_ id: ModuleID) -> Bool { AppController.shared.runtime.isEnabled(id) }

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        if let s = try? SQLiteFrecencyStore.open() { frecency = FrecencyIndex(store: s) }
        let shared = SwitcherShared.shared
        shared.acquire()
        let ctx = CbContext(settings: { [weak self] in self?.settings ?? CommandBarSettings() }, isModuleEnabled: { [weak self] id in MainActor.assumeIsolated { self?.isEnabled(id) ?? false } },
                            rates: { [weak self] in self?.ratesService.table }, now: Date.init)
        let launcherSource = QuickLauncherCbSource()
        let fp = CbFilesProvider(source: files, ctx: ctx)
        fp.onUpdate = { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.research() } } }
        filesProvider = fp
        let snippetSource = LiveCbSnippetSource { [weak self] in MainActor.assumeIsolated { self?.isEnabled(.textSnippets) ?? false } }
        let providers: [CbProvider] = [
            CbCalculatorProvider(ctx: ctx), CbUnitsProvider(ctx: ctx), CbAppsProvider(source: apps, ctx: ctx), CbEntriesProvider(ctx: ctx, launcher: launcherSource),
            CbCommandsProvider(ctx: ctx), CbWindowsProvider(source: SwitcherCbWindowSource(source: shared.source)), CbQuicklinksProvider(ctx: ctx),
            CbScriptsProvider(source: FolderCbScriptSource(), ctx: ctx), CbSnippetsProvider(source: snippetSource), CbMenuProvider(source: menu), fp,
            CbClipboardProvider(source: LiveCbClipSource(), ctx: ctx), CbEmojiProvider(ctx: ctx), CbProcessesProvider(source: processes, ctx: ctx),
            CbUninstallProvider(source: apps, ctx: ctx), CbWebProvider(ctx: ctx)
        ]
        let engine = CbEngine(providers: providers, frecency: frecency) { [weak self] in self?.settings ?? CommandBarSettings() }
        let router = CbActionRouter(fs: FileSystemLauncherChecker(), launcher: AppLauncherExecutor(), host: CommandBarHost(), snippets: snippetSource) { [weak self] in self?.settings ?? CommandBarSettings() }
        model = CommandBarModel(engine: engine, router: router) { [weak self] in self?.settings ?? CommandBarSettings() }
        registerHotkeys()
        ToolsRouter.shared.register(.commandBar) { [weak self] in self?.toggle() }
    }

    func stop() {
        guard running else { return }
        running = false
        close()
        HotkeyManager.shared.unregisterAll(owner: ModuleID.commandBar.rawValue)
        ToolsRouter.shared.unregister(.commandBar)
        SwitcherShared.shared.release()
        model = nil
        filesProvider = nil
        frecency = nil
    }

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register(CommandBarHotkeys.toggle, owner: ModuleID.commandBar.rawValue) { [weak self] in self?.toggle() }
        for (i, spec) in CommandBarHotkeys.slots.enumerated() {
            hk.register(spec, owner: ModuleID.commandBar.rawValue) { [weak self] in self?.runSlot(i + 1) }
        }
    }

    func update(_ s: CommandBarSettings) {
        settings = s.sanitized
        settingsStore.save(settings)
        research()
    }

    func clearUsage() {
        frecency?.clear()
        if frecency == nil, let s = try? SQLiteFrecencyStore.open() { s.removeAll() }
    }

    var usageKeyCount: Int { frecency?.knownKeys.count ?? 0 }

    func runSlot(_ n: Int) {
        guard let outcome = model?.runSlot(n) else { return }
        if case .failed(let m) = outcome { HUD.show(m) }
    }

    func refreshRates(force: Bool) {
        guard settings.currencyOnline || force, !refreshing else { return }
        refreshing = true
        ratesNote = "Загружаю курсы…"
        Task {
            let out = await ratesService.refresh(force: force)
            refreshing = false
            switch out {
            case .updated: ratesNote = ""
            case .failed(let m): ratesNote = "Курсы не загрузились"; Log.write("commandBar rates failed: \(m)")
            default: ratesNote = ""
            }
            if force { HUD.show(out == .updated ? "Курсы валют обновлены" : "Курсы не обновились") }
            research()
        }
    }

    func toggle() { isShown ? close() : show() }

    func show() {
        guard running, let model else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let f = front, f.processIdentifier != getpid() {
            targetApp = AppIdentity(bundleID: f.bundleIdentifier, name: f.localizedName, pid: f.processIdentifier)
            menu.capture(pid: f.processIdentifier, appName: f.localizedName ?? "") { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.research() } } }
        } else {
            menu.clear()
        }
        processes.invalidate()
        SwitcherShared.shared.source.refresh { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.research() } } }
        query = ""
        message = ""
        confirmText = nil
        showActions = false
        model.setQuery("")
        sync()
        let p = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: CommandBarPanelView(c: self))
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.Radius.window
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        panel = p
        layout()
        p.makeKeyAndOrderFront(nil)
        isShown = true
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return MainActor.assumeIsolated { self.handle(e) } ? nil : e
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        isShown = false
        showActions = false
        filesProvider?.reset()
        menu.clear()
    }

    private func layout() {
        guard let p = panel else { return }
        let rows = max(results.count, 1)
        let extra: CGFloat = (message.isEmpty ? 0 : 24) + (confirmText == nil ? 0 : 34) + (showActions ? CGFloat(min(selectedResult?.secondary.count ?? 0, 6)) * 30 + 12 : 0)
        let height = 60 + CGFloat(min(rows, 14)) * 46 + 36 + extra
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let origin = NSPoint(x: f.midX - 330, y: f.minY + f.height * 0.72 - height)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: 660, height: height)), display: true)
    }

    private func sync() {
        guard let model else { return }
        results = model.results
        selection = model.selection
        forced = model.forced
        message = model.message
        confirmText = model.pendingConfirmation?.text
        layout()
    }

    func research() {
        guard let model, isShown else { return }
        model.refresh()
        sync()
        autoRefreshRatesIfNeeded()
    }

    private func autoRefreshRatesIfNeeded() {
        guard settings.currencyOnline, !refreshing, ratesService.isStale else { return }
        if results.contains(where: { $0.id == "unit:rates" || ($0.id.hasPrefix("unit:") && $0.subtitle.hasPrefix(UnitCategory.currency.title)) }) { refreshRates(force: false) }
    }

    func setQuery(_ q: String) {
        model?.setQuery(q)
        showActions = false
        sync()
        autoRefreshRatesIfNeeded()
    }

    var selectedResult: CbResult? { results.indices.contains(selection) ? results[selection] : nil }

    func moveSelection(_ d: Int) { model?.moveSelection(d); showActions = false; sync() }

    func select(_ i: Int) { model?.select(i); sync() }

    func runSelected() {
        guard let model else { return }
        if model.pendingConfirmation != nil { finish(model.confirmPending()); return }
        finish(model.runSelected())
    }

    func run(_ i: Int) { model?.select(i); runSelected() }

    func runSecondary(_ i: Int) {
        guard let model else { return }
        finish(model.runSelected(secondary: i))
    }

    func cancelConfirmation() { model?.cancelPending(); sync() }

    private func finish(_ o: CbOutcome?) {
        guard let o else { return }
        switch o {
        case .done:
            if settings.closeAfterRun { close() } else { sync() }
        case .failed(let m):
            HUD.show(m)
            sync()
        case .needsConfirmation:
            sync()
        }
    }

    func toggleActions() {
        guard let r = selectedResult, !r.secondary.isEmpty else { return }
        showActions.toggle()
        layout()
    }

    private static let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, e.keyCode == 40 { toggleActions(); return true }
        if mods == .command, settings.showNumbers, let n = Self.digitCodes[e.keyCode] {
            if showActions { runSecondary(n - 1) } else if let r = model?.result(number: n), let i = results.firstIndex(of: r) { run(i) }
            return true
        }
        if showActions, mods.isEmpty, let n = Self.digitCodes[e.keyCode] { runSecondary(n - 1); showActions = false; return true }
        if mods == .option, e.keyCode == 36 || e.keyCode == 76 { runSecondary(0); return true }
        if e.keyCode == 53 {
            if showActions { showActions = false; layout() } else if confirmText != nil { cancelConfirmation() } else { close() }
            return true
        }
        return false
    }
}

@MainActor
final class CommandBarModule: Module {
    let info = ModuleID.commandBar.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "magnifyingglass", caption: "Строка") { CommandBarController.shared.toggle() }) }

    func start() { CommandBarController.shared.start(); Log.write("module commandBar start") }
    func stop() { CommandBarController.shared.stop(); Log.write("module commandBar stop") }
}

// MARK: panel view

struct CommandField: NSViewRepresentable {
    @ObservedObject var c: CommandBarController

    func makeCoordinator() -> Coordinator { Coordinator(c) }

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusingField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 20, weight: .regular)
        f.placeholderString = "Приложение, окно, файл, расчёт, единицы…"
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != c.query { f.stringValue = c.query }
    }

    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async { w.makeFirstResponder(self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let c: CommandBarController
        init(_ c: CommandBarController) { self.c = c }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            c.query = f.stringValue
            c.setQuery(f.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): c.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): c.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)): c.runSelected(); return true
            case #selector(NSResponder.insertTab(_:)): c.moveSelection(1); return true
            case #selector(NSResponder.insertBacktab(_:)): c.moveSelection(-1); return true
            default: return false
            }
        }
    }
}

struct CommandBarPanelView: View {
    @ObservedObject var c: CommandBarController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: c.forced?.symbol ?? "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.muted)
                CommandField(c: c)
                if let f = c.forced { Pill(f.title, style: .neutral) }
                if !c.ratesNote.isEmpty { Text(c.ratesNote).font(Theme.Fonts.caption).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 16).frame(height: 56)
            Divider()
            if c.results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(c.results.enumerated()), id: \.element.id) { i, r in row(i, r) }
                    }.padding(6)
                }
            }
            if let t = c.confirmText {
                Divider()
                HStack {
                    Text(t).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Return — да, Esc — нет").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 14).frame(height: 34).background(Theme.warn.opacity(0.12))
            }
            if !c.message.isEmpty { Text(c.message).font(Theme.Fonts.caption).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 24) }
            if c.showActions, let r = c.selectedResult {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(r.secondary.prefix(6).enumerated()), id: \.offset) { i, s in
                        Button { c.runSecondary(i) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: s.symbol).frame(width: 18)
                                Text(s.title).font(.system(size: 13))
                                Spacer()
                                KeyCaps(["⌘", "\(i + 1)"])
                            }.padding(.horizontal, 14).frame(height: 30)
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 6)
            }
            Divider()
            HStack(spacing: 12) {
                hint("↩", "выполнить")
                if c.selectedResult?.secondary.isEmpty == false { hint("⌘K", "действия") }
                if c.settings.showNumbers { hint("⌘1–9", "быстро") }
                Spacer()
                hint("Esc", "закрыть")
            }.padding(.horizontal, 14).frame(height: 36)
        }
        .background { VisualEffect(material: .popover) }
    }

    private func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(Theme.Fonts.mono).foregroundStyle(Theme.muted)
            Text(t).font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.query.isEmpty ? "Начни вводить" : "Ничего не найдено").font(.system(size: 13, weight: .semibold))
            if c.query.isEmpty {
                Text("= расчёт · 5 км в мили · 100 usd в eur · win окна · f файлы · clip буфер · menu меню · : эмодзи · kill процесс · rm удалить приложение · > команды")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private func row(_ i: Int, _ r: CbResult) -> some View {
        let selected = i == c.selection
        return HStack(spacing: 10) {
            CommandIcon(result: r, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !r.subtitle.isEmpty { Text(r.subtitle).font(Theme.Fonts.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if !r.trailing.isEmpty { Text(r.trailing).font(Theme.Fonts.mono).foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.muted) }
            if c.settings.showNumbers && i < 9 { KeyCaps(["⌘", "\(i + 1)"]) }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .foregroundStyle(selected ? Color.white : Theme.primaryText)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { c.run(i) }
    }
}

@MainActor
enum CommandIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = i
        return i
    }
}

struct CommandIcon: View {
    let result: CbResult
    let selected: Bool

    var body: some View {
        if let p = result.iconPath {
            Image(nsImage: CommandIconCache.icon(p)).resizable().frame(width: 30, height: 30)
        } else {
            IconTile(symbol: result.symbol, size: 28, active: selected)
        }
    }
}
