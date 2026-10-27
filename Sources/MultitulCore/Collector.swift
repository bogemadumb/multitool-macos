import Foundation

public protocol Collector: AnyObject {
    var id: String { get }
    var interval: TimeInterval { get }
    var migrations: [Migration] { get }
    var retention: [Retention] { get }
    func collect(store: Store) throws
}

public extension Collector {
    var migrations: [Migration] { [] }
    var retention: [Retention] { [] }
}

public protocol SchedulerClock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemSchedulerClock: SchedulerClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public final class CollectorRegistry {
    public private(set) var collectors: [Collector] = []
    public init() {}

    @discardableResult
    public func register(_ c: Collector) -> Bool {
        guard !collectors.contains(where: { $0.id == c.id }), c.interval > 0 else { return false }
        collectors.append(c)
        return true
    }

    // Later stages add their collectors here.
    public static func standard() -> CollectorRegistry {
        let r = CollectorRegistry()
        r.register(HeartbeatCollector())
        r.register(MaintenanceCollector())
        r.register(VpnHistoryCollector.live())
        r.register(SystemCollector.live())
        r.register(StorozhCollector.live())
        return r
    }
}

public final class HeartbeatCollector: Collector {
    public let id = "heartbeat"
    public let interval: TimeInterval
    private let now: () -> Date
    private let pid: Int32

    public init(interval: TimeInterval = 30, pid: Int32 = getpid(), now: @escaping () -> Date = Date.init) {
        self.interval = interval
        self.pid = pid
        self.now = now
    }

    public func collect(store: Store) throws {
        try store.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)",
                      [.int(Int64(now().timeIntervalSince1970)), .int(Int64(pid)), .text(MultitulBuild.version)])
    }
}

public final class MaintenanceCollector: Collector {
    public let id = "maintenance"
    public let interval: TimeInterval
    private let now: () -> Date

    public init(interval: TimeInterval = 3600, now: @escaping () -> Date = Date.init) {
        self.interval = interval
        self.now = now
    }

    public func collect(store: Store) throws {
        try store.cleanup(now: now())
    }
}

public enum MultitulBuild {
    public static let version = "0.1.0"
}

public struct CollectorStats: Equatable {
    public var runs = 0
    public var failures = 0
    public var lastError: String?
}

public final class CollectorScheduler {
    private let store: Store
    private let collectors: [Collector]
    private let clock: SchedulerClock
    private var nextDue: [String: TimeInterval] = [:]
    public private(set) var stats: [String: CollectorStats] = [:]

    public init(store: Store, collectors: [Collector], clock: SchedulerClock = SystemSchedulerClock()) {
        self.store = store
        self.collectors = collectors
        self.clock = clock
    }

    public func start() throws {
        let now = clock.now
        for c in collectors {
            try store.migrate(c.migrations)
            for r in c.retention { store.addRetention(r) }
            nextDue[c.id] = now
            stats[c.id] = CollectorStats()
        }
    }

    @discardableResult
    public func tick() -> [String] {
        let now = clock.now
        var ran: [String] = []
        for c in collectors {
            guard let due = nextDue[c.id], now >= due else { continue }
            var next = due + c.interval
            if next <= now { next = now + c.interval }
            nextDue[c.id] = next
            var s = stats[c.id] ?? CollectorStats()
            s.runs += 1
            do {
                try c.collect(store: store)
                s.lastError = nil
            } catch {
                s.failures += 1
                s.lastError = "\(error)"
                Log.write("collector \(c.id) failed: \(error)")
            }
            stats[c.id] = s
            ran.append(c.id)
        }
        return ran
    }

    public func secondsUntilNextDue() -> TimeInterval? {
        guard let m = nextDue.values.min() else { return nil }
        return max(0, m - clock.now)
    }
}
