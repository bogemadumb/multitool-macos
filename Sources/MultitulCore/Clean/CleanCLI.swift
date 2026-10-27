import Foundation

// Multitul --disk-scan | --disk-clean <ids|all> (--dry-run | --yes) | --analyze | --analyze-clean <ids|all> --dry-run
//          | --cleaner-scan | --uninstall-scan <App.app>      [--home DIR] [--no-remote] [--progress]
public enum CleanCLI {
    public static let flags = ["--disk-scan", "--disk-clean", "--analyze", "--analyze-clean", "--cleaner-scan", "--uninstall-scan"]

    public static func handles(_ args: [String]) -> Bool { args.contains { flags.contains($0) } }

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let k = args.firstIndex(of: flag), args.count > k + 1 else { return nil }
        return args[k + 1]
    }

    private static func ids(after flag: String, in args: [String]) -> [String] {
        guard let k = args.firstIndex(of: flag) else { return [] }
        var out: [String] = []
        for s in args[(k + 1)...] {
            if s.hasPrefix("--") { break }
            out.append(s)
        }
        return out
    }

    public static func run(arguments a: [String],
                           makeEnv: (String) -> CleanEnv = { CleanEnv.live(home: $0) },
                           out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let home = value(a, "--home") ?? NSHomeDirectory()
        if a.contains("--disk-scan") {
            let env = makeEnv(home)
            out(scanJSON(scanCategoriesSorted(env: env), env: env))
            return 0
        }
        if a.contains("--disk-clean") { return diskClean(a, env: makeEnv(home), out: out, err: err) }
        if a.contains("--cleaner-scan") {
            let env = makeEnv(home)
            out(scanJSON(scanCategoriesSorted(env: env, defs: cleanerDefs), env: env))
            return 0
        }
        if a.contains("--uninstall-scan") {
            guard let path = value(a, "--uninstall-scan"), let app = InstalledApps.read(appPath: path) else {
                err("usage: Multitul --uninstall-scan <path/to/App.app> [--home DIR]")
                return 2
            }
            let env = makeEnv(home)
            let related = Uninstaller.findRelated(app: app, installed: InstalledApps.live(env: env), env: env)
            out("\(app.name) \(app.bundleId)" + (app.protection.map { " [\($0)]" } ?? ""))
            for l in related { out("\(l.kind.rawValue)\t\(l.bytes)\t\(l.blocked ?? "")\t\(l.path)") }
            return 0
        }
        if a.contains("--analyze") || a.contains("--analyze-clean") { return analyze(a, home: home, makeEnv: makeEnv, out: out, err: err) }
        return 2
    }

    private static func diskClean(_ a: [String], env: CleanEnv, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let list = ids(after: "--disk-clean", in: a)
        let dry = a.contains("--dry-run")
        guard dry || a.contains("--yes") else {
            err("refused: --disk-clean <ids...|all> needs --dry-run or --yes")
            return 2
        }
        guard !list.isEmpty else {
            err("usage: Multitul --disk-clean <ids...|all> [--dry-run | --yes] [--home DIR]")
            return 2
        }
        let all = list.contains("all")
        let defs = all ? cleanDefs : (cleanDefs + cleanerDefs).filter { list.contains($0.id) }
        let cats = scanCategoriesSorted(env: env, defs: defs)
        let picked = Set(cats.flatMap { $0.items.map(\.id) })
        if dry {
            let plan = planClean(cats, picked: picked, env: env)
            for s in plan.skipped { out("skip: " + s) }
            for p in plan.ops { out(describeOp(p.op)) }
            err("ops: \(plan.ops.count), denied: \(plan.denied.count), skipped: \(plan.skipped.count)")
            return 0
        }
        let rep = executeClean(cats, picked: picked, env: env)
        for l in reportLines(rep) { out(l) }
        for f in rep.failed { out("failed: " + f) }
        for s in rep.skipped { out("skip: " + s) }
        return rep.failed.isEmpty && !rep.aborted ? 0 : 1
    }

    private static func analyze(_ a: [String], home: String, makeEnv: (String) -> CleanEnv, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        var env = AnalysisEnv.live(home: home, clean: makeEnv(home))
        if a.contains("--no-remote") { env.checkRemote = false }
        if a.contains("--progress") { env.progress = { f, t in FileHandle.standardError.write(Data("[\(Int(f * 100))%] \(t)\n".utf8)) } }
        if a.contains("--analyze") {
            out(String(decoding: analysisJSON(runAnalysis(env: env)), as: UTF8.self))
            return 0
        }
        let list = ids(after: "--analyze-clean", in: a)
        guard a.contains("--dry-run") else {
            err("refused: --analyze-clean <ids...|all> works only with --dry-run")
            return 2
        }
        guard !list.isEmpty else {
            err("usage: Multitul --analyze-clean <ids...|all> --dry-run [--home DIR]")
            return 2
        }
        let res = runAnalysis(env: env)
        let picked: Set<String> = list.contains("all") ? Set(res.allItems.filter(\.selectable).map(\.id)) : Set(list)
        let plan = planAnalysisClean(res, picked: picked, env: env, index: InUseIndex.build(env))
        for s in plan.skipped { out("skip: " + s) }
        for d in plan.denied { out("denied: " + d) }
        for p in plan.ops { out(describeAnalysisOp(p.op)) }
        err("ops: \(plan.ops.count), denied: \(plan.denied.count), skipped: \(plan.skipped.count)")
        return 0
    }
}
