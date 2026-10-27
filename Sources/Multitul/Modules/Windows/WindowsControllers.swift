import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore

@MainActor
final class WindowsShared {
    static let shared = WindowsShared()
    let store = WindowSettingsStore()
    let ax = AXWindowDriver()
    let overlay = SnapPreviewOverlay()
    let scheduler = LiveTimerScheduler()
    let dockPreference = LiveDockPreference()

    func conflicts(for module: ModuleID) -> [String] {
        WindowConflicts.detect(running: NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) }, for: module)
    }
}

@MainActor
class WindowsTapController: InputTapController {
    var tapRequired: Bool { true }
    var healthy: Bool { trusted && (!tapRequired || tapActive) }

    override func refreshStatus() {
        trusted = AXIsProcessTrusted()
        tapActive = running && EventTapHub.shared.isRunning
        conflicts = WindowsShared.shared.conflicts(for: moduleID)
    }
}

@MainActor
final class WindowLayoutController: WindowsTapController {
    static let shared = WindowLayoutController()
    @Published private(set) var settings = WindowLayoutSettings()
    @Published var lastMessage: String?
    @Published private(set) var systemTilingOn = false
    private(set) var engine: WindowLayoutEngine!
    private var tracker: EdgeDragTracker?
    private var edgeStage: EdgeSnapStage?
    private var gestureStage: ModifierGestureStage?
    private var ringStage: WindowRingStage?
    private var activation: NSObjectProtocol?
    private let owner = ModuleID.windowLayout.rawValue
    private var hotkeysOff = false

    init() {
        super.init(.windowLayout)
        engine = WindowLayoutEngine(driver: WindowsShared.shared.ax) { [weak self] in self?.settings ?? WindowLayoutSettings() }
    }

    override var tapRequired: Bool { settings.edge.enabled || (settings.gesture.enabled && settings.gesture.isValid) || settings.ring.enabled }

    override func startImpl() {
        settings = WindowsShared.shared.store.loadLayout()
        let t = EdgeDragTracker(driver: WindowsShared.shared.ax, engine: engine, preview: WindowsShared.shared.overlay) { [weak self] in self?.settings ?? WindowLayoutSettings() }
        tracker = t
        edgeStage = EdgeSnapStage(hub: .shared, tracker: t, trusted: { AXIsProcessTrusted() })
        gestureStage = ModifierGestureStage(hub: .shared, driver: WindowsShared.shared.ax, settings: { [weak self] in self?.settings.gesture ?? GestureSettings() }, trusted: { AXIsProcessTrusted() })
        ringStage = WindowRingStage(hub: .shared, driver: WindowsShared.shared.ax, engine: engine, preview: WindowsShared.shared.overlay, settings: { [weak self] in self?.settings.ring ?? RingSettings() }, trusted: { AXIsProcessTrusted() })
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let me = self, me.frontmostIgnored != me.hotkeysOff else { return }
                me.applyHotkeys()
            }
        }
        applyAll()
    }

    override func stopImpl() {
        if let a = activation { NSWorkspace.shared.notificationCenter.removeObserver(a) }
        activation = nil
        edgeStage?.stop()
        gestureStage?.stop()
        ringStage?.stop()
        edgeStage = nil
        gestureStage = nil
        ringStage = nil
        tracker = nil
        HotkeyManager.shared.unregisterAll(owner: owner)
        HotkeyManager.shared.release(id: InterceptedKeys.windowRingID)
        WindowsShared.shared.overlay.hide()
    }

    func update(_ s: WindowLayoutSettings) {
        let old = settings
        settings = s.sanitized
        WindowsShared.shared.store.saveLayout(settings)
        guard running else { return }
        let hotkeysChanged = old.shortcutsEnabled != settings.shortcutsEnabled || old.cursorDisplayEnabled != settings.cursorDisplayEnabled || old.ignoredApps != settings.ignoredApps
        applyAll(hotkeys: hotkeysChanged)
    }

    private func applyAll(hotkeys: Bool = true) {
        if hotkeys { applyHotkeys() }
        sync(edgeStage, on: settings.edge.enabled) { $0.start() } stop: { $0.stop() }
        sync(gestureStage, on: settings.gesture.enabled && settings.gesture.isValid) { $0.start() } stop: { $0.stop() }
        if settings.ring.enabled {
            HotkeyManager.shared.reserve(id: InterceptedKeys.windowRingID, title: "Кольцо раскладки окон", combo: settings.ring.trigger)
        } else {
            HotkeyManager.shared.release(id: InterceptedKeys.windowRingID)
        }
        sync(ringStage, on: settings.ring.enabled) { $0.start() } stop: { $0.stop() }
        refreshStatus()
        refreshSystemTiling()
    }

    private func sync<T: AnyObject>(_ stage: T?, on: Bool, start: (T) -> Void, stop: (T) -> Void) {
        guard let stage else { return }
        if on { start(stage) } else { stop(stage) }
    }

    func refreshSystemTiling() {
        let d = UserDefaults(suiteName: "com.apple.WindowManager")
        let spaces = UserDefaults(suiteName: "com.apple.spaces")
        let spans = (spaces?.object(forKey: "spans-displays") as? Bool) ?? false
        systemTilingOn = SystemTilingProbe.isEnabled(valueFor: { k in d?.object(forKey: k) == nil ? nil : d?.bool(forKey: k) }, displaysSpan: spans)
    }

    private var frontmostIgnored: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return settings.ignoredApps.contains(id)
    }

    func applyHotkeys() {
        let hm = HotkeyManager.shared
        hm.unregisterAll(owner: owner)
        hotkeysOff = frontmostIgnored
        guard !hotkeysOff else { return }
        if settings.shortcutsEnabled {
            for a in WindowLayoutAction.allCases { hm.register(WindowHotkeys.spec(for: a), owner: owner) { [weak self] in self?.run(a) } }
        }
        if settings.cursorDisplayEnabled {
            hm.register(WindowHotkeys.cursorNextDisplay, owner: owner) { [weak self] in self?.moveCursorToNextDisplay() }
        }
    }

    func run(_ action: WindowLayoutAction) {
        guard AXIsProcessTrusted() else {
            lastMessage = "Нужен «Универсальный доступ»"
            HUD.show("Окна: нужен «Универсальный доступ»")
            return
        }
        let r = engine.perform(action)
        lastMessage = r.message
        if let m = r.message { HUD.show("Окна: " + m) }
    }

    func runFromPanel(_ action: WindowLayoutAction) {
        guard AXIsProcessTrusted() else {
            lastMessage = "Нужен «Универсальный доступ»"
            return
        }
        guard let w = WindowsShared.shared.ax.lastForeignFocusedWindow() else {
            lastMessage = "Нет окна, которое можно двигать"
            return
        }
        let r = engine.perform(action, on: w)
        lastMessage = r.message
    }

    func moveCursorToNextDisplay() {
        guard let here = CGEvent(source: nil)?.location, let dest = engine.cursorDestination(from: here) else {
            HUD.show("Окна: подключён один дисплей")
            return
        }
        CGWarpMouseCursorPosition(dest)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func applyHintCombos() {
        for (id, combo) in WindowHintCombos.all {
            guard let spec = WindowHotkeys.all.first(where: { $0.id == id }) else { continue }
            _ = HotkeyManager.shared.setCombo(spec, to: combo)
        }
    }

    func resetCombos() {
        for spec in WindowHotkeys.all { _ = HotkeyManager.shared.resetCombo(spec) }
    }
}

@MainActor
final class MaximizerController: WindowsTapController {
    static let shared = MaximizerController()
    @Published private(set) var settings = MaximizerSettings()
    @Published private(set) var maximized = 0
    @Published private(set) var restored = 0
    private var clickEngine: MaximizerClickEngine?
    private var stage: MaximizerStage?

    init() { super.init(.windowMaximizer) }

    override func startImpl() {
        settings = WindowsShared.shared.store.loadMaximizer()
        let ax = WindowsShared.shared.ax
        let e = MaximizerClickEngine(probe: LiveZoomProbe(driver: ax), driver: ax) { [weak self] in self?.settings ?? MaximizerSettings() }
        clickEngine = e
        let st = MaximizerStage(hub: .shared, engine: e, trusted: { AXIsProcessTrusted() })
        st.start()
        stage = st
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
        clickEngine = nil
    }

    override func refreshStatus() {
        super.refreshStatus()
        maximized = clickEngine?.maximizedCount ?? 0
        restored = clickEngine?.restoredCount ?? 0
    }

    func update(_ s: MaximizerSettings) {
        settings = s.sanitized
        WindowsShared.shared.store.saveMaximizer(settings)
    }
}

@MainActor
final class DockClickController: WindowsTapController {
    static let shared = DockClickController()
    @Published private(set) var settings = DockClickSettings()
    @Published private(set) var handled = 0
    private var engine: DockClickEngine?
    private var stage: DockClickStage?

    init() { super.init(.dockClick) }

    override func startImpl() {
        settings = WindowsShared.shared.store.loadDockClick()
        let e = DockClickEngine(driver: LiveDockDriver(driver: WindowsShared.shared.ax)) { [weak self] in self?.settings ?? DockClickSettings() }
        engine = e
        let st = DockClickStage(hub: .shared, engine: e, trusted: { AXIsProcessTrusted() })
        st.start()
        stage = st
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
        engine = nil
    }

    override func refreshStatus() {
        super.refreshStatus()
        handled = engine?.handledCount ?? 0
    }

    func update(_ s: DockClickSettings) {
        settings = s
        WindowsShared.shared.store.saveDockClick(s)
    }
}

@MainActor
final class AutoQuitController: ObservableObject {
    static let shared = AutoQuitController()
    @Published private(set) var settings = AutoQuitSettings()
    @Published private(set) var running = false
    @Published private(set) var trusted = true
    @Published private(set) var quitCount = 0
    @Published private(set) var watched = 0
    private var service: AutoQuitService?
    private var watcher: AutoQuitWatcher?

    func start() {
        guard !running else { return }
        running = true
        settings = WindowsShared.shared.store.loadAutoQuit()
        let driver = LiveAutoQuitDriver()
        let s = AutoQuitService(driver: driver, timers: WindowsShared.shared.scheduler) { [weak self] in self?.settings ?? AutoQuitSettings() }
        service = s
        let w = AutoQuitWatcher(service: s, driver: driver)
        watcher = w
        refreshStatus()
        if trusted { w.start() }
    }

    func stop() {
        guard running else { return }
        running = false
        watcher?.stop()
        watcher = nil
        service = nil
    }

    func refreshStatus() {
        trusted = AXIsProcessTrusted()
        quitCount = service?.quitLog.count ?? 0
        watched = watcher?.watchedCount ?? 0
    }

    func retry() {
        watcher?.stop()
        refreshStatus()
        if trusted { watcher?.start() }
    }

    func update(_ s: AutoQuitSettings) {
        settings = s.sanitized
        WindowsShared.shared.store.saveAutoQuit(settings)
    }
}

@MainActor
final class SpacesOrderController: ObservableObject {
    static let shared = SpacesOrderController()
    @Published private(set) var running = false
    @Published private(set) var holding = false
    @Published private(set) var message: String?
    var keepOnTerminate = false
    private let hold: SpacesOrderHold
    private var observers: [NSObjectProtocol] = []

    init() {
        hold = SpacesOrderHold(driver: WindowsShared.shared.dockPreference, store: UserDefaults.standard)
    }

    static func recoverStale(moduleEnabled: Bool) {
        guard !moduleEnabled else { return }
        let h = SpacesOrderHold(driver: WindowsShared.shared.dockPreference, store: UserDefaults.standard)
        if h.isHolding {
            let r = h.release()
            Log.write("spacesOrder recoverStale -> \(r)")
        }
    }

    func start() {
        guard !running else { return }
        running = true
        report(hold.hold())
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUser() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUser() }
        })
    }

    func stop() {
        guard running else { return }
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        guard !keepOnTerminate else { return }
        report(hold.release())
    }

    func recheck() {
        message = nil
        if running { report(hold.hold()) }
    }

    private func checkUser() {
        guard running, hold.reconcile() != nil else { return }
        holding = false
        message = "Порядок столов снова включён в Системных настройках — модуль отпустил настройку. Выключи и включи модуль, чтобы вернуть фиксированный порядок"
        Log.write("spacesOrder user took back control")
    }

    private func report(_ r: SpacesOrderResult) {
        holding = hold.isHolding
        switch r {
        case .held, .alreadyHeld, .released, .nothingToRelease: message = nil
        case .userTookBack: message = "Настройку уже вернули вручную"
        case .blockedByProfile: message = "Настройка закреплена профилем управления — менять её нельзя"
        case .failed(let why): message = why
        }
        Log.write("spacesOrder \(r) holding=\(holding)")
    }
}
