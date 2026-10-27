import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore

@MainActor
final class SwitcherShared {
    static let shared = SwitcherShared()
    let store = SwitcherSettingsStore()
    let source = LiveSwitcherSource()
    let order = WindowUseOrder()
    let cache = ThumbnailCache()
    let capturer = SCKThumbnailCapturer()
    let timers = LiveTimerScheduler()
    let actor: LiveSwitcherActor
    private var users = 0
    private var activation: NSObjectProtocol?

    init() {
        let engine = WindowLayoutEngine(driver: WindowsShared.shared.ax) { WindowsShared.shared.store.loadLayout() }
        actor = LiveSwitcherActor(source: source, driver: WindowsShared.shared.ax, engine: engine)
    }

    var screenRecordingGranted: Bool { SCKThumbnailCapturer.hasPermission }

    func acquire() {
        users += 1
        guard users == 1 else { return }
        source.start()
        let me = ProcessInfo.processInfo.processIdentifier
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.processIdentifier != me else { return }
            MainActor.assumeIsolated { self?.order.touchApp(a.processIdentifier) }
        }
    }

    func release() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        source.stop()
        if let a = activation { NSWorkspace.shared.notificationCenter.removeObserver(a) }
        activation = nil
        cache.prune(keeping: [])
    }
}

@MainActor
final class SwitcherController: WindowsTapController {
    static let shared = SwitcherController()
    @Published private(set) var settings = SwitcherSettings()
    @Published private(set) var takeoverNote: String?
    @Published private(set) var holdingNative = false
    private var engine: SwitcherEngine?
    private var machine: SwitcherKeyMachine?
    private var stage: SwitcherStage?
    private var watchdog: Timer?
    private let takeover = SystemShortcutTakeover(driver: LiveSymbolicHotKeys())
    private var reserved: [KeyCombo] = []

    init() { super.init(.windowSwitcher) }

    static func recoverStale(moduleEnabled: Bool) {
        let t = SystemShortcutTakeover(driver: LiveSymbolicHotKeys())
        if let r = t.recoverStale(moduleEnabled: moduleEnabled) { Log.write("windowSwitcher recoverStale -> \(r)") }
    }

    override func startImpl() {
        let shared = SwitcherShared.shared
        settings = shared.store.loadSwitcher()
        shared.acquire()
        let model = SwitcherPanelModel(cache: shared.cache)
        let panel = SwitcherPanelController(model: model)
        let thumbs = ThumbnailService(capturer: shared.capturer, cache: shared.cache)
        let e = SwitcherEngine(source: shared.source, actor: shared.actor, panel: panel, thumbs: thumbs, order: shared.order,
                               settings: { [weak self] in self?.settings ?? SwitcherSettings() }, screenRecording: { SCKThumbnailCapturer.hasPermission })
        let m = SwitcherKeyMachine(controller: e, timers: shared.timers, settings: { [weak self] in self?.settings ?? SwitcherSettings() }, trusted: { AXIsProcessTrusted() })
        e.onEnded = { [weak m] in m?.panelClosedExternally() }
        model.actions = PanelActions(hover: { [weak e] id in e?.select(id: id) }, activate: { [weak e] id in e?.activateEntry(id: id) },
                                     close: { [weak e] id in e?.closeEntry(id: id) }, quit: { [weak e] pid in e?.quitEntry(pid: pid) })
        engine = e
        machine = m
        let st = SwitcherStage(hub: .shared, machine: m)
        st.start()
        stage = st
        applyReservations()
        applyTakeover()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTakeover() }
        }
    }

    override func stopImpl() {
        watchdog?.invalidate()
        watchdog = nil
        stage?.stop()
        stage = nil
        machine = nil
        engine?.cancel()
        engine = nil
        HotkeyManager.shared.release(id: InterceptedKeys.switcherAppsID)
        HotkeyManager.shared.release(id: InterceptedKeys.switcherWindowsID)
        reserved = []
        let r = takeover.release()
        holdingNative = false
        takeoverNote = nil
        Log.write("windowSwitcher takeover release -> \(r)")
        SwitcherShared.shared.release()
    }

    override func refreshStatus() {
        super.refreshStatus()
        if running { applyTakeover() }
    }

    func update(_ s: SwitcherSettings) {
        settings = s.sanitized
        SwitcherShared.shared.store.saveSwitcher(settings)
        guard running else { return }
        applyReservations()
        applyTakeover()
    }

    private func applyReservations() {
        let combos = settings.reservedCombos
        guard combos != reserved else { return }
        let hm = HotkeyManager.shared
        hm.release(id: InterceptedKeys.switcherAppsID)
        hm.release(id: InterceptedKeys.switcherWindowsID)
        hm.reserve(id: InterceptedKeys.switcherAppsID, title: "Переключатель окон: приложения", combo: combos[0])
        hm.reserve(id: InterceptedKeys.switcherWindowsID, title: "Переключатель окон: окна приложения", combo: combos[1])
        reserved = combos
    }

    private func applyTakeover() {
        let hold = TakeoverPolicy.shouldHoldNative(takeOver: settings.takeOverSystem, trusted: AXIsProcessTrusted(), tapRunning: EventTapHub.shared.isRunning)
        let before = takeover.journal
        let r = hold ? takeover.hold() : takeover.release()
        let now = takeover.journal
        if before != now { Log.write("windowSwitcher takeover hold=\(hold) -> \(r)") }
        holdingNative = takeover.isHolding
        switch r {
        case .unavailable where settings.takeOverSystem: takeoverNote = "Системный ⌘Tab отключить не удалось (нужные вызовы macOS недоступны): сработают оба переключателя. Выключи «Заменить системные ⌘Tab и ⌘`» и назначь свои сочетания."
        case .failed(let why): takeoverNote = why
        default: takeoverNote = nil
        }
    }
}

@MainActor
final class DockPreviewController: WindowsTapController {
    static let shared = DockPreviewController()
    @Published private(set) var settings = DockPreviewSettings()
    @Published private(set) var shown = 0
    private var engine: DockPreviewEngine?
    private var stage: DockPreviewStage?
    private var activation: NSObjectProtocol?

    init() { super.init(.dockPreview) }

    override func startImpl() {
        let shared = SwitcherShared.shared
        settings = shared.store.loadDockPreview()
        shared.acquire()
        let model = DockPreviewPanelModel(cache: shared.cache)
        let panel = DockPreviewPanelController(model: model)
        let thumbs = ThumbnailService(capturer: shared.capturer, cache: shared.cache)
        let e = DockPreviewEngine(driver: LiveDockPreviewDriver(driver: WindowsShared.shared.ax), source: shared.source, actor: shared.actor, panel: panel, thumbs: thumbs, timers: shared.timers,
                                  order: shared.order, settings: { [weak self] in self?.settings ?? DockPreviewSettings() }, screenRecording: { SCKThumbnailCapturer.hasPermission },
                                  trusted: { AXIsProcessTrusted() })
        model.actions = PanelActions(hover: { _ in }, activate: { [weak e] id in e?.focus(id: id) }, close: { [weak e] id in e?.close(id: id) },
                                     quit: { [weak e] pid in
                                         SwitcherShared.shared.actor.quit(pid: pid)
                                         e?.hide()
                                     },
                                     minimize: { [weak e] id in e?.minimize(id: id) }, place: { [weak e] id, a in e?.place(id: id, a) })
        engine = e
        let st = DockPreviewStage(hub: .shared, engine: e)
        st.start()
        stage = st
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.hide() }
        }
    }

    override func stopImpl() {
        if let a = activation { NSWorkspace.shared.notificationCenter.removeObserver(a) }
        activation = nil
        stage?.stop()
        stage = nil
        engine?.hide()
        engine = nil
        SwitcherShared.shared.release()
    }

    override func refreshStatus() {
        super.refreshStatus()
        shown = engine?.shownCount ?? 0
    }

    func update(_ s: DockPreviewSettings) {
        settings = s.sanitized
        SwitcherShared.shared.store.saveDockPreview(settings)
    }
}
