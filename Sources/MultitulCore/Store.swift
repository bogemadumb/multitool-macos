import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Equatable, Sendable {
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(nilLiteral: ()) { self = .null }
}

public struct Row: Sendable {
    public let columns: [String]
    public let values: [SQLValue]

    public func int(_ i: Int) -> Int64? {
        switch values[i] {
        case .int(let v): return v
        case .real(let v): return Int64(v)
        default: return nil
        }
    }
    public func double(_ i: Int) -> Double? {
        switch values[i] {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public func string(_ i: Int) -> String? {
        if case .text(let v) = values[i] { return v }
        return nil
    }
    public func data(_ i: Int) -> Data? {
        if case .blob(let v) = values[i] { return v }
        return nil
    }
    private func index(_ name: String) -> Int? { columns.firstIndex(of: name) }
    public func int(_ name: String) -> Int64? { index(name).flatMap { int($0) } }
    public func double(_ name: String) -> Double? { index(name).flatMap { double($0) } }
    public func string(_ name: String) -> String? { index(name).flatMap { string($0) } }
    public func data(_ name: String) -> Data? { index(name).flatMap { data($0) } }
}

public struct StoreError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "store error \(code): \(message)" }
}

public struct Migration: Sendable {
    public let scope: String
    public let version: Int
    public let name: String
    public let sql: String
    public init(scope: String, version: Int, name: String, sql: String) {
        self.scope = scope
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public struct Retention: Sendable, Equatable {
    public let table: String
    public let column: String
    public let keepSeconds: TimeInterval
    public init(table: String, column: String = "ts", keepSeconds: TimeInterval) {
        self.table = table
        self.column = column
        self.keepSeconds = keepSeconds
    }
}

public final class Store: @unchecked Sendable {
    public static let coreMigrations: [Migration] = [
        Migration(scope: "core", version: 1, name: "heartbeat", sql: """
            CREATE TABLE heartbeat(ts INTEGER NOT NULL, pid INTEGER NOT NULL, version TEXT);
            CREATE INDEX idx_heartbeat_ts ON heartbeat(ts);
            """)
    ]
    public static let coreRetention: [Retention] = [
        Retention(table: "heartbeat", keepSeconds: 7 * 86400)
    ]

    public let path: String
    public let readOnly: Bool
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var cache: [String: OpaquePointer] = [:]
    private var retentions: [Retention] = []
    private var txDepth = 0

    public init(path: String = MultitulPaths.dbPath,
                migrations: [Migration] = Store.coreMigrations,
                retention: [Retention] = Store.coreRetention,
                readOnly: Bool = false) throws {
        self.path = path
        self.readOnly = readOnly
        if !readOnly {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError(code: rc, message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try migrate(migrations)
        }
        retentions = retention
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close(db)
    }

    private func error(_ rc: Int32, _ sql: String = "") -> StoreError {
        StoreError(code: rc, message: String(cString: sqlite3_errmsg(db)) + (sql.isEmpty ? "" : " [\(sql.prefix(80))]"))
    }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var msg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &msg)
        if rc != SQLITE_OK {
            let text = msg.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(msg)
            throw StoreError(code: rc, message: text)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { return s }
        if cache.count >= 128 {
            for (_, s) in cache { sqlite3_finalize(s) }
            cache.removeAll()
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        cache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLValue]) throws {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch a {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), sqliteTransient) }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw error(rc) }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(stmt, args)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(stmt, args)
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var vals: [SQLValue] = []
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: vals.append(.real(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: vals.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    vals.append(.blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n)))
                default: vals.append(.null)
                }
            }
            rows.append(Row(columns: names, values: vals))
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64? {
        try query(sql, args).first?.int(0)
    }

    public var lastInsertRowId: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(db)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if txDepth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        txDepth = 1
        defer { txDepth = 0 }
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var journalMode: String {
        ((try? query("PRAGMA journal_mode").first?.string(0)) ?? nil) ?? ""
    }

    // MARK: migrations

    public func migrate(_ migrations: [Migration]) throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS schema_migrations(
                scope TEXT NOT NULL, version INTEGER NOT NULL, name TEXT NOT NULL, applied_at INTEGER NOT NULL,
                PRIMARY KEY(scope, version))
            """)
        var seen = Set<String>()
        for m in migrations {
            guard m.version > 0, seen.insert("\(m.scope)#\(m.version)").inserted else {
                throw StoreError(code: -1, message: "bad or duplicate migration \(m.scope)#\(m.version)")
            }
        }
        let ordered = migrations.sorted { ($0.scope, $0.version) < ($1.scope, $1.version) }
        for m in ordered {
            let done = try scalarInt("SELECT 1 FROM schema_migrations WHERE scope=? AND version=?", [.text(m.scope), .int(Int64(m.version))])
            if done != nil { continue }
            try transaction {
                let raced = try scalarInt("SELECT 1 FROM schema_migrations WHERE scope=? AND version=?", [.text(m.scope), .int(Int64(m.version))])
                if raced != nil { return }
                try exec(m.sql)
                try run("INSERT INTO schema_migrations(scope,version,name,applied_at) VALUES(?,?,?,?)",
                        [.text(m.scope), .int(Int64(m.version)), .text(m.name), .int(Int64(Date().timeIntervalSince1970))])
            }
        }
    }

    public func appliedMigrations() throws -> [(scope: String, version: Int)] {
        try query("SELECT scope, version FROM schema_migrations ORDER BY scope, version").map {
            ($0.string(0) ?? "", Int($0.int(1) ?? 0))
        }
    }

    // MARK: retention

    private static func isIdentifier(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, f == "_" || (f.value < 128 && CharacterSet.letters.contains(f)) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.value < 128 && CharacterSet.alphanumerics.contains($0)) }
    }

    public func addRetention(_ r: Retention) {
        lock.lock(); defer { lock.unlock() }
        retentions.removeAll { $0.table == r.table }
        retentions.append(r)
    }

    public var retentionRules: [Retention] {
        lock.lock(); defer { lock.unlock() }
        return retentions
    }

    @discardableResult
    public func cleanup(now: Date = Date()) throws -> [String: Int] {
        let rules = retentionRules
        var deleted: [String: Int] = [:]
        for r in rules {
            guard Store.isIdentifier(r.table), Store.isIdentifier(r.column) else {
                throw StoreError(code: -1, message: "bad retention identifier \(r.table).\(r.column)")
            }
            let exists = try scalarInt("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(r.table)])
            guard exists != nil else { continue }
            let cutoff = Int64(now.timeIntervalSince1970 - r.keepSeconds)
            deleted[r.table] = try run("DELETE FROM \(r.table) WHERE \(r.column) < ?", [.int(cutoff)])
        }
        if !readOnly { _ = try? query("PRAGMA wal_checkpoint(PASSIVE)") }
        return deleted
    }
}
