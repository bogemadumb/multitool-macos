import Foundation

public enum SystemStoreSchema {
    public static let scope = "system"
    public static let migrations: [Migration] = [
        Migration(scope: scope, version: 1, name: "system_metrics", sql: """
            CREATE TABLE sys_proc(ts INTEGER NOT NULL, pid INTEGER NOT NULL, ppid INTEGER, name TEXT, cpu REAL, rss INTEGER);
            CREATE INDEX idx_sys_proc_ts ON sys_proc(ts);
            CREATE INDEX idx_sys_proc_name ON sys_proc(name, ts);
            CREATE TABLE sys_state(
                ts INTEGER NOT NULL, cpu_total REAL, pressure INTEGER, swap_mb REAL, idle_s REAL,
                batt_pct INTEGER, on_ac INTEGER, thermal INTEGER, disk_free_gb REAL,
                mem_wired_mb REAL, mem_compressed_mb REAL, mem_app_mb REAL, mem_free_mb REAL, mem_cached_mb REAL,
                temp_cpu REAL, temp_gpu REAL, temp_batt REAL);
            CREATE INDEX idx_sys_state_ts ON sys_state(ts);
            CREATE TABLE sys_power(ts INTEGER NOT NULL, pid INTEGER, name TEXT, power REAL);
            CREATE INDEX idx_sys_power_ts ON sys_power(ts);
            CREATE TABLE sys_battery(ts INTEGER NOT NULL, cycles INTEGER, health_pct REAL, time_remaining_min INTEGER);
            CREATE INDEX idx_sys_battery_ts ON sys_battery(ts);
            """)
    ]
    public static let retentionSeconds: TimeInterval = 7 * 86400
    public static let retention: [Retention] = ["sys_proc", "sys_state", "sys_power", "sys_battery"].map {
        Retention(table: $0, keepSeconds: retentionSeconds)
    }
}

private func real(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }
private func integer(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }

public final class SystemCollector: Collector {
    public let id = "system"
    public let interval: TimeInterval
    public let energyInterval: TimeInterval
    public var migrations: [Migration] { SystemStoreSchema.migrations }
    public var retention: [Retention] { SystemStoreSchema.retention }

    private let source: SystemSource
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var tracker = ProcessCPUTracker()
    private var prevTicks: CPUTicks?
    private var lastEnergyAt: TimeInterval?

    public init(source: SystemSource, interval: TimeInterval = 30, energyInterval: TimeInterval = 300,
                now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.interval = interval
        self.energyInterval = energyInterval
        self.now = now
        self.uptime = uptime
    }

    public static func live() -> SystemCollector { SystemCollector(source: LiveSystemSource()) }

    public func collect(store: Store) throws {
        let ts = Int64(now().timeIntervalSince1970)
        let up = uptime()
        let procs = SystemParsers.ps(source.psText())
        let rows = tracker.update(procs, at: up).map { ProcessCPUTracker.topSelection($0) }
        let state = readState()
        let energy = (lastEnergyAt.map { up - $0 >= energyInterval } ?? true)
        var power: [PowerRow] = []
        var battery: (cycles: Int, health: Double?, remaining: Int?)?
        if energy {
            lastEnergyAt = up
            power = SystemParsers.topPower(source.topPowerText())
            let reg = source.batteryRegistry()
            let b = RegistryParsers.compose(iops: [], smart: reg)
            if let c = b.cycles { battery = (c, b.healthPercent, SystemParsers.pmsetBatt(source.pmsetText()).timeRemainingMin) }
        }
        try store.transaction {
            if let rows {
                for r in rows {
                    try store.run("INSERT INTO sys_proc(ts,pid,ppid,name,cpu,rss) VALUES(?,?,?,?,?,?)",
                                  [.int(ts), .int(Int64(r.pid)), .int(Int64(r.ppid)), .text(r.name), .real(r.cpu), .int(r.rssBytes)])
                }
            }
            try store.run("""
                INSERT INTO sys_state(ts,cpu_total,pressure,swap_mb,idle_s,batt_pct,on_ac,thermal,disk_free_gb,
                    mem_wired_mb,mem_compressed_mb,mem_app_mb,mem_free_mb,mem_cached_mb,temp_cpu,temp_gpu,temp_batt)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.int(ts), real(state.cpuTotal), integer(state.pressure), real(state.swapMb), real(state.idleSec),
                      integer(state.battPct), integer(state.onAC.map { $0 ? 1 : 0 }), integer(state.thermal), real(state.diskFreeGb),
                      real(state.wiredMb), real(state.compressedMb), real(state.appMb), real(state.freeMb), real(state.cachedMb),
                      real(state.tempCPU), real(state.tempGPU), real(state.tempBatt)])
            for p in power {
                try store.run("INSERT INTO sys_power(ts,pid,name,power) VALUES(?,?,?,?)",
                              [.int(ts), .int(Int64(p.pid)), .text(p.name), .real(p.power)])
            }
            if let b = battery {
                try store.run("INSERT INTO sys_battery(ts,cycles,health_pct,time_remaining_min) VALUES(?,?,?,?)",
                              [.int(ts), .int(Int64(b.cycles)), real(b.health), integer(b.remaining)])
            }
        }
    }

    struct State {
        var cpuTotal: Double?
        var pressure: Int?
        var swapMb: Double?
        var idleSec: Double?
        var battPct: Int?
        var onAC: Bool?
        var thermal: Int?
        var diskFreeGb: Double?
        var wiredMb: Double?
        var compressedMb: Double?
        var appMb: Double?
        var freeMb: Double?
        var cachedMb: Double?
        var tempCPU: Double?
        var tempGPU: Double?
        var tempBatt: Double?
    }

    private func readState() -> State {
        var s = State()
        if let t = source.cpuTicks() {
            if let p = prevTicks { s.cpuTotal = (CPUMath.load(prev: p, cur: t).total * 1000).rounded() / 10 }
            prevTicks = t
        }
        s.pressure = source.pressureLevel()
        s.swapMb = source.swapUsedMB()
        s.idleSec = source.idleSeconds()
        s.thermal = source.thermalState()
        s.diskFreeGb = source.diskFreeGB()
        if let pages = source.vmPages() {
            let c = MemoryMath.compose(pages, totalBytes: source.totalMemoryBytes())
            let mb = 1_048_576.0
            s.wiredMb = Double(c.wiredBytes) / mb
            s.compressedMb = Double(c.compressedBytes) / mb
            s.appMb = Double(c.appBytes) / mb
            s.freeMb = Double(c.freeBytes) / mb
            s.cachedMb = Double(c.cachedBytes) / mb
        }
        let pm = SystemParsers.pmsetBatt(source.pmsetText())
        if pm.hasBattery { s.battPct = pm.percent }
        s.onAC = pm.onAC
        let t = source.temperatures()
        s.tempCPU = t.cpu
        s.tempGPU = t.gpu
        s.tempBatt = t.battery
        return s
    }
}
