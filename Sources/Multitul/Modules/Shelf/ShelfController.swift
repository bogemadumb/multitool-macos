import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ShelfController: ObservableObject {
    static let shared = ShelfController()

    @Published private(set) var settings = ShelfSettings()
    @Published private(set) var count = 0
    @Published private(set) var running = false
    @Published private(set) var storeError: String?

    private let settingsStore = ShelfSettingsStore()
    private(set) var service: ShelfService?
    private(set) var model: ShelfViewModel?
    private(set) var intake: ShelfIntake?
    private(set) var panel: ShelfPanelController?
    private let statusItem = ShelfStatusItem()
    private var session: ShelfDragSession?
    private var monitors: [Any] = []
    private var droppedThisDrag = false
    let quickLook = ShelfQuickLook()

    var spec: HotkeySpec { ShelfHotkeys.toggle }
    var isShown: Bool { panel?.isShown == true }

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        do {
            let store = try ShelfStore.open()
            let svc = ShelfService(store: store, fs: LiveShelfFileSystem(), settings: settings)
            service = svc
            storeError = nil
            let removed = svc.cleanupOrphans()
            if !removed.isEmpty { Log.write("shelf cleanup removed=\(removed.count)") }
            let m = ShelfViewModel(service: svc)
            m.actions = self
            model = m
            let take = ShelfIntake(service: svc)
            take.onAdded = { [weak self] r in self?.added(r) }
            intake = take
            let pc = ShelfPanelController(model: m, intake: take)
            pc.placement = { [weak self] in self?.settings.placement ?? .nearCursor }
            pc.statusFrame = { [weak self] in self?.statusItem.iconFrame }
            panel = pc
            svc.onChange = { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        } catch {
            storeError = "\(error)"
            Log.write("shelf store open failed: \(error)")
        }
        statusItem.intake = intake
        statusItem.onLeftClick = { [weak self] in self?.toggle(reason: .menuBarClick) }
        statusItem.menuProvider = { [weak self] in self?.statusMenu() ?? NSMenu() }
        applyStatusItem()
        installDragWatcher()
        HotkeyManager.shared.register(spec, owner: ModuleID.shelf.rawValue) { [weak self] in self?.toggle(reason: .hotkey) }
        refreshCount()
        Log.write("shelf start store=\(service != nil)")
    }

    func stop() {
        guard running else { return }
        running = false
        HotkeyManager.shared.unregisterAll(owner: ModuleID.shelf.rawValue)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        session = nil
        statusItem.remove()
        panel?.destroy()
        panel = nil
        quickLook.close()
        model = nil
        intake = nil
        service = nil
        Log.write("shelf stop")
    }

    func update(_ s: ShelfSettings) {
        let clean = s.sanitized
        settings = clean
        settingsStore.save(clean)
        service?.settings = clean
        applyStatusItem()
        applySessionConfig()
    }

    private func applyStatusItem() {
        if settings.menuBarIcon { statusItem.install() } else { statusItem.remove() }
        statusItem.setCount(count)
    }

    private func applySessionConfig() {
        session?.config.shakeEnabled = settings.shakeEnabled
        session?.config.sensitivity = settings.shakeSensitivity
        session?.config.excludedApps = Set(settings.excludedApps)
        session?.config.shelfVisible = isShown && panel?.reason != .menuBarDrag
    }

    private func refreshCount() {
        count = service?.count ?? 0
        statusItem.setCount(count)
    }

    func toggle(reason: ShelfOpenReason) {
        guard let panel else { return }
        if panel.isShown { panel.hide() } else { model?.refresh(); panel.show(reason: reason) }
    }

    func show(reason: ShelfOpenReason) {
        guard let panel, !panel.isShown else { return }
        model?.refresh()
        panel.show(reason: reason)
    }

    private func changed() {
        refreshCount()
        model?.refresh()
        panel?.resizeToFit()
        if let panel, panel.isShown {
            apply(ShelfAutoHide.decide(.itemsChanged, isEmpty: service?.isEmpty ?? true, autoHideEmpty: settings.autoHideEmpty, openedBy: panel.reason, hovering: panel.isHovered))
        }
    }

    private func apply(_ d: ShelfAutoHideDecision) {
        if case .hide(let after) = d { panel?.hide(after: after) }
    }

    private func added(_ r: ShelfAddResult) {
        droppedThisDrag = true
        panel?.cancelPendingHide()
        if !r.added.isEmpty { HUD.show(r.added.count == 1 ? "Добавлено на полку" : "На полку: \(r.added.count)") }
        else if !r.deduped.isEmpty { HUD.show("Уже на полке") }
        if settings.closeAfterDrop { panel?.hide(after: 0.4) }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: isShown ? "Скрыть полку" : "Показать полку", action: #selector(ShelfMenuTarget.toggle), keyEquivalent: "")
        let clear = NSMenuItem(title: "Очистить (закреплённое останется)", action: #selector(ShelfMenuTarget.clear), keyEquivalent: "")
        open.target = ShelfMenuTarget.shared
        clear.target = ShelfMenuTarget.shared
        menu.addItem(open)
        menu.addItem(clear)
        return menu
    }

    private func installDragWatcher() {
        let s = ShelfDragSession(probe: LiveDragProbe(), frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
        session = s
        applySessionConfig()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type
            let t = e.timestamp
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.mouse(type, p, t) }
        }) { monitors.append(m) }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ t: TimeInterval) {
        guard let session else { return }
        switch type {
        case .leftMouseDown:
            droppedThisDrag = false
            applySessionConfig()
            session.mouseDown(at: p)
        case .leftMouseDragged:
            applySessionConfig()
            handle(session.mouseDragged(to: p, at: t))
        case .leftMouseUp:
            handle(session.mouseUp())
        default: break
        }
    }

    private func handle(_ events: [ShelfDragEvent]) {
        for e in events {
            switch e {
            case .started:
                if settings.menuBarDrop, statusItem.isInstalled, !isShown { panel?.show(reason: .menuBarDrag) }
            case .shake:
                guard let panel else { continue }
                if panel.isShown && panel.reason == .menuBarDrag { panel.hide() }
                panel.show(reason: .shake)
                Log.write("shelf shake")
            case .ended:
                guard let panel, panel.isShown else { continue }
                let dropped = droppedThisDrag
                apply(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: dropped), isEmpty: service?.isEmpty ?? true, autoHideEmpty: settings.autoHideEmpty, openedBy: panel.reason, hovering: panel.isHovered))
            }
        }
    }
}

@MainActor
final class ShelfMenuTarget: NSObject {
    static let shared = ShelfMenuTarget()
    @objc func toggle() { ShelfController.shared.toggle(reason: .menuBarClick) }
    @objc func clear() { ShelfController.shared.clearAll() }
}
