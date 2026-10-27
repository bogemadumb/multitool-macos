import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore

@MainActor
final class InputShared {
    static let shared = InputShared()
    let store = InputSettingsStore()
    let resolver = LivePointerAppResolver()
    let keys = LiveKeyPoster()
    let mouse = LiveMousePoster()
    let frontmost = LiveFrontmost()

    func gate(_ list: AppExceptionList) -> ExceptionGate { ExceptionGate(list: list, resolver: resolver) }

    func conflicts(for module: ModuleID) -> [String] {
        InputConflicts.detect(running: NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) }, for: module)
    }

    func chooseApp() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = false
        p.prompt = "Добавить"
        guard p.runModal() == .OK, let url = p.url, let bid = Bundle(url: url)?.bundleIdentifier else { return nil }
        return bid
    }
}

@MainActor
class InputTapController: ObservableObject {
    @Published var running = false
    @Published var tapActive = false
    @Published var trusted = true
    @Published var conflicts: [String] = []
    let moduleID: ModuleID

    init(_ id: ModuleID) { moduleID = id }

    func refreshStatus() {
        trusted = AXIsProcessTrusted()
        tapActive = running && EventTapHub.shared.isRunning
        conflicts = InputShared.shared.conflicts(for: moduleID)
    }

    func restart() {
        guard running else { return }
        stopImpl()
        running = false
        start()
    }

    func start() {
        guard !running else { return }
        running = true
        startImpl()
        refreshStatus()
        Log.write("input \(moduleID.rawValue) start trusted=\(trusted) tap=\(tapActive) conflicts=\(conflicts)")
    }

    func stop() {
        guard running else { return }
        stopImpl()
        running = false
        tapActive = false
    }

    func startImpl() {}
    func stopImpl() {}
}

@MainActor
final class ScrollInverterController: InputTapController {
    static let shared = ScrollInverterController()
    @Published private(set) var settings = ScrollInverterSettings()
    private var stage: ScrollInverterStage?
    private var gate: ExceptionGate?

    init() { super.init(.scrollInverter) }

    override func startImpl() {
        settings = InputShared.shared.store.loadInverter()
        let g = InputShared.shared.gate(settings.exceptions)
        gate = g
        let s = ScrollInverterStage(hub: .shared, gate: g, vertical: settings.vertical, horizontal: settings.horizontal)
        s.start()
        stage = s
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
    }

    func update(_ s: ScrollInverterSettings) {
        settings = s
        InputShared.shared.store.saveInverter(s)
        gate?.list = s.exceptions
        stage?.vertical = s.vertical
        stage?.horizontal = s.horizontal
    }
}

@MainActor
final class HorizontalScrollController: InputTapController {
    static let shared = HorizontalScrollController()
    @Published private(set) var settings = HorizontalScrollSettings()
    private var stage: HorizontalScrollStage?
    private var gate: ExceptionGate?

    init() { super.init(.scrollHorizontal) }

    override func startImpl() {
        settings = InputShared.shared.store.loadHorizontal()
        let g = InputShared.shared.gate(settings.exceptions)
        gate = g
        let s = HorizontalScrollStage(hub: .shared, gate: g, modifier: settings.modifier)
        s.start()
        stage = s
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
    }

    func update(_ s: HorizontalScrollSettings) {
        settings = s
        InputShared.shared.store.saveHorizontal(s)
        gate?.list = s.exceptions
        stage?.modifier = s.modifier
    }
}

@MainActor
final class LinearScrollController: InputTapController {
    static let shared = LinearScrollController()
    @Published private(set) var settings = LinearScrollSettings()
    private var stage: LinearScrollStage?
    private var gate: ExceptionGate?

    init() { super.init(.linearScroll) }

    var activeLines: Int? { running ? settings.linesPerNotch : nil }

    override func startImpl() {
        settings = InputShared.shared.store.loadLinear()
        let g = InputShared.shared.gate(settings.exceptions)
        gate = g
        let s = LinearScrollStage(hub: .shared, gate: g, linesPerNotch: settings.linesPerNotch)
        s.start()
        stage = s
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
    }

    func update(_ s: LinearScrollSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveLinear(s)
        gate?.list = s.exceptions
        stage?.linesPerNotch = settings.linesPerNotch
    }
}

@MainActor
final class SmoothScrollController: InputTapController {
    static let shared = SmoothScrollController()
    @Published private(set) var settings = SmoothScrollSettings()
    private var stage: SmoothScrollStage?
    private var runner: SmoothScrollRunner?
    private var gate: ExceptionGate?

    init() { super.init(.smoothScroll) }

    override func startImpl() {
        settings = InputShared.shared.store.loadSmooth()
        let g = InputShared.shared.gate(settings.exceptions)
        gate = g
        let r = SmoothScrollRunner(ticker: TimerFrameTicker(), poster: CGScrollPoster(), curve: SmoothCurve(response: settings.response, coast: settings.coast))
        runner = r
        let s = SmoothScrollStage(hub: .shared, gate: g, runner: r, step: settings.step, linearLines: { MainActor.assumeIsolated { LinearScrollController.shared.activeLines } })
        s.start()
        stage = s
    }

    override func stopImpl() {
        stage?.stop()
        runner?.cancel()
        stage = nil
        runner = nil
    }

    func update(_ s: SmoothScrollSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveSmooth(s)
        gate?.list = settings.exceptions
        stage?.step = settings.step
        runner?.setCurve(SmoothCurve(response: settings.response, coast: settings.coast))
    }

    func resetExceptions() {
        var s = settings
        s.exceptions = AppExceptionList(SmoothScrollSettings.suggestedExceptions)
        update(s)
    }
}

@MainActor
final class ScrollZoomController: InputTapController {
    static let shared = ScrollZoomController()
    @Published private(set) var settings = ScrollZoomSettings()
    private var stage: ScrollZoomStage?
    private var gate: ExceptionGate?

    init() { super.init(.scrollZoom) }

    override func startImpl() {
        settings = InputShared.shared.store.loadZoom()
        let g = InputShared.shared.gate(settings.exceptions)
        gate = g
        let s = ScrollZoomStage(hub: .shared, gate: g, poster: LiveMagnifyPoster(), cmdZoom: settings.cmdZoom)
        s.start()
        stage = s
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
    }

    func update(_ s: ScrollZoomSettings) {
        settings = s
        InputShared.shared.store.saveZoom(s)
        gate?.list = s.exceptions
        stage?.cmdZoom = s.cmdZoom
    }
}

@MainActor
final class ClickDebounceController: InputTapController {
    static let shared = ClickDebounceController()
    @Published private(set) var settings = ClickDebounceSettings()
    @Published private(set) var suppressed = 0
    private var stage: ClickDebounceStage?
    private var poll: Timer?

    init() { super.init(.mouseClickDebounce) }

    override func startImpl() {
        settings = InputShared.shared.store.loadClick()
        let s = ClickDebounceStage(hub: .shared, settings: settings)
        s.start()
        stage = s
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.suppressed = self?.stage?.suppressedCount ?? 0 }
        }
    }

    override func stopImpl() {
        poll?.invalidate()
        poll = nil
        stage?.stop()
        stage = nil
    }

    func update(_ s: ClickDebounceSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveClick(s)
        stage?.update(settings)
    }
}

@MainActor
final class KeyDebounceController: InputTapController {
    static let shared = KeyDebounceController()
    @Published private(set) var settings = KeyDebounceSettings()
    @Published private(set) var suppressed = 0
    private var stage: KeyDebounceStage?
    private var poll: Timer?
    private var frontmost: String?
    private var observer: NSObjectProtocol?

    init() { super.init(.keyboardDebounce) }

    override func startImpl() {
        settings = InputShared.shared.store.loadKeys()
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmost = bid }
        }
        let s = KeyDebounceStage(hub: .shared, settings: settings, frontmost: { [weak self] in MainActor.assumeIsolated { self?.frontmost } })
        s.start()
        stage = s
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.suppressed = self?.stage?.suppressedCount ?? 0 }
        }
    }

    override func stopImpl() {
        poll?.invalidate()
        poll = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observer = nil
        stage?.stop()
        stage = nil
    }

    override func refreshStatus() {
        super.refreshStatus()
        trusted = trusted && CGPreflightListenEventAccess()
    }

    func update(_ s: KeyDebounceSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveKeys(s)
        stage?.update(settings)
    }

    func setWindow(_ ms: Int?, for keyCode: Int64) {
        var s = settings
        if let ms { s.keyWindows[keyCode] = ms } else { s.keyWindows.removeValue(forKey: keyCode) }
        update(s)
    }
}

@MainActor
final class FocusFollowsController: InputTapController {
    static let shared = FocusFollowsController()
    @Published private(set) var settings = FocusFollowsSettings()
    @Published private(set) var focused = 0
    private var engine: FocusFollowsEngine?
    private var stage: FocusFollowsStage?
    private var timer: Timer?

    init() { super.init(.focusFollowsMouse) }

    override func startImpl() {
        settings = InputShared.shared.store.loadFocus()
        let e = FocusFollowsEngine(settings: settings, driver: LiveFocusDriver())
        engine = e
        let s = FocusFollowsStage(hub: .shared, engine: e)
        s.onMove = { [weak self] in MainActor.assumeIsolated { self?.ensureTimer() } }
        s.start()
        stage = s
    }

    override func stopImpl() {
        timer?.invalidate()
        timer = nil
        stage?.stop()
        stage = nil
        engine = nil
    }

    func update(_ s: FocusFollowsSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveFocus(s)
        engine?.settings = settings
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let engine else { return }
        let r = engine.tick(now: ProcessInfo.processInfo.systemUptime)
        if case .focused = r { focused = engine.focusCount }
        if !engine.hasPending {
            timer?.invalidate()
            timer = nil
        }
    }
}

@MainActor
final class MouseAccelerationController: ObservableObject {
    static let shared = MouseAccelerationController()
    @Published private(set) var running = false
    @Published private(set) var devices: [PointerDevice] = []
    @Published private(set) var lastReport = AccelApplyReport()
    @Published var conflicts: [String] = []

    private let driver = IOHIDPointerAccelDriver()
    private lazy var engine = MouseAccelerationEngine(driver: driver, store: DefaultsAccelJournal())
    private let watcher = HIDMouseWatcher()
    private var schedule = AccelReapplySchedule()

    static func recoverStale() {
        guard !DefaultsAccelJournal().load().isEmpty else { return }
        let n = shared.engine.recoverPending()
        if n > 0 { Log.write("mouseAcceleration recovered \(n) after unclean exit") }
    }

    func start() {
        guard !running else { return }
        running = true
        _ = engine.recoverPending()
        reapplyNow()
        watcher.start { [weak self] in MainActor.assumeIsolated { self?.hotplug() } }
        conflicts = InputShared.shared.conflicts(for: .mouseAcceleration)
        Log.write("mouseAcceleration start devices=\(devices.count) report=\(lastReport)")
    }

    func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        _ = schedule.restart()
        let n = engine.restore()
        devices = driver.mice()
        Log.write("mouseAcceleration stop restored=\(n)")
    }

    func refresh() {
        devices = driver.mice()
        conflicts = InputShared.shared.conflicts(for: .mouseAcceleration)
    }

    private func reapplyNow() {
        lastReport = engine.apply()
        devices = driver.mice()
    }

    private func hotplug() {
        let t = schedule.restart()
        step(t)
    }

    private func step(_ t: Int) {
        guard running, let delay = schedule.next(for: t) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.reapplyNow()
                self.step(t)
            }
        }
    }
}
