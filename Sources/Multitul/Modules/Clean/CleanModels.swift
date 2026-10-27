import SwiftUI
import AppKit
import MultitulCore

@MainActor
final class CategoryCleanModel: ObservableObject {
    let defs: [CleanDef]
    let customize: @Sendable (inout CleanEnv) -> Void

    @Published private(set) var categories: [CleanCategory] = []
    @Published var picked = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var progress = ""
    @Published private(set) var report: [String] = []
    @Published private(set) var free: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var scanned = false

    init(defs: [CleanDef], customize: @escaping @Sendable (inout CleanEnv) -> Void = { _ in }) {
        self.defs = defs
        self.customize = customize
    }

    var pickedBytes: Int64 {
        categories.filter { $0.level != .never }.flatMap(\.items).filter { picked.contains($0.id) && $0.blocked == nil }.reduce(0) { $0 + $1.bytes }
    }

    var hasPicked: Bool { pickedBytes > 0 || !picked.isEmpty }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        let defs = defs, customize = customize
        Task {
            let r = await Task.detached { () -> ([CleanCategory], Int64, Int64) in
                var env = CleanEnv.live()
                customize(&env)
                return (scanCategoriesSorted(env: env, defs: defs), freeSpaceBytes(env.home), totalSpaceBytes(env.home))
            }.value
            categories = r.0
            free = r.1
            total = r.2
            picked = defaultPicked(r.0)
            scanning = false
            scanned = true
        }
    }

    func toggle(_ item: CleanItem) {
        guard item.blocked == nil else { return }
        if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
    }

    func setCategory(_ cat: CleanCategory, on: Bool) {
        for i in cat.items where i.blocked == nil {
            if on { picked.insert(i.id) } else { picked.remove(i.id) }
        }
    }

    func clean() {
        guard !cleaning, !scanning else { return }
        cleaning = true
        report = []
        progress = "Начинаю…"
        CleanProgressHub.current = self
        let cats = categories, sel = picked, customize = customize
        Task {
            let rep = await Task.detached { () -> CleanReport in
                var env = CleanEnv.live()
                customize(&env)
                return executeClean(cats, picked: sel, env: env) { i, n, name in
                    Task { @MainActor in CleanProgressHub.set("\(i + 1) из \(n): \(name)") }
                }
            }.value
            cleaning = false
            progress = ""
            var lines = reportLines(rep)
            lines += rep.failed.prefix(5).map { "не вышло: " + $0 }
            lines += rep.skipped.prefix(5).map { "пропущено: " + $0 }
            report = lines
            scan()
        }
    }

    fileprivate func setProgress(_ s: String) { progress = s }
}

// Progress callbacks arrive from a background thread; the hub forwards them to whichever model is cleaning.
@MainActor
enum CleanProgressHub {
    static weak var current: CategoryCleanModel?
    static func set(_ s: String) { current?.setProgress(s) }
}

@MainActor
final class RamModel: ObservableObject {
    @Published private(set) var scan: RamScan?
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published var apps = Set<Int32>()
    @Published var sessions = Set<Int32>()
    @Published var orphans = Set<Int32>()
    @Published var purge = true
    @Published private(set) var result: String?

    func refresh() {
        guard !scanning, !cleaning else { return }
        scanning = true
        let front = Set(NSWorkspace.shared.runningApplications.filter(\.isActive).map(\.processIdentifier))
        let list = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { (pid: $0.processIdentifier, name: $0.localizedName ?? "") }
        Task {
            let s = await Task.detached { () -> RamScan in
                let store = FileManager.default.fileExists(atPath: MultitulPaths.dbPath) ? try? StorozhSchema.openStore(readOnly: true) : nil
                return RamClean.scan(lists: ProcessGuardLists.load(), store: store, frontPids: front, apps: list)
            }.value
            scan = s
            apps = []
            sessions = []
            orphans = Set(s.orphans.map(\.id))
            scanning = false
        }
    }

    var hasWork: Bool { purge || !apps.isEmpty || !sessions.isEmpty || !orphans.isEmpty }

    func run() {
        guard let s = scan, !cleaning else { return }
        cleaning = true
        let plan = RamPlan(orphans: s.orphans.filter { orphans.contains($0.id) },
                           sessions: s.sessions.filter { sessions.contains($0.id) },
                           apps: s.heavy.filter { apps.contains($0.id) }, purge: purge)
        Task {
            let r = await Task.detached { RamClean.perform(plan, service: ProcessGuardLists.service()) }.value
            cleaning = false
            result = r.line + (r.failed.isEmpty ? "" : "\n" + r.failed.prefix(4).joined(separator: "\n"))
            refresh()
        }
    }
}

@MainActor
final class RazborModel: ObservableObject {
    @Published private(set) var result: AnalysisResult?
    @Published private(set) var running = false
    @Published private(set) var cleaning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var progressText = ""
    @Published private(set) var elapsed = 0
    @Published var picked = Set<String>()
    @Published var expanded = Set<String>()
    @Published private(set) var report: [String] = []

    private let cancelBox = LockedBox<Bool>(false)
    private var ticker: Task<Void, Never>?
    static var cachePath: String { MultitulPaths.home + "/razbor.json" }

    init() { loadCache() }

    func loadCache() {
        guard let d = FileManager.default.contents(atPath: Self.cachePath), let r = try? JSONDecoder().decode(AnalysisResult.self, from: d) else { return }
        result = r
    }

    func run() {
        guard !running, !cleaning else { return }
        running = true
        progress = 0
        elapsed = 0
        progressText = "Начинаю…"
        picked = []
        cancelBox.mutate { $0 = false }
        let box = cancelBox
        let t0 = Date()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.elapsed = Int(Date().timeIntervalSince(t0))
            }
        }
        let hop: @Sendable (Double, String) -> Void = { [weak self] f, t in Task { @MainActor in self?.progress = f; self?.progressText = t } }
        let done: @Sendable (AnalysisResult) -> Void = { [weak self] res in Task { @MainActor in self?.finish(res) } }
        DispatchQueue.global(qos: .background).async {
            var env = AnalysisEnv.live()
            env.cancelled = { box.value }
            env.progress = hop
            done(runAnalysis(env: env))
        }
    }

    func cancel() {
        cancelBox.mutate { $0 = true }
        progressText = "Останавливаю…"
    }

    private func finish(_ res: AnalysisResult) {
        ticker?.cancel()
        running = false
        guard !res.cancelled else { return }
        result = res
        save(res)
    }

    private func save(_ r: AnalysisResult) {
        try? FileManager.default.createDirectory(atPath: MultitulPaths.home, withIntermediateDirectories: true)
        try? analysisJSON(r).write(to: URL(fileURLWithPath: Self.cachePath))
    }

    var byId: [String: AnalysisItem] {
        Dictionary((result?.allItems ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var pickedItems: [AnalysisItem] {
        guard let r = result else { return [] }
        let parentPaths = r.allItems.filter { picked.contains($0.id) && $0.selectable && $0.kind != "child" && $0.kind != "uv" }.flatMap(\.paths)
        return r.allItems.filter { it in
            guard picked.contains(it.id), it.selectable else { return false }
            return !it.paths.contains { p in parentPaths.contains { $0 != p && p.hasPrefix($0 + "/") } }
        }
    }

    var pickedBytes: Int64 { pickedItems.reduce(0) { $0 + $1.bytes } }

    func toggle(_ it: AnalysisItem) {
        guard it.selectable else { return }
        if picked.contains(it.id) { picked.remove(it.id) } else { picked.insert(it.id) }
    }

    func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean() {
        guard let r = result, !cleaning, !running else { return }
        cleaning = true
        report = []
        let sel = picked
        let items = byId
        Task {
            let rep = await Task.detached { () -> AnalysisReport in
                let env = AnalysisEnv.live()
                let plan = planAnalysisClean(r, picked: sel, env: env, index: InUseIndex.build(env))
                return executeAnalysisClean(plan, items: items, env: env)
            }.value
            cleaning = false
            report = analysisReportLines(rep) + rep.skipped.prefix(4).map { "пропущено: " + $0 } + rep.failed.prefix(4).map { "не вышло: " + $0 }
            apply(rep)
        }
    }

    private func apply(_ rep: AnalysisReport) {
        let gone = Set(rep.doneIds)
        picked = []
        guard var r = result else { return }
        r.orphans.removeAll { gone.contains($0.id) }
        r.envs.removeAll { gone.contains($0.id) }
        r.models.removeAll { gone.contains($0.id) }
        r.folders.removeAll { gone.contains($0.id) }
        for i in r.folders.indices { r.folders[i].children.removeAll { gone.contains($0.id) } }
        if gone.contains("uv:prune") { r.uv = nil }
        result = r
        save(r)
    }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var selected: InstalledApp?
    @Published private(set) var related: [Leftover] = []
    @Published var picked = Set<String>()
    @Published var query = ""
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var report: [String] = []

    func loadApps() {
        guard !loading else { return }
        loading = true
        Task {
            apps = await Task.detached { InstalledApps.live(env: CleanEnv.live()) }.value
            loading = false
        }
    }

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) || $0.bundleId.lowercased().contains(q) }
    }

    func choose(path: String) {
        guard path.hasSuffix(".app"), let app = InstalledApps.read(appPath: path) else { report = ["Это не приложение: \(path)"]; return }
        choose(app)
    }

    func choose(_ app: InstalledApp) {
        selected = app
        related = []
        picked = []
        report = []
        loading = true
        Task {
            let r = await Task.detached { () -> [Leftover] in
                let env = CleanEnv.live()
                return Uninstaller.findRelated(app: app, installed: InstalledApps.live(env: env), env: env)
            }.value
            related = r
            picked = Set(r.filter { $0.blocked == nil }.map(\.id))
            loading = false
        }
    }

    func clearSelection() {
        selected = nil
        related = []
        picked = []
    }

    func toggle(_ l: Leftover) {
        guard l.blocked == nil else { return }
        if picked.contains(l.id) { picked.remove(l.id) } else { picked.insert(l.id) }
    }

    var pickedBytes: Int64 { related.filter { picked.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    func uninstall() {
        guard let app = selected, !working else { return }
        working = true
        let items = related.filter { picked.contains($0.id) }
        Task {
            let rep = await Task.detached { Uninstaller.execute(items, app: app, env: CleanEnv.live()) }.value
            working = false
            report = Uninstaller.reportLines(rep) + rep.failed.prefix(4).map { "не вышло: " + $0 }
            let moved = Set(items.map(\.id))
            if rep.failed.isEmpty && rep.denied.isEmpty { related.removeAll { moved.contains($0.id) && $0.blocked == nil } }
            picked = []
            loadApps()
        }
    }
}
