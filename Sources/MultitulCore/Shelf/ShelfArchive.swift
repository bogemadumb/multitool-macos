import Foundation
import MultitulCtlCore

public struct ShelfZipPlan: Equatable, Sendable {
    public var outputPath: String
    public var workDir: String
    public var names: [String]
    public var links: [(link: String, target: String)]
    public var stageDir: String?

    public static func == (a: ShelfZipPlan, b: ShelfZipPlan) -> Bool {
        a.outputPath == b.outputPath && a.workDir == b.workDir && a.names == b.names && a.stageDir == b.stageDir
            && a.links.map { $0.link + "\u{1}" + $0.target } == b.links.map { $0.link + "\u{1}" + $0.target }
    }
}

public enum ShelfZip {
    public static let multiName = "Архив"

    public static func uniqueName(_ base: String, ext: String, existing: Set<String>) -> String {
        let first = ext.isEmpty ? base : base + "." + ext
        if !existing.contains(first) { return first }
        var n = 2
        while true {
            let cand = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !existing.contains(cand) { return cand }
            n += 1
        }
    }

    public static func plan(paths: [String], outputDir: String, existing: Set<String>, stageName: String) -> ShelfZipPlan? {
        let norm = paths.map(ShelfPaths.normalize)
        guard let first = norm.first else { return nil }
        let parents = Set(norm.map { ($0 as NSString).deletingLastPathComponent })
        let baseName: String
        if norm.count == 1 {
            let n = (first as NSString).lastPathComponent
            baseName = n.isEmpty ? multiName : n
        } else {
            baseName = multiName
        }
        let out = outputDir + "/" + uniqueName(baseName, ext: "zip", existing: existing)
        if parents.count == 1, Set(norm.map { ($0 as NSString).lastPathComponent }).count == norm.count {
            return ShelfZipPlan(outputPath: out, workDir: parents.first!, names: norm.map { ($0 as NSString).lastPathComponent }, links: [], stageDir: nil)
        }
        let stage = outputDir + "/" + stageName
        var used = Set<String>()
        var links: [(String, String)] = []
        for p in norm {
            let n = uniqueName(((p as NSString).deletingPathExtension as NSString).lastPathComponent, ext: (p as NSString).pathExtension, existing: used)
            used.insert(n)
            links.append((stage + "/" + n, p))
        }
        return ShelfZipPlan(outputPath: out, workDir: stage, names: links.map { ($0.0 as NSString).lastPathComponent }, links: links, stageDir: stage)
    }
}

public enum ShelfArchiveError: Error, Equatable, Sendable {
    case nothingToArchive
    case failed(String)
}

public final class ShelfArchiver {
    private let runner: ProcessRunning
    private let fs: ShelfFileSystem
    private let outputDir: String
    private let stageName: () -> String

    public init(runner: ProcessRunning, fs: ShelfFileSystem, outputDir: String = MultitulPaths.shelfArchivesDir, stageName: @escaping () -> String = { ".stage-" + UUID().uuidString }) {
        self.runner = runner
        self.fs = fs
        self.outputDir = outputDir
        self.stageName = stageName
    }

    public static func live() -> ShelfArchiver { ShelfArchiver(runner: SystemProcessRunner(), fs: LiveShelfFileSystem()) }

    public func compress(_ paths: [String]) -> Result<String, ShelfArchiveError> {
        let existing = Set(fs.list(outputDir))
        let alive = paths.filter { fs.exists($0) }
        guard !alive.isEmpty, let plan = ShelfZip.plan(paths: alive, outputDir: outputDir, existing: existing, stageName: stageName()) else { return .failure(.nothingToArchive) }
        fs.makeDirectory(outputDir)
        if let stage = plan.stageDir {
            fs.makeDirectory(stage)
            for l in plan.links { fs.symlink(at: l.link, to: l.target) }
        }
        defer { if let stage = plan.stageDir { fs.remove(stage) } }
        let script = "cd \"$1\" || exit 1; out=\"$2\"; shift 2; exec /usr/bin/zip -r -q \"$out\" -- \"$@\""
        let r = runner.run("/bin/sh", ["-c", script, "sh", plan.workDir, plan.outputPath] + plan.names, timeout: 300)
        guard r.status == 0, !r.timedOut else {
            fs.remove(plan.outputPath)
            return .failure(.failed(r.timedOut ? "время вышло" : (r.stderr.isEmpty ? "код \(r.status)" : String(r.stderr.prefix(200)))))
        }
        return .success(plan.outputPath)
    }
}
