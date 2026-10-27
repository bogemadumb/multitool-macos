import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore
import MultitulUI

final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RadialPanelModel: ObservableObject {
    @Published var state: RadialViewState?
}

final class RadialPanelPresenter: RadialPresenting {
    private var panel: RadialPanel?
    let model: RadialPanelModel = MainActor.assumeIsolated { RadialPanelModel() }

    @MainActor private static func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    func show(_ state: RadialViewState) {
        MainActor.assumeIsolated {
            let side = CGFloat(state.geometry.outerRadius + 40) * 2
            let p = RadialPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            model.state = state
            p.contentView = NSHostingView(rootView: RadialWheelHost(model: model))
            place(p, state)
            p.orderFrontRegardless()
            panel = p
        }
    }

    @MainActor private func place(_ p: NSPanel, _ s: RadialViewState) {
        let side = p.frame.width
        let ns = NSPoint(x: s.center.x, y: Self.primaryHeight() - s.center.y)
        p.setFrame(NSRect(x: ns.x - side / 2, y: ns.y - side / 2, width: side, height: side), display: true)
    }

    func update(_ state: RadialViewState) {
        MainActor.assumeIsolated { if model.state != state { model.state = state } }
    }

    func hide() {
        MainActor.assumeIsolated {
            panel?.orderOut(nil)
            panel?.contentView = nil
            panel = nil
            model.state = nil
        }
    }
}

final class RadialMenuRunner: RadialRunning {
    func run(_ item: RadialItem) {
        MainActor.assumeIsolated {
            switch RadialResolver.resolve(item, fs: FileSystemLauncherChecker()) {
            case .failure(let e): HUD.show(e.message)
            case .success(let cmd):
                switch cmd {
                case .launcher(let c):
                    if case .failed(let m) = AppLauncherExecutor().execute(c) { HUD.show(m) }
                case .openPath(let p):
                    if !NSWorkspace.shared.open(URL(fileURLWithPath: p)) { HUD.show("Не удалось открыть") }
                case .keys(let k):
                    Self.post(k, tries: 0)
                }
            }
        }
    }

    // The trigger modifiers are usually still held when the wheel closes; wait for them to go up before sending the shortcut.
    @MainActor private static func post(_ k: KeyCombo, tries: Int) {
        let held = !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if held, tries < 25 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { MainActor.assumeIsolated { post(k, tries: tries + 1) } }
            return
        }
        guard AXIsProcessTrusted() else { HUD.show("Нужен доступ «Универсальный доступ»"); return }
        LiveKeyPoster().post(keyCode: k.keyCode, flags: k.cgFlags)
    }
}

@MainActor
final class RadialMenuController: InputTapController {
    static let shared = RadialMenuController()
    @Published private(set) var settings = RadialSettings()
    private let store = RadialSettingsStore()
    private var controller: RadialController?
    private var stage: RadialStage?
    private var presenter: RadialPanelPresenter?
    private var detector = FourFingerTapDetector()
    private var touchID: Int?
    @Published private(set) var touchFailed = false

    init() { super.init(.radialMenu) }

    override func startImpl() {
        settings = store.load()
        let pr = RadialPanelPresenter()
        presenter = pr
        let ctl = RadialController(
            settings: { [weak self] in MainActor.assumeIsolated { self?.settings ?? RadialSettings() } },
            presenter: pr, runner: RadialMenuRunner(),
            frontBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            screenFrame: { Self.screenFrame(at: $0) },
            trusted: { AXIsProcessTrusted() })
        controller = ctl
        let st = RadialStage(hub: .shared, controller: ctl)
        st.start()
        stage = st
        applyTrigger()
    }

    override func stopImpl() {
        detachTouch()
        stage?.stop()
        stage = nil
        controller?.cancel()
        controller = nil
        presenter = nil
        HotkeyManager.shared.release(id: InterceptedKeys.radialID)
    }

    private static func screenFrame(at p: CGPoint) -> CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let ns = NSPoint(x: p.x, y: primary - p.y)
        let screen = NSScreen.screens.first { NSMouseInRect(ns, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
    }

    private func applyTrigger() {
        if settings.trigger.hotkeyEnabled {
            HotkeyManager.shared.reserve(id: InterceptedKeys.radialID, title: "Радиальное меню", combo: settings.trigger.hotkey)
        } else {
            HotkeyManager.shared.release(id: InterceptedKeys.radialID)
        }
        if settings.trigger.fourFingerTap { attachTouch() } else { detachTouch() }
    }

    private func attachTouch() {
        guard touchID == nil else { return }
        detector.reset()
        touchID = TouchHub.shared.attach { [weak self] f in
            guard let self, self.detector.ingest(f) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.controller?.handle(.fourFingerTap) } }
        }
        touchFailed = touchID == nil
    }

    private func detachTouch() {
        if let id = touchID { TouchHub.shared.detach(id) }
        touchID = nil
    }

    func update(_ s: RadialSettings) {
        settings = s.sanitized
        store.save(settings)
        guard running else { return }
        applyTrigger()
    }

    var previewState: RadialViewState {
        let p = settings.activeProfile
        return RadialViewState(center: .zero, items: p.items, hovered: nil, mode: .sticky, depth: 0, title: p.name, geometry: settings.geometry, showTitles: settings.showTitles)
    }
}

@MainActor
final class RadialMenuModule: Module {
    let info = ModuleID.radialMenu.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { RadialMenuController.shared.start(); Log.write("module radialMenu start") }
    func stop() { RadialMenuController.shared.stop(); Log.write("module radialMenu stop") }
}

// MARK: wheel drawing

struct RadialWheelHost: View {
    @ObservedObject var model: RadialPanelModel

    var body: some View {
        if let s = model.state { RadialWheelView(state: s) } else { Color.clear }
    }
}

struct RadialWedge: Shape {
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func pt(_ r: Double, _ deg: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + CGFloat(sin(a) * r), y: c.y - CGFloat(cos(a) * r))
        }
        var p = Path()
        let steps = max(Int((end - start) / 3), 2)
        p.move(to: pt(outer, start))
        for i in 1...steps { p.addLine(to: pt(outer, start + (end - start) * Double(i) / Double(steps))) }
        for i in stride(from: steps, through: 0, by: -1) { p.addLine(to: pt(inner, start + (end - start) * Double(i) / Double(steps))) }
        p.closeSubpath()
        return p
    }
}

struct RadialWheelView: View {
    let state: RadialViewState

    var body: some View {
        let g = state.geometry
        let n = max(state.items.count, 1)
        let gap = n > 1 ? 1.2 : 0.0
        ZStack {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                let span = g.span(index: i, count: n)
                let hot = state.hovered == i
                RadialWedge(start: span.start + gap, end: span.end - gap, inner: g.innerRadius + 2, outer: g.outerRadius)
                    .fill(hot ? Theme.accent : Color(nsColor: .windowBackgroundColor).opacity(0.86))
                RadialWedge(start: span.start + gap, end: span.end - gap, inner: g.innerRadius + 2, outer: g.outerRadius)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
                let off = g.offset(index: i, count: n, radius: g.labelRadius)
                VStack(spacing: 3) {
                    Image(systemName: item.symbol).font(.system(size: 20, weight: .medium))
                    if state.showTitles { Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 82) }
                }
                .foregroundStyle(hot ? Color.white : Theme.primaryText)
                .offset(x: CGFloat(off.dx), y: CGFloat(off.dy))
            }
            Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)).frame(width: g.innerRadius * 2, height: g.innerRadius * 2)
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.6).frame(width: g.innerRadius * 2, height: g.innerRadius * 2)
            VStack(spacing: 1) {
                if state.depth > 0 { Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)) }
                Text(centerText).font(.system(size: 9.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.muted).frame(width: g.innerRadius * 1.7)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 3)
    }

    private var centerText: String {
        if let h = state.hovered, state.items.indices.contains(h) { return "" }
        return state.title
    }
}
