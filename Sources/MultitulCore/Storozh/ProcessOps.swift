import Foundation
import MultitulCtlCore

public struct ProcInfo: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String?
    public var hasTTY: Bool
    public var args: String
    public var zombie = false
    public var uid: UInt32 = 0

    public init(pid: Int32, ppid: Int32, name: String, path: String? = nil, hasTTY: Bool = false, args: String = "", zombie: Bool = false, uid: UInt32 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.hasTTY = hasTTY
        self.args = args
        self.zombie = zombie
        self.uid = uid
    }
}

public protocol ProcOps {
    func info(_ pid: Int32) -> ProcInfo?
    func descendants(of pid: Int32) -> [ProcInfo]
    func send(_ sig: Int32, to pid: Int32) -> Bool
    func sleep(_ sec: Double)
    func openBundle(_ id: String) -> Bool
    func bundleId(atPath path: String) -> String?
}

public enum ProcParsers {
    // `ps -o stat=,ppid=,tty=,uid=,comm=` for one pid
    public static func info(pid: Int32, psLine: String, args: String, pathOf: (Int32) -> String? = pidPath) -> ProcInfo? {
        let f = psLine.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard f.count == 5, let ppid = Int32(f[1]), let uid = UInt32(f[3]) else { return nil }
        let comm = f[4].trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcInfo(pid: pid, ppid: ppid, name: SystemParsers.baseName(comm), path: pathOf(pid) ?? comm,
                        hasTTY: f[2] != "??" && f[2] != "?", args: args.trimmingCharacters(in: .whitespacesAndNewlines),
                        zombie: f[0].hasPrefix("Z"), uid: uid)
    }

    // `ps -axo pid=,ppid=,comm=` -> parent -> children map
    public static func descendants(of root: Int32, psText: String, pathOf: (Int32) -> String? = pidPath) -> [ProcInfo] {
        var kids: [Int32: [(Int32, String)]] = [:]
        for line in psText.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let p = Int32(f[0]), let pp = Int32(f[1]) else { continue }
            kids[pp, default: []].append((p, String(f[2])))
        }
        var out: [ProcInfo] = []
        var queue = [root]
        var seen = Set<Int32>([root])
        while let cur = queue.popLast() {
            for (p, comm) in kids[cur] ?? [] where seen.insert(p).inserted {
                out.append(ProcInfo(pid: p, ppid: cur, name: SystemParsers.baseName(comm), path: pathOf(p) ?? comm, hasTTY: false))
                queue.append(p)
            }
        }
        return out
    }
}

public struct SystemProcOps: ProcOps {
    private let privilegedKill: ((Int32, Int32) -> Bool)?
    private let killer: (Int32, Int32) -> Int32

    // `privilegedKill` is used only when a plain kill() fails with EPERM (root-owned process). `killer` returns 0 or errno.
    public init(privilegedKill: ((Int32, Int32) -> Bool)? = nil,
                killer: @escaping (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) == 0 ? 0 : errno }) {
        self.privilegedKill = privilegedKill
        self.killer = killer
    }

    public static func privileged(_ ctl: PrivilegedCtl) -> (Int32, Int32) -> Bool {
        { pid, sig in (try? ctl.kill(pid: pid, signal: sig)) != nil }
    }

    public func info(_ pid: Int32) -> ProcInfo? {
        let line = ToolRunner.run("/bin/ps", ["-o", "stat=,ppid=,tty=,uid=,comm=", "-p", String(pid)])
        let args = ToolRunner.run("/bin/ps", ["-ww", "-o", "args=", "-p", String(pid)])
        return ProcParsers.info(pid: pid, psLine: line, args: args)
    }

    public func descendants(of pid: Int32) -> [ProcInfo] {
        ProcParsers.descendants(of: pid, psText: ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]))
    }

    public func send(_ sig: Int32, to pid: Int32) -> Bool {
        let e = killer(pid, sig)
        if e == 0 { return true }
        if e == EPERM, let privilegedKill { return privilegedKill(pid, sig) }
        return false
    }

    public func sleep(_ sec: Double) { Thread.sleep(forTimeInterval: sec) }

    public func openBundle(_ id: String) -> Bool {
        let r = SystemProcessRunner().run("/usr/bin/open", ["-b", id], timeout: 15)
        return r.status == 0
    }

    public func bundleId(atPath path: String) -> String? { Bundle(path: path)?.bundleIdentifier }
}

public func launchdListedPids() -> Set<Int32> {
    var out = Set<Int32>()
    for line in ToolRunner.run("/bin/launchctl", ["list"]).split(separator: "\n") {
        if let first = line.split(separator: "\t").first, let p = Int32(first) { out.insert(p) }
    }
    return out
}
