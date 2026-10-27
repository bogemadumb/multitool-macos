import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class SystemHub: ObservableObject {
    static let shared = SystemHub()

    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var processes: [ProcRow] = []
    @Published private(set) var netProcesses: [NetProcRow] = []
    @Published private(set) var history = NamedHistory(capacity: 120)
    @Published private(set) var enabled: Set<SystemMetric> = []
    @Published private(set) var lastSpeedTest: SpeedTestResult?
    @Published private(set) var speedTestRunning = false
    @Published var layout: MenuBarLayout = MenuBarLayout.load() {
        didSet {
            guard layout != oldValue else { return }
            layout.save()
            statusItems.apply(layout: layout, enabled: enabled)
            reconfigure()
        }
    }

    private var pageVisible = 0
    private var panelVisible = 0
    private let engine = AlertEngine()
    private lazy var statusItems = MonitorStatusItems { AppController.shared.openSection(ModuleGroup.system.rawValue) }
    private lazy var sampler = LiveSampler { [weak self] frame in
        MainActor.assumeIsolated { self?.handle(frame) }
    }
    private var unmountObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?

    private init() {}

    var uploadFirst: Bool { UserDefaults.standard.bool(forKey: "monitor.network.uploadFirst") }

    var panelOwner: SystemMetric? {
        SystemMetric.allCases.first { enabled.contains($0) && $0.inMenuBar }
    }

    nonisolated static func openHistoryStore() -> Store? {
        guard FileManager.default.fileExists(atPath: MultitulPaths.dbPath) else { return nil }
        return try? Store(path: MultitulPaths.dbPath, readOnly: true)
    }

    func acquire(_ metric: SystemMetric) {
        let wasEmpty = enabled.isEmpty
        enabled.insert(metric)
        if wasEmpty { installObservers() }
        statusItems.apply(layout: layout, enabled: enabled)
        reconfigure()
    }

    func release(_ metric: SystemMetric) {
        enabled.remove(metric)
        history = NamedHistory(capacity: 120).keeping(history, metrics: enabled)
        statusItems.apply(layout: layout, enabled: enabled)
        if enabled.isEmpty { removeObservers(); sampler.stop() }
        reconfigure()
    }

    func pageAppeared() { pageVisible += 1; reconfigure() }
    func pageDisappeared() { pageVisible = max(0, pageVisible - 1); reconfigure() }
    func panelAppeared() { panelVisible += 1; reconfigure() }
    func panelDisappeared() { panelVisible = max(0, panelVisible - 1); reconfigure() }

    func reconfigure() {
        guard !enabled.isEmpty else { return }
        let menuShown = !layout.shown(enabled: enabled).isEmpty
        let alertsOn = !AlertSettings.load().enabled.isEmpty
        let active = pageVisible > 0 || panelVisible > 0 || menuShown || alertsOn
        let interval: TimeInterval = pageVisible > 0 ? 1 : ((panelVisible > 0 || menuShown) ? 2 : 5)
        let wantProcs = pageVisible > 0 && !enabled.isDisjoint(with: [.cpu, .memory, .network])
        sampler.configure(enabled: active ? enabled : [], wantProcesses: wantProcs, interval: interval)
    }

    private func installObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            unmountObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let path = url.path
                MainActor.assumeIsolated { self?.sampler.noteUnmount(path: path) }
            })
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
    }

    private func removeObservers() {
        for o in unmountObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        unmountObservers = []
        if let d = defaultsObserver { NotificationCenter.default.removeObserver(d); defaultsObserver = nil }
    }

    private func handle(_ f: LiveFrame) {
        guard !enabled.isEmpty else { return }
        snapshot = f.snapshot
        processes = f.processes
        netProcesses = f.netProcesses
        let s = f.snapshot
        var h = history
        if let c = s.cpu { h.append(HistoryKey.cpu, c.total * 100) }
        if let g = s.gpu { h.append(HistoryKey.gpu, g.utilization * 100) }
        if let m = s.memory { h.append(HistoryKey.memory, m.composition.usedFraction * 100) }
        if let n = s.network { h.append(HistoryKey.netDown, n.downBps); h.append(HistoryKey.netUp, n.upBps) }
        if let d = s.disk { h.append(HistoryKey.diskRead, d.readBps); h.append(HistoryKey.diskWrite, d.writeBps); h.append(HistoryKey.diskIO, d.readBps + d.writeBps) }
        if let t = s.temps.cpu { h.append(HistoryKey.tempCPU, t) }
        if let t = s.temps.gpu { h.append(HistoryKey.tempGPU, t) }
        if let b = s.battery?.percent { h.append(HistoryKey.battery, Double(b)) }
        if let w = s.battery?.systemPowerW { h.append(HistoryKey.powerW, w) }
        history = h
        statusItems.update(snapshot: s, history: h, uploadFirst: uploadFirst)

        engine.settings = AlertSettings.load()
        for a in engine.evaluate(s) {
            Notifier.shared.post(title: a.title, body: a.body, id: "monitor.\(a.kind.rawValue)")
        }
        if UserDefaults.standard.object(forKey: "monitor.disk.ejectReminder") as? Bool ?? true {
            for p in f.unsafeRemovals {
                Notifier.shared.post(title: "Диск отключён без извлечения", body: "«\((p as NSString).lastPathComponent)» пропал без «Извлечь». Так можно потерять данные.", id: "monitor.eject.\(p)")
            }
        }
    }

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        Task.detached {
            let text = ToolRunner.run("/usr/bin/networkQuality", ["-c"], timeout: 90)
            let r = SystemParsers.networkQuality(text)
            await MainActor.run {
                SystemHub.shared.lastSpeedTest = r
                SystemHub.shared.speedTestRunning = false
            }
        }
    }
}

extension NamedHistory {
    func keeping(_ other: NamedHistory, metrics: Set<SystemMetric>) -> NamedHistory {
        var out = NamedHistory(capacity: capacity)
        var keys = Set<String>()
        if metrics.contains(.cpu) { keys.formUnion([HistoryKey.cpu, HistoryKey.tempCPU]) }
        if metrics.contains(.gpu) { keys.formUnion([HistoryKey.gpu, HistoryKey.tempGPU]) }
        if metrics.contains(.memory) { keys.insert(HistoryKey.memory) }
        if metrics.contains(.network) { keys.formUnion([HistoryKey.netDown, HistoryKey.netUp]) }
        if metrics.contains(.disk) { keys.formUnion([HistoryKey.diskRead, HistoryKey.diskWrite, HistoryKey.diskIO]) }
        if metrics.contains(.power) { keys.formUnion([HistoryKey.battery, HistoryKey.powerW]) }
        for k in keys { for v in other.values(k) { out.append(k, v) } }
        return out
    }
}
