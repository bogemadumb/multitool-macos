import Foundation

public enum BrewAvailability: Equatable, Sendable {
    case available(String)
    case missing

    public var path: String? {
        if case .available(let p) = self { return p }
        return nil
    }
}

public protocol TerminalOpening: AnyObject {
    func open(command: String) -> Bool
}

public struct BrewSnapshot: Equatable, Sendable {
    public var packages: [BrewPackage] = []
    public var outdated: [BrewOutdatedItem] = []
    public var leaves: Set<String> = []
    public var services: [BrewServiceInfo] = []
    public var orphans: [String] = []
    public var cleanup: BrewCleanupReport?
    public var loadedAt: Date?

    public init() {}

    public var formulae: [BrewPackage] { packages.filter { $0.kind == .formula } }
    public var casks: [BrewPackage] { packages.filter { $0.kind == .cask } }
    public var leafPackages: [BrewPackage] { formulae.filter { leaves.contains($0.name) } }
    public var dependencyPackages: [BrewPackage] { formulae.filter { !leaves.contains($0.name) } }
    public var outdatedCount: Int { outdated.count }
    public var pinnedPackages: [BrewPackage] { packages.filter(\.pinned) }

    public func outdatedItem(for p: BrewPackage) -> BrewOutdatedItem? { outdated.first { $0.kind == p.kind && $0.name == p.name } }
}

private final class TrackerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = BrewProgressTracker()

    func feed(_ line: String) -> (Double?, String) {
        lock.lock(); defer { lock.unlock() }
        tracker.feed(line)
        return (tracker.fraction, tracker.statusLine)
    }

    func finish() -> BrewProgressTracker {
        lock.lock(); defer { lock.unlock() }
        tracker.finishAll()
        return tracker
    }

    var current: BrewProgressTracker { lock.lock(); defer { lock.unlock() }; return tracker }
}

@MainActor
public final class BrewManager {
    public let queue: JobQueue
    public private(set) var availability = BrewAvailability.missing
    public private(set) var snapshot = BrewSnapshot()
    public private(set) var searchResults: [BrewSearchResult] = []
    public private(set) var lastFailure: BrewFailure?
    public private(set) var isRefreshing = false
    public private(set) var terminalLines: [Int: String] = [:]
    public var settings: BrewSettings
    public var onChange: (() -> Void)?
    public weak var terminal: TerminalOpening?

    private let runner: ManagerRunning
    private let locator: ToolLocator
    private let clock: ToolsClock
    private var refreshAfterIdle = false

    public init(runner: ManagerRunning, locator: ToolLocator, queue: JobQueue? = nil, settings: BrewSettings = BrewSettings(),
                clock: ToolsClock = SystemToolsClock()) {
        self.runner = runner
        self.locator = locator
        let q = queue ?? JobQueue(maxConcurrent: 1)
        self.queue = q
        self.settings = settings
        self.clock = clock
        q.onFinish = { [weak self] snap in
            guard let self else { return }
            Task { @MainActor in await self.jobFinished(snap) }
        }
        q.onChange = { [weak self] in self?.onChange?() }
    }

    @discardableResult
    public func detect() -> BrewAvailability {
        availability = locator.find("brew").map { .available($0) } ?? .missing
        return availability
    }

    public var commands: BrewCommands? {
        availability.path.map { BrewCommands(brewPath: $0, autoUpdate: settings.autoUpdateIndex) }
    }

    private func fail(_ f: BrewFailure) {
        lastFailure = f
        onChange?()
    }

    private func requireCommands() -> BrewCommands? {
        if commands == nil { detect() }
        guard let c = commands else {
            fail(BrewFailure(kind: .missingBrew, message: "brew не найден в \(locator.directories.joined(separator: ", "))", blockers: []))
            return nil
        }
        return c
    }

    private func exec(_ c: ManagerCommand) async -> ManagerResult {
        guard !c.runsAsRootEscalation else { return ManagerResult(status: 126, stderr: "Error: sudo is not allowed") }
        return await runner.run(c)
    }

    // MARK: reading

    public func refresh() async {
        guard let c = requireCommands(), !isRefreshing else { return }
        isRefreshing = true
        onChange?()
        async let installedR = exec(c.installedInfo())
        async let outdatedR = exec(c.outdated(greedy: settings.includeGreedy))
        async let leavesR = exec(c.leaves())
        async let servicesR = exec(c.servicesList())
        let (ri, ro, rl, rs) = await (installedR, outdatedR, leavesR, servicesR)
        var snap = snapshot
        var failure: BrewFailure?

        if ri.ok {
            do { snap.packages = try BrewParsers.parseInfo(ri.stdout) } catch { failure = BrewFailure(kind: .other, message: "Не удалось разобрать ответ brew info", blockers: []) }
        } else {
            failure = BrewErrorClassifier.classify(ri.combined, status: ri.status, timedOut: ri.timedOut)
        }
        if ro.ok {
            do { snap.outdated = try BrewParsers.parseOutdated(ro.stdout) } catch { failure = failure ?? BrewFailure(kind: .other, message: "Не удалось разобрать ответ brew outdated", blockers: []) }
        } else if failure == nil {
            failure = BrewErrorClassifier.classify(ro.combined, status: ro.status, timedOut: ro.timedOut)
        }
        if rl.ok { snap.leaves = Set(BrewParsers.parseNameList(rl.stdout)) }
        if rs.ok { snap.services = (try? BrewParsers.parseServices(rs.stdout)) ?? [] } else { snap.services = [] }

        let outdatedKeys = Set(snap.outdated.map { $0.kind.rawValue + ":" + $0.name })
        for i in snap.packages.indices {
            let p = snap.packages[i]
            if outdatedKeys.contains(p.kind.rawValue + ":" + p.name) { snap.packages[i].outdated = true }
            if let o = snap.outdated.first(where: { $0.kind == p.kind && $0.name == p.name }), o.pinned { snap.packages[i].pinned = true }
        }
        snap.loadedAt = clock.now
        snapshot = snap
        lastFailure = failure
        isRefreshing = false
        onChange?()
    }

    public func search(_ query: String) async {
        guard let c = requireCommands() else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; onChange?(); return }
        guard let cmd = try? c.search(q, descriptions: settings.searchWithDescriptions) else {
            fail(BrewFailure(kind: .other, message: "Недопустимый запрос", blockers: []))
            return
        }
        let r = await exec(cmd)
        if r.cancelled { return }
        if r.status != 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = BrewErrorClassifier.classify(r.combined, status: r.status, timedOut: r.timedOut)
            if f.kind == .notFound || r.combined.lowercased().contains("no formula or cask found") { searchResults = [] } else { lastFailure = f }
            onChange?()
            return
        }
        searchResults = Array(BrewParsers.parseSearch(r.stdout).prefix(settings.searchLimit))
        onChange?()
    }

    public func details(of name: String, kind: BrewKind) async -> BrewPackage? {
        guard let c = requireCommands(), let cmd = try? c.info(name, kind: kind) else { return nil }
        let r = await exec(cmd)
        guard r.ok, let list = try? BrewParsers.parseInfo(r.stdout) else { return nil }
        return list.first { $0.kind == kind } ?? list.first
    }

    public func dependencyTree(of name: String) async -> BrewDepNode? {
        guard let c = requireCommands(), let cmd = try? c.depsTree(name) else { return nil }
        let r = await exec(cmd)
        return r.ok ? BrewParsers.parseDepsTree(r.stdout) : nil
    }

    public func dependents(of name: String) async -> [String] {
        guard let c = requireCommands(), let cmd = try? c.uses(name) else { return [] }
        let r = await exec(cmd)
        return r.ok ? BrewParsers.parseNameList(r.stdout) : []
    }

    public func previewOrphans() async {
        guard let c = requireCommands() else { return }
        let r = await exec(c.autoremove(dryRun: true))
        guard r.ok else { fail(BrewErrorClassifier.classify(r.combined, status: r.status, timedOut: r.timedOut)); return }
        snapshot.orphans = BrewParsers.parseAutoremove(r.stdout + "\n" + r.stderr)
        onChange?()
    }

    public func previewCleanup(pruneAll: Bool = false) async {
        guard let c = requireCommands() else { return }
        let r = await exec(c.cleanup(dryRun: true, pruneAll: pruneAll))
        guard r.ok else { fail(BrewErrorClassifier.classify(r.combined, status: r.status, timedOut: r.timedOut)); return }
        snapshot.cleanup = BrewParsers.parseCleanup(r.stdout)
        onChange?()
    }

    // MARK: writing

    nonisolated public static func outcome(for result: ManagerResult, tracker: BrewProgressTracker, doneText: String) -> JobOutcome {
        if result.cancelled { return .cancelled }
        if result.ok && tracker.errors.isEmpty { return .success(doneText) }
        var text = result.combined
        if tracker.needsPassword && !BrewProgressParser.isPasswordPrompt(text) { text += "\nsudo: a terminal is required" }
        if result.ok { text = tracker.errors.map { "Error: " + $0 }.joined(separator: "\n") }
        return .failure(BrewErrorClassifier.classify(text, status: result.status, timedOut: result.timedOut).summary)
    }

    private func makeWork(_ cmd: ManagerCommand, done: String) -> JobWork {
        let runner = self.runner
        return { ctx in
            if cmd.runsAsRootEscalation { return .failure("sudo не допускается") }
            let box = TrackerBox()
            let result = await runner.stream(cmd) { line in
                guard !line.text.isEmpty else { return }
                ctx.log(line.text)
                let (frac, status) = box.feed(line.text)
                ctx.setProgress(frac, detail: status)
            }
            return BrewManager.outcome(for: result, tracker: box.finish(), doneText: done)
        }
    }

    @discardableResult
    private func enqueue(_ title: String, kind: String, _ cmd: ManagerCommand, done: String) -> Int {
        let id = queue.enqueue(title: title, kind: kind, work: makeWork(cmd, done: done))
        if let c = commands { terminalLines[id] = c.terminalLine(cmd) }
        return id
    }

    private func guarded(_ build: (BrewCommands) throws -> (String, String, ManagerCommand, String)) -> Int? {
        guard let c = requireCommands() else { return nil }
        do {
            let (title, kind, cmd, done) = try build(c)
            if settings.preferTerminalForCasks, kind.hasSuffix("cask") { return openInTerminalInstead(title: title, kind: kind, cmd: cmd) }
            return enqueue(title, kind: kind, cmd, done: done)
        } catch {
            fail(BrewFailure(kind: .other, message: "Недопустимое имя пакета", blockers: []))
            return nil
        }
    }

    // Cask installs often ask for sudo; with the setting on they go to Terminal and the queue only records the hand-off.
    private func openInTerminalInstead(title: String, kind: String, cmd: ManagerCommand) -> Int? {
        let line = commands?.terminalLine(cmd) ?? ""
        let opened = terminal?.open(command: line) ?? false
        let id = queue.enqueue(title: title, kind: kind) { _ in opened ? .success("Открыто в Terminal") : .failure("Не удалось открыть Terminal") }
        terminalLines[id] = line
        return id
    }

    @discardableResult
    public func install(_ name: String, kind: BrewKind) -> Int? {
        guarded { c in ("Установка \(name)", "install-\(kind.rawValue)", try c.install(name, kind: kind), "\(name) установлен") }
    }

    @discardableResult
    public func uninstall(_ name: String, kind: BrewKind, zap: Bool = false, ignoreDependencies: Bool = false) -> Int? {
        guarded { c in ("Удаление \(name)", "uninstall-\(kind.rawValue)", try c.uninstall(name, kind: kind, zap: zap, ignoreDependencies: ignoreDependencies), "\(name) удалён") }
    }

    @discardableResult
    public func upgrade(_ name: String, kind: BrewKind) -> Int? {
        guarded { c in ("Обновление \(name)", "upgrade-\(kind.rawValue)", try c.upgrade([name], kind: kind, greedy: settings.includeGreedy), "\(name) обновлён") }
    }

    @discardableResult
    public func upgradeAll() -> Int? {
        guarded { c in ("Обновление всего", "upgrade-all", c.upgradeAll(greedy: settings.includeGreedy), "Всё обновлено") }
    }

    @discardableResult
    public func updateIndex() -> Int? {
        guarded { c in ("Обновление списка пакетов", "update", c.update(), "Список пакетов обновлён") }
    }

    @discardableResult
    public func setPinned(_ name: String, pinned: Bool) -> Int? {
        guarded { c in (pinned ? "Закрепление \(name)" : "Открепление \(name)", "pin", try c.pin(name, pinned: pinned), pinned ? "\(name) закреплён" : "\(name) откреплён") }
    }

    @discardableResult
    public func service(_ action: BrewServiceAction, name: String) -> Int? {
        guarded { c in ("\(action.title): \(name)", "service", try c.service(action, name: name), "\(name): готово") }
    }

    @discardableResult
    public func cleanup(pruneAll: Bool = false) -> Int? {
        guarded { c in ("Очистка кэша brew", "cleanup", c.cleanup(dryRun: false, pruneAll: pruneAll), "Кэш очищен") }
    }

    @discardableResult
    public func removeOrphans() -> Int? {
        guarded { c in ("Удаление лишних зависимостей", "autoremove", c.autoremove(dryRun: false), "Лишние зависимости удалены") }
    }

    public func openInTerminal(job id: Int) -> Bool {
        guard let line = terminalLines[id] else { return false }
        return terminal?.open(command: line) ?? false
    }

    public func openInstallerInTerminal() -> Bool { terminal?.open(command: BrewCommands.installCommand) ?? false }

    private func jobFinished(_ snap: JobSnapshot) async {
        refreshAfterIdle = true
        if settings.cleanupAfterUpgrade, case .succeeded = snap.state, snap.kind.hasPrefix("upgrade"), !queue.isBusy, let c = requireCommands() {
            queue.enqueue(title: "Очистка кэша brew", kind: "cleanup", work: makeWork(c.cleanup(dryRun: false), done: "Кэш очищен"))
            return
        }
        if refreshAfterIdle && !queue.isBusy {
            refreshAfterIdle = false
            await refresh()
        }
    }
}

extension BrewManager: CaskInfoProviding {
    public func caskData() async -> (installed: [BrewPackage], outdated: [BrewOutdatedItem]) {
        if availability.path == nil { detect() }
        let stale = snapshot.loadedAt.map { clock.now.timeIntervalSince($0) > 300 } ?? true
        if stale && availability.path != nil { await refresh() }
        return (snapshot.casks, snapshot.outdated.filter { $0.kind == .cask })
    }
}
