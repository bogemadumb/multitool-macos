import Testing
import Foundation
import CryptoKit
@testable import MultitulCore

private let oldSchema = """
CREATE TABLE samples(ts INTEGER NOT NULL, down_bps REAL, up_bps REAL, delay_ms INTEGER, state TEXT);
CREATE INDEX samples_ts ON samples(ts);
CREATE TABLE app_traffic(day TEXT NOT NULL, process TEXT NOT NULL, via TEXT NOT NULL,
  bytes_down INTEGER NOT NULL DEFAULT 0, bytes_up INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, process, via));
CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts_start INTEGER NOT NULL,
  ts_end INTEGER, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
CREATE INDEX events_ts ON events(ts_start);
"""

private func makeOld(samples: Int = 25, keepOpen: Bool = false) throws -> (path: String, keeper: Store) {
    let path = tempDBPath()
    let s = try Store(path: path, migrations: [], retention: [])
    try s.exec(oldSchema)
    let base: Int64 = 1_792_627_200
    try s.transaction {
        for i in 0..<samples {
            try s.run("INSERT INTO samples VALUES(?,?,?,?,?)",
                      [.int(base + Int64(i) * 10), .real(1000 + Double(i)), .real(100), i % 5 == 0 ? .null : .int(Int64(40 + i)), .text(i < 20 ? "ok" : "down")])
        }
        try s.run("INSERT INTO app_traffic VALUES('2026-10-22','Safari','vps',5000,500)")
        try s.run("INSERT INTO app_traffic VALUES('2026-10-22','Safari','direct',700,70)")
        try s.run("INSERT INTO app_traffic VALUES('2026-10-21','claude','vps',9000,900)")
        try s.run("INSERT INTO events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)", [.int(base), .int(base + 95), "server", "сервер недоступен"])
        try s.run("INSERT INTO events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)", [.int(base + 200), .null, "net", "смена сети"])
        try s.run("INSERT INTO events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)", [.int(base + 300), .int(base + 300), "speed", "14,2 МБ/с · 25 МБ за 1,8 с"])
    }
    return (path, s)
}

private func sha(_ path: String) -> String {
    let d = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

private func dump(_ s: Store) throws -> [String] {
    var out: [String] = []
    for r in try s.query("SELECT ts, down_bps, up_bps, IFNULL(delay_ms,-1), state FROM vpn_samples ORDER BY ts") {
        out.append("s|\(r.int(0)!)|\(r.double(1)!)|\(r.double(2)!)|\(r.int(3)!)|\(r.string(4)!)")
    }
    for r in try s.query("SELECT day_ts, process, via, bytes_down, bytes_up FROM vpn_app_traffic ORDER BY day_ts, process, via") {
        out.append("t|\(r.int(0)!)|\(r.string(1)!)|\(r.string(2)!)|\(r.int(3)!)|\(r.int(4)!)")
    }
    for r in try s.query("SELECT ts_start, IFNULL(ts_end,-1), kind, detail FROM vpn_events ORDER BY ts_start") {
        out.append("e|\(r.int(0)!)|\(r.int(1)!)|\(r.string(2)!)|\(r.string(3)!)")
    }
    return out
}

@Suite struct VpnMigrationTests {
    let cal = utcCalendar()

    @Test func copiesEverythingIntoTheNewSchema() throws {
        let (old, _) = try makeOld()
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        let r = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(r.samplesRead == 25 && r.samplesAdded == 25)
        #expect(r.trafficRead == 3 && r.trafficChanged == 3)
        #expect(r.eventsRead == 3 && r.eventsAdded == 3)
        let h = VpnHistoryStore(store: target, calendar: cal)
        #expect(h.sampleCount() == 25)
        let day = Date(timeIntervalSince1970: 1_792_627_200 + 3600)
        let rows = h.trafficRows(day: day, limit: 5)
        #expect(rows.map(\.process) == ["Safari"] && rows[0].vps == 5500 && rows[0].direct == 770)
        #expect(h.trafficRows(day: day.addingTimeInterval(-86400), limit: 5).first?.process == "claude")
        let ev = h.events(limit: 10)
        #expect(ev.count == 3 && ev.first { $0.kind == "net" }!.isOpen && ev.first { $0.kind == "server" }!.duration == 95)
        let nilPing = try target.query("SELECT count(*) FROM vpn_samples WHERE delay_ms IS NULL").first!.int(0)
        #expect(nilPing == 5)
        #expect(try target.query("SELECT state FROM vpn_samples WHERE ts = ?", [.int(1_792_627_200 + 240)]).first?.string(0) == "down")
    }

    @Test func secondRunChangesNothing() throws {
        let (old, _) = try makeOld()
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        _ = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        let before = try dump(target)
        let r2 = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(r2.samplesRead == 25 && r2.samplesAdded == 0 && r2.trafficChanged == 0 && r2.eventsAdded == 0)
        #expect(try dump(target) == before)
        #expect(before.count == 25 + 3 + 3)
    }

    @Test func rerunAfterNewDataKeepsNewerAndOnlyAddsMissing() throws {
        let (old, keeper) = try makeOld()
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        _ = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        let h = VpnHistoryStore(store: target, calendar: cal)
        try h.addTraffic(at: Date(timeIntervalSince1970: 1_792_627_200 + 100), [VpnTrafficDelta(process: "Safari", via: "vps", down: 1000, up: 0)])
        try keeper.run("UPDATE app_traffic SET bytes_down = 6500 WHERE process='Safari' AND via='vps'")
        try keeper.run("INSERT INTO app_traffic VALUES('2026-10-22','curl','direct',10,1)")
        try keeper.run("INSERT INTO samples VALUES(?,?,?,?,?)", [.int(1_792_627_200 + 5000), .real(1), .real(1), .int(30), .text("ok")])
        let r = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(r.samplesAdded == 1 && r.trafficChanged == 2 && r.eventsAdded == 0)
        let rows = h.trafficRows(day: Date(timeIntervalSince1970: 1_792_627_200 + 100), limit: 5)
        #expect(rows.first { $0.process == "Safari" }!.vps == 7000)
        #expect(rows.contains { $0.process == "curl" })
    }

    @Test func sourceFileIsNeverModified() throws {
        let path = tempDBPath()
        do {
            let s = try Store(path: path, migrations: [], retention: [])
            try s.exec(oldSchema)
            try s.run("INSERT INTO samples VALUES(1792627200, 1, 1, 10, 'ok')")
            _ = try s.query("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let before = sha(path)
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        _ = try VpnLegacyMigrator.run(oldPath: path, into: target, calendar: cal)
        #expect(sha(path) == before)
        #expect(!FileManager.default.fileExists(atPath: path + "-wal") || ((try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0) == 0)
    }

    @Test func readsRowsStillSittingInTheWal() throws {
        let (old, keeper) = try makeOld(samples: 7)
        #expect(FileManager.default.fileExists(atPath: old + "-wal"))
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        let r = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(r.samplesAdded == 7 && r.eventsAdded == 3)
        withExtendedLifetime(keeper) {}
    }

    @Test func dryRunReportsButWritesNothing() throws {
        let (old, _) = try makeOld()
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        let r = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal, dryRun: true)
        #expect(r.dryRun && r.samplesAdded == 25 && r.trafficChanged == 3 && r.eventsAdded == 3)
        #expect(try dump(target).isEmpty)
        let real = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(real.samplesAdded == 25 && !real.dryRun)
    }

    @Test func badInputsAreRejected() throws {
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        #expect(throws: VpnMigrationError.self) { try VpnLegacyMigrator.run(oldPath: "/nonexistent/history.sqlite", into: target) }
        let other = try Store(path: tempDBPath(), migrations: [], retention: [])
        try other.exec("CREATE TABLE unrelated(a)")
        #expect(throws: VpnMigrationError.self) { try VpnLegacyMigrator.run(oldPath: other.path, into: target) }
        #expect(try dump(target).isEmpty)
    }

    @Test func emptyTablesAreFine() throws {
        let s = try Store(path: tempDBPath(), migrations: [], retention: [])
        try s.exec(oldSchema)
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        let r = try VpnLegacyMigrator.run(oldPath: s.path, into: target, calendar: cal)
        #expect(r == VpnMigrationReport())
    }

    @Test func largeSourceIsCopiedInChunks() throws {
        let (old, keeper) = try makeOld(samples: 0)
        try keeper.transaction {
            for i in 0..<(VpnLegacyMigrator.chunk * 2 + 17) {
                try keeper.run("INSERT INTO samples VALUES(?,?,?,?,?)", [.int(1_700_000_000 + Int64(i)), .real(1), .real(1), .int(20), .text("ok")])
            }
        }
        let target = try VpnHistorySchema.openStore(path: tempDBPath())
        let r = try VpnLegacyMigrator.run(oldPath: old, into: target, calendar: cal)
        #expect(r.samplesRead == VpnLegacyMigrator.chunk * 2 + 17 && r.samplesAdded == r.samplesRead)
    }
}

@Suite struct VpnMigrationCLITests {
    @Test func usageOnBadArguments() {
        var lines: [String] = []
        #expect(VpnMigrationCLI.run(arguments: [], out: { lines.append($0) }) == 64)
        #expect(VpnMigrationCLI.run(arguments: ["a.db", "b.db"], out: { lines.append($0) }) == 64)
        #expect(VpnMigrationCLI.run(arguments: ["--db"], out: { lines.append($0) }) == 64)
        #expect(lines.allSatisfy { $0.hasPrefix("Использование") })
    }

    @Test func endToEndWithDbOptionAndDryRun() throws {
        let (old, _) = try makeOld()
        let newPath = tempDBPath()
        var out: [String] = []
        #expect(VpnMigrationCLI.run(arguments: [old, "--db", newPath, "--dry-run"], out: { out.append($0) }) == 0)
        #expect(out.first!.hasPrefix("Пробный прогон") && out.contains { $0.contains("добавлено 25") })
        #expect(try VpnHistorySchema.openStore(path: newPath).scalarInt("SELECT count(*) FROM vpn_samples") == 0)
        out = []
        #expect(VpnMigrationCLI.run(arguments: [old, "--db", newPath], out: { out.append($0) }) == 0)
        #expect(out.first == "Готово:")
        #expect(try VpnHistorySchema.openStore(path: newPath).scalarInt("SELECT count(*) FROM vpn_samples") == 25)
    }

    @Test func missingFileExitsWithError() {
        var out: [String] = []
        #expect(VpnMigrationCLI.run(arguments: ["/nonexistent.db", "--db", tempDBPath()], out: { out.append($0) }) == 1)
        #expect(out.first!.hasPrefix("Ошибка миграции"))
    }
}
