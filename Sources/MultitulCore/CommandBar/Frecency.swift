import Foundation

public struct FrecencyConfig: Equatable, Sendable {
    public var halfLifeDays = 14.0
    public var maxPerKey = 20
    public var maxBoost = 24.0
    public var weight = 7.0

    public init() {}
}

public protocol FrecencyStoring: AnyObject {
    func load() -> [String: [Double]]
    func append(key: String, at: Double, keep: Int)
    func remove(key: String)
    func removeAll()
}

public final class MemoryFrecencyStore: FrecencyStoring {
    public private(set) var data: [String: [Double]] = [:]

    public init(_ initial: [String: [Double]] = [:]) { data = initial }

    public func load() -> [String: [Double]] { data }

    public func append(key: String, at: Double, keep: Int) {
        var l = data[key] ?? []
        l.append(at)
        if l.count > keep { l.removeFirst(l.count - keep) }
        data[key] = l
    }

    public func remove(key: String) { data[key] = nil }
    public func removeAll() { data = [:] }
}

public enum CommandBarSchema {
    public static let scope = "commandbar"
    public static let retentionSeconds: TimeInterval = 120 * 86400
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "cb_usage", sql: """
            CREATE TABLE cb_usage(key TEXT NOT NULL, ts INTEGER NOT NULL);
            CREATE INDEX idx_cb_usage_key ON cb_usage(key, ts);
            CREATE INDEX idx_cb_usage_ts ON cb_usage(ts);
            """)
    ]
    public static let retention = [Retention(table: "cb_usage", column: "ts", keepSeconds: retentionSeconds)]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: retention)
    }
}

public final class SQLiteFrecencyStore: FrecencyStoring {
    public let store: Store

    public init(store: Store) { self.store = store }

    public static func open(path: String = MultitulPaths.dbPath) throws -> SQLiteFrecencyStore {
        SQLiteFrecencyStore(store: try CommandBarSchema.openStore(path: path))
    }

    public func load() -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let rows = (try? store.query("SELECT key, ts FROM cb_usage ORDER BY ts ASC")) ?? []
        for r in rows {
            guard let k = r.string("key"), let t = r.int("ts") else { continue }
            out[k, default: []].append(Double(t))
        }
        return out
    }

    public func append(key: String, at: Double, keep: Int) {
        try? store.transaction {
            try store.run("INSERT INTO cb_usage(key, ts) VALUES(?,?)", [.text(key), .int(Int64(at))])
            try store.run("DELETE FROM cb_usage WHERE key=? AND ts NOT IN (SELECT ts FROM cb_usage WHERE key=? ORDER BY ts DESC LIMIT ?)",
                          [.text(key), .text(key), .int(Int64(keep))])
        }
    }

    public func remove(key: String) { _ = try? store.run("DELETE FROM cb_usage WHERE key=?", [.text(key)]) }
    public func removeAll() { _ = try? store.run("DELETE FROM cb_usage") }
}

public final class FrecencyIndex {
    public let config: FrecencyConfig
    private let store: FrecencyStoring
    private let clock: () -> Date
    private var uses: [String: [Double]]

    public init(store: FrecencyStoring, config: FrecencyConfig = FrecencyConfig(), clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.config = config
        self.clock = clock
        uses = store.load()
    }

    public func record(_ key: String) {
        guard !key.isEmpty else { return }
        let now = clock().timeIntervalSince1970.rounded(.down)
        var l = uses[key] ?? []
        l.append(now)
        if l.count > config.maxPerKey { l.removeFirst(l.count - config.maxPerKey) }
        uses[key] = l
        store.append(key: key, at: now, keep: config.maxPerKey)
    }

    public func score(_ key: String) -> Double {
        guard let l = uses[key], !l.isEmpty else { return 0 }
        let now = clock().timeIntervalSince1970
        let half = config.halfLifeDays * 86400
        return l.reduce(0) { $0 + pow(0.5, max(now - $1, 0) / half) }
    }

    public func boost(_ key: String) -> Double {
        let s = score(key)
        return s <= 0 ? 0 : min(config.maxBoost, config.weight * log2(1 + s))
    }

    public func useCount(_ key: String) -> Int { uses[key]?.count ?? 0 }

    public var knownKeys: [String] { Array(uses.keys) }

    public func forget(_ key: String) {
        uses[key] = nil
        store.remove(key: key)
    }

    public func clear() {
        uses = [:]
        store.removeAll()
    }
}
