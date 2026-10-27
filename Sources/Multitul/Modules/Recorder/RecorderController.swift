import SwiftUI
import AppKit
import AVFoundation
import MultitulCore
import MultitulUI

@MainActor
final class RecorderController: ObservableObject {
    static let shared = RecorderController()

    @Published private(set) var settings = RecSettings()
    @Published private(set) var state = RecState.idle
    @Published private(set) var elapsed = 0.0
    @Published private(set) var running = false
    @Published private(set) var selecting = false
    @Published private(set) var lastRecord: RecRecord?
    @Published private(set) var storeError: String?
    @Published private(set) var exportPresets: [RecExportPreset] = []
    @Published var note = ""

    private let settingsStore = RecSettingsStore()
    private let presetStore = RecPresetStore()
    private let selector = ShotSelector()
    private let input = NSEventRecInput()
    private let clock = LiveRecClock()
    private let files = LiveRecFiles()
    private var countdown: ShotCountdownHUD?
    private var countdownShown = false
    private(set) var history: RecHistoryStore?
    private var session: RecSession?
    private var statusItem: NSStatusItem?
    private var tickTimer: Timer?
    private var frame: RecFrameOverlay?
    private var editors: [RecEditorController] = []
    private var historyWindow: NSWindow?
    private var historyModel: RecHistoryModel?
    private var pending: (plan: RecCapturePlan, app: String?, layout: RecTrackLayout, paths: RecSavePaths, started: Date)?

    var events: ShotEventHub { ScreenshotController.shared.events }
    var isActive: Bool { state.isActive }

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        exportPresets = presetStore.load()
        do {
            history = try RecHistoryStore.open()
            storeError = nil
        } catch {
            history = nil
            storeError = "\(error)"
            Log.write("recorder history open failed: \(error)")
        }
        registerHotkeys()
        Log.write("recorder start history=\(history != nil)")
    }

    func stop() {
        guard running else { return }
        let s = session
        session = nil
        Task { await s?.cancel() }
        running = false
        selector.close()
        countdown?.cancel()
        countdown = nil
        removeIndicators()
        for e in editors { e.close() }
        editors = []
        historyWindow?.close()
        historyWindow = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.screenRecorder.rawValue)
        history = nil
        state = .idle
        selecting = false
        Log.write("recorder stop")
    }

    func update(_ s: RecSettings) {
        settings = s.sanitized
        settingsStore.save(settings)
    }

    func applyPreset(_ p: RecCapturePreset) {
        var s = settings
        p.apply(&s)
        s.presetID = p.id
        update(s)
    }

    func saveExportPreset(_ p: RecExportPreset) { exportPresets = presetStore.upsert(p) }
    func removeExportPreset(_ id: String) { exportPresets = presetStore.remove(id: id) }

    private func registerHotkeys() {
        let hm = HotkeyManager.shared
        let owner = ModuleID.screenRecorder.rawValue
        hm.register(RecHotkeys.toggle, owner: owner) { [weak self] in self?.toggle() }
        hm.register(RecHotkeys.area, owner: owner) { [weak self] in self?.begin(.area) }
        hm.register(RecHotkeys.window, owner: owner) { [weak self] in self?.begin(.window) }
        hm.register(RecHotkeys.display, owner: owner) { [weak self] in self?.begin(.display) }
        hm.register(RecHotkeys.stop, owner: owner) { [weak self] in self?.stopRecording() }
        hm.register(RecHotkeys.pause, owner: owner) { [weak self] in self?.togglePause() }
        hm.register(RecHotkeys.editLast, owner: owner) { [weak self] in self?.editLast() }
        hm.register(RecHotkeys.history, owner: owner) { [weak self] in self?.openHistory() }
    }

    func toggle() {
        if state.isActive { stopRecording() } else { begin(settings.mode) }
    }

    // MARK: start

    func begin(_ mode: RecMode) {
        guard running, !state.isActive, !selecting else { return }
        guard SCRecCapture.hasPermission else {
            note = "Нужен доступ «Запись экрана»"
            Permissions.shared.openSettings(.screenRecording)
            return
        }
        note = ""
        var s = settings
        s.mode = mode
        update(s)
        selecting = true
        let displays = ShotLiveScreens.displays()
        switch mode {
        case .display:
            let primaryH = ShotLiveScreens.primaryHeight()
            let cursor = ShotSpace.cocoaToDesktop(NSEvent.mouseLocation, primaryHeight: primaryH)
            guard let d = ShotSpace.display(containing: cursor, in: displays), let plan = RecGeometry.plan(mode: .display, rect: d.frame, displays: displays, resolution: settings.resolution) else {
                abort("Экран не найден")
                return
            }
            launch(plan)
        case .window:
            let windows = ShotLiveScreens.windowList()
            guard !windows.isEmpty else { abort("Окон для записи не нашлось"); return }
            var cfg = ShotSelectionConfig()
            cfg.windowPickOnly = true
            selector.begin(ShotSelectSetup(displays: displays, windows: windows, frozen: [:], config: cfg, hint: "Наведи на окно и кликни · Esc — отмена", highlightWindows: true)) { [weak self] result in
                guard let self else { return }
                guard let w = result?.window, let plan = RecGeometry.plan(mode: .window, rect: w.frame, windowID: w.id, displays: displays, resolution: self.settings.resolution) else {
                    self.abort()
                    return
                }
                self.launch(plan, app: w.ownerName)
            }
        case .area:
            var cfg = ShotSelectionConfig()
            cfg.confirmOnRelease = false
            selector.begin(ShotSelectSetup(displays: displays, windows: ShotLiveScreens.windowList(), frozen: [:], config: cfg,
                                           hint: "Выдели область записи, Return — начать · Esc — отмена", highlightWindows: true)) { [weak self] result in
                guard let self else { return }
                guard let r = result, let plan = RecGeometry.plan(mode: .area, rect: r.rect, displays: displays, resolution: self.settings.resolution), !plan.isEmpty else {
                    self.abort(result == nil ? nil : "Область слишком маленькая")
                    return
                }
                self.launch(plan, app: r.window?.ownerName)
            }
        }
    }

    private func abort(_ message: String? = nil) {
        if let message { note = message }
        selecting = false
    }

    private func micAvailable() async -> Bool {
        guard settings.microphone else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            note = "Нет доступа к микрофону: запись без него"
            return false
        }
    }

    private func launch(_ plan: RecCapturePlan, app: String? = nil) {
        let appName = app ?? NSWorkspace.shared.frontmostApplication?.localizedName
        Task { @MainActor in
            let mic = await micAvailable()
            var micUID = ""
            if mic {
                let r = RecMic.resolve(uid: settings.micDeviceUID, inputs: AudioDeviceInfo.visible(CoreAudioHal().devices(), scope: .input))
                micUID = r.uid ?? ""
                if let n = r.note { note = n }
            }
            let s = settings
            var layoutSettings = s
            layoutSettings.microphone = s.microphone && mic
            let layout = RecTrackLayout.make(settings: layoutSettings, micAvailable: mic)
            let counterKey = "recorder.counter"
            let n = ((UserDefaults.standard.object(forKey: counterKey) as? Int) ?? 0) + 1
            if ShotNaming.usesCounter(s.nameTemplate) { UserDefaults.standard.set(n, forKey: counterKey) }
            let paths = RecSavePlanner.paths(settings: s, mode: plan.mode, appName: appName, windowTitle: nil, width: plan.pixelWidth, height: plan.pixelHeight, counter: n,
                                             date: Date(), exists: { [files] in files.exists($0) })
            let cfg = RecCaptureConfig(plan: plan, fps: s.fps, showCursor: s.showCursor, systemAudio: layout.enabled.contains(.systemAudio),
                                       microphone: layout.enabled.contains(.microphone), micDeviceUID: micUID, excludeOwnWindows: s.excludeOwnWindows)
            input.prepare()
            let sess = RecSession(capture: SCRecCapture(), writerFactory: { AVRecWriter() }, input: input, clock: clock, files: files, events: events)
            sess.onState = { [weak self] st in Task { @MainActor in self?.stateChanged(st) } }
            session = sess
            pending = (plan, appName, layout, paths, Date())
            selecting = false
            if plan.clippedToDisplay { note = "Область захватывает несколько экранов: пишется та часть, что на одном экране" }
            await sess.start(config: cfg, settings: s, layout: layout, paths: paths, countdown: s.countdownSeconds)
        }
    }

    // MARK: state

    private func stateChanged(_ st: RecState) {
        state = st
        switch st {
        case .countdown(let n):
            guard !countdownShown else { break }
            countdownShown = true
            let hud = ShotCountdownHUD()
            countdown = hud
            hud.start(seconds: n, onFire: { [weak self] in
                self?.countdown = nil
                guard let sess = self?.session else { return }
                Task { await sess.completeCountdown() }
            }, onCancel: { [weak self] in
                self?.countdown = nil
                self?.countdownShown = false
                self?.session?.cancelCountdown()
                self?.session = nil
            })
        case .recording:
            countdown = nil
            countdownShown = false
            showIndicators()
        case .paused:
            updateStatusTitle()
        case .stopping:
            updateStatusTitle()
        case .finished:
            removeIndicators()
            if let r = session?.result { Task { await finish(r) } }
            session = nil
        case .failed(let m):
            countdownShown = false
            countdown?.cancel()
            countdown = nil
            removeIndicators()
            note = m
            HUD.show("Запись не получилась")
            Notifier.shared.post(title: "Запись экрана", body: m)
            session = nil
        case .idle:
            countdownShown = false
            removeIndicators()
            session = nil
        }
    }

    func stopRecording() {
        guard let s = session, state.isCapturing else { return }
        Task { await s.stop() }
    }

    func cancelRecording() {
        guard let s = session, state.isActive else { return }
        Task { await s.cancel() }
    }

    func togglePause() {
        guard let s = session, state.isCapturing else { return }
        s.togglePause()
    }

    // MARK: indicators

    private func showIndicators() {
        removeIndicators()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        item.menu = indicatorMenu()
        updateStatusTitle()
        if settings.excludeOwnWindows, let p = pending?.plan, p.mode != .display {
            let f = RecFrameOverlay(desktopRect: p.pointRect)
            f.show()
            frame = f
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func indicatorMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Остановить запись") { [weak self] in self?.stopRecording() })
        m.addItem(ClosureMenuItem(title: state == .paused ? "Продолжить" : "Пауза") { [weak self] in self?.togglePause() })
        m.addItem(NSMenuItem.separator())
        m.addItem(ClosureMenuItem(title: "Отменить и удалить") { [weak self] in self?.cancelRecording() })
        return m
    }

    private func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        let paused = state == .paused
        let dot = paused ? "⏸" : "●"
        let t = NSMutableAttributedString(string: dot + " ", attributes: [.foregroundColor: paused ? NSColor.systemOrange : NSColor.systemRed])
        t.append(NSAttributedString(string: RecTimeFormat.clock(elapsed), attributes: [.foregroundColor: NSColor.labelColor]))
        b.attributedTitle = t
        statusItem?.menu = indicatorMenu()
    }

    private func tick() {
        guard let s = session else { return }
        elapsed = s.elapsed
        updateStatusTitle()
        Task { _ = await s.checkGuards() }
    }

    private func removeIndicators() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        frame?.close()
        frame = nil
        elapsed = 0
    }

    // MARK: result

    private func finish(_ res: RecSessionResult) async {
        let p = pending
        pending = nil
        let url = URL(fileURLWithPath: res.path)
        var info = await RecMedia.probe(url: url, scale: Double(res.plan.scale)) ?? RecSourceInfo(width: res.plan.pixelWidth, height: res.plan.pixelHeight, duration: res.duration, fps: settings.fps, scale: Double(res.plan.scale))
        info.hasSystemAudio = res.layout.enabled.contains(.systemAudio)
        info.hasMicrophone = res.layout.enabled.contains(.microphone)
        info.scale = Double(res.plan.scale)
        var record = RecRecord(created: p?.started ?? Date(), mode: res.plan.mode, title: (res.fileName as NSString).deletingPathExtension, app: p?.app ?? "", path: res.path,
                               width: info.width, height: info.height, duration: res.duration, bytes: res.bytes, codec: settings.codec.rawValue, fps: settings.fps,
                               hasSystemAudio: info.hasSystemAudio, hasMicrophone: info.hasMicrophone)
        if settings.recordHistory, let h = history {
            var thumb: Data?
            if let img = await RecMedia.thumbnail(url: url) { thumb = ShotThumbnail.jpegData(from: img, maxSide: 320) }
            if let id = try? h.insert(record, thumbnail: thumb) {
                record.id = id
                if let d = try? res.log.encoded() { try? h.setInputLog(id: id, json: d) }
                _ = try? h.prune(ShotPrunePolicy(maxCount: settings.historyLimit, maxAgeDays: settings.historyKeepDays))
            }
        }
        lastRecord = record
        for w in res.warnings { note = w }
        HUD.show("Запись сохранена: \(res.fileName)")
        if settings.addToShelf, let svc = ShelfController.shared.service { _ = svc.addPaths([res.path], owned: false, source: "dev.multitool.app") }
        switch settings.afterRecord {
        case .editor: openEditor(record: record, url: url, info: info, log: res.log)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyFile:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
        case .nothing: break
        }
    }

    // MARK: editor and history

    func openEditor(record: RecRecord?, url: URL, info: RecSourceInfo, log: RecInputLog) {
        guard running else { return }
        var doc: RecEditDocument?
        if let id = record?.id, id > 0, let d = try? history?.document(id: id) { doc = try? RecEditDocument.decode(d) }
        let fresh = doc == nil
        var d = doc ?? RecEditDocument(source: info)
        if fresh {
            d.style.background = settings.editorBackground.stored
            d.style.padding = settings.editorPadding
            d.style.corner = settings.editorCorner
            d.style.highlightClicks = settings.highlightClicks
            d.zoomEnabled = settings.autoZoom
            d.zoomSettings.level = settings.zoomLevel
            if settings.autoZoom { d.regenerateZoom(log: log) }
        }
        let ed = RecEditorController(controller: self, record: record, url: url, document: d, log: log)
        ed.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(ed)
        ed.show()
    }

    func openEditor(_ r: RecRecord) {
        guard let p = r.path, files.exists(p) else { note = "Файл записи не найден"; HUD.show("Файл записи не найден"); return }
        var log = RecInputLog()
        if let d = try? history?.inputLog(id: r.id), let l = try? RecInputLog.decode(d) { log = l }
        let url = URL(fileURLWithPath: p)
        Task { @MainActor in
            let probed = await RecMedia.probe(url: url, scale: r.sourceInfo.scale)
            var info = probed ?? r.sourceInfo
            info.hasSystemAudio = r.hasSystemAudio
            info.hasMicrophone = r.hasMicrophone
            openEditor(record: r, url: url, info: info, log: log)
        }
    }

    func editLast() {
        guard running, let r = (try? history?.latest()) ?? nil else {
            HUD.show("Записей пока нет")
            return
        }
        openEditor(r)
    }

    func saveDocument(record: RecRecord?, document: RecEditDocument) {
        guard let id = record?.id, id > 0, let d = try? document.encoded() else { return }
        try? history?.setDocument(id: id, json: d)
    }

    func addExported(path: String, source: RecSourceInfo, plan: RecExportPlan, title: String) {
        guard settings.recordHistory, let h = history else { return }
        let size = files.size(path) ?? 0
        let r = RecRecord(created: Date(), mode: .area, title: title, path: path, width: Int(plan.canvas.width), height: Int(plan.canvas.height), duration: plan.outputDuration,
                          bytes: size, codec: plan.preset.codec.rawValue, fps: plan.fps, hasSystemAudio: !plan.audioGroups.isEmpty, hasMicrophone: false)
        _ = try? h.insert(r)
        historyModel?.reload()
    }

    func openHistory() {
        guard running else { return }
        if historyWindow == nil {
            let m = RecHistoryModel()
            m.controller = self
            historyModel = m
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "История записей"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RecHistoryView(model: m))
            w.center()
            historyWindow = w
        }
        historyModel?.reload()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func historyCount() -> Int { (try? history?.count()) ?? 0 }

    func clearHistory() {
        guard let h = history, let all = try? h.recent(limit: 100_000) else { return }
        _ = try? h.delete(ids: all.filter { !$0.pinned }.map(\.id))
        historyModel?.reload()
    }

    func deleteRecord(_ r: RecRecord, moveFileToTrash: Bool) {
        _ = try? history?.delete(ids: [r.id])
        if moveFileToTrash, let p = r.path { try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
    }

    func makeLink(path: String, record: RecRecord?, done: @escaping (String) -> Void) {
        let upload = ScreenshotController.shared.upload
        guard upload.isConfigured else {
            let m = "Сервис ссылок не настроен: адрес и ключ задаются в настройках скриншотов"
            note = m
            HUD.show("Сервис ссылок не настроен")
            done(m)
            return
        }
        let svc = RecLinkService(settings: { ScreenshotController.shared.upload }, client: URLSessionHTTPClient(), keychain: AppKeychain(), reader: files, history: history,
                                 clipboard: PasteboardTextWriter(), events: events)
        let ttl = ScreenshotController.shared.settings.linkTTL
        Task.detached(priority: .userInitiated) {
            let res = svc.makeLink(record: record, path: path, ttl: ttl)
            await MainActor.run {
                switch res {
                case .success:
                    HUD.show("Ссылка скопирована")
                    done("Ссылка скопирована, действует \(ttl.title)")
                case .failure(let e):
                    HUD.show("Ссылка не получилась")
                    done(e.description)
                }
            }
        }
    }
}

@MainActor
final class RecFrameOverlay {
    private var panel: NSPanel?
    private let desktopRect: CGRect

    init(desktopRect: CGRect) { self.desktopRect = desktopRect }

    func show() {
        let h = ShotLiveScreens.primaryHeight()
        let cocoa = ShotSpace.desktopToCocoa(desktopRect, primaryHeight: h).insetBy(dx: -4, dy: -4)
        let p = NSPanel(contentRect: cocoa, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = RecFrameView(frame: NSRect(origin: .zero, size: cocoa.size))
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private final class RecFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }
}
