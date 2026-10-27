import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

enum PickerPreview {
    case none
    case text(String)
    case image(NSImage)
    case files([String])
    case color(String)
}

@MainActor
final class ClipPickerState: ObservableObject {
    let model: ClipPickerModel
    let store: ClipStore
    @Published var items: [ClipItem] = []
    @Published var selection = 0
    @Published var multi: [Int64] = []
    @Published var preview = PickerPreview.none
    @Published var query = "" { didSet { if query != oldValue { model.query = query; sync() } } }
    @Published var filter = 0 { didSet { applyFilter() } }
    @Published var focusTick = 0

    init(model: ClipPickerModel, store: ClipStore) {
        self.model = model
        self.store = store
        model.reload()
        sync()
    }

    private static let filters: [(String, Set<ClipKind>)] = [("Все", []), ("Текст", [.text, .rich]), ("Картинки", [.image]), ("Файлы", [.files]), ("Цвета", [.color])]
    static var filterTitles: [String] { filters.map(\.0) }

    private func applyFilter() {
        model.kindFilter = Self.filters[min(filter, Self.filters.count - 1)].1
        sync()
    }

    func sync() {
        items = model.items
        selection = model.selection
        multi = model.multi
        loadPreview()
    }

    func move(_ d: Int) { model.move(d); sync() }
    func select(_ i: Int) { model.select(index: i); sync() }
    func toggleMulti(_ it: ClipItem) { model.toggleMulti(id: it.id); sync() }

    private func loadPreview() {
        guard let it = model.highlighted else { preview = .none; return }
        switch it.kind {
        case .text, .rich:
            preview = model.previewText(it).map { .text($0) } ?? .none
        case .image:
            if let reps = try? store.reps(id: it.id), let d = reps.first?.data, let img = NSImage(data: d) { preview = .image(img) } else { preview = .none }
        case .files:
            let reps = (try? store.reps(id: it.id)) ?? []
            preview = .files(ClipComposer.filePaths(reps))
        case .color:
            preview = .color(it.title)
        }
    }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipPickerController {
    private weak var owner: ClipboardController?
    private var panel: PickerPanel?
    private var state: ClipPickerState?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var target: AppIdentity?

    var isShown: Bool { panel?.isVisible == true }

    func attach(_ c: ClipboardController) { owner = c }

    func toggle() { isShown ? close() : show() }

    func show() {
        guard let owner, let store = owner.store, let engine = owner.engine else { return }
        let front = ClipServices.shared.frontmost.frontmost()
        target = front.flatMap { $0.pid == getpid() ? nil : $0 } ?? ClipServices.shared.lastExternal
        let st = ClipPickerState(model: ClipPickerModel(store: store, engine: engine), store: store)
        state = st
        let view = ClipPickerView(state: st, hint: owner.settings.pasteOnPick,
                                  onActivate: { [weak self] it, cmd in self?.click(it, command: cmd) })
        let size = NSSize(width: 760, height: 460)
        let p = PickerPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.Radius.window
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2)) }
        panel?.orderOut(nil)
        panel = p
        p.makeKeyAndOrderFront(nil)
        st.focusTick += 1
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            let handled = MainActor.assumeIsolated { self.handle(e) }
            return handled ? nil : e
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = nil
    }

    private static let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handle(_ e: NSEvent) -> Bool {
        guard let st = state else { return false }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 53: close(); return true
        case 125: st.move(1); return true
        case 126: st.move(-1); return true
        case 36, 76:
            activate(st.model.chosen, plain: flags.contains(.shift), copyOnly: !(owner?.settings.pasteOnPick ?? true))
            return true
        default: break
        }
        guard flags == .command else { return false }
        if let n = Self.digitCodes[e.keyCode], let it = st.model.item(quickKey: n) {
            activate([it], plain: false, copyOnly: false)
            return true
        }
        switch e.keyCode {
        case 8:
            activate(st.model.chosen, plain: false, copyOnly: true)
            return true
        case 35:
            if let it = st.model.highlighted { st.model.togglePin(it); st.sync() }
            return true
        case 51:
            st.model.delete(st.model.chosen)
            st.sync()
            return true
        default: return false
        }
    }

    private func click(_ it: ClipItem, command: Bool) {
        guard let st = state else { return }
        if command { st.toggleMulti(it); return }
        activate([it], plain: false, copyOnly: !(owner?.settings.pasteOnPick ?? true))
    }

    private func activate(_ list: [ClipItem], plain: Bool, copyOnly: Bool) {
        guard let st = state, !list.isEmpty else { return }
        let tgt = target
        close()
        let out = st.model.activate(list, plain: plain, copyOnly: copyOnly, target: tgt) { result in
            if result == .needsAccessibility { HUD.show("Скопировано. Для вставки нужен Универсальный доступ") }
        }
        if out == .copiedOnly { HUD.show("Скопировано в буфер") }
        owner?.refreshCounts()
    }
}

struct ClipPickerView: View {
    @ObservedObject var state: ClipPickerState
    var hint: Bool
    var onActivate: (ClipItem, Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 330)
                Divider()
                previewPane
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 460)
        .background { VisualEffect(material: .popover) }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .onChange(of: state.focusTick) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Поиск по истории", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
            Picker("", selection: $state.filter) {
                ForEach(Array(ClipPickerState.filterTitles.enumerated()), id: \.offset) { i, t in Text(t).tag(i) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if state.items.isEmpty {
                        Text(state.query.isEmpty ? "История пуста" : "Ничего не найдено").font(Theme.Fonts.caption).foregroundStyle(Theme.muted).padding(.top, 40)
                    }
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, it in
                        row(it, index: i).id(it.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _, new in
                if state.items.indices.contains(new) { proxy.scrollTo(state.items[new].id) }
            }
        }
    }

    private func row(_ it: ClipItem, index: Int) -> some View {
        let selected = index == state.selection
        let marked = state.multi.contains(it.id)
        return HStack(spacing: 8) {
            Image(systemName: it.kind.symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(selected ? Color.white : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title.isEmpty ? "—" : it.title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle(it)).font(.system(size: 10)).foregroundStyle(selected ? Color.white.opacity(0.75) : Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if marked { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) }
            if it.pinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
            if index < 9 { Text("⌘\(index + 1)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.muted) }
        }
        .foregroundStyle(selected ? Color.white : Theme.primaryText)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Theme.accent : (marked ? Theme.tileFill : Color.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            state.select(index)
            onActivate(it, NSEvent.modifierFlags.contains(.command))
        }
    }

    private func subtitle(_ it: ClipItem) -> String {
        var parts = [it.kind.title]
        if let n = it.sourceName, !n.isEmpty { parts.append(n) }
        parts.append(it.used.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewPane: some View {
        Group {
            switch state.preview {
            case .none:
                Text("Предпросмотр").font(Theme.Fonts.caption).foregroundStyle(Theme.muted)
            case .text(let t):
                ScrollView { Text(t).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.disabled).padding(12) }
            case .image(let img):
                Image(nsImage: img).resizable().scaledToFit().padding(12)
            case .files(let paths):
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) { ForEach(paths, id: \.self) { Text($0).font(.system(size: 12)).lineLimit(2) } }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            case .color(let hex):
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hexString: hex)).frame(width: 120, height: 120)
                    Text(hex).font(.system(size: 14, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(hint ? "⏎ вставить" : "⏎ скопировать")
            Text("⇧⏎ без формата")
            Text("⌘C копировать")
            Text("⌘P закрепить")
            Text("⌘⌫ удалить")
            Text("⌘-клик несколько")
            Spacer()
        }
        .font(.system(size: 10)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

extension Color {
    init(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
