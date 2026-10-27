import Foundation

public enum AnalysisOp: Sendable, Equatable {
    case trash(String)
    case uv
}

public struct AnalysisPlannedOp: Sendable {
    public var itemId: String
    public var op: AnalysisOp
}

public struct AnalysisPlan: Sendable {
    public var ops: [AnalysisPlannedOp] = []
    public var denied: [String] = []
    public var skipped: [String] = []
}

public struct AnalysisReport: Sendable {
    public var freeBefore: Int64 = 0
    public var freeAfter: Int64 = 0
    public var freedBytes: Int64 = 0
    public var doneIds: [String] = []
    public var failed: [String] = []
    public var denied: [String] = []
    public var skipped: [String] = []
    public var died: [String] = []
    public var aborted = false
    public var inTrash: [String] = []
    public var uv = ""
    public var trashedCount = 0
    public var emptiedCount = 0
}

public func describeAnalysisOp(_ op: AnalysisOp) -> String {
    switch op {
    case .trash(let p): return "trash " + p
    case .uv: return "exec uv cache prune (UV_LOCK_TIMEOUT=5)"
    }
}

public func planAnalysisClean(_ result: AnalysisResult, picked: Set<String>, env: AnalysisEnv, index: InUseIndex) -> AnalysisPlan {
    var plan = AnalysisPlan()
    var byId: [String: AnalysisItem] = [:]
    var parentOf: [String: AnalysisItem] = [:]
    for it in result.allItems { byId[it.id] = it }
    for f in result.folders { for c in f.children { parentOf[c.id] = f } }
    var chosen: [AnalysisItem] = []
    for id in picked.sorted() {
        guard let it = byId[id] else { plan.skipped.append("\(id): нет в разборе"); continue }
        if !it.selectable { plan.skipped.append("\(it.title): \(it.reason)"); continue }
        if it.kind != "uv" {
            var busy = index.users(of: it.path)
            if let par = parentOf[it.id] { busy += index.users(of: par.path) }
            if !busy.isEmpty { plan.skipped.append("\(it.title): работает (\(busy.prefix(2).joined(separator: ", ")))"); continue }
        }
        chosen.append(it)
    }
    var taken: [String] = []
    for it in chosen where it.kind != "uv" { taken += it.paths }
    for it in chosen {
        if it.kind == "uv" { plan.ops.append(AnalysisPlannedOp(itemId: it.id, op: .uv)); continue }
        for p in it.paths {
            if taken.contains(where: { $0 != p && p.hasPrefix($0 + "/") }) { continue }
            if isDeniedAnalysis(p, home: env.home, roots: env.rootsAbs) { plan.denied.append(p); continue }
            if !exists(p) { plan.skipped.append("\(p): уже нет"); continue }
            plan.ops.append(AnalysisPlannedOp(itemId: it.id, op: .trash(p)))
        }
    }
    return plan
}

public enum UvOutcome: Equatable {
    case done, busy, missing
    case failed(String)

    public var text: String {
        switch self {
        case .done: return "готово"
        case .busy: return "занято (MCP), повторю позже"
        case .missing: return "uv не найден"
        case .failed(let s): return "ошибка: " + s
        }
    }
}

public func runUvPrune(env: AnalysisEnv) -> UvOutcome {
    guard let uv = env.clean.findTool("uv") else { return .missing }
    guard let r = env.run("/usr/bin/env", ["UV_LOCK_TIMEOUT=5", uv, "cache", "prune"], timeout: 120) else { return .failed("запуск запрещён") }
    let flag = uvPendingPath(env)
    if r.status == 0 {
        try? FileManager.default.removeItem(atPath: flag)
        return .done
    }
    if lockBusy(env.home + "/.cache/uv/.lock") {
        try? FileManager.default.createDirectory(atPath: env.stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flag, contents: Data(String(Int(Date().timeIntervalSince1970)).utf8))
        return .busy
    }
    return .failed("код \(r.status)")
}

public func uvRetryPending(env: AnalysisEnv) -> UvOutcome? {
    guard exists(uvPendingPath(env)) else { return nil }
    return runUvPrune(env: env)
}

public func executeAnalysisClean(_ plan: AnalysisPlan, items: [String: AnalysisItem], env: AnalysisEnv,
                                 progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) -> AnalysisReport {
    var rep = AnalysisReport()
    rep.freeBefore = freeSpaceBytes(env.home)
    rep.denied = plan.denied
    rep.skipped = plan.skipped
    var moves: [(path: String, id: String)] = []
    for p in plan.ops { if case .trash(let src) = p.op { moves.append((src, p.itemId)) } }
    let before = moves.isEmpty ? [:] : parseLaunchctl(env.clean.launchctlList())
    let moved = moveToTrash(moves, env: env.clean, isDenied: { isDeniedAnalysis($0, home: env.home, roots: env.rootsAbs) }, progress: progress)
    rep.denied += moved.denied
    rep.failed += moved.failed
    var failedIds = moved.failedIds
    rep.trashedCount = moved.moved.count
    rep.inTrash = moved.moved.map { $0.dst }

    if !moved.moved.isEmpty {
        let verdict = verifyServices(before: before, env: env.clean)
        if !verdict.died.isEmpty {
            rep.died = verdict.died
            rep.aborted = true
            rep.freeAfter = freeSpaceBytes(env.home)
            Log.write("analysis aborted, died: \(verdict.died.joined(separator: ","))")
            return rep
        }
    }

    var removed = Set<String>()
    for m in moved.moved {
        if let err = purgeFromTrash(m, env: env.clean) {
            rep.failed.append(err)
            failedIds.insert(m.id)
        } else {
            rep.emptiedCount += 1
            removed.insert(m.id)
        }
    }
    var doneIds = Set<String>()
    for id in removed where !failedIds.contains(id) {
        doneIds.insert(id)
        rep.freedBytes += items[id]?.bytes ?? 0
    }

    if plan.ops.contains(where: { $0.op == .uv }) {
        let out = runUvPrune(env: env)
        rep.uv = out.text
        if out == .done { doneIds.insert("uv:prune") }
    }
    rep.doneIds = doneIds.sorted()
    rep.freeAfter = freeSpaceBytes(env.home)
    return rep
}

public func analysisReportLines(_ r: AnalysisReport) -> [String] {
    var l = ["Свободно: \(fmtBytes(r.freeBefore)) → \(fmtBytes(r.freeAfter))"]
    if r.aborted {
        l.append("СТОП: после переноса в Корзину упали службы: " + r.died.joined(separator: ", "))
        l.append("Корзину не чистил, перенесено \(r.trashedCount)")
        return l
    }
    if r.trashedCount > 0 { l.append("Перенесено в Корзину и удалено оттуда: \(r.emptiedCount) из \(r.trashedCount), ~\(fmtBytes(r.freedBytes))") }
    if !r.uv.isEmpty { l.append("uv: " + r.uv) }
    if !r.failed.isEmpty { l.append("Не вышло: \(r.failed.count)") }
    if !r.denied.isEmpty { l.append("Отказано защитой: \(r.denied.count)") }
    return l
}

