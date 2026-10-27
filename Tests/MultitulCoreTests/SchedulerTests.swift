import Testing
import Foundation
@testable import MultitulCore

final class FakeClock: SchedulerClock {
    var now: TimeInterval = 1000
}

final class CountingCollector: Collector {
    let id: String
    let interval: TimeInterval
    var calls = 0
    var shouldFail = false
    var migrations: [Migration] = []
    var retention: [Retention] = []
    init(_ id: String, every: TimeInterval) { self.id = id; self.interval = every }
    func collect(store: Store) throws {
        calls += 1
        if shouldFail { throw StoreError(code: 1, message: "boom") }
    }
}

@Suite struct SchedulerTests {
    @Test func firstTickRunsEverythingThenRespectsIntervals() throws {
        let clock = FakeClock()
        let a = CountingCollector("a", every: 30)
        let b = CountingCollector("b", every: 100)
        let s = CollectorScheduler(store: try Store(path: tempDBPath()), collectors: [a, b], clock: clock)
        try s.start()
        #expect(s.tick() == ["a", "b"])
        clock.now += 29
        #expect(s.tick().isEmpty)
        clock.now += 1
        #expect(s.tick() == ["a"])
        clock.now += 30; s.tick()
        clock.now += 30; s.tick()
        #expect(a.calls == 4)
        clock.now += 10
        #expect(s.tick() == ["b"])
        #expect(b.calls == 2)
    }

    @Test func secondsUntilNextDueTracksClock() throws {
        let clock = FakeClock()
        let s = CollectorScheduler(store: try Store(path: tempDBPath()),
                                   collectors: [CountingCollector("a", every: 30), CountingCollector("b", every: 10)], clock: clock)
        try s.start()
        #expect(s.secondsUntilNextDue() == 0)
        s.tick()
        #expect(s.secondsUntilNextDue() == 10)
        clock.now += 4
        #expect(s.secondsUntilNextDue() == 6)
        clock.now += 100
        #expect(s.secondsUntilNextDue() == 0)
    }

    @Test func sleepGapDoesNotCauseCatchUpBurst() throws {
        let clock = FakeClock()
        let a = CountingCollector("a", every: 30)
        let s = CollectorScheduler(store: try Store(path: tempDBPath()), collectors: [a], clock: clock)
        try s.start()
        s.tick()
        clock.now += 3600
        #expect(s.tick() == ["a"])
        #expect(s.tick().isEmpty)
        #expect(a.calls == 2)
        clock.now += 30
        #expect(s.tick() == ["a"])
    }

    @Test func failingCollectorIsIsolatedAndCounted() throws {
        let clock = FakeClock()
        let bad = CountingCollector("bad", every: 10)
        bad.shouldFail = true
        let good = CountingCollector("good", every: 10)
        let s = CollectorScheduler(store: try Store(path: tempDBPath()), collectors: [bad, good], clock: clock)
        try s.start()
        #expect(s.tick() == ["bad", "good"])
        clock.now += 10
        s.tick()
        #expect(s.stats["bad"]?.failures == 2)
        #expect(s.stats["bad"]?.lastError != nil)
        #expect(s.stats["good"]?.failures == 0)
        #expect(good.calls == 2)
    }

    @Test func startAppliesCollectorMigrationsAndRetention() throws {
        let store = try Store(path: tempDBPath())
        let c = CountingCollector("m", every: 10)
        c.migrations = [Migration(scope: "m", version: 1, name: "x", sql: "CREATE TABLE mtab(ts INTEGER)")]
        c.retention = [Retention(table: "mtab", keepSeconds: 5)]
        try CollectorScheduler(store: store, collectors: [c], clock: FakeClock()).start()
        #expect(try store.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='mtab'") == 1)
        #expect(store.retentionRules.contains { $0.table == "mtab" })
    }

    @Test func registryRejectsDuplicatesAndBadIntervals() {
        let r = CollectorRegistry()
        #expect(r.register(CountingCollector("a", every: 1)))
        #expect(!r.register(CountingCollector("a", every: 1)))
        #expect(!r.register(CountingCollector("z", every: 0)))
        let std = CollectorRegistry.standard()
        #expect(std.collectors.map(\.id).contains("heartbeat"))
        #expect(std.collectors.first { $0.id == "heartbeat" }?.interval == 30)
    }

    @Test func heartbeatWritesRowEvery30sOfFakeTime() throws {
        let clock = FakeClock()
        let store = try Store(path: tempDBPath())
        var wall = Date(timeIntervalSince1970: 5000)
        let hb = HeartbeatCollector(pid: 42, now: { wall })
        let s = CollectorScheduler(store: store, collectors: [hb], clock: clock)
        try s.start()
        for _ in 0..<4 {
            s.tick()
            clock.now += 30
            wall += 30
        }
        #expect(try store.scalarInt("SELECT count(*) FROM heartbeat") == 4)
        #expect(try store.scalarInt("SELECT max(ts) FROM heartbeat") == 5090)
        #expect(try store.scalarInt("SELECT pid FROM heartbeat LIMIT 1") == 42)
    }
}

@Suite struct AgentHealthTests {
    private func store(withBeatAt ts: Int64?) throws -> Store {
        let s = try Store(path: tempDBPath())
        if let ts { try s.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)", [.int(ts), .int(77), "t"]) }
        return s
    }

    @Test func neverWhenEmpty() throws {
        let h = AgentHealth.check(store: try store(withBeatAt: nil))
        #expect(h.status == .never)
        #expect(!h.isHealthy)
    }

    @Test func aliveWithin2Minutes() throws {
        let h = AgentHealth.check(store: try store(withBeatAt: 1000), now: Date(timeIntervalSince1970: 1119))
        #expect(h.status == .alive)
        #expect(h.pid == 77)
        #expect(h.isHealthy)
    }

    @Test func silentAfter2Minutes() throws {
        let h = AgentHealth.check(store: try store(withBeatAt: 1000), now: Date(timeIntervalSince1970: 1121))
        #expect(h.status == .silent)
        #expect(h.summary.contains("молчит"))
    }

    @Test func usesLatestBeat() throws {
        let s = try store(withBeatAt: 100)
        try s.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)", [.int(1000), .int(5), "t"])
        let h = AgentHealth.check(store: s, now: Date(timeIntervalSince1970: 1010))
        #expect(h.status == .alive)
        #expect(h.pid == 5)
    }
}
