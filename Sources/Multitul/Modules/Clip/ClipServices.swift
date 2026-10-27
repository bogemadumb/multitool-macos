import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class ClipServices {
    static let shared = ClipServices()

    let pasteboard = LivePasteboard()
    let keys = LiveKeystrokes()
    let scheduler = LiveScheduler()
    let activator = LiveActivator()
    let frontmost = LiveFrontmost()
    let settingsStore = ClipSettingsStore()
    private var timer: Timer?
    private(set) var lastExternal: AppIdentity?
    private var activationObserver: NSObjectProtocol?

    private init() {
        lastExternal = frontmost.frontmost().flatMap { $0.pid == getpid() ? nil : $0 }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            let id = AppIdentity(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
            MainActor.assumeIsolated { self?.lastExternal = id }
        }
    }

    private(set) lazy var watcher: PasteboardWatcher = {
        let w = PasteboardWatcher(pasteboard: pasteboard, frontmost: frontmost)
        w.onActiveChange = { [weak self] on in
            MainActor.assumeIsolated { self?.setTimer(on) }
        }
        return w
    }()

    private func setTimer(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: settingsStore.loadClipboard().pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func acknowledge() { watcher.acknowledgeOwnWrite() }
}

@MainActor
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    @Published private(set) var settings = ClipSettings()
    @Published private(set) var count = 0
    @Published private(set) var totalBytes = 0
    @Published private(set) var running = false
    @Published private(set) var storeError: String?
    @Published private(set) var lastItem: ClipItem?

    private let services = ClipServices.shared
    private(set) var store: ClipStore?
    private(set) var engine: ClipPasteEngine?
    private var recorder: ClipboardRecorder?
    private var autoClear: ClipAutoClear?
    private var tokens: [PasteboardWatcher.Token] = []
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    let picker = ClipPickerController()

    var spec: HotkeySpec { ClipHotkeys.picker }

    func start() {
        guard !running else { return }
        running = true
        settings = services.settingsStore.loadClipboard()
        do {
            store = try ClipStore.open()
            storeError = nil
        } catch {
            store = nil
            storeError = "\(error)"
            Log.write("clipboard store open failed: \(error)")
        }
        let eng = ClipPasteEngine(pasteboard: services.pasteboard, keys: services.keys, activator: services.activator, scheduler: services.scheduler) { [services] in services.acknowledge() }
        engine = eng
        if let store {
            let rec = ClipboardRecorder(pasteboard: services.pasteboard, store: store, settings: settings, ownBundleID: Bundle.main.bundleIdentifier)
            rec.onRecorded = { [weak self] it in
                MainActor.assumeIsolated { self?.recorded(it) }
            }
            recorder = rec
            tokens.append(services.watcher.subscribe(priority: 10) { change in rec.handle(change) })
            _ = try? store.prune(settings)
        }
        let clear = ClipAutoClear(pasteboard: services.pasteboard, scheduler: services.scheduler, seconds: settings.autoClearSeconds) { [services] in services.acknowledge() }
        autoClear = clear
        tokens.append(services.watcher.subscribe(priority: 20) { change in clear.handle(change) })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.settings.clearOnSleep == true { self?.autoClear?.clearNow() } }
        })
        lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.settings.clearOnLock == true { self?.autoClear?.clearNow() } }
        })
        HotkeyManager.shared.register(spec, owner: ModuleID.clipboardHistory.rawValue) { [weak self] in self?.picker.toggle() }
        picker.attach(self)
        refreshCounts()
        Log.write("clipboard start store=\(store != nil)")
    }

    func stop() {
        guard running else { return }
        running = false
        for t in tokens { services.watcher.unsubscribe(t) }
        tokens = []
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        for o in lockObservers { DistributedNotificationCenter.default().removeObserver(o) }
        lockObservers = []
        HotkeyManager.shared.unregisterAll(owner: ModuleID.clipboardHistory.rawValue)
        picker.close()
        recorder = nil
        autoClear = nil
        engine = nil
        store = nil
        onChange = nil
    }

    func update(_ s: ClipSettings) {
        let clean = s.sanitized
        settings = clean
        services.settingsStore.saveClipboard(clean)
        recorder?.settings = clean
        autoClear?.seconds = clean.autoClearSeconds
        _ = try? store?.prune(clean)
        refreshCounts()
        onChange?()
    }

    func clearHistory(keepPinned: Bool) {
        _ = try? store?.clear(keepPinned: keepPinned)
        refreshCounts()
        lastItem = nil
        onChange?()
    }

    func clearSystemClipboard() { autoClear?.clearNow() }

    func refreshCounts() {
        count = (try? store?.count()) ?? 0
        totalBytes = (try? store?.totalBytes()) ?? 0
    }

    private func recorded(_ it: ClipItem) {
        lastItem = it
        refreshCounts()
        onChange?()
    }
}

@MainActor
final class PastePlainController: ObservableObject {
    static let shared = PastePlainController()

    @Published private(set) var settings = PastePlainSettings()
    @Published private(set) var lastOutcome: PasteOutcome?
    @Published private(set) var running = false
    private var engine: PastePlainEngine?
    var spec: HotkeySpec { ClipHotkeys.pastePlain }

    func start() {
        guard !running else { return }
        running = true
        settings = ClipServices.shared.settingsStore.loadPlain()
        let s = ClipServices.shared
        engine = PastePlainEngine(pasteboard: s.pasteboard, keys: s.keys, scheduler: s.scheduler, settings: settings) { s.acknowledge() }
        HotkeyManager.shared.register(spec, owner: ModuleID.pastePlain.rawValue) { [weak self] in self?.run() }
    }

    func stop() {
        running = false
        HotkeyManager.shared.unregisterAll(owner: ModuleID.pastePlain.rawValue)
        engine = nil
    }

    func update(_ s: PastePlainSettings) {
        settings = s
        ClipServices.shared.settingsStore.savePlain(s)
        engine?.settings = s
    }

    func run() {
        guard let engine else { return }
        let out = engine.run { [weak self] result in
            MainActor.assumeIsolated { if result == .needsAccessibility { self?.lastOutcome = result; HUD.show("Нужен Универсальный доступ") } }
        }
        lastOutcome = out
        switch out {
        case .nothing: HUD.show("В буфере нет текста")
        case .needsAccessibility: HUD.show("Нужен Универсальный доступ")
        default: break
        }
    }
}

@MainActor
final class UrlCleanerController: ObservableObject {
    static let shared = UrlCleanerController()

    @Published private(set) var settings = UrlCleanerSettings()
    @Published private(set) var cleaned = 0
    @Published private(set) var lastRemoved: [String] = []
    @Published private(set) var running = false
    private var onCopy: UrlCleanOnCopy?
    private var token: PasteboardWatcher.Token?
    var spec: HotkeySpec { ClipHotkeys.cleanUrl }

    func start() {
        guard !running else { return }
        running = true
        let s = ClipServices.shared
        settings = s.settingsStore.loadUrl()
        let oc = UrlCleanOnCopy(pasteboard: s.pasteboard, settings: settings)
        oc.onCleaned = { [weak self] r in MainActor.assumeIsolated { self?.didClean(r) } }
        onCopy = oc
        token = s.watcher.subscribe(priority: 0) { change in oc.handle(change) }
        HotkeyManager.shared.register(spec, owner: ModuleID.urlCleaner.rawValue) { [weak self] in self?.cleanNow() }
    }

    func stop() {
        running = false
        if let token { ClipServices.shared.watcher.unsubscribe(token) }
        token = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.urlCleaner.rawValue)
        onCopy = nil
    }

    func update(_ s: UrlCleanerSettings) {
        settings = s
        ClipServices.shared.settingsStore.saveUrl(s)
        onCopy?.settings = s
    }

    func cleanNow() {
        guard let oc = onCopy else { return }
        if oc.cleanClipboard() == nil { HUD.show("В буфере нет ссылки с лишними параметрами") }
    }

    func preview(_ input: String) -> UrlCleanOutcome { UrlCleaner.outcome(for: UrlCleaner.clean(input, rules: settings.rules)) }

    private func didClean(_ r: UrlCleanResult) {
        ClipServices.shared.acknowledge()
        cleaned += 1
        lastRemoved = r.removed
        if settings.showHud {
            HUD.show(r.unwrapped ? "Ссылка раскрыта и очищена" : "Ссылка очищена · убрано \(r.removed.count)")
        }
    }
}
