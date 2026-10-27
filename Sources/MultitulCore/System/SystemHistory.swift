import Foundation

public struct SystemPoint: Equatable, Sendable {
    public var ts: Int64
    public var cpuTotal: Double?
    public var memUsedPct: Double?
    public var swapMb: Double?
    public var battPct: Int?
    public var onAC: Bool?
    public var thermal: Int?
    public var diskFreeGb: Double?
    public var pressure: Int?
    public var tempCPU: Double?
    public var tempGPU: Double?
}

public struct ProcHistPoint: Equatable, Sendable {
    public var ts: Int64
    public var cpu: Double
    public var rssMb: Double
}

public struct ProcAverage: Equatable, Identifiable, Sendable {
    public var name: String
    public var avgCpu: Double
    public var maxRssMb: Double
    public var id: String { name }
}

public struct BatteryHistoryInfo: Equatable, Sendable {
    public var cycles: Int
    public var healthPct: Double?
    public var timeRemainingMin: Int?
    public var drainPctPerHour: Double?
}

public struct MemBreakdownMB: Equatable, Sendable {
    public var wired = 0.0
    public var compressed = 0.0
    public var app = 0.0
    public var cached = 0.0
    public var free = 0.0
    public var total = 0.0
    public var usedPct: Double { total > 0 ? min((wired + compressed + app) / total * 100, 100) : 0 }
}

public enum SystemHistory {
    public static let maxPoints = 120

    public static func downsample(_ pts: [SystemPoint], maxPoints: Int = maxPoints) -> [SystemPoint] {
        Downsample.bucketRanges(count: pts.count, maxPoints: maxPoints).map { r in
            let b = Array(pts[r])
            var o = b.last!
            o.cpuTotal = Downsample.mean(b.compactMap(\.cpuTotal))
            o.memUsedPct = Downsample.mean(b.compactMap(\.memUsedPct))
            o.swapMb = Downsample.mean(b.compactMap(\.swapMb))
            o.diskFreeGb = Downsample.mean(b.compactMap(\.diskFreeGb))
            o.tempCPU = b.compactMap(\.tempCPU).max()
            o.tempGPU = b.compactMap(\.tempGPU).max()
            o.thermal = b.compactMap(\.thermal).max()
            o.pressure = b.compactMap(\.pressure).max()
            return o
        }
    }

    public static func downsample(_ pts: [ProcHistPoint], maxPoints: Int = maxPoints) -> [ProcHistPoint] {
        Downsample.bucketRanges(count: pts.count, maxPoints: maxPoints).map { r in
            let b = Array(pts[r])
            return ProcHistPoint(ts: b.last!.ts, cpu: Downsample.mean(b.map(\.cpu)) ?? 0, rssMb: Downsample.mean(b.map(\.rssMb)) ?? 0)
        }
    }

    public static func series(_ store: Store, range: TimeInterval, now: Date = Date(),
                              totalMemoryMB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576) -> [SystemPoint] {
        let from = Int64(now.timeIntervalSince1970 - range)
        let rows = (try? store.query("""
            SELECT ts,cpu_total,pressure,swap_mb,batt_pct,on_ac,thermal,disk_free_gb,mem_wired_mb,mem_compressed_mb,mem_app_mb,temp_cpu,temp_gpu
            FROM sys_state WHERE ts >= ? ORDER BY ts
            """, [.int(from)])) ?? []
        let pts = rows.compactMap { r -> SystemPoint? in
            guard let ts = r.int(0) else { return nil }
            var used: Double?
            if let w = r.double(8), let c = r.double(9), let a = r.double(10), totalMemoryMB > 0 {
                used = ((min((w + c + a) / totalMemoryMB * 100, 100)) * 10).rounded() / 10
            }
            return SystemPoint(ts: ts, cpuTotal: r.double(1), memUsedPct: used, swapMb: r.double(3), battPct: r.int(4).map { Int($0) },
                               onAC: r.int(5).map { $0 != 0 }, thermal: r.int(6).map { Int($0) }, diskFreeGb: r.double(7),
                               pressure: r.int(2).map { Int($0) }, tempCPU: r.double(11), tempGPU: r.double(12))
        }
        return downsample(pts)
    }

    public static func processHistory(_ store: Store, name: String, range: TimeInterval, now: Date = Date()) -> [ProcHistPoint] {
        let from = Int64(now.timeIntervalSince1970 - range)
        let rows = (try? store.query("SELECT ts, SUM(cpu), SUM(rss) FROM sys_proc WHERE name = ? AND ts >= ? GROUP BY ts ORDER BY ts",
                                     [.text(name), .int(from)])) ?? []
        return downsample(rows.compactMap { r -> ProcHistPoint? in
            guard let ts = r.int(0), let c = r.double(1), let rss = r.double(2) else { return nil }
            return ProcHistPoint(ts: ts, cpu: (c * 10).rounded() / 10, rssMb: rss / 1_048_576)
        })
    }

    public static func topProcesses(_ store: Store, range: TimeInterval, limit: Int = 10, now: Date = Date()) -> [ProcAverage] {
        let from = Int64(now.timeIntervalSince1970 - range)
        let rows = (try? store.query("""
            SELECT name, SUM(cpu) * 1.0 / MAX((SELECT COUNT(DISTINCT ts) FROM sys_proc WHERE ts >= ?), 1) AS avg_cpu, MAX(rss)
            FROM sys_proc WHERE ts >= ? AND name IS NOT NULL GROUP BY name ORDER BY avg_cpu DESC, name LIMIT ?
            """, [.int(from), .int(from), .int(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let n = r.string(0), let c = r.double(1) else { return nil }
            return ProcAverage(name: n, avgCpu: (c * 10).rounded() / 10, maxRssMb: (r.double(2) ?? 0) / 1_048_576)
        }
    }

    public static func topEnergy(_ store: Store) -> [PowerRow] {
        let rows = (try? store.query("SELECT pid, name, power FROM sys_power WHERE ts = (SELECT MAX(ts) FROM sys_power) ORDER BY power DESC")) ?? []
        return rows.compactMap { r in
            guard let n = r.string(1), let p = r.double(2) else { return nil }
            return PowerRow(pid: Int32(r.int(0) ?? 0), name: n, power: p)
        }
    }

    public static func battery(_ store: Store, now: Date = Date()) -> BatteryHistoryInfo? {
        guard let row = (try? store.query("SELECT cycles, health_pct, time_remaining_min FROM sys_battery ORDER BY ts DESC LIMIT 1"))?.first,
              let cycles = row.int(0) else { return nil }
        let from = Int64(now.timeIntervalSince1970) - 1800
        let pts = ((try? store.query("SELECT ts, batt_pct, on_ac FROM sys_state WHERE ts >= ? AND batt_pct IS NOT NULL AND on_ac IS NOT NULL ORDER BY ts",
                                     [.int(from)])) ?? []).compactMap { r -> (ts: Int64, pct: Int, onAC: Bool)? in
            guard let ts = r.int(0), let p = r.int(1), let ac = r.int(2) else { return nil }
            return (ts: ts, pct: Int(p), onAC: ac != 0)
        }
        return BatteryHistoryInfo(cycles: Int(cycles), healthPct: row.double(1), timeRemainingMin: row.int(2).map { Int($0) },
                                  drainPctPerHour: Downsample.drainRate(pts))
    }

    public static func memory(_ store: Store, totalMB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576) -> MemBreakdownMB? {
        guard let r = (try? store.query("""
            SELECT mem_wired_mb,mem_compressed_mb,mem_app_mb,mem_free_mb,mem_cached_mb FROM sys_state
            WHERE mem_wired_mb IS NOT NULL ORDER BY ts DESC LIMIT 1
            """))?.first, let w = r.double(0), let c = r.double(1), let a = r.double(2), let f = r.double(3) else { return nil }
        return MemBreakdownMB(wired: w, compressed: c, app: a, cached: r.double(4) ?? 0, free: f, total: totalMB)
    }

    public static func weeklyOffenders(_ store: Store, now: Date = Date(), limit: Int = 5) -> [ProcAverage] {
        topProcesses(store, range: 7 * 86400, limit: limit, now: now)
    }
}
