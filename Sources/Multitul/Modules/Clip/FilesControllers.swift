import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class DmgController: ObservableObject {
    static let shared = DmgController()

    @Published private(set) var settings = DmgSettings()
    @Published private(set) var running = false
    @Published private(set) var lastLine = "—"
    @Published private(set) var installed = 0

    nonisolated private let system = DmgSystemLive()
    private let queue = DispatchQueue(label: "dev.multitool.app.dmg")
    private var observer: NSObjectProtocol?
    private var pending: [String: DmgPlan] = [:]
    private var weMounted: Set<String> = []
    private var recent: [String: Date] = [:]
    private var detector = DownloadsDmgDetector()
    private var timer: Timer?
    private let store = ClipSettingsStore()

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadDmg()
        Notifier.shared.register(categories: [NotificationCategorySpec(id: "dmg.offer", actions: [NotificationActionSpec(id: "install", title: "Установить"), NotificationActionSpec(id: "skip", title: "Не сейчас")])])
        Notifier.shared.setHandler(prefix: "dmg-") { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.answer(event) } }
        }
        Notifier.shared.requestAuthorization()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let path = note.userInfo?["NSDevicePath"] as? String
            MainActor.assumeIsolated { if let path { self?.mounted(path, dmg: nil) } }
        }
        applyWatch()
    }

    func stop() {
        running = false
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observer = nil
        timer?.invalidate()
        timer = nil
        Notifier.shared.setHandler(prefix: "dmg-", nil)
        pending = [:]
    }

    func update(_ s: DmgSettings) {
        settings = s
        store.saveDmg(s)
        applyWatch()
    }

    private func applyWatch() {
        timer?.invalidate()
        timer = nil
        guard running, settings.watchDownloads else { return }
        detector = DownloadsDmgDetector()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDownloads() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pollDownloads()
    }

    private func pollDownloads() {
        let dir = NSHomeDirectory() + "/Downloads"
        var det = detector
        queue.async { [weak self] in
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [])) ?? []
            let files = urls.map { u -> DownloadFile in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return DownloadFile(name: u.lastPathComponent, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
            }
            let ready = det.poll(files, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.detector = det
                    for name in ready { self?.mountDownloaded(dir + "/" + name) }
                }
            }
        }
    }

    private func mountDownloaded(_ dmg: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let points = try self.system.attach(dmgPath: dmg)
                DispatchQueue.main.async { MainActor.assumeIsolated { for mp in points { self.weMounted.insert(mp); self.mounted(mp, dmg: dmg) } } }
            } catch {
                Log.write("dmg attach failed: \(error)")
            }
        }
    }

    private func mounted(_ mountPoint: String, dmg: String?) {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 30 }
        guard recent[mountPoint] == nil else { return }
        recent[mountPoint] = now
        let s = settings
        queue.async { [weak self] in
            guard let self else { return }
            let image = dmg ?? HdiutilParser.imagePath(forMountPoint: mountPoint, in: self.system.attachedImages())
            guard let image else { return }
            let result = DmgPlanner.plan(mountPoint: mountPoint, dmgPath: image, settings: s, system: self.system)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.planned(result, mountPoint: mountPoint, dmg: image) } }
        }
    }

    private func planned(_ result: Result<DmgPlan, DmgRefusal>, mountPoint: String, dmg: String) {
        switch result {
        case .failure(let r):
            lastLine = r.message
            Log.write("dmg refused: \(r.message)")
            if !r.isQuiet { Notifier.shared.post(title: "Установка из dmg", body: r.message, id: "dmg-info-\(UUID().uuidString)") }
            releaseIfOurs(mountPoint)
        case .success(let plan):
            if settings.askFirst {
                let id = UUID().uuidString
                pending[id] = plan
                Notifier.shared.post(title: "Установить \(plan.appName)?", body: "Скопировать в \(settings.destination.title)" + (plan.replaces ? " поверх текущей версии" : ""), id: "dmg-offer-\(id)", category: "dmg.offer", userInfo: ["plan": id])
            } else {
                install(plan)
            }
        }
    }

    private func answer(_ event: NotificationEvent) {
        guard let id = event.userInfo["plan"], let plan = pending.removeValue(forKey: id) else { return }
        if event.actionId == "install" || event.actionId == NotificationEvent.defaultAction { install(plan) } else { releaseIfOurs(plan.mountPoint) }
    }

    private func releaseIfOurs(_ mountPoint: String) {
        guard weMounted.remove(mountPoint) != nil else { return }
        queue.async { [system] in _ = system.detach(mountPoint: mountPoint, force: false) }
    }

    func install(_ plan: DmgPlan) {
        lastLine = "Устанавливается \(plan.appName)…"
        queue.async { [weak self] in
            guard let self else { return }
            let report = DmgInstaller(system: self.system).execute(plan)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.weMounted.remove(plan.mountPoint)
                    if report.ok {
                        self.installed += 1
                        self.lastLine = "Установлено: \(plan.appName)"
                        let extra = report.warnings.isEmpty ? "" : " " + report.warnings.joined(separator: ". ")
                        Notifier.shared.post(title: "Установлено: \(plan.appName)", body: "Приложение скопировано в \(self.settings.destination.title).\(extra)", id: "dmg-done-\(UUID().uuidString)")
                    } else {
                        self.lastLine = report.message ?? "Ошибка установки"
                        Notifier.shared.post(title: "Не удалось установить \(plan.appName)", body: report.message ?? "Ошибка", id: "dmg-fail-\(UUID().uuidString)")
                    }
                }
            }
        }
    }
}

@MainActor
final class FinderCutController: ObservableObject {
    static let shared = FinderCutController()

    @Published private(set) var settings = FinderCutSettings()
    @Published private(set) var running = false
    @Published private(set) var cut: FinderCutState?
    @Published private(set) var tapActive = false

    private let services = ClipServices.shared
    private let inspector = AXFocusInspector()
    private var engine: FinderCutPasteEngine?
    private var token: EventTapHub.Token?
    private var indicator: CutIndicator?
    private var appObserver: NSObjectProtocol?
    private let store = ClipSettingsStore()

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadFinderCut()
        let e = FinderCutPasteEngine(pasteboard: services.pasteboard, finder: FinderScriptingLive(), files: FinderFilesLive())
        e.onChange = { [weak self] c in MainActor.assumeIsolated { self?.changed(c) } }
        e.onMessage = { text in MainActor.assumeIsolated { HUD.show(text) } }
        engine = e
        indicator = CutIndicator { [weak self] in self?.engine?.cancel() }
        token = EventTapHub.shared.subscribe(types: [.keyDown], seesDropped: false) { [weak self] _, event in
            guard let self else { return .pass }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        tapActive = EventTapHub.shared.isRunning
        HotkeyManager.shared.reserve(id: InterceptedKeys.finderCutID, title: "Finder: вырезать (⌘X)", combo: InterceptedKeys.finderCut)
        HotkeyManager.shared.reserve(id: InterceptedKeys.finderPasteID, title: "Finder: вставить (⌘V)", combo: InterceptedKeys.finderPaste)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderIndicator() }
        }
        Log.write("finderCut start tap=\(tapActive)")
    }

    func stop() {
        guard running else { return }
        running = false
        if let t = token { EventTapHub.shared.unsubscribe(t) }
        token = nil
        HotkeyManager.shared.release(id: InterceptedKeys.finderCutID)
        HotkeyManager.shared.release(id: InterceptedKeys.finderPasteID)
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        appObserver = nil
        indicator?.hide()
        indicator = nil
        engine = nil
        cut = nil
        tapActive = false
    }

    func update(_ s: FinderCutSettings) {
        settings = s
        store.saveFinderCut(s)
        renderIndicator()
    }

    func cancel() { engine?.cancel() }

    private func changed(_ c: FinderCutState?) {
        cut = c
        renderIndicator()
    }

    private func renderIndicator() {
        guard let indicator else { return }
        let isFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderKeys.finderBundleID
        if settings.indicator, let c = cut, isFinder, engine?.hasCut == true { indicator.show(paths: c.paths) } else { indicator.hide() }
    }

    private func handle(_ event: CGEvent) -> EventTapAction {
        guard event.getIntegerValueField(.eventSourceUserData) != LiveKeystrokes.marker, let engine else { return .pass }
        let stroke = KeyStroke(event: event)
        guard stroke.modifiers == KeyCombo.cmd, stroke.keyCode == FinderKeys.keyX || stroke.keyCode == FinderKeys.keyV else { return .pass }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == FinderKeys.finderBundleID else { return .pass }
        let types = Set(services.pasteboard.typeIdentifiers)
        let ctx = FinderContext(frontmostBundleID: app.bundleIdentifier, focusIsText: inspector.focusIsTextInput(pid: app.processIdentifier), hasCut: engine.hasCut,
                                clipboardHasImage: !types.isDisjoint(with: [PBType.png, PBType.tiff]), clipboardHasFiles: types.contains(PBType.fileURL))
        switch FinderCutRouter.route(stroke, ctx: ctx, pasteImage: settings.pasteImage) {
        case .pass: return .pass
        case .swallow: return .drop
        case .cut:
            DispatchQueue.main.async { MainActor.assumeIsolated { engine.cutSelection() } }
        case .pasteMove:
            DispatchQueue.main.async { MainActor.assumeIsolated { engine.pasteMove() } }
        case .pasteImage:
            DispatchQueue.main.async { MainActor.assumeIsolated { engine.pasteImage() } }
        }
        return .drop
    }
}

@MainActor
final class FinderRenameController: ObservableObject {
    static let shared = FinderRenameController()

    @Published private(set) var running = false
    @Published private(set) var tapActive = false
    @Published private(set) var fired = 0
    private let services = ClipServices.shared
    private let inspector = AXFocusInspector()
    private var token: EventTapHub.Token?
    var spec: HotkeySpec { ClipHotkeys.finderRename }

    func start() {
        guard !running else { return }
        running = true
        token = EventTapHub.shared.subscribe(types: [.keyDown], seesDropped: false) { [weak self] _, event in
            guard let self else { return .pass }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        tapActive = EventTapHub.shared.isRunning
        Log.write("finderRename start tap=\(tapActive)")
    }

    func stop() {
        guard running else { return }
        running = false
        if let t = token { EventTapHub.shared.unsubscribe(t) }
        token = nil
        tapActive = false
    }

    private func handle(_ event: CGEvent) -> EventTapAction {
        if event.getIntegerValueField(.eventSourceUserData) == LiveKeystrokes.marker { return .pass }
        let combo = HotkeyManager.shared.combo(for: spec)
        let stroke = KeyStroke(event: event)
        guard !combo.isNone, stroke.keyCode == combo.keyCode, stroke.modifiers == combo.modifiers else { return .pass }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == FinderKeys.finderBundleID else { return .pass }
        let ctx = FinderContext(frontmostBundleID: app.bundleIdentifier, focusIsText: inspector.focusIsTextInput(pid: app.processIdentifier))
        if FinderRenameRouter.shouldSwallow(stroke, ctx: ctx, combo: combo) { return .drop }
        guard FinderRenameRouter.shouldRename(stroke, ctx: ctx, combo: combo) else { return .pass }
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
            if self?.services.keys.sendReturn() == true { self?.fired += 1 }
        } }
        return .drop
    }
}

@MainActor
final class CutIndicator {
    private var panel: NSPanel?
    private let onCancel: () -> Void
    private var label: NSTextField?

    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func show(paths: [String]) {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let text = names.count == 1 ? "Вырезано: \(names[0])" : "Вырезано: \(names[0]) и ещё \(names.count - 1)"
        if panel == nil { build() }
        label?.stringValue = text
        label?.sizeToFit()
        guard let panel, let fx = panel.contentView, let label else { return }
        let w = min(label.frame.width + 70, 520)
        let size = NSSize(width: w, height: 34)
        panel.setContentSize(size)
        fx.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: 14, y: (size.height - label.frame.height) / 2, width: w - 56, height: label.frame.height)
        label.lineBreakMode = .byTruncatingMiddle
        if let btn = fx.subviews.compactMap({ $0 as? NSButton }).first { btn.frame = NSRect(x: w - 36, y: 5, width: 24, height: 24) }
        if let s = NSScreen.main { panel.setFrameOrigin(NSPoint(x: s.frame.midX - w / 2, y: s.visibleFrame.minY + 28)) }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = NSVisualEffectView(frame: p.contentView!.bounds)
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .labelColor
        fx.addSubview(l)
        let b = NSButton(title: "", target: self, action: #selector(cancelTapped))
        b.bezelStyle = .inline
        b.isBordered = false
        b.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Отменить вырезание")
        fx.addSubview(b)
        p.contentView = fx
        label = l
        panel = p
    }

    @objc private func cancelTapped() { onCancel() }
}
