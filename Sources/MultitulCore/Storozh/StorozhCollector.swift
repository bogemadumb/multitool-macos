import Foundation

// The snapshot (top -l 2 and friends) takes seconds and runs off the collector tick; the notification waits for both
// the snapshot path and the reaction verdict, whichever finishes last enqueues it.
final class SnapshotJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var fileReady = false
    private var file: String?
    private var notify: Bool?
    private var fired = false
    private let finish: @Sendable (String?, Bool) -> Void

    init(finish: @escaping @Sendable (String?, Bool) -> Void) { self.finish = finish }

    func setFile(_ f: String?) {
        lock.lock()
        fileReady = true
        file = f
        let go = takeIfComplete()
        lock.unlock()
        if let go { finish(go.0, go.1) }
    }

    func setNotify(_ n: Bool) {
        lock.lock()
        notify = n
        let go = takeIfComplete()
        lock.unlock()
        if let go { finish(go.0, go.1) }
    }

    private func takeIfComplete() -> (String?, Bool)? {
        guard fileReady, let n = notify, !fired else { return nil }
        fired = true
        return (file, n)
    }
}

public final class StorozhCollector: Collector {
    public let id = "storozh"
    public let interval: TimeInterval
    public var migrations: [Migration] { StorozhSchema.migrations }
    public var retention: [Retention] { StorozhSchema.retention }

    // sys_state older than this means the system collector is not producing data: do not re-judge stale numbers
    public static let maxDataAge: Int64 = 90

    private let ops: ProcOps
    private let pathOf: (Int32) -> String?
    private let launchdPids: () -> Set<Int32>
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let snapshot: ((StorozhRepository, String, AnomalyRow, StorozhThresholds) -> String?)?
    private let snapshotQueue: DispatchQueue?

    public init(ops: ProcOps, pathOf: @escaping (Int32) -> String? = pidPath, launchdPids: @escaping () -> Set<Int32> = launchdListedPids,
                interval: TimeInterval = 30, now: @escaping () -> Date = Date.init, isEnabled: @escaping () -> Bool,
                snapshot: ((StorozhRepository, String, AnomalyRow, StorozhThresholds) -> String?)? = nil,
                snapshotQueue: DispatchQueue? = nil) {
        self.ops = ops
        self.pathOf = pathOf
        self.launchdPids = launchdPids
        self.interval = interval
        self.now = now
        self.isEnabled = isEnabled
        self.snapshot = snapshot
        self.snapshotQueue = snapshotQueue
    }

    public static func live() -> StorozhCollector {
        StorozhCollector(ops: SystemProcOps(), isEnabled: {
            (UserDefaults.standard.object(forKey: ModuleID.storozh.enabledKey) as? Bool) ?? ModuleID.storozh.info.enabledByDefault
        }, snapshot: { repo, kind, row, th in
            SnapshotWriter.write(repo: repo, kind: kind, anomaly: row, tools: SnapshotTools.collect(), keep: th.snapshotKeep)
        }, snapshotQueue: DispatchQueue(label: "dev.multitool.app.storozh.snapshot", qos: .utility))
    }

    public func collect(store: Store) throws {
        guard isEnabled() else { return }
        let repo = StorozhRepository(store: store)
        try repo.seedIfNeeded(now: now())
        let wall = Int64(now().timeIntervalSince1970)
        guard let latest = try store.scalarInt("SELECT MAX(ts) FROM sys_state"), wall - latest <= Self.maxDataAge else { return }
        let settings = try repo.settings()
        let lists = try repo.lists()
        let input = try StorozhDetectors.loadInput(store: store, now: latest, settings: settings)
        let found = StorozhDetectors.detect(input, lists: lists, settings: settings, pathOf: pathOf)
        for c in found {
            let row = try repo.record(ts: latest, c)
            if let snapshot, let queue = snapshotQueue {
                let clock = now
                let join = SnapshotJoin { file, notify in
                    guard notify else { return }
                    do { try repo.enqueueNotification(anomalyId: row.id, snapshot: file, now: clock()) } catch { Log.write("storozh enqueue failed: \(error)") }
                }
                queue.async { join.setFile(snapshot(repo, c.kind, row, settings.thresholds)) }
                let r = try StorozhReactions.autoReact(repo: repo, row: row, lists: lists, ops: ops, launchdPids: launchdPids)
                join.setNotify(r.notify)
                Log.write("storozh anomaly \(c.kind) \(c.name) pid=\(c.pid) snapshot=async reaction=\(r.note)")
                continue
            }
            let file = snapshot?(repo, c.kind, row, settings.thresholds)
            let r = try StorozhReactions.autoReact(repo: repo, row: row, lists: lists, ops: ops, launchdPids: launchdPids)
            if r.notify { try repo.enqueueNotification(anomalyId: row.id, snapshot: file, now: now()) }
            Log.write("storozh anomaly \(c.kind) \(c.name) pid=\(c.pid) snapshot=\(file ?? "none") reaction=\(r.note)")
        }
    }
}
