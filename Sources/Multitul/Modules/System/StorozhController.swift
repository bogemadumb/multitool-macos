import SwiftUI
import AppKit
import MultitulCore

private struct StorozhLoad: Sendable {
    var open: [AnomalyRow] = []
    var recent: [AnomalyRow] = []
    var lists = StorozhLists()
    var settings = StorozhSettings()
    var offenders: [Offender] = []
    var pressure: Int?
    var health = AgentHealth(status: .never, lastBeat: nil, pid: nil, age: nil)
}

@MainActor
final class StorozhController: ObservableObject {
    static let shared = StorozhController()

    @Published private(set) var open: [AnomalyRow] = []
    @Published private(set) var recent: [AnomalyRow] = []
    @Published private(set) var lists = StorozhLists()
    @Published private(set) var settings = StorozhSettings()
    @Published private(set) var offenders: [Offender] = []
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var icon = StorozhIconState(level: .normal, paused: false)
    @Published private(set) var health = AgentHealth(status: .never, lastBeat: nil, pid: nil, age: nil)
    @Published private(set) var busy = false
    @Published var toast: String?

    var onIcon: ((StorozhIconState) -> Void)?

    private var repo: StorozhRepository?
    private var timer: Timer?
    private var watchdog = CollectorWatchdog()
    private var running = false
    private var loading = false

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        Notifier.shared.requestAuthorization()
        Notifier.shared.register(categories: StorozhNotifications.categories)
        Notifier.shared.setHandler(prefix: "storozh-") { event in
            Task { @MainActor in StorozhController.shared.handle(event) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in StorozhController.shared.refresh() }
        }
        refresh()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        Notifier.shared.setHandler(prefix: "storozh-", nil)
        onIcon = nil
    }

    private nonisolated static func openRepo() -> StorozhRepository? {
        (try? StorozhSchema.openStore()).map(StorozhRepository.init)
    }

    private func ensureRepo() -> StorozhRepository? {
        if repo == nil { repo = Self.openRepo() }
        return repo
    }

    func refresh() {
        guard !loading, let repo = ensureRepo() else { return }
        loading = true
        Task {
            let now = Date()
            let load = await Task.detached { Self.load(repo, now: now) }.value
            loading = false
            open = load.open
            recent = load.recent
            lists = load.lists
            settings = load.settings
            offenders = load.offenders
            health = load.health
            let state = StorozhIconState.compute(openCount: load.open.count, pressure: load.pressure, pausedUntil: load.settings.pausedUntil, now: now.timeIntervalSince1970)
            icon = state
            onIcon?(state)
            if watchdog.shouldKick(health: load.health, now: now) {
                Log.write("storozh: collector silent, launchctl kickstart")
                _ = await Task.detached { AgentKicker().kickstart() }.value
            }
        }
    }

    private nonisolated static func load(_ repo: StorozhRepository, now: Date) -> StorozhLoad {
        var l = StorozhLoad()
        let ts = Int64(now.timeIntervalSince1970)
        l.settings = (try? repo.settings()) ?? StorozhSettings()
        l.lists = (try? repo.lists()) ?? StorozhLists()
        l.open = (try? repo.openAnomalies(since: ts - 86400)) ?? []
        l.recent = (try? repo.recentAnomalies(limit: 40)) ?? []
        l.offenders = (try? repo.weeklyOffenders(now: now)) ?? []
        l.pressure = (try? repo.store.query("SELECT pressure FROM sys_state ORDER BY ts DESC LIMIT 1").first?.int(0)).map { Int($0) }
        l.health = AgentHealth.check(store: repo.store, now: now)
        deliver(repo, settings: l.settings, now: now)
        return l
    }

    // Outbox -> notifications. While paused the entries are consumed silently.
    private nonisolated static func deliver(_ repo: StorozhRepository, settings: StorozhSettings, now: Date) {
        let pending = (try? repo.pendingNotifications(since: Int64(now.timeIntervalSince1970) - 86400)) ?? []
        for p in pending {
            if !settings.isPaused(at: now.timeIntervalSince1970) {
                let (title, body) = StorozhReactions.notificationText(p.anomaly)
                Notifier.shared.post(title: title, body: body, id: StorozhNotifications.requestId(p.anomaly.id),
                                     category: StorozhNotifications.category(for: p.anomaly), userInfo: StorozhNotifications.userInfo(for: p))
            }
            try? repo.markDelivered(p.outboxId, now: now)
        }
    }

    func handle(_ event: NotificationEvent) {
        switch StorozhNotifications.route(event) {
        case .act(let id, let action): act(id: id, action: action, label: nil)
        case .openSnapshot(let path): _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case nil: break
        }
    }

    // MARK: actions

    private static let verbs = ["kill": "убит", "restart": "перезапущен", "ignore": "в игноре", "whitelist": "в белом списке", "dismiss": "закрыта"]

    func act(_ row: AnomalyRow, _ action: String) { act(id: row.id, action: action, label: row.name) }

    private func act(id: Int64, action: String, label: String?) {
        guard let repo = ensureRepo(), !busy else { return }
        busy = true
        Task {
            let out = await Task.detached { StorozhReactions.handleAction(repo: repo, id: id, action: action, ops: SystemProcOps(privilegedKill: SystemProcOps.privileged(PrivilegedCtl()))) }.value
            let name = label ?? "Аномалия #\(id)"
            showToast(out.status == "done" ? "\(name): \(Self.verbs[action] ?? action)" : "\(name): не вышло (\(out.note))")
            busy = false
            refresh()
        }
    }

    func setPause(_ p: PausePreset) {
        mutate { try $0.setPausedUntil(pauseUntil(p)) }
    }

    func setKind(_ kind: DetectorKind, enabled: Bool) {
        mutate { try $0.setKind(kind.rawValue, enabled: enabled) }
    }

    func setThreshold(_ field: ThresholdField, _ value: Double) {
        field.set(value, in: &settings.thresholds)
        mutate { try $0.updateThreshold(field, to: value) }
    }

    func resetThresholds() {
        settings.thresholds = StorozhThresholds()
        mutate { try $0.resetThresholds() }
    }

    func add(_ entry: String, to list: StorozhList) { mutate { try $0.addEntry(entry, to: list) } }
    func remove(_ entry: String, from list: StorozhList) { mutate { try $0.removeEntry(entry, from: list) } }

    private func mutate(_ body: @escaping @Sendable (StorozhRepository) throws -> Void) {
        guard let repo = ensureRepo() else { showToast("База недоступна"); return }
        Task {
            let ok = await Task.detached { (try? body(repo)) != nil }.value
            if !ok { showToast("Не записалось") }
            refresh()
        }
    }

    func snapshot(copyForClaude: Bool) {
        guard let repo = ensureRepo(), !busy else { return }
        busy = true
        showToast("Снимаю…")
        let keep = settings.thresholds.snapshotKeep
        Task {
            let path = await Task.detached { SnapshotWriter.write(repo: repo, kind: "manual", anomaly: nil, tools: SnapshotTools.collect(), keep: keep) }.value
            busy = false
            guard let path else { showToast("Снимок не записался"); return }
            if copyForClaude {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SnapshotWriter.claudePrompt(snapshotPath: path), forType: .string)
                showToast("Снимок записан, текст для Claude скопирован")
            } else {
                showToast("Снимок записан")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    func loadSessions() {
        let store = ensureRepo()?.store
        Task { sessions = await Task.detached { ClaudeSessions.live(store: store) }.value }
    }

    func restartCollector() {
        guard !busy else { return }
        busy = true
        Task {
            let ok = await Task.detached { AgentKicker().kickstart() }.value
            try? await Task.sleep(for: .seconds(2))
            busy = false
            showToast(ok ? "Сборщик перезапущен" : "Сборщик не перезапустился")
            refresh()
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast == text { toast = nil }
        }
    }
}
