import AppKit
import SwiftUI
import MultitulCore
import MultitulUI

final class PopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PanelController: NSObject {
    private let runtime: ModuleRuntime
    private let openWindow: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: PopPanel?
    private var host: NSHostingView<AnyView>?
    private var hiddenAt = Date.distantPast
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    let layout = PanelLayoutStore()
    private var anchor = NSPoint.zero
    private var anchorVis = NSRect.zero
    private var panelWidth: CGFloat = 340
    private var sizeReady = false
    private var shownAt = Date.distantPast
    private var revealed = true
    private static let maxPanelHeight: CGFloat = 520

    init(runtime: ModuleRuntime, openWindow: @escaping () -> Void) {
        self.runtime = runtime
        self.openWindow = openWindow
        super.init()
        if let b = item.button {
            let mark = MenuBarMark.image()
            mark.accessibilityDescription = "Мультитул"
            b.image = mark
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseDown])
        }
    }

    @objc private func clicked() { toggle() }

    func setIconHidden(_ hidden: Bool) {
        item.isVisible = !hidden
        if hidden { hide() }
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        if isShown { hide(); return }
        if Date().timeIntervalSince(hiddenAt) < 0.25 { return }
        show()
    }

    private func makePanel() -> PopPanel {
        let p = PopPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onCancel = { [weak self] in self?.hide() }
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        h.sizingOptions = []
        h.wantsLayer = true
        h.layer?.cornerRadius = PanelMetrics.windowRadius
        h.layer?.cornerCurve = .continuous
        h.layer?.masksToBounds = true
        h.layer?.borderWidth = 1
        host = h
        p.contentView = h
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.shownAt) < 0.6, let p = self.panel, p.isVisible {
                    Log.write("panel: resign key during activation, retaking")
                    p.makeKeyAndOrderFront(nil)
                    return
                }
                Log.write("panel: resign key"); self.hide()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != getpid() { MainActor.assumeIsolated { Log.write("panel: app switch to \(app?.bundleIdentifier ?? "?")"); self?.hide() } }
        })
        return p
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        guard let host else { return }
        let screen = (item.isVisible ? item.button?.window?.screen : nil) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 340
        let size = NSSize(width: width, height: 240)
        let combo = HotkeyManager.shared.combo(for: CoreHotkeys.window).display
        layout.reconcile(available: panelItemIDs(runtime))
        anchorVis = vis
        if item.isVisible, let bw = item.button?.window {
            let f = bw.frame
            anchor = NSPoint(x: min(max(f.midX - width / 2, vis.minX + 8), vis.maxX - width - 8), y: f.minY - 4)
        } else {
            anchor = NSPoint(x: vis.maxX - width - 8, y: vis.maxY - 4)
        }
        panelWidth = width
        sizeReady = false
        revealed = false
        host.rootView = AnyView(PanelView(runtime: runtime, layout: layout, windowCombo: combo, width: width, maxHeight: min(vis.height - 12, Self.maxPanelHeight), onHeight: { [weak self] h in
            MainActor.assumeIsolated { self?.applyHeight(h) }
        }, openWindow: { [weak self] in self?.openWindow() }))
        p.setFrame(NSRect(x: anchor.x, y: anchor.y - size.height, width: width, height: size.height), display: false)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        host.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.12)).cgColor
        shownAt = Date()
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        revealIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sizeReady = true; self?.revealIfNeeded() }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { Log.write("panel: outside click"); self?.hide() }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53, e.window === self?.panel { self?.hide(); return nil }
                return e
            }
        }
        Log.write("panel shown")
    }

    private func applyHeight(_ h: CGFloat) {
        guard let p = panel else { return }
        let minY = anchorVis.minY + 6
        let height = min(h, anchorVis.height - 12)
        let y = max(anchor.y - height, minY)
        p.setFrame(NSRect(x: anchor.x, y: y, width: panelWidth, height: height), display: true)
        sizeReady = true
        revealIfNeeded()
    }

    private func revealIfNeeded() {
        guard !revealed, sizeReady, let p = panel, p.isVisible else { return }
        revealed = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        hiddenAt = Date()
        p.orderOut(nil)
        host?.rootView = AnyView(EmptyView())
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        Log.write("panel hidden")
    }
}
