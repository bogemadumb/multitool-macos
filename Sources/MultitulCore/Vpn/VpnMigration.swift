import Foundation

public struct VpnMigrationReport: Equatable, Sendable {
    public var samplesRead = 0
    public var samplesAdded = 0
    public var trafficRead = 0
    public var trafficChanged = 0
    public var eventsRead = 0
    public var eventsAdded = 0
    public var dryRun = false

    public init() {}
}

public enum VpnMigrationError: Error, CustomStringConvertible {
    case missingSource(String)
    case notAHistoryDatabase(String)

    public var description: String {
        switch self {
        case .missingSource(let p): return "файл не найден: \(p)"
        case .notAHistoryDatabase(let p): return "в файле нет таблиц истории VPN-значка: \(p)"
        }
    }
}

private struct DryRunDone: Error {}

// Copies samples / app_traffic / events from the old VPNMonitor history.sqlite into the vpn_* tables.
// Safe to repeat: samples and events are INSERT OR IGNORE on natural keys, traffic keeps the larger counter.
public enum VpnLegacyMigrator {
    static let chunk = 5000

    public static func run(oldPath: String, into store: Store, calendar: Calendar = .current, dryRun: Bool = false) throws -> VpnMigrationReport {
        guard FileManager.default.fileExists(atPath: oldPath) else { throw VpnMigrationError.missingSource(oldPath) }
        let tmp = NSTemporaryDirectory() + "multitul-vpn-migrate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let copy = tmp + "/history.sqlite"
        try FileManager.default.copyItem(atPath: oldPath, toPath: copy)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: oldPath + suffix) {
            try? FileManager.default.copyItem(atPath: oldPath + suffix, toPath: copy + suffix)
        }
        let old = try Store(path: copy, migrations: [], retention: [])
        let tables = Set(try old.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string(0) })
        guard tables.contains("samples") || tables.contains("app_traffic") || tables.contains("events") else {
            throw VpnMigrationError.notAHistoryDatabase(oldPath)
        }
        try store.migrate(VpnHistorySchema.migrations)

        var report = VpnMigrationReport()
        report.dryRun = dryRun
        do {
            try store.transaction {
                if tables.contains("samples") { try copySamples(old, store, &report) }
                if tables.contains("app_traffic") { try copyTraffic(old, store, calendar, &report) }
                if tables.contains("events") { try copyEvents(old, store, &report) }
                if dryRun { throw DryRunDone() }
            }
        } catch is DryRunDone {}
        return report
    }

    private static func copySamples(_ old: Store, _ store: Store, _ r: inout VpnMigrationReport) throws {
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT rowid, ts, down_bps, up_bps, delay_ms, state FROM samples WHERE rowid > ? ORDER BY rowid LIMIT ?",
                                     [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.samplesRead += 1
                guard let ts = row.int(1) else { continue }
                r.samplesAdded += try store.run("INSERT OR IGNORE INTO vpn_samples(ts, down_bps, up_bps, delay_ms, state) VALUES(?,?,?,?,?)",
                                                [.int(ts), row.double(2).map { .real($0) } ?? .null, row.double(3).map { .real($0) } ?? .null,
                                                 row.int(4).map { .int($0) } ?? .null, .text(row.string(5) ?? "off")])
            }
        }
    }

    private static func copyTraffic(_ old: Store, _ store: Store, _ calendar: Calendar, _ r: inout VpnMigrationReport) throws {
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT rowid, day, process, via, bytes_down, bytes_up FROM app_traffic WHERE rowid > ? ORDER BY rowid LIMIT ?",
                                     [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.trafficRead += 1
                guard let day = row.string(1).flatMap({ VpnDay.parseKey($0, calendar: calendar) }),
                      let process = row.string(2), let via = row.string(3) else { continue }
                let down = row.int(4) ?? 0, up = row.int(5) ?? 0
                let before = try store.query("SELECT bytes_down, bytes_up FROM vpn_app_traffic WHERE day_ts=? AND process=? AND via=?",
                                             [.int(day), .text(process), .text(via)]).first
                let newDown = max(down, before?.int(0) ?? 0), newUp = max(up, before?.int(1) ?? 0)
                if before != nil && before?.int(0) == newDown && before?.int(1) == newUp { continue }
                try store.run("""
                    INSERT INTO vpn_app_traffic(day_ts, process, via, bytes_down, bytes_up) VALUES(?,?,?,?,?)
                    ON CONFLICT(day_ts, process, via) DO UPDATE SET bytes_down = excluded.bytes_down, bytes_up = excluded.bytes_up
                    """, [.int(day), .text(process), .text(via), .int(newDown), .int(newUp)])
                r.trafficChanged += 1
            }
        }
    }

    private static func copyEvents(_ old: Store, _ store: Store, _ r: inout VpnMigrationReport) throws {
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT id, ts_start, ts_end, kind, detail FROM events WHERE id > ? ORDER BY id LIMIT ?",
                                     [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.eventsRead += 1
                guard let start = row.int(1), let kind = row.string(3) else { continue }
                r.eventsAdded += try store.run("INSERT OR IGNORE INTO vpn_events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)",
                                               [.int(start), row.int(2).map { .int($0) } ?? .null, .text(kind), .text(row.string(4) ?? "")])
            }
        }
    }
}

public enum VpnMigrationCLI {
    public static let usage = "Использование: Multitul --migrate-vpn <старая history.sqlite> [--db <новая multitul.db>] [--dry-run]"

    // Returns the process exit code; `out` receives the lines shown to the user.
    public static func run(arguments: [String], out: (String) -> Void) -> Int32 {
        var old: String?
        var db = MultitulPaths.dbPath
        var dry = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--dry-run": dry = true
            case "--db":
                i += 1
                guard i < arguments.count else { out(usage); return 64 }
                db = arguments[i]
            default:
                guard old == nil, !arguments[i].hasPrefix("--") else { out(usage); return 64 }
                old = arguments[i]
            }
            i += 1
        }
        guard let old else { out(usage); return 64 }
        do {
            let store = try VpnHistorySchema.openStore(path: db)
            let r = try VpnLegacyMigrator.run(oldPath: old, into: store, dryRun: dry)
            out(dry ? "Пробный прогон, в базу ничего не записано:" : "Готово:")
            out("  замеры: прочитано \(r.samplesRead), добавлено \(r.samplesAdded)")
            out("  трафик по приложениям: прочитано \(r.trafficRead), изменено \(r.trafficChanged)")
            out("  события: прочитано \(r.eventsRead), добавлено \(r.eventsAdded)")
            return 0
        } catch {
            out("Ошибка миграции: \(error)")
            return 1
        }
    }
}
