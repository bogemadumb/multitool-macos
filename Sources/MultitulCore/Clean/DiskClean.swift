import Foundation

public enum CleanLevel: String, Sendable, CaseIterable {
    case safe, review, never

    public var title: String {
        switch self {
        case .safe: "Безопасно"
        case .review: "Проверь"
        case .never: "Никогда"
        }
    }
}

public enum CleanAction: Sendable {
    // Moved to the Trash; with purge the moved items are removed from the Trash once the services check has passed.
    case trash(purge: Bool)
    case emptyTrash
    case command(tool: String, args: [String])
    case none
}

public struct CleanItem: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle = ""
    public var bytes: Int64 = 0
    public var paths: [String] = []
    public var contentsOnly = false
    public var blocked: String?

    public init(id: String, title: String, subtitle: String = "", bytes: Int64 = 0, paths: [String] = [], contentsOnly: Bool = false, blocked: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.bytes = bytes
        self.paths = paths
        self.contentsOnly = contentsOnly
        self.blocked = blocked
    }
}

public struct CleanCategory: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var level: CleanLevel
    public var action: CleanAction
    public var items: [CleanItem]

    public init(id: String, title: String, subtitle: String, level: CleanLevel, action: CleanAction, items: [CleanItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.level = level
        self.action = action
        self.items = items
    }

    public var bytes: Int64 { items.filter { $0.blocked == nil }.reduce(0) { $0 + $1.bytes } }
    public var blockedBytes: Int64 { items.filter { $0.blocked != nil }.reduce(0) { $0 + $1.bytes } }
    public var note: String? {
        let reasons = Set(items.compactMap(\.blocked))
        return reasons.count == 1 && items.allSatisfy({ $0.blocked != nil }) ? reasons.first : nil
    }
}

public struct CleanDef: Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var level: CleanLevel
    public var action: CleanAction
    public var scan: @Sendable (CleanEnv) -> [CleanItem]

    public func run(_ env: CleanEnv) -> CleanCategory {
        CleanCategory(id: id, title: title, subtitle: subtitle, level: level, action: action, items: scan(env))
    }
}

func aggregate(_ id: String, title: String, paths: [String], bytes: Int64, contentsOnly: Bool = false, blocked: String? = nil) -> [CleanItem] {
    paths.isEmpty && bytes == 0 ? [] : [CleanItem(id: id, title: title, bytes: bytes, paths: paths, contentsOnly: contentsOnly, blocked: blocked)]
}

private let cacheSkipNames: Set<String> = ["ms-playwright", "colima", "uv", "pip", "homebrew", "npm", "google", "multitul", "storozh"]

func scanTrash(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.trashDir
    guard exists(dir) else { return [] }
    var paths: [String] = []
    var bytes: Int64 = 0
    for n in childNames(dir) {
        let p = dir + "/" + n
        paths.append(p)
        bytes += scanTree(p).bytes
    }
    return aggregate("trash", title: "Корзина", paths: paths, bytes: bytes)
}

func scanSystemCaches(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Library/Caches")
    var paths: [String] = []
    var bytes: Int64 = 0
    for n in childNames(dir) {
        let l = n.lowercased()
        if cacheSkipNames.contains(l) || l.hasPrefix("com.apple.") || l.contains("claude") || l.contains("playwright") || l.hasPrefix("dev.multitool.") { continue }
        if e.cacheOwnerRunning(n) { continue }
        let p = dir + "/" + n
        guard isRealDir(p) else { continue }
        paths.append(p)
        bytes += scanTree(p).bytes
    }
    return aggregate("caches", title: "Кэши приложений", paths: paths, bytes: bytes)
}

func scanOldLogs(_ e: CleanEnv, olderThanDays: Int = 7) -> [CleanItem] {
    let dir = e.path("Library/Logs")
    let limit = e.now.addingTimeInterval(-Double(olderThanDays) * 86400)
    var paths: [String] = []
    var bytes: Int64 = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return [] }
    for case let url as URL in en {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isSymbolicLink == true { continue }
        guard v.isRegularFile == true, let m = v.contentModificationDate, m < limit else { continue }
        paths.append(url.path)
        bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
    return aggregate("logs", title: "Логи старше \(olderThanDays) дней", paths: paths, bytes: bytes)
}

func scanDerivedData(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Library/Developer/Xcode/DerivedData")
    var paths: [String] = []
    var bytes: Int64 = 0
    for n in childNames(dir) {
        let p = dir + "/" + n
        paths.append(p)
        bytes += scanTree(p).bytes
    }
    return aggregate("xcode", title: "DerivedData", paths: paths, bytes: bytes)
}

func scanVSCode(_ e: CleanEnv) -> [CleanItem] {
    let base = e.path("Library/Application Support/Code")
    var items: [CleanItem] = []
    let main = ["Cache", "CachedData"].map { base + "/" + $0 }.filter(isRealDir)
    if !main.isEmpty { items += aggregate("vscode-cache", title: "VS Code: Cache и CachedData", paths: main, bytes: main.reduce(0) { $0 + scanTree($1).bytes }, contentsOnly: true) }
    let gpu = base + "/GPUCache"
    if isRealDir(gpu) {
        items += aggregate("vscode-gpu", title: "VS Code: GPUCache", paths: [gpu], bytes: scanTree(gpu).bytes, contentsOnly: true,
                           blocked: e.appRunning("com.microsoft.vscode") ? "закрой VS Code" : nil)
    }
    return items
}

func scanChrome(_ e: CleanEnv) -> [CleanItem] {
    let running = e.appRunning("com.google.chrome")
    var paths: [String] = []
    let cache = e.path("Library/Caches/Google/Chrome")
    if isRealDir(cache) { paths.append(cache) }
    let prof = e.path("Library/Application Support/Google/Chrome")
    for n in childNames(prof) where n == "Default" || n.hasPrefix("Profile ") {
        for sub in ["Cache", "Code Cache", "GPUCache"] {
            let p = prof + "/" + n + "/" + sub
            if isRealDir(p) { paths.append(p) }
        }
    }
    return aggregate("chrome", title: "Кэш Chrome", paths: paths, bytes: paths.reduce(0) { $0 + scanTree($1).bytes },
                     contentsOnly: true, blocked: running ? "закрой Chrome" : nil)
}

func resolveClaudeKeep(_ e: CleanEnv) -> String? {
    let link = e.path(".local/bin/claude")
    let real = canonicalPath(link)
    let versions = canonicalPath(e.path(".local/share/claude/versions"))
    guard real.hasPrefix(versions + "/") else { return nil }
    return String(real.dropFirst(versions.count + 1)).split(separator: "/").first.map(String.init)
}

func scanClaudeVersions(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path(".local/share/claude/versions")
    guard let keep = resolveClaudeKeep(e) else { return [] }
    var paths: [String] = []
    var bytes: Int64 = 0
    for n in childNames(dir) where n != keep {
        let p = dir + "/" + n
        if e.processBlob.contains(p) || e.processBlob.contains("/versions/" + n) { continue }
        paths.append(p)
        bytes += scanTree(p).bytes
    }
    return aggregate("claude-versions", title: "Старые версии claude", paths: paths, bytes: bytes)
}

private func commandItem(_ e: CleanEnv, id: String, title: String, tool: String, bytes: () -> Int64) -> [CleanItem] {
    guard e.findTool(tool) != nil else { return [] }
    return [CleanItem(id: id, title: title, bytes: bytes())]
}

func scanDocker(_ e: CleanEnv) -> [CleanItem] {
    guard let docker = e.findTool("docker") else { return [] }
    let info = e.exec(docker, ["info"], 8)
    guard info.status == 0 else {
        return [CleanItem(id: "docker", title: "Docker", subtitle: "colima не запущен", blocked: "Docker не запущен")]
    }
    let df = e.exec(docker, ["system", "df", "--format", "{{.Type}}|{{.Reclaimable}}"], 20)
    var total: Int64 = 0
    var parts: [String] = []
    for line in df.out.split(separator: "\n") {
        let f = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard f.count == 2, f[0] != "Local Volumes" else { continue }
        let b = parseDockerSize(f[1])
        total += b
        if b > 0 { parts.append("\(f[0]) \(f[1].split(separator: " ").first ?? "")") }
    }
    return [CleanItem(id: "docker", title: "Образы, контейнеры, билд-кэш", subtitle: parts.joined(separator: " · "), bytes: total)]
}

func scanTelegram(_ e: CleanEnv) -> [CleanItem] {
    let gc = e.path("Library/Group Containers")
    let blocked = e.appRunning("keepcoder.telegram") ? "закрой Telegram" : nil
    var items: [CleanItem] = []
    var n = 0
    for c in childNames(gc) where c.hasSuffix("ru.keepcoder.Telegram") {
        let app = gc + "/" + c + "/appstore"
        for acc in childNames(app) where acc.hasPrefix("account-") {
            var paths = [app + "/" + acc + "/postbox/media"]
            let cached = app + "/" + acc + "/cached"
            if isRealDir(cached) { paths.append(cached) }
            paths = paths.filter(isRealDir)
            guard !paths.isEmpty else { continue }
            n += 1
            let b = paths.reduce(0) { $0 + scanTree($1).bytes }
            items.append(CleanItem(id: "telegram-\(acc)", title: "Аккаунт \(n): медиа и кэш", subtitle: "скачивается заново при просмотре",
                                   bytes: b, paths: paths, contentsOnly: true, blocked: blocked))
        }
        let temp = app + "/temp"
        if isRealDir(temp) {
            items.append(CleanItem(id: "telegram-temp", title: "Временные файлы", bytes: scanTree(temp).bytes, paths: [temp], contentsOnly: true, blocked: blocked))
        }
    }
    return items.sorted { $0.bytes > $1.bytes }
}

func scanDownloads(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Downloads")
    let limit = e.now.addingTimeInterval(-30 * 86400)
    var items: [CleanItem] = []
    for n in childNames(dir) where !n.hasPrefix(".") {
        let p = dir + "/" + n
        let st = scanTree(p)
        guard st.newestFile > Date.distantPast, st.newestFile < limit else { continue }
        items.append(CleanItem(id: "dl-" + n, title: n, subtitle: "\(days(st.newestFile, e.now)) дн. назад", bytes: st.bytes, paths: [p]))
    }
    return items.sorted { $0.bytes > $1.bytes }
}

func scanHFModels(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path(".cache/huggingface/hub")
    let limit = e.now.addingTimeInterval(-60 * 86400)
    var items: [CleanItem] = []
    for n in childNames(dir) where n.hasPrefix("models--") {
        let p = dir + "/" + n
        guard isRealDir(p) else { continue }
        let st = scanTree(p)
        guard st.newestAccess < limit, st.bytes >= 1_000_000 else { continue }
        let name = n.dropFirst(8).replacingOccurrences(of: "--", with: "/")
        items.append(CleanItem(id: "hf-" + n, title: name, subtitle: "не открывалась \(days(st.newestAccess, e.now)) дн.", bytes: st.bytes, paths: [p]))
    }
    return items.sorted { $0.bytes > $1.bytes }
}

func playwrightOld(_ names: [String]) -> [String] {
    var best: [String: Int] = [:]
    var parsed: [(String, String, Int)] = []
    for n in names {
        guard let r = n.range(of: #"-(\d+)$"#, options: .regularExpression), let rev = Int(n[r].dropFirst()) else { continue }
        let browser = String(n[..<r.lowerBound])
        guard !browser.isEmpty else { continue }
        parsed.append((n, browser, rev))
        best[browser] = max(best[browser] ?? 0, rev)
    }
    return parsed.filter { $0.2 < (best[$0.1] ?? 0) }.map(\.0)
}

func scanPlaywright(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Library/Caches/ms-playwright")
    var items: [CleanItem] = []
    for n in playwrightOld(childNames(dir)) {
        let p = dir + "/" + n
        guard isRealDir(p) else { continue }
        let inUse = e.processBlob.contains(p + "/")
        items.append(CleanItem(id: "pw-" + n, title: n, subtitle: inUse ? "сейчас запущен" : "есть версия новее", bytes: scanTree(p).bytes,
                               paths: [p], blocked: inUse ? "используется" : nil))
    }
    return items.sorted { $0.bytes > $1.bytes }
}

// "Never" rows are shown with their size and can never be picked.
func neverScan(id: String, title: String, rel: String, why: String) -> @Sendable (CleanEnv) -> [CleanItem] {
    { e in
        let p = e.path(rel)
        guard exists(p) else { return [] }
        return [CleanItem(id: id, title: title, subtitle: why, bytes: scanTree(p).bytes, paths: [p], blocked: "никогда")]
    }
}

public let cleanDefs: [CleanDef] = [
    CleanDef(id: "trash", title: "Корзина", subtitle: "удаляется насовсем", level: .safe, action: .emptyTrash, scan: scanTrash),
    CleanDef(id: "caches", title: "Кэши приложений", subtitle: "кроме запущенных и системных", level: .safe, action: .trash(purge: true), scan: scanSystemCaches),
    CleanDef(id: "logs", title: "Логи старше 7 дней", subtitle: "~/Library/Logs", level: .safe, action: .trash(purge: true), scan: { scanOldLogs($0) }),
    CleanDef(id: "xcode", title: "Xcode DerivedData", subtitle: "пересоберётся сама", level: .safe, action: .trash(purge: true), scan: scanDerivedData),
    CleanDef(id: "vscode", title: "Кэши VS Code", subtitle: "Cache, CachedData, GPUCache", level: .safe, action: .trash(purge: true), scan: scanVSCode),
    CleanDef(id: "chrome", title: "Кэш Chrome", subtitle: "только при закрытом Chrome", level: .safe, action: .trash(purge: true), scan: scanChrome),
    CleanDef(id: "claude-versions", title: "Старые версии claude", subtitle: "текущая остаётся", level: .safe, action: .trash(purge: true), scan: scanClaudeVersions),
    CleanDef(id: "npm", title: "Кэш npm", subtitle: "npm cache clean --force", level: .safe,
             action: .command(tool: "npm", args: ["cache", "clean", "--force"]),
             scan: { e in commandItem(e, id: "npm", title: "Кэш npm", tool: "npm") { scanTree(e.path(".npm/_cacache")).bytes } }),
    CleanDef(id: "brew", title: "Homebrew", subtitle: "brew cleanup -s, оценка по кэшу", level: .safe,
             action: .command(tool: "brew", args: ["cleanup", "-s"]),
             scan: { e in commandItem(e, id: "brew", title: "Homebrew", tool: "brew") { scanTree(e.path("Library/Caches/Homebrew")).bytes } }),
    CleanDef(id: "pip", title: "Кэш pip", subtitle: "pip3 cache purge", level: .safe,
             action: .command(tool: "pip3", args: ["cache", "purge"]),
             scan: { e in commandItem(e, id: "pip", title: "Кэш pip", tool: "pip3") { scanTree(e.path("Library/Caches/pip")).bytes } }),
    CleanDef(id: "docker", title: "Docker / colima", subtitle: "docker system prune -a, место в образе colima может не вернуться", level: .review,
             action: .command(tool: "docker", args: ["system", "prune", "-a", "-f"]), scan: scanDocker),
    CleanDef(id: "telegram", title: "Медиакэш Telegram", subtitle: "только при закрытом Telegram", level: .review, action: .trash(purge: true), scan: scanTelegram),
    CleanDef(id: "downloads", title: "Загрузки старше 30 дней", subtitle: "уйдут в Корзину и там останутся", level: .review, action: .trash(purge: false), scan: scanDownloads),
    CleanDef(id: "hf", title: "Модели HuggingFace", subtitle: "без обращений 60 дней, в Корзину", level: .review, action: .trash(purge: false), scan: scanHFModels),
    CleanDef(id: "playwright", title: "Старые браузеры playwright", subtitle: "новейшая версия остаётся", level: .review, action: .trash(purge: true), scan: scanPlaywright),
    CleanDef(id: "never-uv", title: "Кэш uv", subtitle: "uvx-окружения ссылаются на archive-v0, MCP сломается", level: .never, action: .none,
             scan: neverScan(id: "never-uv", title: ".cache/uv", rel: ".cache/uv", why: "чистится только через uv cache prune в «Разборе»")),
    CleanDef(id: "never-system", title: "Документы/Система", subtitle: "доступы, движки, бэкапы", level: .never, action: .none,
             scan: neverScan(id: "never-system", title: "Documents/Система", rel: "Documents/Система", why: "инфраструктура")),
    CleanDef(id: "never-claude", title: ".claude/projects", subtitle: "память и история сессий Claude", level: .never, action: .none,
             scan: neverScan(id: "never-claude", title: ".claude/projects", rel: ".claude/projects", why: "память Claude")),
]

public func cleanDefs(level: CleanLevel) -> [CleanDef] { cleanDefs.filter { $0.level == level } }

// concurrentPerform runs on the calling thread too, so many scans started from the cooperative pool cannot starve each other.
public func scanCategories(env: CleanEnv, defs: [CleanDef] = cleanDefs, onEach: @escaping @Sendable (CleanCategory) -> Void) {
    DispatchQueue.concurrentPerform(iterations: defs.count) { onEach(defs[$0].run(env)) }
}

public func scanCategoriesSorted(env: CleanEnv, defs: [CleanDef] = cleanDefs) -> [CleanCategory] {
    let box = LockedBox<[CleanCategory]>([])
    scanCategories(env: env, defs: defs) { c in box.mutate { $0.append(c) } }
    let order = defs.map(\.id)
    return box.value.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
}

public func defaultPicked(_ cats: [CleanCategory]) -> Set<String> {
    Set(cats.filter { $0.level == .safe }.flatMap { $0.items.filter { $0.blocked == nil }.map(\.id) })
}

// MARK: plan and execute

public enum CleanOp: Sendable, Equatable {
    case trash(String, purge: Bool)
    case emptyTrash(String)
    case exec(String, [String])
}

public struct PlannedOp: Sendable {
    public var catId: String
    public var itemId: String
    public var op: CleanOp
}

public struct CleanPlan: Sendable {
    public var ops: [PlannedOp] = []
    public var denied: [String] = []
    public var skipped: [String] = []
}

public func planClean(_ cats: [CleanCategory], picked: Set<String>, env: CleanEnv) -> CleanPlan {
    var plan = CleanPlan()
    let ordered = cats.filter { $0.id == "trash" } + cats.filter { $0.id != "trash" && $0.level == .safe } + cats.filter { $0.level == .review }
    for cat in cats where cat.level == .never {
        for item in cat.items where picked.contains(item.id) { plan.skipped.append("\(item.title): никогда") }
    }
    for cat in ordered {
        var execDone = false
        for item in cat.items where picked.contains(item.id) {
            if let b = item.blocked { plan.skipped.append("\(item.title): \(b)"); continue }
            switch cat.action {
            case .none:
                plan.skipped.append("\(item.title): действие не предусмотрено")
            case .command(let tool, let args):
                guard !execDone else { continue }
                guard let path = env.findTool(tool) else { plan.skipped.append("\(cat.title): \(tool) не найден"); continue }
                execDone = true
                plan.ops.append(PlannedOp(catId: cat.id, itemId: item.id, op: .exec(path, args)))
            case .trash, .emptyTrash:
                var targets: [String] = []
                for p in item.paths {
                    if item.contentsOnly {
                        targets += childNames(p).map { p + "/" + $0 }
                    } else {
                        targets.append(p)
                    }
                }
                for t in targets {
                    if isDeniedPath(t, home: env.home) { plan.denied.append(t); continue }
                    if case .trash(let purge) = cat.action {
                        plan.ops.append(PlannedOp(catId: cat.id, itemId: item.id, op: .trash(t, purge: purge)))
                    } else {
                        plan.ops.append(PlannedOp(catId: cat.id, itemId: item.id, op: .emptyTrash(t)))
                    }
                }
            }
        }
    }
    return plan
}

public func describeOp(_ op: CleanOp) -> String {
    switch op {
    case .trash(let p, let purge): return (purge ? "trash+purge " : "trash ") + p
    case .emptyTrash(let p): return "empty-trash " + p
    case .exec(let t, let a): return "exec " + ([t] + a).joined(separator: " ")
    }
}

public struct CleanReport: Sendable {
    public var freeBefore: Int64 = 0
    public var freeAfter: Int64 = 0
    public var removedBytes: Int64 = 0
    public var trashedBytes: Int64 = 0
    public var opsOk = 0
    public var failed: [String] = []
    public var denied: [String] = []
    public var skipped: [String] = []
    public var finderFallback = false
    public var died: [String] = []
    public var aborted = false
    public var movedCount = 0
    public var purgedCount = 0
    public var doneItemIds: [String] = []
}

// Order: empty old Trash content -> move picked items into the Trash -> check dev.multitool.* services -> purge the
// moved items that are allowed to disappear -> run tool commands. A dead service stops everything after the move.
public func executeClean(_ cats: [CleanCategory], picked: Set<String>, env: CleanEnv,
                         progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) -> CleanReport {
    var rep = CleanReport()
    rep.freeBefore = freeSpaceBytes(env.home)
    let plan = planClean(cats, picked: picked, env: env)
    rep.denied = plan.denied
    rep.skipped = plan.skipped
    var failedItems = Set<String>()
    var trashFailed = false
    let total = plan.ops.count
    var step = 0

    for p in plan.ops {
        guard case .emptyTrash(let path) = p.op else { continue }
        progress(step, total, p.catId)
        step += 1
        var ok = true
        if isDeniedPath(path, home: env.home) {
            rep.denied.append(path)
            ok = false
        } else if exists(path) {
            if let err = purgeFromTrash(TrashedItem(src: path, dst: path, id: p.itemId), env: env) {
                ok = false
                rep.failed.append(err)
                trashFailed = true
            }
        }
        if ok { rep.opsOk += 1 } else { failedItems.insert(p.itemId) }
        Log.write("clean \(describeOp(p.op)): \(ok ? "ok" : "fail")")
    }
    if trashFailed, env.allowExec, env.finderEmptyTrash() {
        rep.finderFallback = true
        failedItems.subtract(plan.ops.filter { $0.catId == "trash" }.map(\.itemId))
        rep.failed.removeAll { $0.contains("/.Trash/") }
    }

    var moves: [(path: String, id: String)] = []
    var purgeById: [String: Bool] = [:]
    for p in plan.ops {
        if case .trash(let path, let purge) = p.op {
            moves.append((path, p.itemId))
            purgeById[p.itemId] = purge
        }
    }
    let before = moves.isEmpty ? [:] : parseLaunchctl(env.launchctlList())
    let moved = moveToTrash(moves, env: env, isDenied: { isDeniedPath($0, home: env.home) }, progress: { i, _, n in progress(step + i, total, n) })
    step += moves.count
    rep.denied += moved.denied
    rep.failed += moved.failed
    failedItems.formUnion(moved.failedIds)
    rep.movedCount = moved.moved.count
    rep.opsOk += moved.moved.count

    if !moved.moved.isEmpty {
        let verdict = verifyServices(before: before, env: env)
        if !verdict.died.isEmpty {
            rep.died = verdict.died
            rep.aborted = true
            rep.freeAfter = freeSpaceBytes(env.home)
            Log.write("clean aborted, died: \(verdict.died.joined(separator: ","))")
            return rep
        }
    }

    for m in moved.moved where purgeById[m.id] == true {
        if let err = purgeFromTrash(m, env: env) {
            rep.failed.append(err)
            failedItems.insert(m.id)
        } else {
            rep.purgedCount += 1
        }
    }

    for p in plan.ops {
        guard case .exec(let tool, let args) = p.op else { continue }
        progress(step, total, p.catId)
        step += 1
        var ok = true
        if !env.allowExec {
            rep.skipped.append("не запускаю: " + describeOp(p.op))
            ok = false
        } else {
            let r = env.exec(tool, args, 900)
            if r.status != 0 {
                ok = false
                rep.failed.append("\((tool as NSString).lastPathComponent) \(args.first ?? ""): код \(r.status)")
            }
        }
        if ok { rep.opsOk += 1 } else { failedItems.insert(p.itemId) }
        Log.write("clean \(describeOp(p.op)): \(ok ? "ok" : "fail")")
    }

    for cat in cats {
        for item in cat.items where picked.contains(item.id) && item.blocked == nil && !failedItems.contains(item.id) {
            guard plan.ops.contains(where: { $0.itemId == item.id }) else { continue }
            rep.doneItemIds.append(item.id)
            if case .trash(let purge) = cat.action, !purge { rep.trashedBytes += item.bytes } else { rep.removedBytes += item.bytes }
        }
    }
    rep.freeAfter = freeSpaceBytes(env.home)
    return rep
}

public func reportLines(_ r: CleanReport) -> [String] {
    var l = ["Свободно: \(fmtBytes(r.freeBefore)) → \(fmtBytes(r.freeAfter))"]
    if r.aborted {
        l.append("СТОП: после переноса в Корзину упали службы: " + r.died.joined(separator: ", "))
        l.append("Корзину не чистил, перенесено \(r.movedCount)")
        return l
    }
    if r.removedBytes > 0 { l.append("Удалено: ~\(fmtBytes(r.removedBytes))") }
    if r.trashedBytes > 0 { l.append("В Корзине: ~\(fmtBytes(r.trashedBytes)), место освободится после очистки Корзины") }
    if !r.failed.isEmpty { l.append("Не вышло: \(r.failed.count)") }
    if !r.denied.isEmpty { l.append("Отказано защитой: \(r.denied.count)") }
    return l
}

public func scanJSON(_ cats: [CleanCategory], env: CleanEnv) -> String {
    let arr: [[String: Any]] = cats.map { c in
        ["id": c.id, "title": c.title, "level": c.level.rawValue, "bytes": c.bytes, "blocked_bytes": c.blockedBytes,
         "note": c.note ?? "",
         "items": c.items.map { ["id": $0.id, "title": $0.title, "bytes": $0.bytes, "paths": $0.paths.count, "blocked": $0.blocked ?? ""] as [String: Any] }]
    }
    let obj: [String: Any] = ["free_bytes": freeSpaceBytes(env.home), "total_bytes": totalSpaceBytes(env.home), "categories": arr]
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}
