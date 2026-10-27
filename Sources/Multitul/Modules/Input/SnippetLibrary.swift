import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class SnippetLibraryState: ObservableObject {
    let model: SnippetLibraryModel
    @Published var query = "" { didSet { if query != oldValue { model.query = query; sync() } } }
    @Published var items: [Snippet] = []
    @Published var selection = 0
    @Published var focusTick = 0

    init(model: SnippetLibraryModel) {
        self.model = model
        sync()
    }

    func sync() {
        items = model.filtered
        selection = model.selection
    }

    func move(_ d: Int) { model.move(d); sync() }
    func select(_ i: Int) { model.select(i); sync() }
}

@MainActor
final class SnippetLibraryController {
    private weak var owner: SnippetsController?
    private var panel: PickerPanel?
    private var state: SnippetLibraryState?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var target: AppIdentity?

    var isShown: Bool { panel?.isVisible == true }

    func attach(_ c: SnippetsController) { owner = c }

    func toggle() { isShown ? close() : show() }

    func show() {
        guard let owner else { return }
        let services = ClipServices.shared
        let front = services.frontmost.frontmost()
        target = front.flatMap { $0.pid == getpid() ? nil : $0 } ?? services.lastExternal
        let st = SnippetLibraryState(model: SnippetLibraryModel(snippets: owner.snippets))
        state = st
        let view = SnippetLibraryView(state: st) { [weak self] s in self?.pick(s) }
        let size = NSSize(width: 560, height: 380)
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
            return MainActor.assumeIsolated { self.handle(e) } ? nil : e
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

    private func handle(_ e: NSEvent) -> Bool {
        guard let st = state else { return false }
        switch e.keyCode {
        case 53: close(); return true
        case 125: st.move(1); return true
        case 126: st.move(-1); return true
        case 36, 76:
            if let s = st.model.selected { pick(s) }
            return true
        default: return false
        }
    }

    private func pick(_ s: Snippet) {
        let tgt = target
        close()
        guard let owner, let expander = owner.expander else { return }
        if let tgt { LiveActivator().activate(tgt) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                let r = expander.expand(s, deleting: 0, terminator: nil)
                switch r {
                case .expanded: break
                case .secureInput, .secureField: HUD.show("В защищённом поле сниппеты не вставляются")
                case .excludedApp: HUD.show("В этом приложении сниппеты выключены")
                }
            }
        }
    }
}

struct SnippetLibraryView: View {
    @ObservedObject var state: SnippetLibraryState
    var onPick: (Snippet) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Поиск сниппета", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if state.items.isEmpty {
                            Text(state.query.isEmpty ? "Сниппетов пока нет" : "Ничего не найдено").font(Theme.Fonts.caption).foregroundStyle(Theme.muted).padding(.top, 40)
                        }
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { i, s in row(s, index: i).id(s.id) }
                    }
                    .padding(6)
                }
                .onChange(of: state.selection) { _, new in
                    if state.items.indices.contains(new) { proxy.scrollTo(state.items[new].id) }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("⏎ вставить")
                Text("↑↓ выбор")
                Text("Esc закрыть")
                Spacer()
            }
            .font(.system(size: 10)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 560, height: 380)
        .background { VisualEffect(material: .popover) }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .onChange(of: state.focusTick) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private func row(_ s: Snippet, index: Int) -> some View {
        let selected = index == state.selection
        return HStack(spacing: 10) {
            Text(s.trigger).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(s.title.isEmpty ? s.body.replacingOccurrences(of: "\n", with: " ") : s.title)
                .font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.muted)
            Spacer(minLength: 4)
        }
        .foregroundStyle(selected ? Color.white : Theme.primaryText)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            state.select(index)
            onPick(s)
        }
    }
}
