import Foundation

public enum ClipSchema {
    public static let scope = "clip"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "clip_core", sql: """
            CREATE TABLE clip_items(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, hash TEXT NOT NULL UNIQUE, title TEXT NOT NULL, search TEXT NOT NULL,
                created INTEGER NOT NULL, used INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0,
                source_bundle TEXT, source_name TEXT);
            CREATE TABLE clip_reps(
                item_id INTEGER NOT NULL, idx INTEGER NOT NULL, type TEXT NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY(item_id, idx, type));
            """),
        Migration(scope: scope, version: 2, name: "clip_use_count_and_order", sql: """
            ALTER TABLE clip_items ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX idx_clip_items_order ON clip_items(pinned, used);
            """)
    ]

    public static func openStore(path: String = MultitulPaths.dbPath) throws -> Store {
        try Store(path: path, migrations: migrations, retention: [])
    }
}

public struct ClipInsertResult: Equatable, Sendable {
    public var id: Int64
    public var deduped: Bool
}

public struct ClipPruneResult: Equatable, Sendable {
    public var byAge = 0
    public var byCount = 0
    public var bySize = 0
    public var total: Int { byAge + byCount + bySize }
}

public final class ClipStore {
    public let store: Store
    private let now: () -> Date

    public init(store: Store, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public static func open(path: String = MultitulPaths.dbPath, now: @escaping () -> Date = Date.init) throws -> ClipStore {
        ClipStore(store: try ClipSchema.openStore(path: path), now: now)
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }

    private static let columns = "id, kind, hash, title, created, used, pinned, size, source_bundle, source_name, use_count"

    private static func item(_ r: Row) -> ClipItem? {
        guard let id = r.int("id"), let k = r.string("kind").flatMap(ClipKind.init(rawValue:)) else { return nil }
        return ClipItem(id: id, kind: k, hash: r.string("hash") ?? "", title: r.string("title") ?? "",
                        created: date(r.int("created") ?? 0), used: date(r.int("used") ?? 0), pinned: (r.int("pinned") ?? 0) != 0,
                        size: Int(r.int("size") ?? 0), sourceBundle: r.string("source_bundle"), sourceName: r.string("source_name"),
                        useCount: Int(r.int("use_count") ?? 0))
    }

    @discardableResult
    public func insert(_ c: ClipCandidate) throws -> ClipInsertResult {
        return try store.transaction {
            let t = try stamp()
            let source: [SQLValue] = [c.source?.bundleID.map { .text($0) } ?? .null, c.source?.name.map { .text($0) } ?? .null]
            if let existing = try store.scalarInt("SELECT id FROM clip_items WHERE hash=?", [.text(c.hash)]) {
                try store.run("UPDATE clip_items SET kind=?, title=?, search=?, used=?, size=?, source_bundle=?, source_name=? WHERE id=?",
                              [.text(c.kind.rawValue), .text(c.title), .text(c.search), .int(t), .int(Int64(c.size))] + source + [.int(existing)])
                try store.run("DELETE FROM clip_reps WHERE item_id=?", [.int(existing)])
                try writeReps(existing, c.reps)
                return ClipInsertResult(id: existing, deduped: true)
            }
            try store.run("INSERT INTO clip_items(kind, hash, title, search, created, used, pinned, size, source_bundle, source_name) VALUES(?,?,?,?,?,?,0,?,?,?)",
                          [.text(c.kind.rawValue), .text(c.hash), .text(c.title), .text(c.search), .int(t), .int(t), .int(Int64(c.size))] + source)
            let id = store.lastInsertRowId
            try writeReps(id, c.reps)
            return ClipInsertResult(id: id, deduped: false)
        }
    }

    private func stamp() throws -> Int64 {
        max(Self.ms(now()), (try store.scalarInt("SELECT COALESCE(MAX(used),0) FROM clip_items") ?? 0) + 1)
    }

    private func writeReps(_ id: Int64, _ reps: [ClipRep]) throws {
        for r in reps {
            try store.run("INSERT OR REPLACE INTO clip_reps(item_id, idx, type, data) VALUES(?,?,?,?)", [.int(id), .int(Int64(r.index)), .text(r.type), .blob(r.data)])
        }
    }

    public func items(limit: Int = 200) throws -> [ClipItem] {
        try store.query("SELECT \(Self.columns) FROM clip_items ORDER BY pinned DESC, used DESC, id DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.item)
    }

    public func search(_ query: String, kinds: Set<ClipKind>? = nil, limit: Int = 200) throws -> [ClipItem] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var sql = "SELECT \(Self.columns) FROM clip_items WHERE 1=1"
        var args: [SQLValue] = []
        for w in words {
            sql += " AND (search LIKE ? ESCAPE '\\' OR lower(title) LIKE ? ESCAPE '\\')"
            let pat = "%" + Self.escapeLike(w) + "%"
            args.append(.text(pat))
            args.append(.text(pat))
        }
        if let kinds, !kinds.isEmpty {
            sql += " AND kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
            args += kinds.map { .text($0.rawValue) }
        }
        sql += " ORDER BY pinned DESC, used DESC, id DESC LIMIT ?"
        args.append(.int(Int64(limit)))
        return try store.query(sql, args).compactMap(Self.item)
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    public func item(id: Int64) throws -> ClipItem? {
        try store.query("SELECT \(Self.columns) FROM clip_items WHERE id=?", [.int(id)]).compactMap(Self.item).first
    }

    public func reps(id: Int64) throws -> [ClipRep] {
        try store.query("SELECT idx, type, data FROM clip_reps WHERE item_id=? ORDER BY idx, type", [.int(id)]).compactMap { r in
            guard let i = r.int(0), let t = r.string(1), let d = r.data(2) else { return nil }
            return ClipRep(index: Int(i), type: t, data: d)
        }
    }

    public func text(id: Int64) throws -> String? {
        try reps(id: id).first { $0.type == PBType.utf8 }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try store.run("UPDATE clip_items SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .int(id)])
    }

    public func touch(id: Int64) throws {
        try store.run("UPDATE clip_items SET used=?, use_count=use_count+1 WHERE id=?", [.int(try stamp()), .int(id)])
    }

    public func delete(ids: [Int64]) throws {
        try store.transaction {
            for id in ids {
                try store.run("DELETE FROM clip_reps WHERE item_id=?", [.int(id)])
                try store.run("DELETE FROM clip_items WHERE id=?", [.int(id)])
            }
        }
    }

    @discardableResult
    public func clear(keepPinned: Bool = true) throws -> Int {
        try store.transaction {
            let cond = keepPinned ? "WHERE pinned=0" : ""
            try store.run("DELETE FROM clip_reps WHERE item_id IN (SELECT id FROM clip_items \(cond))")
            return try store.run("DELETE FROM clip_items \(cond)")
        }
    }

    public func count() throws -> Int { Int(try store.scalarInt("SELECT count(*) FROM clip_items") ?? 0) }
    public func totalBytes() throws -> Int { Int(try store.scalarInt("SELECT COALESCE(SUM(size),0) FROM clip_items") ?? 0) }

    @discardableResult
    public func prune(_ s: ClipSettings) throws -> ClipPruneResult {
        var res = ClipPruneResult()
        try store.transaction {
            if s.maxAgeDays > 0 {
                let cutoff = Self.ms(now().addingTimeInterval(-Double(s.maxAgeDays) * 86400))
                res.byAge = try deleteWhere("pinned=0 AND used < ?", [.int(cutoff)])
            }
            res.byCount = try deleteWhere("pinned=0 AND id NOT IN (SELECT id FROM clip_items WHERE pinned=0 ORDER BY used DESC, id DESC LIMIT ?)", [.int(Int64(s.maxItems))])
            let cap = Int64(s.maxTotalMB) * 1024 * 1024
            var total = try store.scalarInt("SELECT COALESCE(SUM(size),0) FROM clip_items WHERE pinned=0") ?? 0
            if total > cap {
                for r in try store.query("SELECT id, size FROM clip_items WHERE pinned=0 ORDER BY used ASC, id ASC") where total > cap {
                    guard let id = r.int(0) else { continue }
                    total -= r.int(1) ?? 0
                    res.bySize += try deleteWhere("id=?", [.int(id)])
                }
            }
        }
        return res
    }

    private func deleteWhere(_ cond: String, _ args: [SQLValue]) throws -> Int {
        try store.run("DELETE FROM clip_reps WHERE item_id IN (SELECT id FROM clip_items WHERE \(cond))", args)
        return try store.run("DELETE FROM clip_items WHERE \(cond)", args)
    }
}
