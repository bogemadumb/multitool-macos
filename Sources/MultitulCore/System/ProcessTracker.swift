import Foundation

public struct ProcessCPUTracker {
    private var prev: [Int32: RawProc] = [:]
    private var prevAt: TimeInterval?

    public init() {}

    public mutating func update(_ cur: [Int32: RawProc], at now: TimeInterval) -> [ProcRow]? {
        defer { prev = cur; prevAt = now }
        guard let at = prevAt, now > at else { return nil }
        let wall = now - at
        var rows: [ProcRow] = []
        rows.reserveCapacity(cur.count)
        for (pid, c) in cur {
            var cpu = 0.0
            if let p = prev[pid], c.cpuTime >= p.cpuTime { cpu = (c.cpuTime - p.cpuTime) / wall * 100 }
            rows.append(ProcRow(pid: pid, ppid: c.ppid, name: c.name, cpu: (cpu * 10).rounded() / 10, rssBytes: c.rssBytes))
        }
        return rows
    }

    public static func topSelection(_ rows: [ProcRow], top: Int = 30) -> [ProcRow] {
        let byCpu = rows.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }.prefix(top)
        let byRss = rows.sorted { $0.rssBytes != $1.rssBytes ? $0.rssBytes > $1.rssBytes : $0.pid < $1.pid }.prefix(top)
        var seen = Set<Int32>()
        var out: [ProcRow] = []
        for r in Array(byCpu) + Array(byRss) where seen.insert(r.pid).inserted { out.append(r) }
        return out
    }
}
