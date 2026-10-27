import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore

@MainActor
final class MouseNavigationController: InputTapController {
    static let shared = MouseNavigationController()
    @Published private(set) var settings = MouseNavigationSettings()
    @Published private(set) var handled = 0
    private var stage: MouseNavigationStage?
    private var poll: Timer?

    init() { super.init(.mouseNavigation) }

    override func startImpl() {
        settings = InputShared.shared.store.loadNavigation()
        let s = MouseNavigationStage(hub: .shared, keys: InputShared.shared.keys, frontmost: InputShared.shared.frontmost, settings: settings)
        s.start()
        stage = s
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handled = self?.stage?.handledCount ?? 0 }
        }
    }

    override func stopImpl() {
        poll?.invalidate()
        poll = nil
        stage?.stop()
        stage = nil
    }

    func update(_ s: MouseNavigationSettings) {
        settings = s
        InputShared.shared.store.saveNavigation(s)
        stage?.settings = s
    }
}

@MainActor
final class ButtonShortcutsController: InputTapController {
    static let shared = ButtonShortcutsController()
    @Published private(set) var settings = ButtonShortcutsSettings()
    @Published private(set) var learning = false
    private var engine: ButtonShortcutEngine?
    private var stage: ButtonShortcutsStage?

    init() { super.init(.mouseButtonShortcuts) }

    override func startImpl() {
        settings = InputShared.shared.store.loadButtons()
        let e = ButtonShortcutEngine(settings: settings, keys: InputShared.shared.keys, mouse: InputShared.shared.mouse,
                                     symbolic: LiveSymbolicHotKeyPoster(keys: InputShared.shared.keys),
                                     frontmostBundle: { InputShared.shared.frontmost.frontmost()?.bundleID })
        let s = ButtonShortcutsStage(hub: .shared, engine: e)
        s.start()
        engine = e
        stage = s
    }

    override func stopImpl() {
        learning = false
        stage?.stop()
        stage = nil
        engine = nil
    }

    func update(_ s: ButtonShortcutsSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveButtons(s)
        engine?.settings = settings
    }

    func startLearning(_ done: @escaping (ButtonTrigger) -> Void) {
        guard let engine else { return }
        learning = true
        engine.onLearn = { [weak self] trigger in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.learning = false; done(trigger) } }
        }
    }

    func cancelLearning() {
        engine?.onLearn = nil
        learning = false
    }
}

@MainActor
final class MiddleClickController: InputTapController {
    static let shared = MiddleClickController()
    @Published private(set) var settings = MiddleClickSettings()
    @Published private(set) var deviceMissing = false
    @Published private(set) var required = 3
    @Published private(set) var converted = 0
    private var service: MiddleClickService?
    private var poll: Timer?

    init() { super.init(.middleClick) }

    override func startImpl() {
        settings = InputShared.shared.store.loadMiddle()
        let s = MiddleClickService(hub: .shared, source: TouchHub.shared.makeSource(), mouse: InputShared.shared.mouse, gesture: LiveSystemGestureInfo(), settings: settings)
        s.start()
        service = s
        sync()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.refreshSystemGesture(); self?.sync() }
        }
    }

    override func stopImpl() {
        poll?.invalidate()
        poll = nil
        service?.stop()
        service = nil
    }

    private func sync() {
        deviceMissing = service?.deviceMissing ?? false
        required = service?.requiredFingers ?? 3
        converted = (service?.convertedCount ?? 0) + (service?.tapCount ?? 0)
    }

    func update(_ s: MiddleClickSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveMiddle(s)
        service?.update(settings)
    }
}

@MainActor
final class SuperKeyController: InputTapController {
    static let shared = SuperKeyController()
    @Published private(set) var settings = SuperKeySettings()
    @Published private(set) var mappingFailed = false
    private var service: SuperKeyService?

    init() { super.init(.superKey) }

    static func recoverStale() {
        let g = SuperKeyRemapGuard(remapper: HidutilRemapper())
        guard g.applied else { return }
        g.recoverStale()
        Log.write("superKey recovered stale remap applied=\(g.applied)")
    }

    override func startImpl() {
        settings = InputShared.shared.store.loadSuperKey()
        let s = SuperKeyService(hub: .shared, settings: settings, caps: LiveCapsLock(), input: LiveInputSourceSwitcher(), keys: InputShared.shared.keys,
                                remap: SuperKeyRemapGuard(remapper: HidutilRemapper()), frontmostBundle: { InputShared.shared.frontmost.frontmost()?.bundleID })
        s.start()
        service = s
        mappingFailed = s.mappingFailed
        syncReserved()
    }

    override func stopImpl() {
        service?.stop()
        service = nil
        mappingFailed = false
        HotkeyManager.shared.release(id: InterceptedKeys.superKeyID)
    }

    override func refreshStatus() {
        super.refreshStatus()
        trusted = trusted && CGPreflightListenEventAccess()
    }

    func update(_ s: SuperKeySettings) {
        settings = s.sanitized
        InputShared.shared.store.saveSuperKey(s)
        service?.update(settings)
        mappingFailed = service?.mappingFailed ?? false
        syncReserved()
    }

    private func syncReserved() {
        if settings.source == .capsLock {
            HotkeyManager.shared.reserve(id: InterceptedKeys.superKeyID, title: "Супер-клавиша (Caps Lock)", combo: InterceptedKeys.superKeyCaps)
        } else {
            HotkeyManager.shared.release(id: InterceptedKeys.superKeyID)
        }
    }
}

@MainActor
final class QuitProtectionController: InputTapController {
    static let shared = QuitProtectionController()
    @Published private(set) var settings = QuitProtectionSettings()
    private var engine: QuitProtectionEngine?
    private var stage: QuitProtectionStage?

    init() { super.init(.quitProtection) }

    override func startImpl() {
        settings = InputShared.shared.store.loadQuit()
        let e = QuitProtectionEngine(settings: settings, frontmost: InputShared.shared.frontmost, timers: LiveTimerScheduler(), keys: InputShared.shared.keys,
                                     hud: { text in MainActor.assumeIsolated { HUD.show(text) } })
        let s = QuitProtectionStage(hub: .shared, engine: e)
        s.start()
        engine = e
        stage = s
        syncReserved()
    }

    override func stopImpl() {
        stage?.stop()
        stage = nil
        engine = nil
        HotkeyManager.shared.release(id: InterceptedKeys.quitID)
        HotkeyManager.shared.release(id: InterceptedKeys.closeID)
    }

    override func refreshStatus() {
        super.refreshStatus()
        trusted = trusted && CGPreflightListenEventAccess()
    }

    func update(_ s: QuitProtectionSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveQuit(s)
        engine?.settings = settings
        syncReserved()
    }

    private func syncReserved() {
        let hk = HotkeyManager.shared
        if settings.quit.mode != .off { hk.reserve(id: InterceptedKeys.quitID, title: "Защита ⌘Q", combo: InterceptedKeys.quit) } else { hk.release(id: InterceptedKeys.quitID) }
        if settings.close.mode != .off { hk.reserve(id: InterceptedKeys.closeID, title: "Защита ⌘W", combo: InterceptedKeys.close) } else { hk.release(id: InterceptedKeys.closeID) }
    }
}

@MainActor
final class SnippetsController: InputTapController {
    static let shared = SnippetsController()
    @Published private(set) var settings = SnippetSettings()
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var expanded = 0
    @Published var message: String?
    private(set) var store: SnippetStore?
    private var engine: SnippetEngine?
    private(set) var expander: SnippetExpander?
    private var stage: SnippetStage?
    private var poll: Timer?
    let library = SnippetLibraryController()

    init() { super.init(.textSnippets) }

    var spec: HotkeySpec { SnippetHotkeys.library }

    override func startImpl() {
        settings = InputShared.shared.store.loadSnippets()
        do {
            store = try SnippetStore.open()
            message = nil
        } catch {
            store = nil
            message = "База сниппетов не открылась: \(error)"
            Log.write("snippets store open failed: \(error)")
        }
        let services = ClipServices.shared
        let secure = LiveSecureInput()
        let exp = SnippetExpander(pasteboard: services.pasteboard, keys: InputShared.shared.keys, scheduler: services.scheduler, secure: secure, focus: AXSecureFocusInspector(),
                                  frontmost: services.frontmost, settings: settings, acknowledge: { MainActor.assumeIsolated { ClipServices.shared.acknowledge() } })
        exp.onExpanded = { [weak self] s in
            MainActor.assumeIsolated {
                try? self?.store?.markUsed(id: s.id)
                self?.expanded += 1
            }
        }
        let eng = SnippetEngine(settings: settings, expander: exp, secure: secure, frontmost: services.frontmost, scheduler: services.scheduler)
        expander = exp
        engine = eng
        reload()
        let st = SnippetStage(hub: .shared, engine: eng)
        st.start()
        stage = st
        library.attach(self)
    }

    override func stopImpl() {
        library.close()
        stage?.stop()
        stage = nil
        engine = nil
        expander = nil
        store = nil
    }

    override func refreshStatus() {
        super.refreshStatus()
        trusted = trusted && CGPreflightListenEventAccess()
    }

    func reload() {
        snippets = (try? store?.all()) ?? []
        engine?.load(snippets)
    }

    func update(_ s: SnippetSettings) {
        settings = s.sanitized
        InputShared.shared.store.saveSnippets(s)
        engine?.settings = settings
    }

    @discardableResult
    func run(_ block: (SnippetStore) throws -> Void) -> Bool {
        guard let store else { message = "База сниппетов недоступна"; return false }
        do {
            try block(store)
            message = nil
            reload()
            return true
        } catch let e as SnippetError {
            switch e {
            case .invalid(let issue): message = issue.message
            case .notFound: message = "Сниппет не найден"
            case .badFormat: message = "Файл не похож на экспорт сниппетов"
            }
            return false
        } catch {
            message = "\(error)"
            return false
        }
    }

    func toggleLibrary() { library.toggle() }
}
