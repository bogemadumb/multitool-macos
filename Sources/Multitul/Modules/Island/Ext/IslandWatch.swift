import SwiftUI
import AppKit
import ScreenCaptureKit
import MultitulCore
import MultitulUI

enum IslWatchGrab {
    static func signature(_ image: CGImage) -> IslWatSignature? {
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n)
        let ok = px.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? IslWatSignature.make(gray: px, width: n, height: n) : nil
    }

    static func capture(_ r: IslWatRegion) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == r.displayID }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        let k = min(2.0, 900 / max(r.width, r.height))
        cfg.width = max(Int(r.width * k), 8)
        cfg.height = max(Int(r.height * k), 8)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
    }
}

@MainActor
final class IslandWatchService: ObservableObject {
    static let shared = IslandWatchService()
    static let regionKey = "notch.watch.region"

    @Published private(set) var revision = 0
    @Published private(set) var settings: IslWatSettings
    @Published private(set) var region: IslWatRegion?
    @Published private(set) var note = ""
    @Published private(set) var selecting = false
    private(set) var detector: IslWatDetector
    private(set) var settledAt: Date?
    var onChange: (() -> Void)?
    private let store = IslWatSettingsStore()
    private let recognizer = VisionOcrRecognizer()
    private let capture = ScreenCapture()
    private var overlay = ScreenOverlaySet()
    private var keyMonitor: Any?
    private var timer: Timer?
    private var busy = false
    private(set) var running = false

    private init() {
        let s = store.load()
        settings = s
        detector = IslWatDetector(settings: s)
        region = IslWatRegion(stored: UserDefaults.standard.string(forKey: Self.regionKey))
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        detector.settings = settings
        region = IslWatRegion(stored: UserDefaults.standard.string(forKey: Self.regionKey))
    }

    func stop() {
        guard running else { return }
        running = false
        stopWatching()
        finishSelection()
    }

    var watching: Bool { detector.isRunning }

    // MARK: region

    func pickRegion() {
        guard running, !selecting else { return }
        guard ScreenCapture.hasPermission else {
            note = "Нужен доступ «Запись экрана»"
            Permissions.shared.openSettings(.screenRecording)
            publish()
            return
        }
        selecting = true
        IslandController.shared.closeAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let shots = await capture.captureAll()
            guard selecting else { return }
            guard !shots.isEmpty else { note = "Не удалось снять экран"; selecting = false; publish(); return }
            present(shots)
        }
    }

    private func present(_ shots: [ScreenCapture.Shot]) {
        overlay = ScreenOverlaySet()
        for shot in shots {
            guard let screen = NSScreen.screens.first(where: { $0.frame == shot.frame }) else { continue }
            let v = RegionSelectView(shot: shot)
            v.hint = "Выдели область, за которой нужно следить (прогресс, статус, счёт) · Esc — отмена"
            v.onFinish = { [weak self, weak v] rect, shot in
                let h = v?.bounds.height ?? shot.frame.height
                self?.finishSelection()
                guard let rect else { return }
                let r = IslWatRegion(displayID: shot.displayID, x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
                self?.setRegion(r)
            }
            overlay.add(screen, content: v)
        }
        guard !overlay.windows.isEmpty else { selecting = false; return }
        overlay.showAll()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.finishSelection() }
            return nil
        }
    }

    private func finishSelection() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlay.closeAll()
        selecting = false
        publish()
    }

    private func setRegion(_ r: IslWatRegion) {
        guard r.isValid else { return }
        region = r
        UserDefaults.standard.set(r.stored, forKey: Self.regionKey)
        beginWatching()
    }

    // MARK: watching

    func beginWatching() {
        guard running, let r = region, !busy else { return }
        note = ""
        settledAt = nil
        busy = true
        Task { @MainActor in
            let (sig, text) = await grabFrame(r)
            busy = false
            guard sig != nil else { note = "Не удалось снять область"; publish(); return }
            _ = detector.begin(sig, text: text, now: Date())
            schedule()
            publish()
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        detector.stop()
        settledAt = nil
        publish()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: settings.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard detector.isRunning, !busy, let r = region else { return }
        busy = true
        Task { @MainActor in
            let (sig, text) = await grabFrame(r)
            busy = false
            guard detector.isRunning else { return }
            let events = detector.feed(sig, text: text, now: Date())
            for e in events {
                switch e {
                case .settled(let after):
                    settledAt = Date()
                    NSSound(named: NSSound.Name("Glass"))?.play()
                    Notifier.shared.post(title: "Область перестала меняться", body: "Менялась \(IslTimeFormat.clock(after))", id: "island-watch-done")
                    if settings.stopAfterSettled { timer?.invalidate(); timer = nil } else { _ = detector.begin(sig, text: text, now: Date()) }
                default: break
                }
            }
            if !events.isEmpty { publish() } else { revision &+= 1 }
        }
    }

    private func grabFrame(_ r: IslWatRegion) async -> (IslWatSignature?, String?) {
        guard let image = await IslWatchGrab.capture(r) else { return (nil, nil) }
        let sig = IslWatchGrab.signature(image)
        var text: String?
        if settings.readText {
            var cfg = OcrRequestConfig()
            cfg.level = .fast
            let rec = recognizer
            text = await Task.detached { (try? rec.recognizeText(in: image, config: cfg))?.map(\.text).joined(separator: " ") }.value
        }
        return (sig, text)
    }

    private func publish() {
        revision &+= 1
        onChange?()
    }

    func update(_ s: IslWatSettings) {
        settings = s.sanitized
        store.save(settings)
        detector.settings = settings
        if detector.isRunning { schedule() }
        revision &+= 1
    }

    func activity() -> IslActivity? { running ? IslWatActivityFactory.activity(detector, settledAt: settledAt, now: Date()) : nil }
}

@MainActor
final class IslandWatchSection: IslandSectionBase {
    private let service = IslandWatchService.shared

    init() { super.init(IslSectionIDs.watch) }

    override var availability: IslAvailability { requires(.notchWatch) }

    override var activities: [IslActivity] { service.activity().map { [$0] } ?? [] }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        AnyView(Image(systemName: activity.token.hasPrefix("done") ? "eye.fill" : "eye").font(.system(size: 13, weight: .semibold)).foregroundStyle(activity.token.hasPrefix("done") ? Theme.ok : .white))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        if activity.token.hasPrefix("done") { return AnyView(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ok)) }
        if let p = service.detector.progress { return AnyView(Text("\(Int((p * 100).rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)) }
        return AnyView(Circle().fill(service.detector.phase == .changing ? Theme.warn : Theme.ok).frame(width: 7, height: 7))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(HStack(spacing: 10) {
            Image(systemName: "eye").foregroundStyle(.white)
            Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 14))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandWatchView(service: service, context: context)) }
}

struct IslandWatchView: View {
    @ObservedObject var service: IslandWatchService
    let context: IslExpandContext

    var body: some View {
        let _ = service.revision
        let d = service.detector
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon(d.phase)).font(.system(size: 24)).foregroundStyle(d.phase == .settled ? Theme.ok : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(d)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle(d)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            if let p = d.progress { IslSlider(value: .constant(p), height: 4).allowsHitTesting(false).frame(height: 8) }
            HStack(spacing: 8) {
                IslTile(symbol: "viewfinder", title: service.region == nil ? "Выбрать область" : "Другая область") {
                    context.closeIsland()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { service.pickRegion() }
                }
                if service.region != nil {
                    IslTile(symbol: service.watching ? "stop.circle" : "play.circle", title: service.watching ? "Остановить" : "Следить снова", active: service.watching) {
                        if service.watching { service.stopWatching() } else { service.beginWatching() }
                    }
                }
            }
            if !service.note.isEmpty { Text(service.note).font(.system(size: 10.5)).foregroundStyle(Theme.warn) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
    }

    private func icon(_ p: IslWatDetector.Phase) -> String {
        switch p {
        case .idle: "eye.slash"
        case .watching: "eye"
        case .changing: "waveform.path.ecg"
        case .settled: "checkmark.circle.fill"
        }
    }

    private func title(_ d: IslWatDetector) -> String {
        switch d.phase {
        case .idle: service.region == nil ? "Область не выбрана" : "Наблюдение остановлено"
        case .watching: "Слежу за областью"
        case .changing: "Область меняется"
        case .settled: "Область перестала меняться"
        }
    }

    private func subtitle(_ d: IslWatDetector) -> String {
        switch d.phase {
        case .idle: "Выбери часть окна: прогресс-бар, статус сборки, счёт"
        case .watching: "Сообщу, когда там что-то изменится"
        case .changing: "Сообщу, когда картинка простоит \(Int(service.settings.settleSeconds)) с. Изменений: \(d.changes)"
        case .settled: "Менялась \(IslTimeFormat.clock((service.settledAt ?? Date()).timeIntervalSince(d.firstChange ?? Date())))"
        }
    }
}

struct IslandWatchSettings: View {
    @ObservedObject var service: IslandWatchService

    private func binding<T>(_ kp: WritableKeyPath<IslWatSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .screenRecording, text: "Для наблюдения нужна «Запись экрана».")
        Section {
            IslandStepperRow(symbol: "hourglass", title: "Считать законченным, когда стоит", value: Binding(get: { Int(service.settings.settleSeconds) }, set: { v in var s = service.settings; s.settleSeconds = Double(v); service.update(s) }), range: 5...300, unit: " с")
            IslandStepperRow(symbol: "timer", title: "Проверять раз в", value: Binding(get: { Int(service.settings.interval) }, set: { v in var s = service.settings; s.interval = Double(v); service.update(s) }), range: 1...30, unit: " с")
            SliderSetting("Чувствительность", "Правее — реагирует на мелкие изменения", value: Binding(get: { -log10(service.settings.sensitivity) }, set: { v in var s = service.settings; s.sensitivity = pow(10, -v); service.update(s) }), in: 0.7...2.7)
            Toggle(isOn: binding(\.readText)) { SettingLabel("Читать текст в области", "Проценты и слова «готово» тоже считаются изменением; нагружает чуть сильнее") }
            Toggle("Останавливаться после завершения", isOn: binding(\.stopAfterSettled))
        } header: { Text("Наблюдение за областью") }
    }
}
