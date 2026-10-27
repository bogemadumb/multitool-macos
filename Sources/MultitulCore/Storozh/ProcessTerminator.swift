import Foundation

public struct ActionOutcome: Equatable, Sendable {
    public var action: String
    public var status: String
    public var note: String
    public init(action: String, status: String, note: String) {
        self.action = action
        self.status = status
        self.note = note
    }
}

public enum ProcessTerminator {
    // Leaves first, root last: [deepest ... root]. Children of one node keep ps order.
    public static func killOrder(root: Int32, descendants: [ProcInfo]) -> [Int32] {
        var kids: [Int32: [Int32]] = [:]
        for d in descendants { kids[d.ppid, default: []].append(d.pid) }
        var out: [Int32] = []
        var seen = Set<Int32>()
        func visit(_ pid: Int32) {
            guard seen.insert(pid).inserted else { return }
            for k in kids[pid] ?? [] { visit(k) }
            out.append(pid)
        }
        visit(root)
        return out
    }

    // SIGTERM -> wait up to termWait -> SIGKILL -> optional `open -b` for the main app bundle.
    public static func terminate(pid: Int32, expectedName: String, relaunch: Bool, lists: StorozhLists,
                                 ops: ProcOps, dry: Bool = false, termWait: Double = 5, allowClaude: Bool = false) -> ActionOutcome {
        let act = relaunch ? "restart" : "kill"
        func fail(_ note: String) -> ActionOutcome { ActionOutcome(action: act, status: "failed", note: note) }
        func blocked(_ p: ProcInfo) -> Bool {
            isUntouchable(p, lists) && !(allowClaude && isClaudeProcess(name: p.name, pid: p.pid, path: p.path, args: p.args))
        }
        guard let cur = ops.info(pid), !cur.zombie else { return fail("process gone") }
        guard cur.name == expectedName else { return fail("pid reused: now \(cur.name), expected \(expectedName)") }
        guard !blocked(cur) else { return fail("refused: untouchable \(cur.name)") }
        if let bad = ops.descendants(of: pid).first(where: blocked) {
            return fail("refused: untouchable child \(bad.name) pid=\(bad.pid)")
        }
        var bundleId: String?
        if relaunch, let p = cur.path, let b = mainBundlePath(ofExecutable: p) { bundleId = ops.bundleId(atPath: b) }
        if dry { return ActionOutcome(action: act, status: "dry_run", note: "would \(act) \(cur.name) pid=\(pid) bundle=\(bundleId ?? "none")") }

        guard ops.send(SIGTERM, to: pid) else { return fail("SIGTERM failed") }
        var waited = 0.0
        while waited < termWait, let p = ops.info(pid), !p.zombie, p.name == expectedName {
            ops.sleep(0.25)
            waited += 0.25
        }
        if let p = ops.info(pid), !p.zombie, p.name == expectedName {
            guard !blocked(p) else { return fail("refused before SIGKILL") }
            _ = ops.send(SIGKILL, to: pid)
            ops.sleep(1)
            if let p2 = ops.info(pid), !p2.zombie, p2.name == expectedName { return fail("still alive after SIGKILL") }
        }
        if relaunch, let id = bundleId {
            return ops.openBundle(id)
                ? ActionOutcome(action: act, status: "done", note: "restarted via open -b \(id)")
                : fail("killed, open -b \(id) failed")
        }
        return ActionOutcome(action: act, status: "done", note: relaunch ? "killed (no bundle to relaunch)" : "killed")
    }

    // The whole tree is refused if any member is untouchable. Leaves get SIGTERM first, then the root; survivors get SIGKILL in the same order.
    public static func killTree(pid: Int32, expectedName: String, lists: StorozhLists, ops: ProcOps,
                                dry: Bool = false, termWait: Double = 5) -> ActionOutcome {
        let act = "kill_tree"
        func fail(_ note: String) -> ActionOutcome { ActionOutcome(action: act, status: "failed", note: note) }
        guard let root = ops.info(pid), !root.zombie else { return fail("process gone") }
        guard root.name == expectedName else { return fail("pid reused: now \(root.name), expected \(expectedName)") }
        guard !isUntouchable(root, lists) else { return fail("refused: untouchable \(root.name)") }
        let kids = ops.descendants(of: pid)
        if let bad = kids.first(where: { isUntouchable($0, lists) }) { return fail("refused: untouchable child \(bad.name) pid=\(bad.pid)") }
        let order = killOrder(root: pid, descendants: kids)
        if dry { return ActionOutcome(action: act, status: "dry_run", note: "would kill \(order.count) processes: \(order.map(String.init).joined(separator: ","))") }

        var names: [Int32: String] = [pid: root.name]
        for k in kids { names[k.pid] = k.name }
        func alive(_ p: Int32) -> Bool {
            guard let i = ops.info(p), !i.zombie else { return false }
            return i.name == names[p]
        }
        for p in order where alive(p) { _ = ops.send(SIGTERM, to: p) }
        var waited = 0.0
        while waited < termWait, order.contains(where: alive) {
            ops.sleep(0.25)
            waited += 0.25
        }
        let left = order.filter(alive)
        for p in left { _ = ops.send(SIGKILL, to: p) }
        if !left.isEmpty { ops.sleep(1) }
        let stuck = order.filter(alive)
        if !stuck.isEmpty { return fail("still alive after SIGKILL: \(stuck.map(String.init).joined(separator: ","))") }
        return ActionOutcome(action: act, status: "done", note: "killed \(order.count) processes")
    }
}
