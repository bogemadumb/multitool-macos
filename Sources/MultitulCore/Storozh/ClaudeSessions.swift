import Foundation

public struct ClaudeSession: Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var name: String
    public var cpu: Double
    public var rssMb: Double
    public var uptime: TimeInterval?
    public var cwd: String?
    public var id: Int32 { pid }
}

// Read-only: Claude Code / Codex process trees, one row per tree root.
public enum ClaudeSessions {
    public static func roots(procs: [Int32: RawProc], pathOf: (Int32) -> String?) -> [Int32] {
        var matched: [Int32: RawProc] = [:]
        for (pid, p) in procs where isClaudeProcess(name: p.name, pid: pid, path: pathOf(pid), args: nil) { matched[pid] = p }
        return matched.filter { matched[$0.value.ppid] == nil }.map(\.key).sorted()
    }

    public static func live(store: Store? = nil) -> [ClaudeSession] {
        let procs = SystemParsers.ps(ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,time=,comm="]))
        var cpuByPid: [Int32: Double] = [:]
        if let store {
            for r in (try? store.query("SELECT pid, cpu FROM sys_proc WHERE ts = (SELECT MAX(ts) FROM sys_proc)")) ?? [] {
                if let p = r.int(0), let c = r.double(1) { cpuByPid[Int32(p)] = c }
            }
        }
        return roots(procs: procs, pathOf: pidPath).compactMap { pid in
            guard let p = procs[pid] else { return nil }
            let up = bsdInfo(pid).map { max(Date().timeIntervalSince($0), 0) }
            let rss = residentBytes(pid) ?? p.rssBytes
            return ClaudeSession(pid: pid, name: p.name, cpu: cpuByPid[pid] ?? 0, rssMb: Double(rss) / 1_048_576, uptime: up, cwd: cwdOf(pid))
        }
    }

    private static func bsdInfo(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    }

    private static func residentBytes(_ pid: Int32) -> Int64? {
        var t = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
        return n == Int32(MemoryLayout<proc_taskinfo>.size) ? Int64(t.pti_resident_size) : nil
    }

    private static func cwdOf(_ pid: Int32) -> String? {
        var v = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let s = withUnsafePointer(to: &v.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return s.isEmpty ? nil : s
    }
}
