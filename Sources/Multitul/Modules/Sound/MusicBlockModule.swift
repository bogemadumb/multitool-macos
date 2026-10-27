import SwiftUI
import AppKit
import ApplicationServices
import MultitulCore
import MultitulUI

@MainActor
final class MusicBlockController: ObservableObject {
    static let shared = MusicBlockController()

    @Published private(set) var settings = MusicBlockSettings()
    @Published private(set) var running = false
    @Published private(set) var tapActive = false
    @Published private(set) var trusted = true
    @Published private(set) var blocked = 0
    @Published private(set) var lastBlocked: Date?

    private let store = MusicBlockStore()
    private var logic = MusicBlockLogic()
    private var tapToken: EventTapHub.Token?
    private var observers: [NSObjectProtocol] = []
    private var lastReplacementOpen: TimeInterval = 0

    private static let gestureTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown]

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        logic = MusicBlockLogic(settings: settings)
        trusted = AXIsProcessTrusted()
        if let systemDefined = CGEventType(rawValue: 14) {
            tapToken = EventTapHub.shared.subscribe(types: [systemDefined]) { [weak self] _, event in
                MainActor.assumeIsolated { self?.mediaKey(event) }
                return .pass
            }
        }
        tapActive = EventTapHub.shared.isRunning
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.launched(note) }
            })
        }
        Log.write("musicBlock start trusted=\(trusted) tap=\(tapActive)")
    }

    func stop() {
        guard running else { return }
        running = false
        if let t = tapToken { EventTapHub.shared.unsubscribe(t) }
        tapToken = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        logic.reset()
        tapActive = false
    }

    func restart() {
        stop()
        start()
    }

    func update(_ s: MusicBlockSettings) {
        settings = s
        store.save(s)
        logic.settings = s
    }

    func chooseReplacement() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = false
        p.prompt = "Выбрать"
        guard p.runModal() == .OK, let url = p.url, let bid = Bundle(url: url)?.bundleIdentifier else { return }
        guard MusicBlockLogic.replacementUsable(url.path, bundleID: bid), MusicBlockLogic.isSafeBundleID(bid) else {
            Log.write("musicBlock replacement rejected \(bid)")
            return
        }
        var s = settings
        s.replacementPath = url.path
        s.replacementBundleID = bid
        update(s)
    }

    func clearReplacement() {
        var s = settings
        s.replacementPath = ""
        s.replacementBundleID = ""
        update(s)
    }

    private func mediaKey(_ cg: CGEvent) {
        guard let ev = NSEvent(cgEvent: cg), ev.type == .systemDefined,
              let key = MediaKeyPress.decode(subtype: Int(ev.subtype.rawValue), data1: ev.data1) else { return }
        logic.keyPressed(key, at: ProcessInfo.processInfo.systemUptime)
    }

    private func gestureAge() -> TimeInterval {
        Self.gestureTypes.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    private func launched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let decision = logic.appLaunched(bundleID: app.bundleIdentifier, pid: pid, at: ProcessInfo.processInfo.systemUptime, secondsSinceGesture: gestureAge())
        guard case .block(let action) = decision else {
            if app.bundleIdentifier.map({ MusicBlockSettings.blockedBundleIDs.contains($0) }) == true { Log.write("musicBlock allow \(decision)") }
            return
        }
        guard app.forceTerminate() || app.terminate() else {
            logic.cancelBlock(pid: pid)
            Log.write("musicBlock could not stop pid=\(pid)")
            return
        }
        blocked = logic.blockedCount
        lastBlocked = Date()
        Log.write("musicBlock blocked pid=\(pid) replacement=\(action.openReplacement) play=\(action.startPlayback)")
        if action.openReplacement { openReplacement(play: action.startPlayback) }
    }

    private func openReplacement(play: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReplacementOpen > 1 else { return }
        lastReplacementOpen = now
        let url = URL(fileURLWithPath: settings.replacementPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bid = settings.replacementBundleID
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error == nil, play, MusicBlockLogic.isSafeBundleID(bid) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { MusicBlockController.shared.play(bid, attempt: 0) } }
        }
    }

    private func play(_ bundleID: String, attempt: Int) {
        guard running, settings.playInReplacement else { return }
        var err: NSDictionary?
        NSAppleScript(source: "tell application id \"\(bundleID)\" to play")?.executeAndReturnError(&err)
        guard let err else { return }
        let status = (err[NSAppleScript.errorNumber] as? Int) ?? 0
        Log.write("musicBlock play attempt=\(attempt) status=\(status)")
        if MusicPlaybackRetry.shouldRetry(status: status, attempt: attempt) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { MusicBlockController.shared.play(bundleID, attempt: attempt + 1) } }
        }
    }
}

@MainActor
final class MusicBlockModule: Module {
    let info = ModuleID.musicBlock.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        MusicBlockController.shared.start()
        Log.write("module musicBlock start")
    }

    func stop() {
        MusicBlockController.shared.stop()
        Log.write("module musicBlock stop")
    }
}

struct MusicBlockView: View {
    @ObservedObject private var c = MusicBlockController.shared

    private func binding<T>(_ kp: WritableKeyPath<MusicBlockSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        let ready = c.trusted && c.tapActive
        Section {
            LabeledContent("Состояние") { StatusLabel(ready ? "следит" : "нет доступа", color: ready ? .green : .orange) }
            if !ready {
                ToolWarning(text: "Нужен «Универсальный доступ»: без него клавиши не видны. Выдай доступ и нажми «Повторить».")
                Button("Повторить") { c.restart() }
            }
            LabeledContent {
                HStack {
                    Button("Выбрать…") { c.chooseReplacement() }
                    if !c.settings.replacementPath.isEmpty { Button("Убрать") { c.clearReplacement() } }
                }
            } label: { SettingLabel("Приложение-замена", c.settings.replacementPath.isEmpty ? "Не выбрано: Музыка просто закрывается" : (c.settings.replacementPath as NSString).lastPathComponent) }
            ToggleSetting(title: "Запускать воспроизведение в замене", subtitle: c.settings.replacementPath.isEmpty ? "Сначала выбери приложение-замену" : "Только если нажата клавиша Play/Pause; при первом запуске macOS спросит про Автоматизацию", isOn: binding(\.playInReplacement))
                .disabled(c.settings.replacementPath.isEmpty)
        } header: { Text("Запрет самовольного запуска Музыки") } footer: {
            SectionFooter("Если «Музыка» открылась сразу после медиа-клавиши и ты ничего не нажимал, её закрывают. Открытая тобой вручную остаётся. " + (c.blocked == 0 ? "С запуска закрыто: 0." : "С запуска закрыто: \(c.blocked), последний раз \(c.lastBlocked.map { Self.time.string(from: $0) } ?? "—")."))
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
