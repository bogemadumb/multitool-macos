import Foundation

public struct AgentHealth: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case alive
        case silent
        case never
    }

    public static let silenceThreshold: TimeInterval = 120

    public let status: Status
    public let lastBeat: Date?
    public let pid: Int32?
    public let age: TimeInterval?

    public init(status: Status, lastBeat: Date?, pid: Int32?, age: TimeInterval?) {
        self.status = status
        self.lastBeat = lastBeat
        self.pid = pid
        self.age = age
    }

    public var isHealthy: Bool { status == .alive }

    public var summary: String {
        switch status {
        case .alive: return "Сборщик работает"
        case .never: return "Сборщик ещё ни разу не отвечал"
        case .silent:
            let m = Int((age ?? 0) / 60)
            return "Сборщик молчит уже \(m) мин"
        }
    }

    public static func checkLive(path: String = MultitulPaths.dbPath, now: Date = Date()) -> AgentHealth {
        guard FileManager.default.fileExists(atPath: path), let store = try? Store(path: path, readOnly: true) else {
            return AgentHealth(status: .never, lastBeat: nil, pid: nil, age: nil)
        }
        return check(store: store, now: now)
    }

    public static func check(store: Store, now: Date = Date(), threshold: TimeInterval = silenceThreshold) -> AgentHealth {
        guard let row = (try? store.query("SELECT ts, pid FROM heartbeat ORDER BY ts DESC LIMIT 1"))?.first,
              let ts = row.int(0) else {
            return AgentHealth(status: .never, lastBeat: nil, pid: nil, age: nil)
        }
        let beat = Date(timeIntervalSince1970: TimeInterval(ts))
        let age = max(0, now.timeIntervalSince(beat))
        return AgentHealth(status: age > threshold ? .silent : .alive, lastBeat: beat,
                           pid: row.int(1).map { Int32($0) }, age: age)
    }
}
