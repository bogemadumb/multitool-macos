import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

final class ScratchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScratchpadController: ObservableObject {
    static let shared = ScratchpadController()

    @Published private(set) var settings = ScratchpadSettings()
    @Published private(set) var revision = 0
    @Published var preview = false
    @Published private(set) var storeError: String?
    @Published private(set) var isShown = false

    private let settingsStore = ScratchpadSettingsStore()
    private var model: ScratchpadModel?
    private var panel: ScratchPanel?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var modalOpen = false
    let spec = ScratchpadHotkeys.toggle

    var notes: [ScratchNote] { model?.notes ?? [] }
    var activeIndex: Int { model?.activeIndex ?? 0 }
    var text: String { model?.active?.text ?? "" }

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        do {
            let m = ScratchpadModel(store: try SQLiteScratchStore.open(), settings: settings)
            m.load()
            model = m
            storeError = m.lastError
        } catch {
            storeError = "\(error)"
            Log.write("scratchpad store failed: \(error)")
        }
        preview = settings.startInPreview
        HotkeyManager.shared.register(spec, owner: ModuleID.scratchpad.rawValue) { [weak self] in self?.toggle() }
        ToolsRouter.shared.register(.scratchpad) { [weak self] in self?.toggle() }
        bump()
    }

    func stop() {
        guard running else { return }
        running = false
        hide()
        model?.flush()
        model = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.scratchpad.rawValue)
        ToolsRouter.shared.unregister(.scratchpad)
        bump()
    }

    private func bump() { revision += 1 }

    func update(_ s: ScratchpadSettings) {
        settings = s.sanitized
        settingsStore.save(settings)
        model?.settings = settings
        bump()
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard let model else { return }
        model.applyAutoClear()
        bump()
        let size = NSSize(width: 460, height: 380)
        let p = panel ?? ScratchPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        if panel == nil {
            p.title = "Блокнот"
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ScratchpadPanelView(c: self))
            p.setFrameAutosaveName("dev.multitool.app.scratchpad")
            if !p.setFrameUsingName("dev.multitool.app.scratchpad"), let vis = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 40, y: vis.maxY - size.height - 40))
            }
            panel = p
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.flush()
                    if self.settings.closeOnOutsideClick && !self.modalOpen { self.hide() }
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.flush(); self?.isShown = false }
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        isShown = true
    }

    func hide() {
        model?.flush()
        panel?.orderOut(nil)
        isShown = false
    }

    func select(_ i: Int) { model?.select(i); bump() }
    func add() { if model?.addNote() == false { HUD.show("Предел вкладок: \(settings.maxTabs)") }; bump() }
    func close(_ i: Int) { model?.closeNote(at: i); bump() }
    func rename(_ i: Int, _ title: String) { model?.rename(at: i, to: title); bump() }
    func move(_ from: Int, _ to: Int) { model?.moveNote(from: from, to: to); bump() }
    func edit(_ text: String) { model?.edit(text); storeError = model?.lastError }
    func clear() { model?.clearActive(); bump() }

    func export(all: Bool) {
        guard let model else { return }
        model.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        let idx = model.activeIndex
        if all {
            panel.nameFieldStringValue = "Блокнот.md"
        } else if let n = model.active {
            panel.nameFieldStringValue = ScratchExport.fileName(for: n, index: idx)
        }
        NSApp.activate(ignoringOtherApps: true)
        modalOpen = true
        let result = panel.runModal()
        modalOpen = false
        guard result == .OK, let url = panel.url else { return }
        let body = all ? ScratchExport.combined(model.notes) : (model.active?.text ?? "")
        do { try body.write(to: url, atomically: true, encoding: .utf8) } catch { HUD.show("Не удалось сохранить файл") }
    }

    func copyAll() {
        PasteboardTextWriter().write(text)
        HUD.show("Заметка скопирована")
    }
}

@MainActor
final class ScratchpadModule: Module {
    let info = ModuleID.scratchpad.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(QuickTile(symbol: "note.text", caption: "Блокнот") { ScratchpadController.shared.toggle() }) }

    func start() { ScratchpadController.shared.start(); Log.write("module scratchpad start") }
    func stop() { ScratchpadController.shared.stop(); Log.write("module scratchpad stop") }
}

struct ScratchpadPanelView: View {
    @ObservedObject var c: ScratchpadController
    @State private var editing: Int?
    @State private var draft = ""

    private var textBinding: Binding<String> {
        Binding(get: { c.text }, set: { c.edit($0) })
    }

    var body: some View {
        let _ = c.revision
        VStack(spacing: 0) {
            tabs
            Divider()
            if c.preview {
                ScrollView {
                    MarkdownView(text: c.text).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            } else {
                TextEditor(text: textBinding)
                    .font(.system(size: CGFloat(c.settings.fontSize), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            Divider()
            footer
        }
        .background { VisualEffect(material: .popover) }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(c.notes.enumerated()), id: \.element.id) { i, n in
                        let active = i == c.activeIndex
                        HStack(spacing: 4) {
                            if editing == i {
                                TextField("", text: $draft, onCommit: { c.rename(i, draft); editing = nil })
                                    .textFieldStyle(.plain).frame(width: 90)
                            } else {
                                Text(n.displayTitle(index: i)).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                            }
                            Button { c.close(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(active ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { c.select(i) }
                        .contextMenu {
                            Button("Переименовать") { draft = n.title; editing = i }
                            Button("Сдвинуть влево") { c.move(i, max(i - 1, 0)) }.disabled(i == 0)
                            Button("Сдвинуть вправо") { c.move(i, min(i + 1, c.notes.count - 1)) }.disabled(i == c.notes.count - 1)
                            Button("Закрыть") { c.close(i) }
                        }
                    }
                }
            }
            Button { c.add() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Новая вкладка")
            Spacer(minLength: 0)
            Button { c.preview.toggle() } label: { Image(systemName: c.preview ? "pencil" : "eye") }
                .buttonStyle(.plain).help(c.preview ? "Править" : "Предпросмотр Markdown")
            Menu {
                Button("Сохранить заметку в файл…") { c.export(all: false) }
                Button("Сохранить все заметки в один файл…") { c.export(all: true) }
                Button("Скопировать текст") { c.copyAll() }
                Divider()
                Button("Очистить заметку", role: .destructive) { c.clear() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 10).padding(.top, 26).padding(.bottom, 6)
    }

    private var footer: some View {
        let st = ScratchStats.of(c.text)
        return HStack {
            Text("\(st.words) сл. · \(st.characters) симв.").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            Spacer()
            if let e = c.storeError { Text("Не сохраняется: \(e)").font(Theme.Fonts.caption).foregroundStyle(Theme.warn).lineLimit(1) }
            else { Text("автосохранение").font(Theme.Fonts.caption).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }

    @ViewBuilder
    private func block(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t).font(.system(size: CGFloat(max(26 - level * 3, 14)), weight: .bold))
        case .paragraph(let t):
            inline(t).font(.system(size: 13.5))
        case .bullet(let t, let indent):
            HStack(alignment: .top, spacing: 6) { Text("•"); inline(t) }.padding(.leading, CGFloat(indent) * 14).font(.system(size: 13.5))
        case .numbered(let n, let t):
            HStack(alignment: .top, spacing: 6) { Text("\(n)."); inline(t) }.font(.system(size: 13.5))
        case .checkbox(let done, let t):
            HStack(alignment: .top, spacing: 6) { Image(systemName: done ? "checkmark.square" : "square"); inline(t).strikethrough(done) }.font(.system(size: 13.5))
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.muted).frame(width: 3)
                inline(t).foregroundStyle(Theme.secondaryText)
            }.font(.system(size: 13.5))
        case .code(_, let t):
            Text(t).font(.system(size: 12, design: .monospaced)).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider()
        }
    }
}

struct ScratchpadSections: View {
    @ObservedObject private var c = ScratchpadController.shared

    private func binding<T>(_ kp: WritableKeyPath<ScratchpadSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent("Заметок", value: "\(c.notes.count)")
            Button(c.isShown ? "Скрыть блокнот" : "Показать блокнот") { c.toggle() }
        } header: { Text("Блокнот") } footer: {
            if let e = c.storeError { SectionFooter("Хранилище недоступно: \(e)", color: .orange) } else { SectionFooter("Заметки лежат в базе Мультитула и переживают перезапуск.") }
        }
        Section("Вид и хранение") {
            Picker(selection: binding(\.autoClear)) {
                ForEach(AutoClearPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Автоочистка", "Заметки без правок дольше этого срока очищаются при открытии блокнота") }
            IntSliderSetting("Размер шрифта", unit: " пт", value: binding(\.fontSize), in: ScratchpadSettings.fontRange)
            IntSliderSetting("Предел вкладок", unit: " шт", value: binding(\.maxTabs), in: ScratchpadSettings.tabsRange)
            Picker(selection: binding(\.autosaveDelay)) {
                ForEach([0.3, 1.0, 2.0, 5.0], id: \.self) { Text(String(format: "%.1f с", $0)).tag($0) }
            } label: { SettingLabel("Автосохранение через", "После последней правки; при закрытии и смене вкладки сохраняется сразу") }
        }
        Section("Поведение") {
            Toggle(isOn: binding(\.closeOnOutsideClick)) { SettingLabel("Закрывать по клику снаружи", "Блокнот прячется, когда фокус уходит в другое окно") }
            Toggle(isOn: binding(\.startInPreview)) { SettingLabel("Открывать в режиме предпросмотра", "Markdown сразу отрисован; правка кнопкой-карандашом в панели") }
        }
    }
}
