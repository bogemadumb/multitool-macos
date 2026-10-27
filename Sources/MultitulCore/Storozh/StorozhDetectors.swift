import Foundation

public struct ProcPoint: Equatable, Sendable {
    public var ts: Int64
    public var pid: Int32
    public var name: String
    public var cpu: Double
    public var rss: Int64
    public init(ts: Int64, pid: Int32, name: String, cpu: Double, rss: Int64) {
        self.ts = ts
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.rss = rss
    }
}

public struct SysPoint: Equatable, Sendable {
    public var ts: Int64
    public var pressure: Int?
    public var swapMb: Double?
    public var idleS: Double?
    public var battPct: Int?
    public var onAC: Bool?
    public var thermal: Int?
    public var diskFreeGb: Double?
    public init(ts: Int64, pressure: Int? = nil, swapMb: Double? = nil, idleS: Double? = nil, battPct: Int? = nil,
                onAC: Bool? = nil, thermal: Int? = nil, diskFreeGb: Double? = nil) {
        self.ts = ts
        self.pressure = pressure
        self.swapMb = swapMb
        self.idleS = idleS
        self.battPct = battPct
        self.onAC = onAC
        self.thermal = thermal
        self.diskFreeGb = diskFreeGb
    }
}

public struct AnomalyCandidate {
    public var kind: String
    public var pid: Int32
    public var name: String
    public var detail: [String: Any]
}

public struct DetectorInput {
    public var now: Int64
    public var procs: [ProcPoint]
    public var sys: [SysPoint]
    public var power: [PowerRow]
    public var anomalies: [AnomalyRow]
    public init(now: Int64, procs: [ProcPoint], sys: [SysPoint], power: [PowerRow], anomalies: [AnomalyRow]) {
        self.now = now
        self.procs = procs
        self.sys = sys
        self.power = power
        self.anomalies = anomalies
    }
}

public enum StorozhDetectors {
    public static let sampleStepSec = 30

    private static func groupByPid(_ pts: [ProcPoint]) -> [Int32: [ProcPoint]] {
        var g: [Int32: [ProcPoint]] = [:]
        for p in pts { g[p.pid, default: []].append(p) }
        for k in g.keys { g[k]!.sort { $0.ts < $1.ts } }
        return g
    }

    public static func cpuHogs(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        guard let idle = input.sys.last?.idleS, idle >= Double(th.cpuHogIdleSec) else { return [] }
        let minSamples = max(1, th.cpuHogWindowSec / sampleStepSec - 1)
        let from = input.now - Int64(th.cpuHogWindowSec) - 5
        var out: [AnomalyCandidate] = []
        for (pid, all) in groupByPid(input.procs) {
            let pts = all.filter { $0.ts >= from && $0.ts <= input.now }
            guard pts.count >= minSamples, let last = pts.last, last.ts >= input.now - 5 else { continue }
            guard pts.allSatisfy({ $0.cpu > th.cpuHogPercent }) else { continue }
            let avg = pts.map(\.cpu).reduce(0, +) / Double(pts.count)
            out.append(AnomalyCandidate(kind: "cpu_hog", pid: pid, name: last.name, detail: [
                "avg_cpu": (avg * 10).rounded() / 10,
                "max_cpu": pts.map(\.cpu).max() ?? 0,
                "samples": pts.count,
                "window_s": th.cpuHogWindowSec,
                "idle_s": Int(idle),
                "rss_mb": Int(last.rss / 1_048_576),
            ]))
        }
        return out.sorted { ($0.detail["avg_cpu"] as? Double ?? 0) > ($1.detail["avg_cpu"] as? Double ?? 0) }
    }

    public static func memLeaks(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        let windowSec = Int64(th.memLeakWindowMin) * 60
        let from = input.now - windowSec - 5
        let growthMin = Int64(th.memLeakMb) * 1_048_576
        var out: [AnomalyCandidate] = []
        for (pid, all) in groupByPid(input.procs) {
            let pts = all.filter { $0.ts >= from && $0.ts <= input.now }
            guard pts.count >= 10, let first = pts.first, let last = pts.last,
                  last.ts >= input.now - 5, last.ts - first.ts >= windowSec / 2 else { continue }
            let growth = last.rss - first.rss
            guard growth > growthMin else { continue }
            var up = 0
            for i in 1..<pts.count where pts[i].rss >= pts[i - 1].rss { up += 1 }
            let share = Double(up) / Double(pts.count - 1)
            guard share >= th.memLeakUpShare else { continue }
            out.append(AnomalyCandidate(kind: "mem_leak", pid: pid, name: last.name, detail: [
                "growth_mb": Int(growth / 1_048_576),
                "rss_mb": Int(last.rss / 1_048_576),
                "up_share": (share * 100).rounded() / 100,
                "span_min": Int((last.ts - first.ts) / 60),
            ]))
        }
        return out.sorted { ($0.detail["growth_mb"] as? Int ?? 0) > ($1.detail["growth_mb"] as? Int ?? 0) }
    }

    public static func memPressure(_ input: DetectorInput) -> [AnomalyCandidate] {
        let tail = input.sys.suffix(2)
        guard tail.count == 2, let a = tail.first, let b = tail.last, b.ts - a.ts <= 120,
              let pa = a.pressure, let pb = b.pressure, pa >= 2, pb >= 2 else { return [] }
        return [AnomalyCandidate(kind: "mem_pressure", pid: 0, name: "system", detail: [
            "level": max(pa, pb),
            "level_name": max(pa, pb) >= 4 ? "critical" : "warn",
        ])]
    }

    public static func swap(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        guard let swap = input.sys.last?.swapMb, swap > Double(th.swapMb) else { return [] }
        return [AnomalyCandidate(kind: "swap", pid: 0, name: "system", detail: [
            "swap_mb": Int(swap),
            "limit_mb": th.swapMb,
        ])]
    }

    public static func batteryDrain(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        guard let cur = input.sys.last, cur.onAC == false,
              let idle = cur.idleS, idle >= Double(th.batteryIdleSec) else { return [] }
        let from = input.now - Int64(th.batteryIdleSec) - 15
        let win = input.sys.filter { $0.ts >= from }
        guard !win.isEmpty, win.allSatisfy({ $0.onAC == false && $0.battPct != nil }),
              let first = win.first, let last = win.last,
              let b0 = first.battPct, let b1 = last.battPct else { return [] }
        let span = Double(last.ts - first.ts)
        guard span >= Double(th.batteryIdleSec) - 30 else { return [] }
        let rate = Double(b0 - b1) / span * 3600
        guard rate > th.batteryDrainPerHour else { return [] }
        let top = input.power.max { $0.power < $1.power }
        return [AnomalyCandidate(kind: "battery_drain", pid: top?.pid ?? 0, name: top?.name ?? "unknown", detail: [
            "drain_pct_per_h": (rate * 10).rounded() / 10,
            "batt_pct": b1,
            "span_s": Int(span),
            "idle_s": Int(idle),
            "culprit_power": top?.power ?? 0,
        ])]
    }

    public static func diskLow(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        guard let free = input.sys.last?.diskFreeGb, free < th.diskLowGb else { return [] }
        return [AnomalyCandidate(kind: "disk_low", pid: 0, name: "system", detail: [
            "free_gb": (free * 10).rounded() / 10,
            "limit_gb": th.diskLowGb,
        ])]
    }

    public static func thermal(_ input: DetectorInput, _ th: StorozhThresholds) -> [AnomalyCandidate] {
        let from = input.now - Int64(th.thermalSec) - 15
        let win = input.sys.filter { $0.ts >= from }
        guard let first = win.first, let last = win.last, last.ts >= input.now - 5,
              win.allSatisfy({ ($0.thermal ?? 0) >= 2 }) else { return [] }
        let span = last.ts - first.ts
        guard span >= Int64(th.thermalSec) - 10 else { return [] }
        let level = win.compactMap(\.thermal).max() ?? 2
        return [AnomalyCandidate(kind: "thermal", pid: 0, name: "system", detail: [
            "level": level,
            "level_name": level >= 3 ? "critical" : "serious",
            "span_s": Int(span),
        ])]
    }

    public static func detect(_ input: DetectorInput, lists: StorozhLists, settings: StorozhSettings,
                              pathOf: (Int32) -> String?) -> [AnomalyCandidate] {
        let th = settings.thresholds
        var all: [AnomalyCandidate] = []
        func on(_ k: DetectorKind) -> Bool { settings.isEnabled(k.rawValue) }
        if on(.cpuHog) { all += cpuHogs(input, th) }
        if on(.memLeak) { all += memLeaks(input, th) }
        if on(.memPressure) { all += memPressure(input) }
        if on(.swap) { all += swap(input, th) }
        if on(.batteryDrain) { all += batteryDrain(input, th) }
        if on(.diskLow) { all += diskLow(input, th) }
        if on(.thermal) { all += thermal(input, th) }
        let untouchable = lists.effectiveUntouchable
        all = all.filter { c in
            guard DetectorKind(rawValue: c.kind)?.isPerProcess == true else { return true }
            let path = pathOf(c.pid)
            return !isListed(name: c.name, pid: c.pid, path: path, list: untouchable)
                && !isListed(name: c.name, pid: c.pid, path: path, list: lists.ignore)
        }
        let cooldownFrom = input.now - Int64(th.cooldownMin) * 60
        let repeatFrom = input.now - Int64(th.repeatWindowMin) * 60
        var seen = Set<String>()
        var out: [AnomalyCandidate] = []
        for var c in all {
            let key = c.kind + "|" + c.name
            if seen.contains(key) { continue }
            if input.anomalies.contains(where: { $0.kind == c.kind && $0.name == c.name && $0.ts > cooldownFrom }) { continue }
            seen.insert(key)
            if c.kind == "cpu_hog" {
                let prior = input.anomalies.filter { $0.kind == "cpu_hog" && $0.name == c.name && $0.ts > repeatFrom }.count
                c.detail["repeat"] = prior + 1 >= th.repeatCount
                c.detail["hogs_in_window"] = prior + 1
            }
            out.append(c)
        }
        return out
    }

    public static func loadInput(store: Store, now: Int64, settings: StorozhSettings) throws -> DetectorInput {
        let th = settings.thresholds
        let procWindow = Int64(max(th.cpuHogWindowSec, th.memLeakWindowMin * 60)) + 10
        let leakBytes = Int64(th.memLeakMb) * 1_048_576
        let procRows = try store.query("""
            SELECT ts,pid,name,cpu,rss FROM sys_proc
            WHERE ts >= ? AND pid IN (SELECT pid FROM sys_proc WHERE ts = ? AND (cpu > ? OR rss >= ?))
            ORDER BY ts
            """, [.int(now - procWindow), .int(now), .real(th.cpuHogPercent), .int(leakBytes)])
        let procs = procRows.compactMap { r -> ProcPoint? in
            guard let ts = r.int(0), let pid = r.int(1), let cpu = r.double(3), let rss = r.int(4) else { return nil }
            return ProcPoint(ts: ts, pid: Int32(pid), name: r.string(2) ?? "", cpu: cpu, rss: rss)
        }
        let sysRows = try store.query("""
            SELECT ts,pressure,swap_mb,idle_s,batt_pct,on_ac,thermal,disk_free_gb FROM sys_state WHERE ts >= ? AND ts <= ? ORDER BY ts
            """, [.int(now - Int64(max(1800, th.batteryIdleSec * 2))), .int(now)])
        let sys = sysRows.compactMap { r -> SysPoint? in
            guard let ts = r.int(0) else { return nil }
            return SysPoint(ts: ts, pressure: r.int(1).map { Int($0) }, swapMb: r.double(2), idleS: r.double(3),
                            battPct: r.int(4).map { Int($0) }, onAC: r.int(5).map { $0 != 0 },
                            thermal: r.int(6).map { Int($0) }, diskFreeGb: r.double(7))
        }
        let power = try store.query("SELECT pid,name,power FROM sys_power WHERE ts = (SELECT MAX(ts) FROM sys_power)").compactMap { r -> PowerRow? in
            guard let pid = r.int(0), let pw = r.double(2) else { return nil }
            return PowerRow(pid: Int32(pid), name: r.string(1) ?? "", power: pw)
        }
        let anomalyWindow = Int64(max(th.cooldownMin, th.repeatWindowMin)) * 60
        let anomalies = try StorozhRepository(store: store).anomalies(since: now - anomalyWindow)
        return DetectorInput(now: now, procs: procs, sys: sys, power: power, anomalies: anomalies)
    }
}
