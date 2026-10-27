import SwiftUI
import AppKit
import MultitulCore

final class FanRuntime: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.multitool.app.fan")
    private let guardQueue = DispatchQueue(label: "dev.multitool.app.fan.watchdog")
    private let engine: FanEngine
    private let publishHandler: @Sendable (FanSnapshot) -> Void
    private var timer: DispatchSourceTimer?
    private var guardTimer: DispatchSourceTimer?
    private var fast = false
    private var interval: TimeInterval = 0

    init(onNotify: @escaping @Sendable (String, String) -> Void, onPublish: @escaping @Sendable (FanSnapshot) -> Void) {
        engine = FanEngine.live(notify: onNotify)
        publishHandler = onPublish
    }

    func start() {
        queue.async { [self] in
            engine.start()
            publish()
            rearm()
        }
        let g = DispatchSource.makeTimerSource(queue: guardQueue)
        g.schedule(deadline: .now() + 5, repeating: 5)
        g.setEventHandler { [engine] in engine.watchdog.check() }
        g.resume()
        guardTimer = g
    }

    func stop() {
        guardTimer?.cancel()
        guardTimer = nil
        queue.sync {
            timer?.cancel()
            timer = nil
            engine.stop()
        }
    }

    func async(_ work: @escaping @Sendable (FanEngine) -> Void) {
        queue.async { [self] in
            work(engine)
            publish()
            rearm()
        }
    }

    func sleepNow() {
        queue.sync {
            engine.sleep()
            publish()
        }
    }

    func setFast(_ on: Bool) {
        queue.async { [self] in
            fast = on
            rearm()
        }
    }

    private func rearm() {
        let want: TimeInterval = (fast || engine.isControlling || engine.restorePending) ? 2 : 30
        guard want != interval else { return }
        interval = want
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + want, repeating: want)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            engine.tick()
            publish()
            rearm()
        }
        t.resume()
        timer = t
    }

    private func publish() { publishHandler(engine.snapshot()) }
}

@MainActor
final class FanControlController: ObservableObject {
    static let shared = FanControlController()

    @Published private(set) var snapshot = FanSnapshot()
    @Published private(set) var presets: [FanPreset] = []
    @Published private(set) var activePreset: String?

    private var runtime: FanRuntime?
    private var observers: [NSObjectProtocol] = []
    private var termSource: DispatchSourceSignal?
    private var library: FanPresetLibrary?
    private var viewers = 0
    private let settings = FanSettingsStore()

    var running: Bool { runtime != nil }

    func start() {
        guard runtime == nil else { return }
        let lib = FanPresetLibrary(store: settings)
        library = lib
        presets = lib.all
        activePreset = settings.activePreset
        let rt = FanRuntime(onNotify: { title, body in
            Notifier.shared.post(title: title, body: body, id: "fancontrol")
        }, onPublish: { snap in
            DispatchQueue.main.async { MainActor.assumeIsolated { FanControlController.shared.apply(snap) } }
        })
        runtime = rt
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runtime?.sleepNow() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { self?.runtime?.async { $0.wake() } }
                }
            }
        })
        rt.start()
        rt.setFast(viewers > 0)
    }

    func stop() {
        guard let rt = runtime else { return }
        runtime = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        rt.stop()
        releaseTermHandler()
        snapshot = FanSnapshot()
        library = nil
    }

    func viewerAppeared() {
        viewers += 1
        runtime?.setFast(true)
    }

    func viewerGone() {
        viewers = max(0, viewers - 1)
        runtime?.setFast(viewers > 0)
    }

    func setMode(_ mode: FanControlMode) {
        runtime?.async { $0.setMode(mode) }
    }

    func update(_ config: FanConfig) {
        runtime?.async { $0.update(config) }
    }

    func applyPreset(_ id: String) {
        guard let lib = library, let cfg = lib.config(applying: id, to: snapshot.config) else { return }
        settings.activePreset = id
        activePreset = id
        update(cfg)
    }

    func savePreset(name: String) {
        guard let lib = library, let p = lib.save(name: name, config: snapshot.config) else { return }
        presets = lib.all
        settings.activePreset = p.id
        activePreset = p.id
    }

    func deletePreset(_ id: String) {
        guard let lib = library, lib.delete(id) else { return }
        presets = lib.all
        activePreset = settings.activePreset
    }

    private func apply(_ snap: FanSnapshot) {
        guard runtime != nil else { return }
        if snap != snapshot { snapshot = snap }
        if snap.isControlling { holdTermHandler() } else { releaseTermHandler() }
    }

    // SIGTERM would kill the process before the fans are returned: while controlling, route it through a normal quit.
    private func holdTermHandler() {
        guard termSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src
    }

    private func releaseTermHandler() {
        guard let src = termSource else { return }
        src.cancel()
        termSource = nil
        signal(SIGTERM, SIG_DFL)
    }
}

@MainActor
final class FanControlModule: Module {
    let info = ModuleID.fanControl.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        FanControlController.shared.start()
        Log.write("module fanControl start")
    }

    func stop() {
        FanControlController.shared.stop()
        Log.write("module fanControl stop")
    }
}
