import Foundation

public enum StorozhSchema {
    public static let scope = "storozh"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "storozh_core", sql: """
            CREATE TABLE storozh_anomalies(
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL, pid INTEGER, name TEXT,
                detail TEXT, action TEXT, status TEXT);
            CREATE INDEX idx_storozh_anomalies_ts ON storozh_anomalies(ts);
            CREATE TABLE storozh_lists(list TEXT NOT NULL, entry TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY(list, entry));
            CREATE TABLE storozh_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE storozh_outbox(
                id INTEGER PRIMARY KEY AUTOINCREMENT, anomaly_id INTEGER NOT NULL, snapshot TEXT,
                created_at INTEGER NOT NULL, delivered_at INTEGER);
            CREATE INDEX idx_storozh_outbox_pending ON storozh_outbox(delivered_at);
            """)
    ]
    public static let retention: [Retention] = [
        Retention(table: "storozh_anomalies", keepSeconds: 30 * 86400),
        Retention(table: "storozh_outbox", column: "created_at", keepSeconds: 2 * 86400),
    ]

    public static var allMigrations: [Migration] { Store.coreMigrations + SystemStoreSchema.migrations + migrations }
    public static var allRetention: [Retention] { Store.coreRetention + SystemStoreSchema.retention + retention }

    public static func openStore(path: String = MultitulPaths.dbPath, readOnly: Bool = false) throws -> Store {
        try Store(path: path, migrations: allMigrations, retention: allRetention, readOnly: readOnly)
    }
}

public struct AnomalyRow: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var ts: Int64
    public var kind: String
    public var pid: Int32
    public var name: String
    public var detail: String
    public var action: String?
    public var status: String

    public init(id: Int64, ts: Int64, kind: String, pid: Int32, name: String, detail: String, action: String? = nil, status: String) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.pid = pid
        self.name = name
        self.detail = detail
        self.action = action
        self.status = status
    }

    public var detailDict: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any] ?? [:]
    }

    public var isProcessKind: Bool { DetectorKind(rawValue: kind)?.isPerProcess ?? false }
}

public struct PendingNotification: Equatable, Sendable {
    public var outboxId: Int64
    public var anomaly: AnomalyRow
    public var snapshot: String?
}

public struct Offender: Equatable, Sendable {
    public var name: String
    public var count: Int
    public var kinds: [String]
}

public final class StorozhRepository: @unchecked Sendable {
    public let store: Store

    public init(store: Store) { self.store = store }

    // MARK: lists and settings

    public func seedIfNeeded(now: Date = Date()) throws {
        try store.transaction {
            guard try getSetting("seeded") == nil else { return }
            let ts = Int64(now.timeIntervalSince1970)
            for (list, entries) in [(StorozhList.whitelist, StorozhLists.defaultWhitelist), (.untouchable, StorozhLists.defaultUntouchable)] {
                for e in entries {
                    try store.run("INSERT OR IGNORE INTO storozh_lists(list,entry,added_at) VALUES(?,?,?)", [.text(list.rawValue), .text(e), .int(ts)])
                }
            }
            try setSetting("seeded", "1")
        }
    }

    public func isSeeded() throws -> Bool { try getSetting("seeded") != nil }

    public func markSeeded() throws { try setSetting("seeded", "1") }

    public func lists() throws -> StorozhLists {
        let rows = try store.query("SELECT list, entry FROM storozh_lists ORDER BY added_at, rowid")
        var out = StorozhLists(whitelist: [], untouchable: [], ignore: [])
        for r in rows {
            guard let l = r.string(0).flatMap(StorozhList.init(rawValue:)), let e = r.string(1) else { continue }
            switch l {
            case .whitelist: out.whitelist.append(e)
            case .untouchable: out.untouchable.append(e)
            case .ignore: out.ignore.append(e)
            }
        }
        return out
    }

    @discardableResult
    public func addEntry(_ entry: String, to list: StorozhList, now: Date = Date()) throws -> Bool {
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return false }
        return try store.run("INSERT OR IGNORE INTO storozh_lists(list,entry,added_at) VALUES(?,?,?)",
                             [.text(list.rawValue), .text(e), .int(Int64(now.timeIntervalSince1970))]) > 0
    }

    @discardableResult
    public func removeEntry(_ entry: String, from list: StorozhList) throws -> Bool {
        if list == .untouchable && StorozhLists.isBuiltin(entry) { return false }
        return try store.run("DELETE FROM storozh_lists WHERE list=? AND entry=?", [.text(list.rawValue), .text(entry)]) > 0
    }

    // whitelist and ignore exclude each other, as in the old config editor
    public func moveEntry(_ entry: String, to list: StorozhList, now: Date = Date()) throws {
        try store.transaction {
            try addEntry(entry, to: list, now: now)
            let other: StorozhList = list == .whitelist ? .ignore : .whitelist
            if list != .untouchable { try store.run("DELETE FROM storozh_lists WHERE list=? AND entry=?", [.text(other.rawValue), .text(entry)]) }
        }
    }

    func getSetting(_ key: String) throws -> String? {
        try store.query("SELECT value FROM storozh_settings WHERE key=?", [.text(key)]).first?.string(0)
    }

    func setSetting(_ key: String, _ value: String) throws {
        try store.run("INSERT INTO storozh_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(key), .text(value)])
    }

    public func settings() throws -> StorozhSettings {
        var s = StorozhSettings()
        if let t = try getSetting("thresholds"), let th = try? JSONDecoder().decode(StorozhThresholds.self, from: Data(t.utf8)) { s.thresholds = th }
        if let d = try getSetting("disabled_kinds"), let arr = try? JSONDecoder().decode([String].self, from: Data(d.utf8)) { s.disabledKinds = Set(arr) }
        if let p = try getSetting("paused_until"), let v = Double(p) { s.pausedUntil = v }
        return s
    }

    public func setThresholds(_ t: StorozhThresholds) throws {
        let data = try JSONEncoder().encode(t)
        try setSetting("thresholds", String(decoding: data, as: UTF8.self))
    }

    // Read-modify-write of one field under a transaction, so two editors cannot overwrite each other's field.
    @discardableResult
    public func updateThreshold(_ field: ThresholdField, to value: Double) throws -> StorozhThresholds {
        try store.transaction {
            var t = try settings().thresholds
            field.set(value, in: &t)
            try setThresholds(t)
            return t
        }
    }

    public func resetThresholds() throws { try setThresholds(StorozhThresholds()) }

    public func setDisabled(_ kinds: Set<String>) throws {
        let data = try JSONEncoder().encode(kinds.sorted())
        try setSetting("disabled_kinds", String(decoding: data, as: UTF8.self))
    }

    public func setKind(_ kind: String, enabled: Bool) throws {
        var s = try settings().disabledKinds
        if enabled { s.remove(kind) } else { s.insert(kind) }
        try setDisabled(s)
    }

    public func setPausedUntil(_ v: Double) throws { try setSetting("paused_until", String(v)) }

    // MARK: anomalies

    private static func row(_ r: Row) -> AnomalyRow? {
        guard let id = r.int(0), let ts = r.int(1) else { return nil }
        return AnomalyRow(id: id, ts: ts, kind: r.string(2) ?? "", pid: Int32(r.int(3) ?? 0), name: r.string(4) ?? "",
                          detail: r.string(5) ?? "", action: r.string(6), status: r.string(7) ?? "")
    }

    private static let cols = "id,ts,kind,pid,name,detail,action,status"

    public func anomalies(since: Int64, limit: Int = 500) throws -> [AnomalyRow] {
        try store.query("SELECT \(Self.cols) FROM storozh_anomalies WHERE ts >= ? ORDER BY ts, id LIMIT ?", [.int(since), .int(Int64(limit))])
            .compactMap(Self.row)
    }

    public func recentAnomalies(limit: Int = 50) throws -> [AnomalyRow] {
        try store.query("SELECT \(Self.cols) FROM storozh_anomalies ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.row)
    }

    public func openAnomalies(since: Int64, limit: Int = 20) throws -> [AnomalyRow] {
        try store.query("SELECT \(Self.cols) FROM storozh_anomalies WHERE status = 'pending_user' AND ts >= ? ORDER BY id DESC LIMIT ?",
                        [.int(since), .int(Int64(limit))]).compactMap(Self.row)
    }

    public func anomaly(id: Int64) throws -> AnomalyRow? {
        try store.query("SELECT \(Self.cols) FROM storozh_anomalies WHERE id = ?", [.int(id)]).compactMap(Self.row).first
    }

    @discardableResult
    public func record(ts: Int64, _ c: AnomalyCandidate) throws -> AnomalyRow {
        let data = (try? JSONSerialization.data(withJSONObject: c.detail, options: [.sortedKeys])) ?? Data("{}".utf8)
        let detail = String(decoding: data, as: UTF8.self)
        try store.run("INSERT INTO storozh_anomalies(ts,kind,pid,name,detail,action,status) VALUES(?,?,?,?,?,NULL,'open')",
                      [.int(ts), .text(c.kind), .int(Int64(c.pid)), .text(c.name), .text(detail)])
        return AnomalyRow(id: store.lastInsertRowId, ts: ts, kind: c.kind, pid: c.pid, name: c.name, detail: detail, action: nil, status: "open")
    }

    public func setAction(id: Int64, action: String, status: String) throws {
        try store.run("UPDATE storozh_anomalies SET action = ?, status = ? WHERE id = ?", [.text(action), .text(status), .int(id)])
    }

    public func dismiss(id: Int64) throws { try setAction(id: id, action: "dismiss", status: "done") }

    public func weeklyOffenders(now: Date = Date(), limit: Int = 20) throws -> [Offender] {
        let from = Int64(now.timeIntervalSince1970) - 7 * 86400
        return try store.query("""
            SELECT name, COUNT(*) AS c, GROUP_CONCAT(DISTINCT kind) FROM storozh_anomalies
            WHERE ts >= ? AND name <> 'system' GROUP BY name ORDER BY c DESC, name LIMIT ?
            """, [.int(from), .int(Int64(limit))]).compactMap { r in
            guard let n = r.string(0), let c = r.int(1) else { return nil }
            return Offender(name: n, count: Int(c), kinds: (r.string(2) ?? "").split(separator: ",").map(String.init).sorted())
        }
    }

    // MARK: outbox (agent -> app)

    public func enqueueNotification(anomalyId: Int64, snapshot: String?, now: Date = Date()) throws {
        try store.run("INSERT INTO storozh_outbox(anomaly_id,snapshot,created_at) VALUES(?,?,?)",
                      [.int(anomalyId), snapshot.map { .text($0) } ?? .null, .int(Int64(now.timeIntervalSince1970))])
    }

    public func pendingNotifications(since: Int64) throws -> [PendingNotification] {
        let rows = try store.query("""
            SELECT o.id, o.snapshot, a.id,a.ts,a.kind,a.pid,a.name,a.detail,a.action,a.status
            FROM storozh_outbox o JOIN storozh_anomalies a ON a.id = o.anomaly_id
            WHERE o.delivered_at IS NULL AND o.created_at >= ? ORDER BY o.id
            """, [.int(since)])
        return rows.compactMap { r in
            guard let oid = r.int(0), let id = r.int(2), let ts = r.int(3) else { return nil }
            let a = AnomalyRow(id: id, ts: ts, kind: r.string(4) ?? "", pid: Int32(r.int(5) ?? 0), name: r.string(6) ?? "",
                               detail: r.string(7) ?? "", action: r.string(8), status: r.string(9) ?? "")
            return PendingNotification(outboxId: oid, anomaly: a, snapshot: r.string(1))
        }
    }

    public func markDelivered(_ outboxId: Int64, now: Date = Date()) throws {
        try store.run("UPDATE storozh_outbox SET delivered_at = ? WHERE id = ?", [.int(Int64(now.timeIntervalSince1970)), .int(outboxId)])
    }
}
