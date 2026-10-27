import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickLauncherController: ObservableObject {
    static let shared = QuickLauncherController()

    @Published private(set) var settings = QuickLauncherSettings()
    @Published private(set) var selection = 0
    @Published private(set) var message = ""
    @Published private(set) var isShown = false

    private let store = QuickLauncherSettingsStore()
    private var model: LauncherModel
    private var panel: LauncherPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var running = false

    private init() {
        model = QuickLauncherController.makeModel(QuickLauncherSettings(), save: { _ in })
    }

    private static func makeModel(_ s: QuickLauncherSettings, save: @escaping (QuickLauncherSettings) -> Void) -> LauncherModel {
        LauncherModel(settings: s, fs: FileSystemLauncherChecker(), executor: AppLauncherExecutor(), save: save)
    }

    var items: [LauncherItem] { model.items }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        model = Self.makeModel(settings) { [weak self] s in self?.persisted(s) }
        registerHotkeys()
        sync()
    }

    func stop() {
        guard running else { return }
        running = false
        close()
        HotkeyManager.shared.unregisterAll(owner: ModuleID.quickLauncher.rawValue)
    }

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register(LauncherHotkeys.toggle, owner: ModuleID.quickLauncher.rawValue) { [weak self] in self?.toggle() }
        for (i, spec) in LauncherHotkeys.slots.enumerated() {
            hk.register(spec, owner: ModuleID.quickLauncher.rawValue) { [weak self] in self?.runSlot(i + 1) }
        }
    }

    private func persisted(_ s: QuickLauncherSettings) {
        store.save(s)
        settings = s
    }

    private func sync() {
        settings = model.settings
        selection = model.selection
    }

    func updateOptions(closeAfterRun: Bool? = nil, showNumbers: Bool? = nil) {
        var s = model.settings
        if let closeAfterRun { s.closeAfterRun = closeAfterRun }
        if let showNumbers { s.showNumbers = showNumbers }
        model = Self.makeModel(s) { [weak self] v in self?.persisted(v) }
        persisted(s)
        sync()
    }

    func add(_ target: LauncherTarget, title: String = "") {
        switch model.add(target, title: title) {
        case .success: message = ""
        case .failure(let e): message = e.message
        }
        sync()
    }

    func remove(_ id: String) { model.remove(id: id); sync() }
    func rename(_ id: String, _ t: String) { model.rename(id: id, to: t); sync() }
    func reset() { model.resetToDefaults(); sync() }

    func move(from: IndexSet, to: Int) {
        guard let f = from.first else { return }
        let dest = f < to ? to - 1 : to
        model.move(from: f, to: dest)
        sync()
    }

    func run(_ item: LauncherItem) {
        switch model.run(item) {
        case .success:
            message = ""
            if settings.closeAfterRun { close() }
        case .failure(let e):
            message = e.message
            HUD.show(e.message)
        }
    }

    func runSlot(_ n: Int) {
        guard let item = model.item(digit: n) else { HUD.show("Пункт \(n) в палитре пуст"); return }
        run(item)
    }

    func select(_ i: Int) { model.select(i); sync() }
    func moveSelection(_ d: Int) { model.moveSelection(d); sync() }

    func toggle() { isShown ? close() : show() }

    func show() {
        guard running else { return }
        sync()
        let rows = max(model.items.count, 1)
        let size = NSSize(width: 380, height: CGFloat(min(rows, 12)) * 40 + 78)
        let p = LauncherPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: LauncherPaletteView(c: self))
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.Radius.window
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2)) }
        panel = p
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
    }

    private static let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handle(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 53: close(); return true
        case 125: moveSelection(1); return true
        case 126: moveSelection(-1); return true
        case 36, 76:
            if model.items.indices.contains(model.selection) { run(model.items[model.selection]) }
            return true
        default: break
        }
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let n = Self.digitCodes[e.keyCode] {
            runSlot(n)
            return true
        }
        return false
    }
}

@MainActor
final class QuickLauncherModule: Module {
    let info = ModuleID.quickLauncher.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "square.grid.2x2", caption: "Палитра") { QuickLauncherController.shared.toggle() }) }

    func start() { QuickLauncherController.shared.start(); Log.write("module quickLauncher start") }
    func stop() { QuickLauncherController.shared.stop(); Log.write("module quickLauncher stop") }
}

struct LauncherPaletteView: View {
    @ObservedObject var c: QuickLauncherController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Быстрая палитра").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !c.message.isEmpty { Text(c.message).font(Theme.Fonts.caption).foregroundStyle(Theme.warn).lineLimit(1) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if c.items.isEmpty {
                Text("Палитра пуста. Добавь пункты в разделе «Инструменты».").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(c.items.enumerated()), id: \.element.id) { i, item in
                            row(i, item)
                        }
                    }.padding(6)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("↑↓ выбор").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                Text("Return — запуск").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                Text("1–9 — сразу").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
                Spacer()
                Text("Esc").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background { VisualEffect(material: .popover) }
    }

    private func row(_ i: Int, _ item: LauncherItem) -> some View {
        let selected = i == c.selection
        return HStack(spacing: 10) {
            IconTile(symbol: item.symbol, size: 26, active: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.target.kindTitle).font(Theme.Fonts.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.muted)
            }
            Spacer()
            if c.settings.showNumbers && i < 9 { KeyCaps(["\(i + 1)"]) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Theme.primaryText)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { c.select(i); c.run(item) }
    }
}

struct QuickLauncherSections: View {
    @ObservedObject private var c = QuickLauncherController.shared

    var body: some View {
        Section {
            Button("Показать палитру") { c.toggle() }
            Toggle(isOn: Binding(get: { c.settings.closeAfterRun }, set: { c.updateOptions(closeAfterRun: $0) })) { SettingLabel("Закрывать палитру после запуска", "Выключи, если запускаешь несколько пунктов подряд") }
            Toggle(isOn: Binding(get: { c.settings.showNumbers }, set: { c.updateOptions(showNumbers: $0) })) { SettingLabel("Показывать цифры", "Номер 1–9 справа от пункта") }
            NavigationLink(value: ToolRoute.launcherItems) { LabeledContent("Пункты палитры", value: "\(c.items.count)") }
            NavigationLink(value: ToolRoute.launcherSlots) { Text("Сочетания для пунктов") }
        } header: { Text("Быстрая палитра") } footer: {
            SectionFooter("Первые девять пунктов запускаются цифрами и своими сочетаниями.")
        }
    }
}

struct LauncherItemsPage: View {
    @ObservedObject private var c = QuickLauncherController.shared
    @State private var urlText = ""

    private func detail(_ item: LauncherItem) -> String? {
        switch item.target {
        case .app(let a), .url(let a), .script(let a): a
        default: nil
        }
    }

    var body: some View {
        SettingsPage {
            Section {
                if c.items.isEmpty {
                    ContentUnavailableView("Палитра пуста", systemImage: "square.grid.2x2", description: Text("Добавьте инструмент, приложение, скрипт или ссылку"))
                }
                ForEach(c.items) { item in
                    LabeledContent {
                        Button { c.remove(item.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    } label: {
                        Label {
                            SettingLabel(item.title, item.target.kindTitle + (detail(item).map { " · " + $0 } ?? ""))
                        } icon: { Image(systemName: item.symbol) }
                    }
                }
                .onMove { c.move(from: $0, to: $1) }
            } header: { Text("Пункты") } footer: {
                SectionFooter("Перетаскивайте строки, чтобы изменить порядок.")
            }
            Section {
                addMenu
                Button("Сбросить к стандартным", role: .destructive) { c.reset() }
            }
            Section {
                TextField("Ссылка", text: $urlText, prompt: Text("example.com или https://…"))
                Button("Добавить ссылку") { c.add(.url(urlText)); if c.message.isEmpty { urlText = "" } }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Ссылка") } footer: {
                if !c.message.isEmpty { SectionFooter(c.message, color: .orange) }
            }
        }
    }

    private var addMenu: some View {
        Menu("Добавить") {
            Menu("Инструмент") {
                ForEach(LauncherTool.allCases) { t in Button(t.title) { c.add(.tool(t)) } }
            }
            Menu("Переключатель") {
                ForEach(QuickToggleID.allCases) { t in Button(t.title) { c.add(.toggle(t)) } }
            }
            Button("Приложение…") { pickFile(types: [.application], dir: "/Applications") { c.add(.app($0)) } }
            Button("Скрипт…") { pickFile(types: [.item], dir: NSHomeDirectory()) { c.add(.script($0)) } }
        }
    }

    private func pickFile(types: [UTType], dir: String, _ done: (String) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: dir)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

struct LauncherSlotsPage: View {
    @ObservedObject private var c = QuickLauncherController.shared

    var body: some View {
        SettingsPage {
            Section {
                ForEach(0..<min(max(c.items.count, 1), LauncherHotkeys.slotCount), id: \.self) { i in
                    HotkeyLine(i < c.items.count ? c.items[i].title : "Пункт \(i + 1)", spec: LauncherHotkeys.slots[i])
                }
            } footer: {
                SectionFooter("Сочетание запускает пункт с этим номером из любого приложения.")
            }
        }
    }
}
