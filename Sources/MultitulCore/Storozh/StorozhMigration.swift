import Foundation

public struct StorozhMigrationReport: Equatable, Sendable {
    public var procRead = 0, procAdded = 0
    public var stateRead = 0, stateAdded = 0
    public var powerRead = 0, powerAdded = 0
    public var batteryRead = 0, batteryAdded = 0
    public var anomaliesRead = 0, anomaliesAdded = 0
    public var configFound = false
    public var listEntriesAdded = 0
    public var thresholdsCopied = false
    public var disabledKindsAdded = 0
    public var dryRun = false
    public init() {}
}

public enum StorozhMigrationError: Error, CustomStringConvertible {
    case missingSource(String)
    case notStorozhDatabase(String)

    public var description: String {
        switch self {
        case .missingSource(let p): return "файл не найден: \(p)"
        case .notStorozhDatabase(let p): return "в файле нет таблиц Сторожа (samples/system/anomalies): \(p)"
        }
    }
}

private struct DryRunDone: Error {}

// Copies the old Storozh history into sys_* / storozh_* tables. Reads a copy of the old database; never writes to it.
// Idempotent: samples are copied per timestamp that the target does not have yet, anomalies by (ts, kind, name, pid), list entries by union.
public enum StorozhLegacyMigrator {
    public static func run(oldPath: String, configPath: String? = nil, into store: Store, dryRun: Bool = false, chunk: Int = 5000) throws -> StorozhMigrationReport {
        guard FileManager.default.fileExists(atPath: oldPath) else { throw StorozhMigrationError.missingSource(oldPath) }
        let tmp = NSTemporaryDirectory() + "multitul-storozh-migrate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let copy = tmp + "/storozh.db"
        try FileManager.default.copyItem(atPath: oldPath, toPath: copy)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: oldPath + suffix) {
            try? FileManager.default.copyItem(atPath: oldPath + suffix, toPath: copy + suffix)
        }
        let old = try Store(path: copy, migrations: [], retention: [])
        let tables = Set(try old.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string(0) })
        guard tables.contains("samples") || tables.contains("system") || tables.contains("anomalies") else {
            throw StorozhMigrationError.notStorozhDatabase(oldPath)
        }
        let cfgPath = configPath ?? ((oldPath as NSString).deletingLastPathComponent + "/config.json")
        let config = loadConfig(cfgPath)

        var report = StorozhMigrationReport()
        report.dryRun = dryRun
        report.configFound = config != nil
        do {
            try store.transaction {
                try store.migrate(StorozhSchema.allMigrations)
                if tables.contains("samples") { try copySamples(old, store, &report, chunk) }
                if tables.contains("system") { try copySystem(old, store, &report, chunk) }
                if tables.contains("power") { try copyPower(old, store, &report, chunk) }
                if tables.contains("battery_info") { try copyBattery(old, store, &report) }
                if tables.contains("anomalies") { try copyAnomalies(old, store, &report) }
                if let config { try copyConfig(config, store, &report) }
                if dryRun { throw DryRunDone() }
            }
        } catch is DryRunDone {}
        return report
    }

    // MARK: history

    // Timestamps the target already has inside the old table's range, taken once before any insert:
    // a timestamp split across two chunks must not be mistaken for existing data.
    private static func existingTs(_ old: Store, _ store: Store, source: String, table: String) throws -> Set<Int64> {
        guard let range = try old.query("SELECT MIN(ts), MAX(ts) FROM \(source)").first, let lo = range.int(0), let hi = range.int(1) else { return [] }
        return Set(try store.query("SELECT DISTINCT ts FROM \(table) WHERE ts BETWEEN ? AND ?", [.int(lo), .int(hi)]).compactMap { $0.int(0) })
    }

    private static func copySamples(_ old: Store, _ store: Store, _ r: inout StorozhMigrationReport, _ chunk: Int) throws {
        let have = try existingTs(old, store, source: "samples", table: "sys_proc")
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT rowid, ts, pid, ppid, name, cpu, rss FROM samples WHERE rowid > ? ORDER BY rowid LIMIT ?", [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.procRead += 1
                guard let ts = row.int(1), let pid = row.int(2), !have.contains(ts) else { continue }
                r.procAdded += try store.run("INSERT INTO sys_proc(ts,pid,ppid,name,cpu,rss) VALUES(?,?,?,?,?,?)",
                                             [.int(ts), .int(pid), row.int(3).map { .int($0) } ?? .null, .text(row.string(4) ?? ""),
                                              row.double(5).map { .real($0) } ?? .null, row.int(6).map { .int($0) } ?? .null])
            }
        }
    }

    private static func copySystem(_ old: Store, _ store: Store, _ r: inout StorozhMigrationReport, _ chunk: Int) throws {
        let have = Set(try old.query("PRAGMA table_info(system)").compactMap { $0.string(1) })
        let wanted = ["pressure", "swap_mb", "idle_s", "batt_pct", "on_ac", "thermal", "disk_free_gb",
                      "mem_wired_mb", "mem_compressed_mb", "mem_app_mb", "mem_free_mb"]
        let cols = wanted.filter { have.contains($0) }
        let select = (["rowid", "ts"] + cols).joined(separator: ", ")
        let existing = try existingTs(old, store, source: "system", table: "sys_state")
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT \(select) FROM system WHERE rowid > ? ORDER BY rowid LIMIT ?", [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.stateRead += 1
                guard let ts = row.int(1), !existing.contains(ts) else { continue }
                var names = ["ts"], values: [SQLValue] = [.int(ts)]
                for (i, c) in cols.enumerated() {
                    names.append(c)
                    switch row.values[i + 2] {
                    case .null: values.append(.null)
                    default: values.append(row.values[i + 2])
                    }
                }
                let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
                r.stateAdded += try store.run("INSERT INTO sys_state(\(names.joined(separator: ","))) VALUES(\(marks))", values)
            }
        }
    }

    private static func copyPower(_ old: Store, _ store: Store, _ r: inout StorozhMigrationReport, _ chunk: Int) throws {
        let have = try existingTs(old, store, source: "power", table: "sys_power")
        var last: Int64 = 0
        while true {
            let rows = try old.query("SELECT rowid, ts, pid, name, power FROM power WHERE rowid > ? ORDER BY rowid LIMIT ?", [.int(last), .int(Int64(chunk))])
            if rows.isEmpty { break }
            for row in rows {
                last = row.int(0) ?? last
                r.powerRead += 1
                guard let ts = row.int(1), !have.contains(ts) else { continue }
                r.powerAdded += try store.run("INSERT INTO sys_power(ts,pid,name,power) VALUES(?,?,?,?)",
                                              [.int(ts), row.int(2).map { .int($0) } ?? .null, .text(row.string(3) ?? ""), row.double(4).map { .real($0) } ?? .null])
            }
        }
    }

    private static func copyBattery(_ old: Store, _ store: Store, _ r: inout StorozhMigrationReport) throws {
        let rows = try old.query("SELECT ts, cycles, health_pct, time_remaining_min FROM battery_info ORDER BY ts")
        for row in rows {
            r.batteryRead += 1
            guard let ts = row.int(0), try store.scalarInt("SELECT 1 FROM sys_battery WHERE ts=?", [.int(ts)]) == nil else { continue }
            r.batteryAdded += try store.run("INSERT INTO sys_battery(ts,cycles,health_pct,time_remaining_min) VALUES(?,?,?,?)",
                                            [.int(ts), row.int(1).map { .int($0) } ?? .null, row.double(2).map { .real($0) } ?? .null, row.int(3).map { .int($0) } ?? .null])
        }
    }

    private static func copyAnomalies(_ old: Store, _ store: Store, _ r: inout StorozhMigrationReport) throws {
        let rows = try old.query("SELECT ts, kind, pid, name, detail, action, status FROM anomalies ORDER BY id")
        for row in rows {
            r.anomaliesRead += 1
            guard let ts = row.int(0), let kind = row.string(1) else { continue }
            let pid = row.int(2) ?? 0, name = row.string(3) ?? ""
            if try store.scalarInt("SELECT 1 FROM storozh_anomalies WHERE ts=? AND kind=? AND name=? AND pid=?",
                                   [.int(ts), .text(kind), .text(name), .int(pid)]) != nil { continue }
            r.anomaliesAdded += try store.run("INSERT INTO storozh_anomalies(ts,kind,pid,name,detail,action,status) VALUES(?,?,?,?,?,?,?)",
                                              [.int(ts), .text(kind), .int(pid), .text(name), .text(row.string(4) ?? "{}"),
                                               row.string(5).map { .text($0) } ?? .null, .text(row.string(6) ?? "done")])
        }
    }

    // MARK: config.json

    struct LegacyConfig {
        var whitelist: [String]?
        var untouchable: [String]?
        var ignore: [String]?
        var mutedKinds: [String]?
        var thresholds: StorozhThresholds?
    }

    static func loadConfig(_ path: String) -> LegacyConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var c = LegacyConfig()
        c.whitelist = obj["whitelist"] as? [String]
        c.untouchable = obj["untouchable"] as? [String]
        c.ignore = obj["ignore"] as? [String]
        c.mutedKinds = obj["mutedKinds"] as? [String]
        if let t = obj["thresholds"], let d = try? JSONSerialization.data(withJSONObject: t) { c.thresholds = try? JSONDecoder().decode(StorozhThresholds.self, from: d) }
        return c
    }

    // An unseeded target takes the old lists as they are (the old file is the user's curated state); a seeded one gets the union.
    private static func copyConfig(_ c: LegacyConfig, _ store: Store, _ r: inout StorozhMigrationReport) throws {
        let repo = StorozhRepository(store: store)
        if try !repo.isSeeded() { try repo.markSeeded() }
        for (list, entries) in [(StorozhList.whitelist, c.whitelist), (.untouchable, c.untouchable), (.ignore, c.ignore)] {
            guard let entries else { continue }
            for e in entries where try repo.addEntry(e, to: list) { r.listEntriesAdded += 1 }
        }
        if let t = c.thresholds, try repo.getSetting("thresholds") == nil {
            try repo.setThresholds(t)
            r.thresholdsCopied = true
        }
        if let muted = c.mutedKinds {
            let before = try repo.settings().disabledKinds
            let after = before.union(muted)
            if after != before {
                try repo.setDisabled(after)
                r.disabledKindsAdded = after.count - before.count
            }
        }
    }
}

public enum StorozhMigrationCLI {
    public static let usage = "Использование: Multitul --migrate-storozh <старая storozh.db> [--config <config.json>] [--db <новая multitul.db>] [--dry-run]"

    public static func run(arguments: [String], out: (String) -> Void) -> Int32 {
        var old: String?
        var config: String?
        var db = MultitulPaths.dbPath
        var dry = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--dry-run": dry = true
            case "--db", "--config":
                let flag = arguments[i]
                i += 1
                guard i < arguments.count else { out(usage); return 64 }
                if flag == "--db" { db = arguments[i] } else { config = arguments[i] }
            default:
                guard old == nil, !arguments[i].hasPrefix("--") else { out(usage); return 64 }
                old = arguments[i]
            }
            i += 1
        }
        guard let old else { out(usage); return 64 }
        do {
            // dry run never creates or touches the target file
            let target = dry && !FileManager.default.fileExists(atPath: db) ? NSTemporaryDirectory() + "multitul-dry-\(UUID().uuidString)/multitul.db" : db
            defer { if target != db { try? FileManager.default.removeItem(atPath: (target as NSString).deletingLastPathComponent) } }
            let store = try Store(path: target, migrations: dry ? [] : StorozhSchema.allMigrations, retention: StorozhSchema.allRetention)
            let r = try StorozhLegacyMigrator.run(oldPath: old, configPath: config, into: store, dryRun: dry)
            out(dry ? "Пробный прогон, в базу ничего не записано:" : "Готово:")
            out("  процессы: прочитано \(r.procRead), добавлено \(r.procAdded)")
            out("  замеры системы: прочитано \(r.stateRead), добавлено \(r.stateAdded)")
            out("  энергия: прочитано \(r.powerRead), добавлено \(r.powerAdded)")
            out("  батарея: прочитано \(r.batteryRead), добавлено \(r.batteryAdded)")
            out("  аномалии: прочитано \(r.anomaliesRead), добавлено \(r.anomaliesAdded)")
            out(r.configFound ? "  config.json: в списки добавлено \(r.listEntriesAdded), пороги \(r.thresholdsCopied ? "скопированы" : "не менялись"), отключено детекторов +\(r.disabledKindsAdded)"
                              : "  config.json не найден, списки не тронуты")
            return 0
        } catch {
            out("Ошибка миграции: \(error)")
            return 1
        }
    }
}
