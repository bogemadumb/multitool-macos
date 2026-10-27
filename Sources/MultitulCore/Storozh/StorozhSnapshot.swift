import Foundation

public struct SnapshotTools: Equatable, Sendable {
    public var topCpu = ""
    public var topMem = ""
    public var vmStat = ""
    public var swap = ""
    public var batt = ""
    public init() {}

    private static func lastTopBlock(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let i = lines.lastIndex(where: { $0.hasPrefix("Processes:") }) else { return text }
        return lines[i...].joined(separator: "\n")
    }

    // Takes several seconds (top -l 2 -s 1): call off the main thread.
    public static func collect() -> SnapshotTools {
        var t = SnapshotTools()
        t.topCpu = lastTopBlock(ToolRunner.run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "cpu", "-n", "25",
                                                                "-stats", "pid,command,cpu,time,mem,cmprs,ppid,state"], timeout: 30))
        t.topMem = lastTopBlock(ToolRunner.run("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", "15",
                                                                "-stats", "pid,command,mem,cmprs,cpu,ppid,state"], timeout: 30))
        t.vmStat = ToolRunner.run("/usr/bin/vm_stat", [])
        t.swap = ToolRunner.run("/usr/sbin/sysctl", ["vm.swapusage"])
        t.batt = ToolRunner.run("/usr/bin/pmset", ["-g", "batt"])
        return t
    }
}

public enum SnapshotWriter {
    public static var defaultDir: String { NSHomeDirectory() + "/Documents/Scratch/storozh-snimki" }

    private static func block(_ title: String, _ body: String) -> String {
        "## \(title)\n\n```\n\(body.trimmingCharacters(in: .newlines))\n```\n\n"
    }

    public static func formatTime(_ ts: Int64, _ fmt: String = "yyyy-MM-dd HH:mm:ss") -> String {
        let f = DateFormatter()
        f.dateFormat = fmt
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    public static func markdown(kind: String, anomaly: AnomalyRow?, tools: SnapshotTools, recent: [AnomalyRow], now: Int64) -> String {
        var md = "# Снимок Мультитула, \(formatTime(now)), \(kind)\n\n"
        if let a = anomaly {
            md += "## Аномалия\n\n- id: \(a.id)\n- вид: \(a.kind)\n- процесс: \(a.name) (pid \(a.pid))\n- время: \(formatTime(a.ts))\n- детали: `\(a.detail)`\n\n"
        } else {
            md += "## Аномалия\n\nСнимок по запросу, аномалии нет.\n\n"
        }
        md += block("top по CPU (25)", tools.topCpu)
        md += block("top по памяти (15)", tools.topMem)
        md += block("vm_stat", tools.vmStat)
        md += block("Своп", tools.swap)
        md += block("Батарея (pmset -g batt)", tools.batt)
        var rows = "id | время | вид | pid | процесс | статус | детали\n"
        for r in recent { rows += "\(r.id) | \(formatTime(r.ts, "HH:mm:ss")) | \(r.kind) | \(r.pid) | \(r.name) | \(r.status) | \(r.detail)\n" }
        if recent.isEmpty { rows += "(пусто)\n" }
        md += block("Аномалии за последний час", rows)
        return md
    }

    @discardableResult
    public static func write(repo: StorozhRepository, kind: String, anomaly: AnomalyRow?, tools: SnapshotTools, keep: Int,
                             dir: String = defaultDir, now: Int64 = Int64(Date().timeIntervalSince1970)) -> String? {
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            Log.write("snapshot dir error: \(error)")
            return nil
        }
        let recent = (try? repo.anomalies(since: now - 3600)) ?? []
        let md = markdown(kind: kind, anomaly: anomaly, tools: tools, recent: recent, now: now)
        let base = formatTime(now, "yyyy-MM-dd_HHmmss") + "_" + kind
        var path = dir + "/" + base + ".md"
        var n = 2
        while fm.fileExists(atPath: path) {
            path = dir + "/" + base + "-\(n).md"
            n += 1
        }
        do { try md.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            Log.write("snapshot write error: \(error)")
            return nil
        }
        prune(dir: dir, keep: keep)
        return path
    }

    public static func prune(dir: String, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let files = names.filter { $0.hasSuffix(".md") }.compactMap { n -> (String, String)? in
            let p = dir + "/" + n
            guard (try? fm.attributesOfItem(atPath: p)) != nil else { return nil }
            return (p, n)
        }.sorted { $0.1 > $1.1 }
        for f in files.dropFirst(max(keep, 0)) { try? fm.removeItem(atPath: f.0) }
    }

    public static func latestPath(kind: String, dir: String = defaultDir) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix("_\(kind).md") }.sorted().last.map { dir + "/" + $0 }
    }

    public static func claudePrompt(snapshotPath: String) -> String {
        "Глянь снимок Мультитула: \(snapshotPath). Что грузит Мак и что сделать?"
    }
}
