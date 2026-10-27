import Foundation

public struct RawProc: Equatable, Sendable {
    public var ppid: Int32
    public var name: String
    public var cpuTime: Double
    public var rssBytes: Int64
}

public struct PowerRow: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var power: Double
}

public struct PmsetReading: Equatable, Sendable {
    public var hasBattery = false
    public var onAC = false
    public var percent: Int?
    public var state: String?
    public var timeRemainingMin: Int?
    public var isCharging: Bool { state == "charging" || state == "finishing charge" }
    public var isCharged: Bool { state == "charged" }
}

public struct NetCounter: Equatable, Sendable {
    public var name: String
    public var pid: Int32
    public var bytesIn: UInt64
    public var bytesOut: UInt64
}

public enum SystemParsers {
    public static func cpuTime(_ s: String) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86400 + total
    }

    public static func baseName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    public static func ps(_ text: String) -> [Int32: RawProc] {
        var res: [Int32: RawProc] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), let rss = Int64(f[2]) else { continue }
            res[pid] = RawProc(ppid: ppid, name: baseName(String(f[4])), cpuTime: cpuTime(String(f[3])), rssBytes: rss * 1024)
        }
        return res
    }

    public static func vmStat(_ text: String) -> VMPages? {
        var pageSize: UInt64 = 16384
        if let r = text.range(of: #"page size of (\d+) bytes"#, options: .regularExpression) {
            let digits = text[r].split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }
            if let v = digits.first { pageSize = v }
        }
        var vals: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let num = line[line.index(after: colon)...].filter(\.isNumber)
            if let v = UInt64(num) { vals[key] = v }
        }
        guard vals["Pages free"] != nil else { return nil }
        var p = VMPages(pageSize: pageSize)
        p.free = vals["Pages free"] ?? 0
        p.active = vals["Pages active"] ?? 0
        p.inactive = vals["Pages inactive"] ?? 0
        p.speculative = vals["Pages speculative"] ?? 0
        p.wired = vals["Pages wired down"] ?? 0
        p.compressor = vals["Pages occupied by compressor"] ?? 0
        p.purgeable = vals["Pages purgeable"] ?? 0
        p.fileBacked = vals["File-backed pages"] ?? 0
        p.anonymous = vals["Anonymous pages"] ?? 0
        return p
    }

    public static func timeRemaining(_ pmset: String) -> Int? {
        guard let r = pmset.range(of: #"\d+:\d{2}(?= remaining)"#, options: .regularExpression) else { return nil }
        let p = pmset[r].split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        let total = h * 60 + m
        return total > 0 ? total : nil
    }

    public static func pmsetBatt(_ text: String) -> PmsetReading {
        var r = PmsetReading()
        let lines = text.split(separator: "\n")
        if let first = lines.first { r.onAC = first.contains("AC Power") }
        guard let l = lines.first(where: { $0.contains("%") }) else { return r }
        r.hasBattery = true
        if let m = l.range(of: #"\d+(?=%)"#, options: .regularExpression) { r.percent = Int(l[m]) }
        let parts = l.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 { r.state = parts[1].lowercased() }
        r.timeRemainingMin = timeRemaining(String(l))
        return r
    }

    public static func topPower(_ text: String) -> [PowerRow] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lastHeader = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }
        var rows: [PowerRow] = []
        for l in lines[(lastHeader + 1)...] {
            let f = l.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let pw = Double(f[f.count - 1]) else { continue }
            rows.append(PowerRow(pid: pid, name: f[1..<(f.count - 1)].joined(separator: " "), power: pw))
        }
        return rows
    }

    public static func nettop(_ text: String) -> [NetCounter] {
        var inIdx: Int?
        var outIdx: Int?
        var nameIdx = 0
        var rows: [NetCounter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let cells = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if let i = cells.firstIndex(of: "bytes_in") {
                inIdx = i
                outIdx = cells.firstIndex(of: "bytes_out")
                nameIdx = cells[..<i].firstIndex(of: "") ?? 0
                rows = []
                continue
            }
            guard let ii = inIdx, let oi = outIdx, cells.count > max(ii, oi), nameIdx < cells.count,
                  let bi = UInt64(cells[ii]), let bo = UInt64(cells[oi]) else { continue }
            let label = cells[nameIdx]
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            rows.append(NetCounter(name: String(label[..<dot]), pid: pid, bytesIn: bi, bytesOut: bo))
        }
        return rows
    }

    public static func smartStatus(plist data: Data) -> SmartStatus {
        guard let obj = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let s = obj["SMARTStatus"] as? String else { return .unknown }
        switch s.lowercased() {
        case "verified": return .verified
        case "failing": return .failing
        case "not supported": return .unsupported
        default: return .unknown
        }
    }

    public static func procArgs(_ data: [UInt8]) -> (execPath: String, args: [String])? {
        guard data.count > 4 else { return nil }
        let argc = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        var i = 4
        func readString() -> String {
            let start = i
            while i < data.count, data[i] != 0 { i += 1 }
            return String(decoding: data[start..<i], as: UTF8.self)
        }
        let exec = readString()
        while i < data.count, data[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < data.count {
            args.append(readString())
            i += 1
        }
        return (exec, args)
    }

    public static func bundlePath(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public static func groupProcesses(_ rows: [ProcRow]) -> [ProcGroup] {
        var groups: [String: ProcGroup] = [:]
        for r in rows {
            var g = groups[r.name] ?? ProcGroup(name: r.name, pids: [], cpu: 0, rssBytes: 0, netBps: 0)
            g.pids.append(r.pid)
            g.cpu += r.cpu
            g.rssBytes += r.rssBytes
            g.netBps += r.netDownBps + r.netUpBps
            groups[r.name] = g
        }
        return Array(groups.values)
    }
}
