import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class ShotShelfAdapter: ShotShelfSinking {
    var isAvailable: Bool { MainActor.assumeIsolated { ShelfController.shared.service != nil } }

    func addScreenshot(path: String?, data: Data, fileName: String) -> Bool {
        MainActor.assumeIsolated {
            guard let svc = ShelfController.shared.service else { return false }
            let r: ShelfAddResult
            if let path { r = svc.addPaths([path], owned: false, source: "dev.multitool.app") } else {
                r = svc.add([.image(data, ext: (fileName as NSString).pathExtension, name: (fileName as NSString).deletingPathExtension)], source: "dev.multitool.app")
            }
            return !r.ids.isEmpty
        }
    }
}

@MainActor
final class ScreenshotController: ObservableObject {
    static let shared = ScreenshotController()

    @Published private(set) var settings = ShotSettings()
    @Published private(set) var upload = ShotUploadSettings()
    @Published private(set) var busy = false
    @Published var note = ""
    @Published private(set) var lastRecord: ShotRecord?
    @Published private(set) var holdingNative = false
    @Published private(set) var takeoverNote: String?
    @Published private(set) var running = false
    @Published private(set) var storeError: String?

    private let settingsStore = ShotSettingsStore()
    private let uploadStore = ShotUploadSettingsStore()
    private let live = ShotLiveCapture()
    private let selector = ShotSelector()
    private let overlay = ShotQuickOverlay()
    let pins = ShotPins()
    let events = ShotEventHub()
    private(set) var history: ShotHistoryStore?
    private(set) var pipeline: ShotPipeline?
    private var linkService: ShotLinkService?
    private var oneShot: ((inout ShotSettings) -> Void)?
    private var editors: [ShotEditorController] = []
    private var historyWindow: NSWindow?
    private var historyModel: ShotHistoryModel?
    private var countdown: ShotCountdownHUD?
    private var scrollHUD: ShotScrollHUD?
    private var scrollSession: ShotScrollSession?
    private let takeover = SystemShortcutTakeover(driver: LiveSymbolicHotKeys(), journalKey: ShotSystemKeys.journalKey)
    private var frontApp: (name: String?, title: String?) = (nil, nil)

    static func recoverStale(moduleEnabled: Bool) {
        let t = SystemShortcutTakeover(driver: LiveSymbolicHotKeys(), journalKey: ShotSystemKeys.journalKey)
        if let r = t.recoverStale(moduleEnabled: moduleEnabled) { Log.write("screenshot recoverStale -> \(r)") }
    }

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        upload = uploadStore.load()
        pins.controller = self
        overlay.controller = self
        do {
            let h = try ShotHistoryStore.open()
            history = h
            storeError = nil
        } catch {
            history = nil
            storeError = "\(error)"
            Log.write("screenshot history open failed: \(error)")
        }
        pipeline = ShotPipeline(settings: { [weak self] in
            var s = self?.settings ?? ShotSettings()
            self?.oneShot?(&s)
            return s
        }, files: LiveShotFiles(), encoder: ImageIOShotEncoder(), clipboard: PasteboardShotWriter(), shelf: ShotShelfAdapter(), history: history,
           indexer: ShotOcrIndexer(recognizer: VisionOcrRecognizer()), counter: ShotCounter(), events: events)
        linkService = ShotLinkService(uploader: ShotUploader(settings: { [weak self] in self?.upload ?? ShotUploadSettings() }, client: URLSessionHTTPClient(), keychain: AppKeychain()),
                                      history: history, clipboard: PasteboardTextWriter(), events: events, files: LiveShotFiles(), encoder: ImageIOShotEncoder())
        registerHotkeys()
        applyTakeover()
        Log.write("screenshot start history=\(history != nil)")
    }

    func stop() {
        guard running else { return }
        running = false
        selector.close()
        countdown?.cancel()
        scrollSession?.cancel()
        overlay.closeAll()
        pins.closeAll()
        for e in editors { e.close() }
        editors = []
        historyWindow?.close()
        historyWindow = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.screenshot.rawValue)
        let r = takeover.release()
        holdingNative = false
        takeoverNote = nil
        busy = false
        Log.write("screenshot stop takeover release -> \(r)")
        pipeline = nil
        history = nil
        linkService = nil
    }

    func update(_ s: ShotSettings) {
        settings = s.sanitized
        settingsStore.save(settings)
        guard running else { return }
        applyTakeover()
    }

    func updateUpload(_ s: ShotUploadSettings) {
        upload = s.sanitized
        uploadStore.save(upload)
    }

    private func registerHotkeys() {
        let hm = HotkeyManager.shared
        let owner = ModuleID.screenshot.rawValue
        hm.register(ShotHotkeys.area, owner: owner) { [weak self] in self?.begin(.area) }
        hm.register(ShotHotkeys.screen, owner: owner) { [weak self] in self?.begin(.screen) }
        hm.register(ShotHotkeys.window, owner: owner) { [weak self] in self?.begin(.window) }
        hm.register(ShotHotkeys.allScreens, owner: owner) { [weak self] in self?.begin(.allScreens) }
        hm.register(ShotHotkeys.scroll, owner: owner) { [weak self] in self?.begin(.scroll) }
        hm.register(ShotHotkeys.link, owner: owner) { [weak self] in self?.begin(.area, thenLink: true) }
        hm.register(ShotHotkeys.editLast, owner: owner) { [weak self] in self?.editLast() }
        hm.register(ShotHotkeys.history, owner: owner) { [weak self] in self?.openHistory() }
        hm.register(ShotHotkeys.editClipboard, owner: owner) { [weak self] in self?.editFromClipboard() }
        hm.register(ShotHotkeys.pinsToggle, owner: owner) { [weak self] in self?.pins.toggleAllHidden() }
    }

    private func applyTakeover() {
        let hm = HotkeyManager.shared
        let owner = ModuleID.screenshot.rawValue
        if settings.takeOverSystemKeys {
            let r = takeover.hold(ids: ShotSystemKeys.symbolicIDs)
            switch r {
            case .held, .alreadyHeld:
                holdingNative = takeover.isHolding
                takeoverNote = nil
                for e in ShotSystemKeys.entries {
                    hm.register(e.spec, owner: owner) { [weak self] in
                        guard let self else { return }
                        if let m = e.mode { self.begin(m, clipboardOnly: e.clipboardOnly) } else { self.showModeMenu() }
                    }
                }
            case .unavailable:
                takeoverNote = "Системные сочетания отключить не удалось: недоступно на этой версии macOS"
            case .failed(let m):
                takeoverNote = m
                holdingNative = takeover.isHolding
            default:
                break
            }
        } else {
            for e in ShotSystemKeys.entries { hm.unregister(e.spec.id) }
            if takeover.isHolding {
                let r = takeover.release()
                Log.write("screenshot takeover release -> \(r)")
            }
            holdingNative = false
            takeoverNote = nil
        }
    }

    // MARK: flow

    func begin(_ mode: ShotMode, clipboardOnly: Bool = false, thenLink: Bool = false) {
        guard running, !busy else { return }
        guard ShotLiveCapture.hasPermission else {
            note = "Нужен доступ «Запись экрана»"
            Permissions.shared.openSettings(.screenRecording)
            return
        }
        note = ""
        busy = true
        oneShot = nil
        if clipboardOnly { oneShot = { $0.copyToClipboard = true; $0.saveToDisk = false; $0.afterCapture = .nothing; $0.openEditorImmediately = false } }
        let app = NSWorkspace.shared.frontmostApplication
        frontApp = (app?.localizedName, nil)
        let secs = settings.timerSeconds
        switch mode {
        case .area, .scroll:
            selectArea(mode: mode, thenLink: thenLink)
        case .window:
            if secs > 0 { startCountdown(secs) { [weak self] in self?.selectWindow(thenLink: thenLink) } } else { selectWindow(thenLink: thenLink) }
        case .screen, .allScreens:
            let go: () -> Void = { [weak self] in
                Task { @MainActor in await self?.captureScreens(all: mode == .allScreens, thenLink: thenLink) }
            }
            if secs > 0 { startCountdown(secs, go) } else { go() }
        }
    }

    private func abort(_ message: String? = nil) {
        if let message { note = message }
        busy = false
        oneShot = nil
    }

    private func startCountdown(_ secs: Int, _ fire: @escaping () -> Void) {
        let hud = ShotCountdownHUD()
        countdown = hud
        hud.start(seconds: secs, onFire: { [weak self] in
            self?.countdown = nil
            fire()
        }, onCancel: { [weak self] in
            self?.countdown = nil
            self?.abort()
        })
    }

    private func captureScreens(all: Bool, thenLink: Bool) async {
        let displays = ShotLiveScreens.displays()
        let plan: ShotAreaPlan
        let rect: CGRect
        let scale: CGFloat
        if all {
            plan = ShotAreaMath.allDisplays(displays)
            rect = ShotSpace.bounds(displays)
            scale = plan.outputScale
        } else {
            let primaryH = ShotLiveScreens.primaryHeight()
            let cursor = ShotSpace.cocoaToDesktop(NSEvent.mouseLocation, primaryHeight: primaryH)
            guard let d = ShotSpace.display(containing: cursor, in: displays) else { abort("Экран не найден"); return }
            plan = ShotAreaMath.fullDisplay(d)
            rect = d.frame
            scale = d.scale
        }
        guard let img = await live.capture(plan: plan, includeCursor: settings.includeCursor) else { abort("Не удалось снять экран"); return }
        deliver(ShotCaptureResult(image: img, mode: all ? .allScreens : .screen, rect: rect, scale: scale, appName: frontApp.name), thenLink: thenLink)
    }

    private func selectWindow(thenLink: Bool) {
        let displays = ShotLiveScreens.displays()
        let windows = ShotLiveScreens.windowList()
        guard !windows.isEmpty else { abort("Окон для съёмки не нашлось"); return }
        var cfg = ShotSelectionConfig()
        cfg.windowPickOnly = true
        selector.begin(ShotSelectSetup(displays: displays, windows: windows, frozen: [:], config: cfg, hint: "Наведи на окно и кликни · Esc — отмена", highlightWindows: true)) { [weak self] result in
            guard let self else { return }
            guard let w = result?.window else { self.abort(); return }
            Task { @MainActor in await self.captureWindow(w, displays: displays, thenLink: thenLink) }
        }
    }

    private func captureWindow(_ w: ShotWindowInfo, displays: [ShotDisplay], thenLink: Bool) async {
        try? await Task.sleep(nanoseconds: 140_000_000)
        let scale = ShotWindowMath.scale(for: w.frame, displays: displays)
        let plan = ShotWindowMath.plan(frame: w.frame, scale: scale, withShadow: settings.windowShadow)
        guard let img = await live.captureWindow(id: w.id, plan: plan, includeCursor: settings.includeCursor) else { abort("Не удалось снять окно"); return }
        deliver(ShotCaptureResult(image: img, mode: .window, rect: w.frame, scale: scale, appName: w.ownerName, windowTitle: w.title), thenLink: thenLink)
    }

    private func selectArea(mode: ShotMode, thenLink: Bool) {
        let displays = ShotLiveScreens.displays()
        let windows = ShotLiveScreens.windowList()
        var cfg = ShotSelectionConfig()
        cfg.confirmOnRelease = settings.confirmOnRelease
        let freeze = settings.freezeScreen && settings.timerSeconds == 0 && mode == .area
        Task { @MainActor in
            var frozen: [UInt32: ShotSourceImage] = [:]
            if freeze {
                frozen = await live.captureDisplays(displays, includeCursor: false)
                if frozen.isEmpty { abort("Не удалось снять экран"); return }
            }
            let hint = mode == .scroll ? "Выдели область страницы, которую прокручивать · Esc — отмена" : "Выдели область · пробел — переместить · ⇧ — квадрат · ⌥ — от центра · Esc — отмена"
            self.selector.begin(ShotSelectSetup(displays: displays, windows: windows, frozen: frozen, config: cfg, hint: hint, highlightWindows: true)) { result in
                guard let result else { self.abort(); return }
                let secs = self.settings.timerSeconds
                let go: () -> Void = { Task { @MainActor in await self.finishArea(result, displays: displays, frozen: frozen, mode: mode, thenLink: thenLink) } }
                if secs > 0 { self.startCountdown(secs) { go() } } else { go() }
            }
        }
    }

    private func finishArea(_ r: ShotSelectionResult, displays: [ShotDisplay], frozen: [UInt32: ShotSourceImage], mode: ShotMode, thenLink: Bool) async {
        let plan = ShotAreaMath.plan(for: r.rect, displays: displays)
        guard !plan.isEmpty else { abort("Область пустая"); return }
        let appName = r.window?.ownerName ?? frontApp.name
        if mode == .scroll {
            await runScroll(plan: plan, appName: appName, thenLink: thenLink)
            return
        }
        var img: CGImage?
        if !frozen.isEmpty { img = ShotCompositor.compose(plan: plan, sources: frozen) } else {
            try? await Task.sleep(nanoseconds: 160_000_000)
            img = await live.capture(plan: plan, includeCursor: settings.includeCursor)
        }
        guard let image = img else { abort("Не удалось снять область"); return }
        deliver(ShotCaptureResult(image: image, mode: .area, rect: plan.rect, scale: plan.outputScale, appName: appName, windowTitle: r.window?.title), thenLink: thenLink)
    }

    private func runScroll(plan: ShotAreaPlan, appName: String?, thenLink: Bool) async {
        var cfg = ShotStitchConfig()
        cfg.maxTotalHeight = settings.scrollMaxHeight
        cfg.ignoreRightColumns = Int(14 * plan.outputScale)
        cfg.mismatchTolerance = 0.01
        cfg.quantizeBits = 2
        let session = ShotScrollSession(config: cfg)
        scrollSession = session
        let hud = ShotScrollHUD()
        scrollHUD = hud
        let displays = ShotLiveScreens.displays()
        let anchorDisplay = ShotSpace.display(containing: CGPoint(x: plan.rect.midX, y: plan.rect.midY), in: displays)
        hud.show(avoiding: plan.rect, display: anchorDisplay, onStop: { [weak session] in session?.cancel() })
        session.onProgress = { frames, height in Task { @MainActor in hud.update(frames: frames, height: height) } }
        let driver = LiveScrollDriver(capture: live, plan: plan)
        let result = await session.run(driver: driver)
        hud.close()
        scrollHUD = nil
        scrollSession = nil
        guard result.frames > 0, let img = result.bitmap.makeImage() else { abort("Не удалось снять страницу"); return }
        if result.stop == .lostOverlap { note = "Прокрутка остановилась: не удалось сшить кадры, сохранено то, что успело" }
        deliver(ShotCaptureResult(image: img, mode: .scroll, rect: plan.rect, scale: plan.outputScale, appName: appName), thenLink: thenLink)
    }

    private func deliver(_ cap: ShotCaptureResult, thenLink: Bool) {
        defer { busy = false }
        guard let pipeline else { oneShot = nil; return }
        let outcome = pipeline.process(cap)
        oneShot = nil
        if let e = outcome.error { note = e }
        if let r = outcome.record {
            lastRecord = r
            if settings.indexText {
                let image = outcome.image
                Task.detached(priority: .utility) { pipeline.index(recordID: r.id, image: image) }
            }
        }
        if outcome.data == nil { return }
        if outcome.copied && settings.afterCapture != .overlay { HUD.show("Снимок скопирован") }
        switch outcome.next {
        case .overlay: overlay.show(outcome, settings: settings, uploadConfigured: upload.isConfigured)
        case .editor: openEditor(record: outcome.record, image: outcome.image)
        case .pin: pin(image: outcome.image, record: outcome.record, title: outcome.record?.title ?? "Снимок", origin: cap.rect, scale: cap.scale)
        case .copyOnly, .saveOnly, .nothing: break
        }
        if thenLink { makeLink(record: outcome.record, image: outcome.image) { [weak self] text in if let text { HUD.show(text); self?.note = text } } }
    }

    private func showModeMenu() {
        let m = NSMenu()
        for mode in ShotMode.allCases {
            m.addItem(ClosureMenuItem(title: mode.title) { [weak self] in self?.begin(mode) })
        }
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: actions

    func copy(_ image: CGImage, data: Data?) {
        guard let pipeline else { return }
        let png = data.flatMap { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? $0 : nil } ?? pipeline.encoder.encode(image, format: .png, quality: 1)
        guard let png, pipeline.clipboard.writeImage(png: png) else { note = "Не удалось скопировать"; return }
        events.emit(.copied)
        HUD.show("Скопировано")
    }

    func saveFromOverlay(_ o: ShotOutcome, done: @escaping (Bool) -> Void) {
        guard let pipeline, let data = o.data else { done(false); return }
        let base = (o.fileName as NSString).deletingPathExtension
        let fmt = ShotFormat.from(fileExtension: (o.fileName as NSString).pathExtension) ?? .png
        if let p = pipeline.saveToDirectory(record: o.record, data: data, format: fmt, width: o.image.width, height: o.image.height, baseName: base) {
            HUD.show("Сохранено: \((p as NSString).lastPathComponent)")
            done(true)
        } else {
            note = "Не удалось сохранить"
            done(false)
        }
    }

    func saveEdited(record: ShotRecord?, image: CGImage, document: AnnotationDocument?) -> ShotRecord? {
        guard let pipeline else { return nil }
        if let record {
            let out = pipeline.saveEdited(record: record, image: image, document: document)
            if let e = out.error { note = e; return nil }
            lastRecord = out.record
            return out.record
        }
        let out = pipeline.process(ShotCaptureResult(image: image, mode: .area, scale: 2, date: Date()))
        if let e = out.error { note = e; return nil }
        if let r = out.record, let document, let json = try? document.json() { try? history?.setDocument(id: r.id, json: json) }
        lastRecord = out.record
        return out.record ?? ShotRecord(created: Date(), mode: .area, title: "Снимок", path: out.path)
    }

    func openEditor(record: ShotRecord?, image: CGImage) {
        guard running else { return }
        var doc: AnnotationDocument?
        if let id = record?.id, id > 0, let json = try? history?.document(id: id) { doc = try? AnnotationDocument.decode(json) }
        let ed = ShotEditorController(controller: self, image: image, record: record, document: doc)
        ed.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(ed)
        ed.show()
    }

    func editLast() {
        guard running, let r = (try? history?.latest()) ?? nil, let p = r.path, let img = ShotImageOps.load(path: p) else {
            note = "Последнего снимка нет"
            HUD.show("Последнего снимка нет")
            return
        }
        openEditor(record: r, image: img)
    }

    func editFromClipboard() {
        guard running else { return }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first, let img = ShotImageOps.load(path: u.path) {
            openEditor(record: nil, image: img)
            return
        }
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff), let img = ShotImageOps.decode(d) {
            openEditor(record: nil, image: img)
            return
        }
        HUD.show("В буфере нет картинки")
    }

    func pin(image: CGImage, record: ShotRecord?, title: String, origin: CGRect? = nil, scale: CGFloat? = nil) {
        guard running else { return }
        var cocoaOrigin: CGPoint?
        if let origin {
            let r = ShotSpace.desktopToCocoa(origin, primaryHeight: ShotLiveScreens.primaryHeight())
            cocoaOrigin = r.origin
        }
        pins.add(image: image, record: record, title: title, scale: scale ?? NSScreen.main?.backingScaleFactor ?? 2, origin: cocoaOrigin)
    }

    func makeLink(record: ShotRecord?, image: CGImage, done: @escaping (String?) -> Void) {
        guard upload.isConfigured else {
            note = "Сервис ссылок не настроен: адрес и ключ задаются в настройках скриншотов"
            HUD.show("Сервис ссылок не настроен")
            done(nil)
            return
        }
        guard let service = linkService else { done(nil); return }
        let ttl = settings.linkTTL
        let fmt = settings.format
        let name = record?.title ?? "screenshot"
        Task.detached(priority: .userInitiated) {
            let res = service.makeLink(record: record, image: image, format: fmt, fileName: name + "." + fmt.fileExtension, ttl: ttl)
            await MainActor.run {
                switch res {
                case .success(let r):
                    HUD.show("Ссылка скопирована")
                    done("Ссылка скопирована, действует \(ttl.title)")
                    Log.write("screenshot link ok expires=\(r.expires)")
                case .failure(let e):
                    self.note = e.description
                    HUD.show("Ссылка не получилась")
                    done(e.description)
                }
            }
        }
    }

    func share(_ o: ShotOutcome, from panel: NSPanel) {
        var url: URL?
        if let p = o.path { url = URL(fileURLWithPath: p) } else if let d = o.data {
            let path = MultitulPaths.shotCacheDir + "/share-" + String(UUID().uuidString.prefix(8)) + "-" + (o.fileName.isEmpty ? "screenshot.png" : o.fileName)
            if LiveShotFiles().write(d, to: path) { url = URL(fileURLWithPath: path) }
        }
        guard let u = url, let view = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: [u])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func delete(_ o: ShotOutcome) {
        if let id = o.record?.id { pipeline?.discard(recordID: id) } else if let p = o.path, o.record == nil { _ = LiveShotFiles().trash(p) }
        HUD.show("Снимок удалён")
    }

    func openHistory() {
        guard running else { return }
        if historyWindow == nil {
            let m = ShotHistoryModel()
            m.controller = self
            historyModel = m
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "История скриншотов"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ShotHistoryView(model: m))
            w.center()
            historyWindow = w
        }
        historyModel?.reload()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func clearHistory() {
        guard let h = history, let all = try? h.recent(limit: 100_000) else { return }
        for r in all where !r.pinned { pipeline?.discard(recordID: r.id) }
        historyModel?.reload()
    }

    func historyCount() -> Int { (try? history?.count()) ?? 0 }
}

@MainActor
final class ShotCountdownHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var countdown = ShotCountdown(seconds: 0)
    private var onFire: (() -> Void)?
    private var onCancel: (() -> Void)?

    func start(seconds: Int, onFire: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFire = onFire
        self.onCancel = onCancel
        countdown = ShotCountdown(seconds: seconds)
        let size = NSSize(width: 150, height: 150)
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "\(seconds)")
        l.font = .systemFont(ofSize: 64, weight: .semibold)
        l.alignment = .center
        l.frame = NSRect(x: 0, y: 44, width: size.width, height: 80)
        fx.addSubview(l)
        let b = NSButton(title: "Отмена", target: self, action: #selector(cancelTapped))
        b.bezelStyle = .rounded
        b.frame = NSRect(x: 35, y: 12, width: 80, height: 26)
        fx.addSubview(b)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        if let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.maxY - size.height - 40))
        }
        p.orderFrontRegardless()
        panel = p
        label = l
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if countdown.tick() {
            finish()
            let cb = onFire
            onFire = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { cb?() }
        } else {
            label?.stringValue = "\(countdown.remaining)"
        }
    }

    @objc private func cancelTapped() {
        cancel()
        let cb = onCancel
        onCancel = nil
        cb?()
    }

    func cancel() {
        countdown.cancel()
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

@MainActor
final class ShotScrollHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var onStop: (() -> Void)?

    func show(avoiding region: CGRect, display: ShotDisplay?, onStop: @escaping () -> Void) {
        self.onStop = onStop
        let size = NSSize(width: 300, height: 64)
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "Снимаю страницу…")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.frame = NSRect(x: 16, y: 34, width: 270, height: 18)
        fx.addSubview(l)
        let b = NSButton(title: "Готово", target: self, action: #selector(stopTapped))
        b.bezelStyle = .rounded
        b.frame = NSRect(x: 16, y: 8, width: 80, height: 24)
        fx.addSubview(b)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        let screen = NSScreen.screens.first { s in
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return id == display?.id
        } ?? NSScreen.main
        if let s = screen {
            let h = ShotLiveScreens.primaryHeight()
            let cocoaRegion = ShotSpace.desktopToCocoa(region, primaryHeight: h)
            var y = s.visibleFrame.maxY - size.height - 12
            if cocoaRegion.maxY > y, cocoaRegion.minY - size.height - 12 >= s.visibleFrame.minY { y = cocoaRegion.minY - size.height - 12 }
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - size.width / 2, y: y))
        }
        p.orderFrontRegardless()
        panel = p
        label = l
    }

    func update(frames: Int, height: Int) { label?.stringValue = "Кадров: \(frames), высота \(height) px" }

    @objc private func stopTapped() { onStop?() }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
