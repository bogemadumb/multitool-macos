import Testing
import Foundation
@testable import MultitulCore

final class FixtureSource: SystemSource {
    var ps = SysFixtures.ps
    var pages: VMPages? = SystemParsers.vmStat(SysFixtures.vmStat)
    var pmset = SysFixtures.pmsetBattery
    var top = SysFixtures.topPower
    var ticks = CPUTicks(user: 0, system: 0, idle: 0)
    var topCalls = 0
    var temps = TemperatureReading(cpu: 55, gpu: 48, battery: 31)

    func psText() -> String { ps }
    func vmPages() -> VMPages? { pages }
    func swapUsedMB() -> Double? { 512 }
    func pressureLevel() -> Int? { 2 }
    func idleSeconds() -> Double? { 3.5 }
    func pmsetText() -> String { pmset }
    func topPowerText() -> String { topCalls += 1; return top }
    func batteryRegistry() -> [String: Any]? { RegistryParsersTests.smart }
    func thermalState() -> Int { 1 }
    func diskFreeGB() -> Double? { 123.4 }
    func cpuTicks() -> CPUTicks? { ticks }
    func temperatures() -> TemperatureReading { temps }
    func totalMemoryBytes() -> UInt64 { 16 * 1024 * 1024 * 1024 }
}

@Suite struct SystemCollectorTests {
    func make(_ src: FixtureSource, clock: Clock) throws -> (SystemCollector, Store) {
        let c = SystemCollector(source: src, now: { Date(timeIntervalSince1970: 1_000_000 + clock.t) }, uptime: { clock.t })
        let store = try Store(path: tempDBPath(), migrations: Store.coreMigrations + c.migrations, retention: Store.coreRetention + c.retention)
        return (c, store)
    }

    final class Clock { var t: Double = 100 }

    @Test func migrationsAndRetentionRegistered() throws {
        let src = FixtureSource()
        let (c, store) = try make(src, clock: Clock())
        #expect(try store.appliedMigrations().contains { $0.scope == "system" && $0.version == 1 })
        #expect(c.retention.count == 4)
        #expect(c.retention.allSatisfy { $0.keepSeconds == 7 * 86400 })
        #expect(c.interval == 30)
    }

    @Test func firstTickWritesStateWithoutProcessesAndEnergy() throws {
        let src = FixtureSource()
        let (c, store) = try make(src, clock: Clock())
        try c.collect(store: store)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_proc") == 0)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_state") == 1)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_power") == 3)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_battery") == 1)
        let r = try #require(try store.query("SELECT * FROM sys_state").first)
        #expect(r.int("pressure") == 2)
        #expect(r.double("swap_mb") == 512)
        #expect(r.int("batt_pct") == 87)
        #expect(r.int("on_ac") == 0)
        #expect(r.double("disk_free_gb") == 123.4)
        #expect(r.double("temp_cpu") == 55)
        #expect(r.double("cpu_total") == nil)
        let c0 = try #require(r.double("mem_app_mb"))
        #expect(abs(c0 - Double((150000 - 3000) * 16384) / 1_048_576) < 0.01)
    }

    @Test func secondTickComputesCpuAndProcessDeltas() throws {
        let src = FixtureSource()
        let clock = Clock()
        let (c, store) = try make(src, clock: clock)
        try c.collect(store: store)
        clock.t += 30
        src.ticks = CPUTicks(user: 150, system: 50, idle: 800)
        src.ps = SysFixtures.ps.replacingOccurrences(of: "1:02:03.45", with: "1:02:33.45")
        try c.collect(store: store)
        let cpuRow = try #require(try store.query("SELECT cpu_total FROM sys_state ORDER BY ts DESC LIMIT 1").first)
        #expect(cpuRow.double(0) == 20.0)
        let chrome = try #require(try store.query("SELECT cpu, rss, name FROM sys_proc WHERE pid=523").first)
        #expect(chrome.double(0) == 100.0)
        #expect(chrome.string(2) == "Google Chrome")
        #expect(try store.scalarInt("SELECT count(*) FROM sys_proc") == 3)
        #expect(src.topCalls == 1)
    }

    @Test func energyRunsEveryFiveMinutes() throws {
        let src = FixtureSource()
        let clock = Clock()
        let (c, store) = try make(src, clock: clock)
        try c.collect(store: store)
        clock.t += 30; try c.collect(store: store)
        clock.t += 200; try c.collect(store: store)
        #expect(src.topCalls == 1)
        clock.t += 100; try c.collect(store: store)
        #expect(src.topCalls == 2)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_battery") == 2)
    }

    @Test func retentionPrunesOldRows() throws {
        let src = FixtureSource()
        let clock = Clock()
        let (c, store) = try make(src, clock: clock)
        try c.collect(store: store)
        let now = Date(timeIntervalSince1970: 1_000_000 + clock.t + 8 * 86400)
        let deleted = try store.cleanup(now: now)
        #expect(deleted["sys_state"] == 1)
        #expect(try store.scalarInt("SELECT count(*) FROM sys_state") == 0)
    }

    @Test func registryIncludesSystemCollector() {
        #expect(CollectorRegistry.standard().collectors.contains { $0.id == "system" })
    }

    @Test func historyQueries() throws {
        let src = FixtureSource()
        let clock = Clock()
        let (c, store) = try make(src, clock: clock)
        try c.collect(store: store)
        for i in 1...3 {
            clock.t += 30
            src.ticks = CPUTicks(user: UInt32(100 * i), system: 0, idle: UInt32(100 * i))
            try c.collect(store: store)
        }
        let now = Date(timeIntervalSince1970: 1_000_000 + clock.t)
        let pts = SystemHistory.series(store, range: 3600, now: now, totalMemoryMB: 16384)
        #expect(pts.count == 4)
        #expect(pts.last?.cpuTotal == 50.0)
        #expect(pts.last?.memUsedPct != nil)
        let ph = SystemHistory.processHistory(store, name: "Google Chrome", range: 3600, now: now)
        #expect(ph.count == 3)
        let top = SystemHistory.topProcesses(store, range: 3600, limit: 2, now: now)
        #expect(top.count == 2)
        #expect(SystemHistory.topEnergy(store).first?.name == "Google Chrome H")
        let b = try #require(SystemHistory.battery(store, now: now))
        #expect(b.cycles == 312 && b.healthPct == 90.0)
        let m = try #require(SystemHistory.memory(store, totalMB: 16384))
        #expect(m.usedPct > 0 && m.wired > 0)
        #expect(SystemHistory.series(store, range: 10, now: now.addingTimeInterval(86400)).isEmpty)
    }

    @Test func downsampleLimitsPoints() {
        let pts = (0..<500).map { SystemPoint(ts: Int64($0), cpuTotal: Double($0 % 10), memUsedPct: nil, swapMb: nil, battPct: nil, onAC: nil,
                                              thermal: nil, diskFreeGb: nil, pressure: nil, tempCPU: Double($0), tempGPU: nil) }
        let d = SystemHistory.downsample(pts)
        #expect(d.count == 120)
        #expect(d.last?.tempCPU == 499)
    }
}

@Suite struct PidLockTests {
    func tmp() -> String { NSTemporaryDirectory() + "multitul-lock-\(UUID().uuidString)/agent.lock" }

    @Test func secondAcquireFailsUntilRelease() throws {
        let path = tmp()
        let a = try #require(PidLock.acquire(path: path))
        #expect(PidLock.acquire(path: path) == nil)
        #expect(PidLock.holderPID(path: path) == getpid())
        a.release()
        let b = PidLock.acquire(path: path)
        #expect(b != nil)
        b?.release()
    }

    @Test func lockReleasedOnDeinit() {
        let path = tmp()
        do { _ = PidLock.acquire(path: path) }
        let again = PidLock.acquire(path: path)
        #expect(again != nil)
    }

    @Test func differentPathsDoNotCollide() {
        let a = PidLock.acquire(path: tmp())
        let b = PidLock.acquire(path: tmp())
        #expect(a != nil && b != nil)
    }
}

@Suite struct AgentHealthLiveTests {
    @Test func neverWhenNoDatabase() {
        #expect(AgentHealth.checkLive(path: NSTemporaryDirectory() + "nope-\(UUID().uuidString)/x.db").status == .never)
    }

    @Test func aliveAndSilentFromHeartbeat() throws {
        let path = tempDBPath()
        let s = try Store(path: path)
        let now = Date()
        try s.run("INSERT INTO heartbeat(ts,pid,version) VALUES(?,?,?)", [.int(Int64(now.timeIntervalSince1970) - 10), .int(77), "t"])
        let h = AgentHealth.checkLive(path: path, now: now)
        #expect(h.status == .alive && h.pid == 77)
        let late = AgentHealth.checkLive(path: path, now: now.addingTimeInterval(600))
        #expect(late.status == .silent)
        #expect(late.summary.contains("молчит"))
    }
}
