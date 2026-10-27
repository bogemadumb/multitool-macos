import Foundation
import MultitulCtlCore

public struct VpnHistoryReading: Sendable {
    public var available: Bool
    public var daemonRunning: Bool
    public var apiOK: Bool
    public var delayMs: Int?
    public var conns: [VpnConnSnap]

    public init(available: Bool = true, daemonRunning: Bool, apiOK: Bool, delayMs: Int? = nil, conns: [VpnConnSnap] = []) {
        self.available = available
        self.daemonRunning = daemonRunning
        self.apiOK = apiOK
        self.delayMs = delayMs
        self.conns = conns
    }
}

public protocol VpnHistorySource: Sendable {
    func read() -> VpnHistoryReading
}

public final class VpnHistoryCollector: Collector {
    public let id = "vpn.history"
    public let interval: TimeInterval
    public var migrations: [Migration] { VpnHistorySchema.migrations }
    public var retention: [Retention] { VpnHistorySchema.retention }

    private let source: VpnHistorySource
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let calendar: Calendar
    private var machine = VpnStateMachine()
    private var tracker = VpnTrafficTracker()
    private var lastAt: Date?
    public private(set) var lastState: VpnState = .connecting

    public init(source: VpnHistorySource, interval: TimeInterval = 10, calendar: Calendar = .current,
                isEnabled: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.interval = interval
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.now = now
    }

    public static func live() -> VpnHistoryCollector {
        VpnHistoryCollector(source: ClashHistorySource(), isEnabled: {
            (UserDefaults.standard.object(forKey: ModuleID.vpn.enabledKey) as? Bool) ?? ModuleID.vpn.info.enabledByDefault
        })
    }

    public func collect(store: Store) throws {
        guard isEnabled() else {
            lastAt = nil
            return
        }
        let reading = source.read()
        let at = now()
        guard reading.available else {
            lastAt = nil
            return
        }
        machine.tick(daemonRunning: reading.daemonRunning, apiOK: reading.apiOK, delayMs: reading.delayMs, at: at, isExpensive: false)
        lastState = machine.state
        let deltas = tracker.update(reading.conns)
        let dt = lastAt.map { max(1, at.timeIntervalSince($0)) }
        lastAt = at
        var down = 0.0, up = 0.0
        if let dt {
            down = deltas.reduce(0) { $0 + $1.down } / dt
            up = deltas.reduce(0) { $0 + $1.up } / dt
        }
        let history = VpnHistoryStore(store: store, calendar: calendar)
        try history.insertSample(ts: at, down: down, up: up, delay: reading.delayMs, state: machine.state.rawValue)
        if dt != nil { try history.addTraffic(at: at, deltas) }
    }
}

final class ClashHistorySource: VpnHistorySource, @unchecked Sendable {
    private let client: ClashAPI
    private let daemon: VpnDaemonProbing

    init(client: ClashAPI = ClashClient(), daemon: VpnDaemonProbing = LaunchctlDaemonProbe()) {
        self.client = client
        self.daemon = daemon
    }

    func read() -> VpnHistoryReading {
        guard client.hasSecret else { return VpnHistoryReading(available: false, daemonRunning: false, apiOK: false) }
        let status = daemon.read()
        guard status.running else { return VpnHistoryReading(daemonRunning: false, apiOK: false) }
        let client = self.client
        let result = VpnSyncBridge.wait(timeout: 12) { () -> (Bool, Int?, [VpnConnSnap]) in
            do {
                let conns = try await client.connections()
                let d = try? await client.delay(timeoutMs: 5000)
                let snaps = conns.map { c in
                    VpnConnSnap(id: c.id, process: VpnConnLogic.processName(c.processPath),
                                via: VpnConnLogic.route(chains: c.chains, rule: c.rule, destIP: c.destIP).rawValue,
                                down: c.download, up: c.upload)
                }
                return (true, d, snaps)
            } catch {
                return (false, nil, [])
            }
        }
        guard let r = result else { return VpnHistoryReading(daemonRunning: true, apiOK: false) }
        return VpnHistoryReading(daemonRunning: true, apiOK: r.0, delayMs: r.1, conns: r.2)
    }
}

enum VpnSyncBridge {
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    // Blocks the calling thread; never call from the main actor or the cooperative pool.
    static func wait<T: Sendable>(timeout: TimeInterval, _ op: @escaping @Sendable () async -> T) -> T? {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let v = await op()
            box.value = v
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return nil
        }
        return box.value
    }
}
