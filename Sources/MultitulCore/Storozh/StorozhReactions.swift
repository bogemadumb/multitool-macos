import Foundation

public enum StorozhReaction: String, Sendable {
    case skip
    case ignored
    case restart
    case restartUseless = "restart_useless"
    case notify
}

public struct ProcFacts {
    public var info: ProcInfo
    public var launchdPids: Set<Int32>
    public init(info: ProcInfo, launchdPids: Set<Int32>) {
        self.info = info
        self.launchdPids = launchdPids
    }
}

public let devServerNames = ["node", "npm", "uvx", "vite", "python*"]

public func isDevServerName(_ name: String) -> Bool {
    devServerNames.contains { nameMatches($0, name) }
}

public func isOrphanDevServer(_ f: ProcFacts) -> Bool {
    let i = f.info
    guard i.ppid == 1, !i.hasTTY, !f.launchdPids.contains(i.pid) else { return false }
    if i.name.hasPrefix("python") { return i.args.contains("http.server") }
    return isDevServerName(i.name)
}

public enum StorozhReactions {
    public static func decide(kind: String, name: String, pid: Int32, repeatFlag: Bool, facts: ProcFacts?, lists: StorozhLists) -> StorozhReaction {
        guard DetectorKind(rawValue: kind)?.isPerProcess == true else { return .notify }
        let path = facts?.info.path
        let args = facts?.info.args
        if isListed(name: name, pid: pid, path: path, list: lists.effectiveUntouchable, args: args) { return .skip }
        if isListed(name: name, pid: pid, path: path, list: lists.ignore, args: args) { return .ignored }
        guard isListed(name: name, pid: pid, path: path, list: lists.whitelist, args: args) else { return .notify }
        if isDevServerName(name) {
            guard let f = facts, isOrphanDevServer(f) else { return .notify }
        }
        return repeatFlag ? .restartUseless : .restart
    }

    // Applies the reaction to a freshly recorded anomaly. Returns the reaction and whether the user must be told.
    @discardableResult
    public static func autoReact(repo: StorozhRepository, row: AnomalyRow, lists: StorozhLists, ops: ProcOps,
                                 launchdPids: () -> Set<Int32>) throws -> (note: String, notify: Bool) {
        var facts: ProcFacts?
        if row.isProcessKind, let i = ops.info(row.pid), i.name == row.name, !i.zombie {
            facts = ProcFacts(info: i, launchdPids: launchdPids())
        }
        let rep = row.detailDict["repeat"] as? Bool ?? false
        let d = decide(kind: row.kind, name: row.name, pid: row.pid, repeatFlag: rep, facts: facts, lists: lists)
        switch d {
        case .skip:
            try repo.setAction(id: row.id, action: "skip", status: "done")
            return ("skip", false)
        case .ignored:
            try repo.setAction(id: row.id, action: "ignored", status: "done")
            return ("ignored", false)
        case .notify, .restartUseless:
            try repo.setAction(id: row.id, action: d.rawValue, status: "pending_user")
            return (d.rawValue, true)
        case .restart:
            let out = ProcessTerminator.terminate(pid: row.pid, expectedName: row.name, relaunch: true, lists: lists, ops: ops)
            if out.note.hasPrefix("refused") {
                try repo.setAction(id: row.id, action: "skip", status: "done")
                return ("skip (\(out.note))", false)
            }
            try repo.setAction(id: row.id, action: "restart", status: out.status)
            return ("restart \(out.status) (\(out.note))", false)
        }
    }

    public static let userActions: Set<String> = ["restart", "kill", "ignore", "whitelist", "dismiss"]

    // Button handlers from notifications and the page.
    public static func handleAction(repo: StorozhRepository, id: Int64, action: String, ops: ProcOps, dry: Bool = false) -> ActionOutcome {
        func fail(_ note: String) -> ActionOutcome { ActionOutcome(action: action, status: "failed", note: note) }
        guard userActions.contains(action) else { return fail("unknown action") }
        guard let row = try? repo.anomaly(id: id) else { return fail("anomaly \(id) not found") }
        if action == "dismiss" {
            if !dry { try? repo.dismiss(id: id) }
            return ActionOutcome(action: action, status: dry ? "dry_run" : "done", note: "dismissed")
        }
        guard row.isProcessKind else { return fail("system-level anomaly, no process action") }
        let lists = (try? repo.lists()) ?? StorozhLists()
        var out: ActionOutcome
        do {
            switch action {
            case "restart", "kill":
                out = ProcessTerminator.terminate(pid: row.pid, expectedName: row.name, relaunch: action == "restart", lists: lists, ops: ops, dry: dry)
            case "ignore":
                if dry { out = ActionOutcome(action: action, status: "dry_run", note: "would ignore \(row.name)") } else {
                    try repo.moveEntry(row.name, to: .ignore)
                    out = ActionOutcome(action: action, status: "done", note: "added to ignore")
                }
            default:
                if dry { out = ActionOutcome(action: action, status: "dry_run", note: "would whitelist \(row.name)") } else {
                    try repo.moveEntry(row.name, to: .whitelist)
                    out = ActionOutcome(action: action, status: "done", note: "added to whitelist")
                }
            }
            if out.status != "dry_run" { try repo.setAction(id: id, action: action, status: out.status) }
        } catch {
            return fail("\(error)")
        }
        Log.write("storozh act id=\(id) \(action) -> \(out.status): \(out.note)")
        return out
    }

    public static func notificationText(_ row: AnomalyRow) -> (title: String, body: String) {
        let d = row.detailDict
        func num(_ k: String) -> String {
            if let v = d[k] as? Double { return v == v.rounded() ? String(Int(v)) : String(v) }
            if let v = d[k] as? Int { return String(v) }
            return "?"
        }
        switch row.kind {
        case "cpu_hog":
            let body = "\(num("avg_cpu"))% CPU за \(num("window_s")) с, RSS \(num("rss_mb")) МБ, pid \(row.pid)"
            if row.action == "restart_useless" {
                return ("\(row.name): перезапуск не помогает", "Снова грузит CPU (\(num("hogs_in_window")) раз за 2 ч). \(body)")
            }
            return ("\(row.name) грузит CPU", body)
        case "mem_leak":
            return ("\(row.name) пухнет по памяти", "+\(num("growth_mb")) МБ за \(num("span_min")) мин, сейчас \(num("rss_mb")) МБ, pid \(row.pid)")
        case "swap":
            return ("Своп \(num("swap_mb")) МБ", "Лимит \(num("limit_mb")) МБ. Открой снимок.")
        case "mem_pressure":
            return ("Давление памяти: \(d["level_name"] as? String ?? "?")", "Открой снимок.")
        case "battery_drain":
            return ("Батарея садится \(num("drain_pct_per_h"))%/ч", "Виновник: \(row.name), заряд \(num("batt_pct"))%. Открой снимок.")
        case "disk_low":
            return ("Мало места на диске: \(num("free_gb")) ГБ", "Порог \(num("limit_gb")) ГБ. Открой снимок.")
        case "thermal":
            return ("Мак перегрет: \(d["level_name"] as? String ?? "?")", "Уже \(num("span_s")) с. Открой снимок.")
        default:
            return (row.kind, row.name)
        }
    }
}

public enum StorozhNotifications {
    public static let categoryProc = "storozh.proc"
    public static let categoryUseless = "storozh.useless"
    public static let categorySystem = "storozh.system"

    public static var categories: [NotificationCategorySpec] {
        [
            NotificationCategorySpec(id: categoryProc, actions: [
                NotificationActionSpec(id: "restart", title: "Перезапустить"),
                NotificationActionSpec(id: "kill", title: "Убить", destructive: true),
                NotificationActionSpec(id: "ignore", title: "Игнор"),
                NotificationActionSpec(id: "whitelist", title: "В белый список"),
            ]),
            NotificationCategorySpec(id: categoryUseless, actions: [
                NotificationActionSpec(id: "kill", title: "Убить", destructive: true),
                NotificationActionSpec(id: "ignore", title: "Игнор"),
            ]),
            NotificationCategorySpec(id: categorySystem, actions: []),
        ]
    }

    public static func category(for row: AnomalyRow) -> String {
        guard row.isProcessKind else { return categorySystem }
        return row.action == "restart_useless" ? categoryUseless : categoryProc
    }

    public static func requestId(_ anomalyId: Int64) -> String { "storozh-\(anomalyId)" }

    public enum Request: Equatable, Sendable {
        case act(anomalyId: Int64, action: String)
        case openSnapshot(path: String)
    }

    // Notifier hands over action id + string userInfo; anything not from Storozh is ignored.
    public static func route(_ e: NotificationEvent) -> Request? {
        guard e.requestId.hasPrefix("storozh-") else { return nil }
        if e.actionId == NotificationEvent.defaultAction {
            return e.userInfo["snapshot"].map { .openSnapshot(path: $0) }
        }
        guard let id = e.userInfo["anomalyId"].flatMap({ Int64($0) }), StorozhReactions.userActions.contains(e.actionId) else { return nil }
        return .act(anomalyId: id, action: e.actionId)
    }

    public static func userInfo(for p: PendingNotification) -> [String: String] {
        var info = ["anomalyId": String(p.anomaly.id)]
        if let s = p.snapshot { info["snapshot"] = s }
        return info
    }
}
