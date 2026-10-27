import Foundation
@testable import MultitulCore

final class MockOps: ProcOps, @unchecked Sendable {
    var procs: [Int32: ProcInfo] = [:]
    var children: [Int32: [ProcInfo]] = [:]
    var sent: [(sig: Int32, pid: Int32)] = []
    var opened: [String] = []
    var diesOnTerm = true
    var bundles: [String: String] = [:]

    func info(_ pid: Int32) -> ProcInfo? { procs[pid] }
    func descendants(of pid: Int32) -> [ProcInfo] { children[pid] ?? [] }
    func send(_ sig: Int32, to pid: Int32) -> Bool {
        sent.append((sig, pid))
        if sig == SIGKILL || (sig == SIGTERM && diesOnTerm) { procs[pid] = nil }
        return true
    }
    func sleep(_ sec: Double) {}
    func openBundle(_ id: String) -> Bool { opened.append(id); return true }
    func bundleId(atPath path: String) -> String? { bundles[path] }
}

func pinfo(_ pid: Int32, _ name: String, path: String? = nil, ppid: Int32 = 500, tty: Bool = false, args: String = "") -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, name: name, path: path ?? "/Users/x/bin/\(name)", hasTTY: tty, args: args)
}

let stzNow: Int64 = 1_800_000_000

func stzHogSeries(pid: Int32 = 500, name: String = "yes", cpu: Double = 99, count: Int = 11, step: Int64 = 30) -> [ProcPoint] {
    (0..<count).map { i in ProcPoint(ts: stzNow - Int64(count - 1 - i) * step, pid: pid, name: name, cpu: cpu, rss: 10_000_000) }
}

func stzIdleSys(idle: Double, count: Int = 11) -> [SysPoint] {
    (0..<count).map { i in
        SysPoint(ts: stzNow - Int64(count - 1 - i) * 30, pressure: 1, swapMb: 100, idleS: idle, battPct: 80, onAC: true)
    }
}

func stzInput(procs: [ProcPoint] = [], sys: [SysPoint] = [], power: [PowerRow] = [], anomalies: [AnomalyRow] = []) -> DetectorInput {
    DetectorInput(now: stzNow, procs: procs, sys: sys.isEmpty ? stzIdleSys(idle: 0) : sys, power: power, anomalies: anomalies)
}

func stzRun(_ i: DetectorInput, lists: StorozhLists = StorozhLists(), settings: StorozhSettings = StorozhSettings(),
            path: String? = "/Users/x/bin/tool") -> [AnomalyCandidate] {
    StorozhDetectors.detect(i, lists: lists, settings: settings, pathOf: { _ in path })
}

func stzAnomaly(kind: String, name: String, agoSec: Int64, id: Int64 = 1) -> AnomalyRow {
    AnomalyRow(id: id, ts: stzNow - agoSec, kind: kind, pid: 1, name: name, detail: "{}", action: nil, status: "open")
}

func stzStore() throws -> Store { try StorozhSchema.openStore(path: tempDBPath()) }

// Rows as SystemCollector writes them.
func stzInsertState(_ store: Store, ts: Int64, pressure: Int = 1, swap: Double = 100, idle: Double = 0, batt: Int? = 80, ac: Bool = true,
                    thermal: Int = 0, disk: Double = 100) throws {
    try store.run("INSERT INTO sys_state(ts,pressure,swap_mb,idle_s,batt_pct,on_ac,thermal,disk_free_gb) VALUES(?,?,?,?,?,?,?,?)",
                  [.int(ts), .int(Int64(pressure)), .real(swap), .real(idle), batt.map { .int(Int64($0)) } ?? .null, .int(ac ? 1 : 0), .int(Int64(thermal)), .real(disk)])
}

func stzInsertProc(_ store: Store, ts: Int64, pid: Int32, name: String, cpu: Double, rss: Int64 = 10_000_000) throws {
    try store.run("INSERT INTO sys_proc(ts,pid,ppid,name,cpu,rss) VALUES(?,?,?,?,?,?)",
                  [.int(ts), .int(Int64(pid)), .int(1), .text(name), .real(cpu), .int(rss)])
}
