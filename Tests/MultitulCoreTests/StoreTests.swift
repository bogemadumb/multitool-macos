import Testing
import Foundation
@testable import MultitulCore

func tempDBPath() -> String {
    let dir = NSTemporaryDirectory() + "multitul-test-\(UUID().uuidString)"
    return dir + "/multitul.db"
}

@Suite struct StoreTests {
    @Test func opensInWalMode() throws {
        let s = try Store(path: tempDBPath())
        #expect(s.journalMode == "wal")
    }

    @Test func coreMigrationApplied() throws {
        let s = try Store(path: tempDBPath())
        let applied = try s.appliedMigrations()
        #expect(applied.contains { $0.scope == "core" && $0.version == 1 })
        #expect(try s.scalarInt("SELECT count(*) FROM heartbeat") == 0)
    }

    @Test func migrationsRunOnceAndInOrder() throws {
        let path = tempDBPath()
        let m1 = Migration(scope: "t", version: 1, name: "a", sql: "CREATE TABLE t1(x INTEGER)")
        let m2 = Migration(scope: "t", version: 2, name: "b", sql: "ALTER TABLE t1 ADD COLUMN y TEXT")
        do {
            let s = try Store(path: path, migrations: [m2, m1])
            try s.run("INSERT INTO t1(x,y) VALUES(?,?)", [1, "a"])
        }
        let s = try Store(path: path, migrations: [m1, m2])
        #expect(try s.scalarInt("SELECT count(*) FROM schema_migrations WHERE scope='t'") == 2)
        #expect(try s.scalarInt("SELECT count(*) FROM t1") == 1)
        let m3 = Migration(scope: "t", version: 3, name: "c", sql: "CREATE TABLE t3(z INTEGER)")
        try s.migrate([m1, m2, m3])
        #expect(try s.scalarInt("SELECT count(*) FROM schema_migrations WHERE scope='t'") == 3)
    }

    @Test func failedMigrationRollsBack() throws {
        let path = tempDBPath()
        let bad = Migration(scope: "t", version: 1, name: "bad", sql: "CREATE TABLE ok1(x INTEGER); CREATE TABLE ok1(x INTEGER)")
        #expect(throws: StoreError.self) { try Store(path: path, migrations: [bad]) }
        let s = try Store(path: path, migrations: [])
        #expect(try s.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='ok1'") == 0)
        #expect(try s.scalarInt("SELECT count(*) FROM schema_migrations") == 0)
    }

    @Test func duplicateMigrationVersionRejected() throws {
        let a = Migration(scope: "t", version: 1, name: "a", sql: "SELECT 1")
        #expect(throws: StoreError.self) { try Store(path: tempDBPath(), migrations: [a, a]) }
    }

    @Test func typedHelpers() throws {
        let s = try Store(path: tempDBPath(), migrations: [
            Migration(scope: "t", version: 1, name: "a", sql: "CREATE TABLE v(i INTEGER, r REAL, s TEXT, n TEXT)")
        ])
        try s.run("INSERT INTO v(i,r,s,n) VALUES(?,?,?,?)", [.int(7), .real(2.5), .text("привет"), .null])
        let row = try #require(try s.query("SELECT * FROM v").first)
        #expect(row.int("i") == 7)
        #expect(row.double("r") == 2.5)
        #expect(row.string("s") == "привет")
        #expect(row.string("n") == nil)
        #expect(s.lastInsertRowId == 1)
    }

    @Test func transactionRollsBackOnError() throws {
        let s = try Store(path: tempDBPath(), migrations: [
            Migration(scope: "t", version: 1, name: "a", sql: "CREATE TABLE v(i INTEGER)")
        ])
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try s.transaction {
                try s.run("INSERT INTO v(i) VALUES(1)")
                throw Boom()
            }
        }
        #expect(try s.scalarInt("SELECT count(*) FROM v") == 0)
    }

    @Test func retentionDeletesOnlyOldRowsPerTable() throws {
        let s = try Store(path: tempDBPath(), migrations: Store.coreMigrations + [
            Migration(scope: "t", version: 1, name: "a", sql: "CREATE TABLE fast(ts INTEGER); CREATE TABLE slow(at INTEGER); CREATE TABLE keep(ts INTEGER)")
        ])
        s.addRetention(Retention(table: "fast", keepSeconds: 100))
        s.addRetention(Retention(table: "slow", column: "at", keepSeconds: 1000))
        let now = Date(timeIntervalSince1970: 10_000)
        for ts in [8_000, 9_850, 9_950] { try s.run("INSERT INTO fast(ts) VALUES(?)", [.int(Int64(ts))]) }
        for ts in [8_000, 9_850] { try s.run("INSERT INTO slow(at) VALUES(?)", [.int(Int64(ts))]) }
        try s.run("INSERT INTO keep(ts) VALUES(1)")
        try s.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)", [.int(-700_000), .int(1), "x"])
        let deleted = try s.cleanup(now: now)
        #expect(deleted["fast"] == 2)
        #expect(deleted["slow"] == 1)
        #expect(deleted["heartbeat"] == 1)
        #expect(deleted["keep"] == nil)
        #expect(try s.scalarInt("SELECT count(*) FROM fast") == 1)
        #expect(try s.scalarInt("SELECT count(*) FROM slow") == 1)
        #expect(try s.scalarInt("SELECT count(*) FROM keep") == 1)
    }

    @Test func retentionRejectsBadIdentifiersAndSkipsMissingTables() throws {
        let s = try Store(path: tempDBPath())
        s.addRetention(Retention(table: "nope", keepSeconds: 1))
        #expect(try s.cleanup()["nope"] == nil)
        s.addRetention(Retention(table: "heartbeat; DROP TABLE heartbeat", keepSeconds: 1))
        #expect(throws: StoreError.self) { try s.cleanup() }
        #expect(try s.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='heartbeat'") == 1)
    }

    @Test func concurrentReadersWhileWriting() throws {
        let path = tempDBPath()
        let writer = try Store(path: path)
        let total = 400
        let failures = Counter()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let reader = try Store(path: path, readOnly: true)
                    var last: Int64 = 0
                    while last < Int64(total) {
                        let n = try reader.scalarInt("SELECT count(*) FROM heartbeat") ?? 0
                        if n < last { failures.add() }
                        last = n
                    }
                } catch { failures.add() }
            }
        }
        for i in 0..<total {
            try writer.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)", [.int(Int64(i)), .int(1), "t"])
        }
        group.wait()
        #expect(failures.value == 0)
        #expect(try writer.scalarInt("SELECT count(*) FROM heartbeat") == Int64(total))
    }

    @Test func multitulHomeOverridesPath() {
        setenv("MULTITUL_HOME", "/tmp/multitul-home-x", 1)
        defer { unsetenv("MULTITUL_HOME") }
        #expect(MultitulPaths.dbPath == "/tmp/multitul-home-x/multitul.db")
    }
}

final class Counter: @unchecked Sendable {
    private let l = NSLock()
    private var n = 0
    func add() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
}
