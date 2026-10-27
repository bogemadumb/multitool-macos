import Testing
import Foundation
@testable import MultitulCore

@Suite struct StorozhMigrationTests {
    struct Fixture {
        let dir: String
        var db: String { dir + "/storozh.db" }
        var config: String { dir + "/config.json" }
    }

    // Old Storozh schema, as DB.swift created it.
    func makeOld(config: String? = nil) throws -> Fixture {
        let dir = NSTemporaryDirectory() + "stz-old-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = Fixture(dir: dir)
        let old = try Store(path: f.db, migrations: [], retention: [])
        try old.exec("""
            CREATE TABLE samples(ts INTEGER NOT NULL, pid INTEGER NOT NULL, ppid INTEGER, name TEXT, cpu REAL, rss INTEGER);
            CREATE TABLE system(ts INTEGER NOT NULL, pressure INTEGER, swap_mb REAL, idle_s REAL, batt_pct INTEGER, on_ac INTEGER,
                thermal INTEGER, disk_free_gb REAL, mem_wired_mb REAL, mem_compressed_mb REAL, mem_app_mb REAL, mem_free_mb REAL);
            CREATE TABLE anomalies(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT, pid INTEGER, name TEXT, detail TEXT, action TEXT, status TEXT, notified INTEGER DEFAULT 0);
            CREATE TABLE power(ts INTEGER NOT NULL, pid INTEGER, name TEXT, power REAL);
            CREATE TABLE battery_info(ts INTEGER NOT NULL, cycles INTEGER, health_pct REAL, time_remaining_min INTEGER);
            """)
        for t in 0..<4 {
            let ts = Int64(1_700_000_000 + t * 30)
            try old.run("INSERT INTO samples VALUES(?,?,?,?,?,?)", [.int(ts), .int(500), .int(1), .text("yes"), .real(95), .int(12_000_000)])
            try old.run("INSERT INTO samples VALUES(?,?,?,?,?,?)", [.int(ts), .int(501), .int(1), .text("node"), .real(3), .int(80_000_000)])
            try old.run("INSERT INTO system(ts,pressure,swap_mb,idle_s,batt_pct,on_ac,thermal,disk_free_gb,mem_wired_mb,mem_compressed_mb,mem_app_mb,mem_free_mb) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                          [.int(ts), .int(1), .real(512), .real(40), .int(80), .int(0), .int(0), .real(90), .real(2000), .real(100), .real(5000), .real(900)])
        }
        try old.run("INSERT INTO power VALUES(?,?,?,?)", [.int(1_700_000_000), .int(500), .text("yes"), .real(20)])
        try old.run("INSERT INTO battery_info VALUES(?,?,?,?)", [.int(1_700_000_000), .int(335), .real(82.6), .int(187)])
        try old.run("INSERT INTO anomalies(ts,kind,pid,name,detail,action,status) VALUES(?,?,?,?,?,?,?)",
                    [.int(1_700_000_100), .text("cpu_hog"), .int(500), .text("yes"), .text("{\"avg_cpu\":95.0}"), .text("notify"), .text("pending_user")])
        try old.run("INSERT INTO anomalies(ts,kind,pid,name,detail,action,status) VALUES(?,?,?,?,?,?,?)",
                    [.int(1_700_000_200), .text("swap"), .int(0), .text("system"), .text("{}"), .text("notify"), .text("pending_user")])
        if let config { try config.write(toFile: f.config, atomically: true, encoding: .utf8) }
        return f
    }

    static let configJson = """
    {"thresholds":{"swapMb":2000,"cooldownMin":10},"whitelist":["Telegram","Slack*"],"untouchable":["sing-box","my-daemon"],
     "ignore":["Spotify"],"mutedKinds":["thermal"],"notifyPausedUntil":9999999999,"analysisRoots":["Documents/x"]}
    """

    func counts(_ s: Store) throws -> [Int64] {
        try ["sys_proc", "sys_state", "sys_power", "sys_battery", "storozh_anomalies", "storozh_lists"].map {
            try s.scalarInt("SELECT count(*) FROM \($0)") ?? -1
        }
    }

    @Test func migratesHistoryAnomaliesAndConfig() throws {
        let f = try makeOld(config: Self.configJson)
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        let r = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        #expect(r.procRead == 8 && r.procAdded == 8)
        #expect(r.stateAdded == 4 && r.powerAdded == 1 && r.batteryAdded == 1 && r.anomaliesAdded == 2)
        #expect(r.configFound && r.thresholdsCopied)
        let st = try #require(try store.query("SELECT * FROM sys_state ORDER BY ts LIMIT 1").first)
        #expect(st.double("swap_mb") == 512 && st.int("batt_pct") == 80 && st.int("on_ac") == 0 && st.double("disk_free_gb") == 90)
        #expect(st.double("mem_app_mb") == 5000)
        #expect(st.double("cpu_total") == nil)
        let b = try #require(try store.query("SELECT * FROM sys_battery").first)
        #expect(b.int("cycles") == 335 && b.double("health_pct") == 82.6)
        let repo = StorozhRepository(store: store)
        let a = try repo.anomalies(since: 0)
        #expect(a.map(\.kind) == ["cpu_hog", "swap"])
        #expect(a[0].status == "pending_user" && a[0].action == "notify" && a[0].detail == "{\"avg_cpu\":95.0}")
        let l = try repo.lists()
        #expect(l.whitelist == ["Telegram", "Slack*"])
        #expect(l.untouchable == ["sing-box", "my-daemon"])
        #expect(l.ignore == ["Spotify"])
        let s = try repo.settings()
        #expect(s.thresholds.swapMb == 2000 && s.thresholds.cooldownMin == 10 && s.thresholds.diskLowGb == 10)
        #expect(s.disabledKinds == ["thermal"])
        #expect(s.pausedUntil == 0)
        #expect(try repo.isSeeded())
    }

    @Test func secondRunChangesNothing() throws {
        let f = try makeOld(config: Self.configJson)
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        _ = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        let first = try counts(store)
        let again = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        #expect(try counts(store) == first)
        #expect(again.procAdded == 0 && again.stateAdded == 0 && again.powerAdded == 0 && again.batteryAdded == 0 && again.anomaliesAdded == 0)
        #expect(again.listEntriesAdded == 0 && !again.thresholdsCopied && again.disabledKindsAdded == 0)
        #expect(again.procRead == 8)
    }

    @Test func timestampSplitAcrossChunksIsCopiedWhole() throws {
        let f = try makeOld()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        let r = try StorozhLegacyMigrator.run(oldPath: f.db, into: store, chunk: 3)
        #expect(r.procRead == 8 && r.procAdded == 8 && r.stateAdded == 4)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_proc") == 8)
        let again = try StorozhLegacyMigrator.run(oldPath: f.db, into: store, chunk: 3)
        #expect(again.procAdded == 0 && again.stateAdded == 0)
    }

    @Test func dryRunReportsButWritesNothing() throws {
        let f = try makeOld(config: Self.configJson)
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        let r = try StorozhLegacyMigrator.run(oldPath: f.db, into: store, dryRun: true)
        #expect(r.dryRun && r.procAdded == 8 && r.anomaliesAdded == 2 && r.listEntriesAdded > 0)
        #expect(try counts(store) == [0, 0, 0, 0, 0, 0])
        #expect(try StorozhRepository(store: store).isSeeded() == false)
        #expect(try StorozhRepository(store: store).settings() == StorozhSettings())
        let real = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        #expect(real.procAdded == 8 && real.listEntriesAdded == r.listEntriesAdded)
    }

    @Test func existingNewDataIsNotDuplicatedOrOverwritten() throws {
        let f = try makeOld()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        try stzInsertState(store, ts: 1_700_000_030, swap: 7)
        try stzInsertProc(store, ts: 1_700_000_030, pid: 999, name: "newer", cpu: 1)
        let r = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        #expect(r.stateAdded == 3 && r.procAdded == 6)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_state WHERE ts=1700000030") == 1)
        #expect(try store.query("SELECT swap_mb FROM sys_state WHERE ts=1700000030").first?.double(0) == 7)
        #expect(!r.configFound)
        #expect(try StorozhRepository(store: store).isSeeded() == false)
    }

    @Test func seededTargetGetsUnionNotReplacement() throws {
        let f = try makeOld(config: Self.configJson)
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let store = try stzStore()
        let repo = StorozhRepository(store: store)
        try repo.seedIfNeeded()
        try repo.removeEntry("node", from: .whitelist)
        _ = try StorozhLegacyMigrator.run(oldPath: f.db, into: store)
        let l = try repo.lists()
        #expect(Set(l.whitelist) == Set(StorozhLists.defaultWhitelist).subtracting(["node"]).union(["Slack*"]))
        #expect(l.untouchable.contains("my-daemon"))
    }

    @Test func sourceFileIsNotModifiedAndGarbageRejected() throws {
        let f = try makeOld(config: Self.configJson)
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let before = try Data(contentsOf: URL(fileURLWithPath: f.db))
        let cfgBefore = try Data(contentsOf: URL(fileURLWithPath: f.config))
        _ = try StorozhLegacyMigrator.run(oldPath: f.db, into: try stzStore())
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.db)) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.config)) == cfgBefore)

        let junk = NSTemporaryDirectory() + "stz-junk-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: junk) }
        let other = try Store(path: junk, migrations: [], retention: [])
        try other.exec("CREATE TABLE unrelated(x)")
        #expect(throws: StorozhMigrationError.self) { try StorozhLegacyMigrator.run(oldPath: junk, into: try stzStore()) }
        #expect(throws: StorozhMigrationError.self) { try StorozhLegacyMigrator.run(oldPath: "/nonexistent/storozh.db", into: try stzStore()) }
    }

    @Test func cliDryRunDoesNotCreateTargetAndRealRunIsRepeatable() throws {
        let f = try makeOld(config: Self.configJson)
        let target = NSTemporaryDirectory() + "stz-target-\(UUID().uuidString)/multitul.db"
        defer {
            try? FileManager.default.removeItem(atPath: f.dir)
            try? FileManager.default.removeItem(atPath: (target as NSString).deletingLastPathComponent)
        }
        var lines: [String] = []
        #expect(StorozhMigrationCLI.run(arguments: [f.db, "--db", target, "--dry-run"], out: { lines.append($0) }) == 0)
        #expect(lines.first?.contains("Пробный прогон") == true)
        #expect(!FileManager.default.fileExists(atPath: target))
        lines = []
        #expect(StorozhMigrationCLI.run(arguments: [f.db, "--db", target], out: { lines.append($0) }) == 0)
        #expect(lines.first == "Готово:")
        let store = try StorozhSchema.openStore(path: target)
        let first = try counts(store)
        #expect(first[0] == 8)
        #expect(StorozhMigrationCLI.run(arguments: [f.db, "--db", target], out: { _ in }) == 0)
        #expect(try counts(store) == first)
        #expect(StorozhMigrationCLI.run(arguments: [], out: { _ in }) == 64)
        #expect(StorozhMigrationCLI.run(arguments: [f.db, "--bogus"], out: { _ in }) == 64)
        #expect(StorozhMigrationCLI.run(arguments: ["/nonexistent.db", "--db", target], out: { _ in }) == 1)
    }
}
