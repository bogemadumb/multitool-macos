import Foundation

public struct CatalogProcess: Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var cpu: Double
    public var rssBytes: Int64
    public var name: String
    public var path: String
    public var id: Int32 { pid }

    public var bundlePath: String? { Self.outerBundle(path) }
    public var isRoot: Bool { uid == 0 }

    // Outermost .app: helpers nested inside another bundle belong to the main app.
    static func outerBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

public struct CatalogGroup: Equatable, Identifiable, Sendable {
    public var key: String
    public var title: String
    public var bundlePath: String?
    public var processes: [CatalogProcess]
    public var id: String { key }
    public var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    public var rssBytes: Int64 { processes.reduce(0) { $0 + $1.rssBytes } }
}

public enum ProcessCatalog {
    // `ps -axo pid=,ppid=,uid=,%cpu=,rss=,comm=`; comm is the last column and may contain spaces.
    public static func parse(_ text: String) -> [CatalogProcess] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]),
                  let cpu = Double(f[3]), let rss = Int64(f[4]) else { return nil }
            let path = f[5].trimmingCharacters(in: .whitespaces)
            return CatalogProcess(pid: pid, ppid: ppid, uid: uid, cpu: cpu, rssBytes: rss * 1024, name: SystemParsers.baseName(path), path: path)
        }
    }

    public static func live() -> [CatalogProcess] {
        parse(ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="]))
    }

    public static func group(_ procs: [CatalogProcess]) -> [CatalogGroup] {
        var groups: [String: CatalogGroup] = [:]
        for p in procs {
            let key: String, title: String
            if let b = p.bundlePath {
                key = b
                title = SystemParsers.baseName(b).replacingOccurrences(of: ".app", with: "")
            } else {
                key = "proc:" + p.name
                title = p.name
            }
            var g = groups[key] ?? CatalogGroup(key: key, title: title, bundlePath: p.bundlePath, processes: [])
            g.processes.append(p)
            groups[key] = g
        }
        return groups.values.map { var g = $0; g.processes.sort { $0.pid < $1.pid }; return g }
            .sorted { $0.rssBytes != $1.rssBytes ? $0.rssBytes > $1.rssBytes : $0.title < $1.title }
    }

    public static func search(_ groups: [CatalogGroup], query: String) -> [CatalogGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        let pidQuery = Int32(q)
        return groups.compactMap { g in
            if g.title.lowercased().contains(q) { return g }
            let hit = g.processes.filter { $0.name.lowercased().contains(q) || $0.pid == pidQuery }
            if hit.isEmpty { return nil }
            var copy = g
            copy.processes = hit
            return copy
        }
    }
}

// Kill Process actions with the same guard and signal sequence as the detectors. Blocking: call off the main thread.
public struct KillProcessService {
    private let ops: ProcOps
    private let lists: StorozhLists

    public init(ops: ProcOps, lists: StorozhLists = StorozhLists()) {
        self.ops = ops
        self.lists = lists
    }

    public static func live(lists: StorozhLists, privileged: PrivilegedCtl? = PrivilegedCtl()) -> KillProcessService {
        KillProcessService(ops: SystemProcOps(privilegedKill: privileged.map(SystemProcOps.privileged)), lists: lists)
    }

    public func forceQuit(_ p: CatalogProcess) -> ActionOutcome {
        ProcessTerminator.terminate(pid: p.pid, expectedName: p.name, relaunch: false, lists: lists, ops: ops)
    }

    public func restart(_ p: CatalogProcess) -> ActionOutcome {
        ProcessTerminator.terminate(pid: p.pid, expectedName: p.name, relaunch: true, lists: lists, ops: ops)
    }

    public func killTree(_ p: CatalogProcess) -> ActionOutcome {
        ProcessTerminator.killTree(pid: p.pid, expectedName: p.name, lists: lists, ops: ops)
    }

    // Whole app: trees of the group's top-level members (those whose parent is not in the group), each refused as a unit.
    public func quitGroup(_ g: CatalogGroup) -> [ActionOutcome] {
        let pids = Set(g.processes.map(\.pid))
        return g.processes.filter { !pids.contains($0.ppid) }.map(killTree)
    }

    // Single process by pid and expected name; allowClaude only for sessions the user explicitly chose to close.
    public func terminate(pid: Int32, name: String, allowClaude: Bool = false) -> ActionOutcome {
        ProcessTerminator.terminate(pid: pid, expectedName: name, relaunch: false, lists: lists, ops: ops, allowClaude: allowClaude)
    }

    public var untouchableLists: StorozhLists { lists }

    public func canTouch(_ p: CatalogProcess) -> Bool {
        let info = ProcInfo(pid: p.pid, ppid: p.ppid, name: p.name, path: p.path, uid: p.uid)
        return !isUntouchable(info, lists)
    }
}
