import Foundation
import AppKit
import MultitulCtlCore

public struct HeavyApp: Identifiable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var rssMb: Int
    public var id: Int32 { pid }
}

public struct IdleSession: Identifiable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var cwd: String?
    public var rssMb: Int
    public var idleMinutes: Int
    public var id: Int32 { pid }
}

public struct OrphanServer: Identifiable, Sendable, Equatable {
    public var info: ProcInfo
    public var rssKb: Int64
    public var id: Int32 { info.pid }
    public var rssMb: Int { Int(rssKb / 1024) }
}

public struct RamScan: Sendable {
    public var freeMb = 0
    public var heavy: [HeavyApp] = []
    public var sessions: [IdleSession] = []
    public var orphans: [OrphanServer] = []
}

public struct RamPlan: Sendable {
    public var orphans: [OrphanServer] = []
    public var sessions: [IdleSession] = []
    public var apps: [HeavyApp] = []
    public var purge = false
    public init(orphans: [OrphanServer] = [], sessions: [IdleSession] = [], apps: [HeavyApp] = [], purge: Bool = false) {
        self.orphans = orphans
        self.sessions = sessions
        self.apps = apps
        self.purge = purge
    }
}

public struct RamResult: Sendable, Equatable {
    public var killed = 0
    public var sessionsClosed = 0
    public var appsQuit = 0
    public var failed: [String] = []
    public var purge: String?
    public var freedMb = 0

    public var line: String {
        var parts = ["Освобождено ~\(max(freedMb, 0)) МБ"]
        if killed > 0 { parts.append("dev-серверов: \(killed)") }
        if sessionsClosed > 0 { parts.append("сессий Claude: \(sessionsClosed)") }
        if appsQuit > 0 { parts.append("приложений закрыто: \(appsQuit)") }
        if let p = purge { parts.append("purge: \(p)") }
        if !failed.isEmpty { parts.append("не вышло: \(failed.count)") }
        return parts.joined(separator: " · ")
    }
}

public enum RamClean {
    public static let heavyThresholdMb = 1024
    public static let idleWindowSec = 7200
    public static let idleMinSamples = 100

    public static func isIdleSample(_ cpu: [Double]) -> Bool {
        guard cpu.count >= idleMinSamples else { return false }
        let avg = cpu.reduce(0, +) / Double(cpu.count)
        return avg < 1.0 && (cpu.max() ?? 0) < 2.0
    }

    public static func treeRssKb(_ root: Int32, procs: [ProcInfo], rss: [Int32: Int64]) -> Int64 {
        var kids: [Int32: [Int32]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        var total: Int64 = 0
        var queue = [root]
        var seen: Set<Int32> = [root]
        while let c = queue.popLast() {
            total += rss[c] ?? 0
            for k in kids[c] ?? [] where seen.insert(k).inserted { queue.append(k) }
        }
        return total
    }

    public static func heavyBackgroundApps(procs: [ProcInfo], rss: [Int32: Int64], frontPids: Set<Int32>, lists: StorozhLists,
                                           apps: [(pid: Int32, name: String)], selfPid: Int32 = getpid(),
                                           thresholdMb: Int = heavyThresholdMb) -> [HeavyApp] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [HeavyApp] = []
        for a in apps where a.pid != selfPid && !frontPids.contains(a.pid) {
            guard let info = byPid[a.pid], !isUntouchable(info, lists) else { continue }
            if a.name == "Finder" || info.name == "Finder" { continue }
            let mb = Int(treeRssKb(a.pid, procs: procs, rss: rss) / 1024)
            if mb > thresholdMb { out.append(HeavyApp(pid: a.pid, name: a.name, rssMb: mb)) }
        }
        return out.sorted { $0.rssMb > $1.rssMb }
    }

    public static func orphanCandidates(_ procs: [ProcInfo], launchd: Set<Int32>, lists: StorozhLists, selfPid: Int32 = getpid()) -> [ProcInfo] {
        procs.filter { p in
            guard !p.zombie, p.pid != selfPid else { return false }
            guard isOrphanDevServer(ProcFacts(info: p, launchdPids: launchd)) else { return false }
            guard !isUntouchable(p, lists) else { return false }
            return !([p.name, p.path ?? "", p.args].joined(separator: " ").contains("dev.multitool."))
        }
    }

    // `ps -axww -o pid=,args=` and `ps -axo pid=,ppid=,tty=,stat=,rss=,comm=`
    public static func parseProcessList(argsText: String, statText: String, pathOf: (Int32) -> String? = pidPath) -> (procs: [ProcInfo], rssKb: [Int32: Int64]) {
        var args: [Int32: String] = [:]
        for line in argsText.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if f.count == 2, let pid = Int32(f[0]) { args[pid] = String(f[1]) }
        }
        var out: [ProcInfo] = []
        var rss: [Int32: Int64] = [:]
        for line in statText.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]), let kb = Int64(f[4]) else { continue }
            let comm = String(f[5])
            let name = comm.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? comm
            let noTty = f[2] == "??" || f[2] == "?"
            let path = (ppid == 1 && noTty) ? (pathOf(pid) ?? comm) : comm
            out.append(ProcInfo(pid: pid, ppid: ppid, name: name, path: path, hasTTY: !noTty, args: args[pid] ?? "", zombie: f[3].hasPrefix("Z")))
            rss[pid] = kb
        }
        return (out, rss)
    }

    public static func liveProcessList() -> (procs: [ProcInfo], rssKb: [Int32: Int64]) {
        parseProcessList(argsText: ToolRunner.run("/bin/ps", ["-axww", "-o", "pid=,args="]),
                         statText: ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,stat=,rss=,comm="]))
    }

    public static func parseFreeMemoryMb(vmStat text: String) -> Int {
        var page = 16384
        var pages = 0
        for line in text.split(separator: "\n") {
            if line.contains("page size of "), let r = line.range(of: #"\d+(?= bytes)"#, options: .regularExpression) {
                page = Int(line[r]) ?? page
            } else if line.hasPrefix("Pages free") || line.hasPrefix("Pages speculative") {
                let digits = line.split(separator: ":").last?.filter(\.isNumber) ?? ""
                pages += Int(digits) ?? 0
            }
        }
        return pages * page / 1_048_576
    }

    public static func liveFreeMemoryMb() -> Int { parseFreeMemoryMb(vmStat: ToolRunner.run("/usr/bin/vm_stat", [])) }

    // Sessions older than the idle window whose recorded CPU never rose: sys_proc is the only source of history.
    public static func idleSessions(sessions: [ClaudeSession], store: Store?, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [IdleSession] {
        guard let store else { return [] }
        var out: [IdleSession] = []
        for s in sessions {
            guard (s.uptime ?? 0) >= Double(idleWindowSec) else { continue }
            let rows = (try? store.query("SELECT cpu FROM sys_proc WHERE pid = ? AND ts >= ?", [.int(Int64(s.pid)), .int(now - Int64(idleWindowSec))])) ?? []
            guard isIdleSample(rows.compactMap { $0.double(0) }) else { continue }
            out.append(IdleSession(pid: s.pid, name: s.name, cwd: s.cwd, rssMb: Int(s.rssMb), idleMinutes: idleWindowSec / 60))
        }
        return out.sorted { $0.rssMb > $1.rssMb }
    }

    public static func scan(lists: StorozhLists, store: Store?, frontPids: Set<Int32>, apps: [(pid: Int32, name: String)],
                            ops: ProcOps = SystemProcOps()) -> RamScan {
        let (procs, rss) = liveProcessList()
        var scan = RamScan()
        scan.freeMb = liveFreeMemoryMb()
        scan.heavy = heavyBackgroundApps(procs: procs, rss: rss, frontPids: frontPids, lists: lists, apps: apps)
        scan.sessions = idleSessions(sessions: ClaudeSessions.live(store: store), store: store)
        scan.orphans = orphans(procs: procs, rss: rss, launchd: launchdListedPids(), lists: lists, ops: ops)
        return scan
    }

    public static func orphans(procs: [ProcInfo], rss: [Int32: Int64], launchd: Set<Int32>, lists: StorozhLists, ops: ProcOps) -> [OrphanServer] {
        orphanCandidates(procs, launchd: launchd, lists: lists)
            .filter { c in !ops.descendants(of: c.pid).contains { isUntouchable($0, lists) } }
            .map { OrphanServer(info: $0, rssKb: rss[$0.pid] ?? 0) }
            .sorted { $0.rssKb > $1.rssKb }
    }

    // Blocking: call off the main thread. Every stop goes through KillProcessService, which refuses untouchable processes.
    public static func perform(_ plan: RamPlan, service: KillProcessService,
                               freeMb: () -> Int = liveFreeMemoryMb,
                               quitApp: (Int32) -> Bool = { quitApplication(pid: $0) },
                               purge: () throws -> Void = { try PrivilegedCtl().purgeMemory() },
                               settle: Double = 1.5) -> RamResult {
        var res = RamResult()
        let before = freeMb()
        for o in plan.orphans {
            let out = service.terminate(pid: o.info.pid, name: o.info.name)
            if out.status == "done" { res.killed += 1 } else { res.failed.append("\(o.info.name) \(o.info.pid): \(out.note)") }
            Log.write("ram orphan \(o.info.name) pid=\(o.info.pid): \(out.status) \(out.note)")
        }
        for s in plan.sessions {
            let out = service.terminate(pid: s.pid, name: s.name, allowClaude: true)
            if out.status == "done" { res.sessionsClosed += 1 } else { res.failed.append("\(s.name) \(s.pid): \(out.note)") }
            Log.write("ram claude-session \(s.name) pid=\(s.pid): \(out.status) \(out.note)")
        }
        for a in plan.apps {
            if quitApp(a.pid) { res.appsQuit += 1 } else { res.failed.append("\(a.name) \(a.pid): не закрылось") }
            Log.write("ram app \(a.name) pid=\(a.pid)")
        }
        if plan.purge {
            do { try purge(); res.purge = "выполнен" } catch { res.purge = "пропущен: \(error)" }
        }
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        res.freedMb = freeMb() - before
        return res
    }

    // Graceful quit, up to 5 seconds. Blocking.
    public static func quitApplication(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.terminate() else { return false }
        for _ in 0..<20 {
            if app.isTerminated { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return app.isTerminated
    }
}
