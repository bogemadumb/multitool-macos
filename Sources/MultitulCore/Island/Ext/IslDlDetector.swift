import Foundation

public enum IslDlState: String, Equatable, Sendable { case downloading, stalled, completed, cancelled }

public struct IslDlItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tempName: String?
    public var browser: IslDlBrowser
    public var state: IslDlState
    public var bytes: Int64
    public var expectedTotal: Int64?
    public var startedAt: Date
    public var lastGrowthAt: Date
    public var finishedAt: Date?
    public var speed: Double

    public var progress: Double? {
        if state == .completed { return 1 }
        guard let t = expectedTotal, t > 0 else { return nil }
        return min(max(Double(bytes) / Double(t), 0), 1)
    }

    public var isActive: Bool { state == .downloading || state == .stalled }
}

public enum IslDlEvent: Equatable, Sendable {
    case started(IslDlItem)
    case stalled(IslDlItem)
    case finished(IslDlItem)
    case cancelled(IslDlItem)
}

public struct IslDlDetectorConfig: Equatable, Sendable {
    public var stallAfter: TimeInterval = 15
    public var dropAfter: TimeInterval = 600
    public var plainStableAfter: TimeInterval = 2
    public var minPlainBytes: Int64 = 64 * 1024
    public var trackPlainFiles = true
    public var historyLimit = 12
    public var cancelledLifetime: TimeInterval = 4

    public init() {}
}

public struct IslDlDetector: Sendable {
    public var config = IslDlDetectorConfig()
    public private(set) var items: [IslDlItem] = []
    private var baseline = Set<String>()
    private var previous: [String: IslDlFile] = [:]
    private var primed = false
    private var plainSeen: [String: (size: Int64, since: Date)] = [:]
    private var consumed = Set<String>()
    private var lastScan: Date?

    public init(config: IslDlDetectorConfig = IslDlDetectorConfig()) { self.config = config }

    public var active: [IslDlItem] { items.filter(\.isActive) }

    public var recentFinished: [IslDlItem] {
        items.filter { $0.state == .completed }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    public mutating func reset() { self = IslDlDetector(config: config) }

    public mutating func scan(_ files: [IslDlFile], now: Date) -> [IslDlEvent] {
        var events: [IslDlEvent] = []
        let dt = lastScan.map { max(now.timeIntervalSince($0), 0.001) } ?? 1
        lastScan = now
        var byName: [String: IslDlFile] = [:]
        for f in files { byName[f.name] = f }

        if !primed {
            baseline = Set(files.filter { !IslDlRules.isTemp($0.name) }.map(\.name))
            primed = true
        }

        for f in files where IslDlRules.isTemp(f.name) {
            if let i = items.firstIndex(where: { $0.tempName == f.name && $0.isActive }) {
                var it = items[i]
                if f.size > it.bytes {
                    let rate = Double(f.size - it.bytes) / dt
                    it.speed = it.speed == 0 ? rate : it.speed * 0.5 + rate * 0.5
                    it.lastGrowthAt = now
                    it.state = .downloading
                } else {
                    it.speed *= 0.5
                    if now.timeIntervalSince(it.lastGrowthAt) >= config.stallAfter, it.state != .stalled {
                        it.state = .stalled
                        it.speed = 0
                        items[i] = it
                        events.append(.stalled(it))
                        continue
                    }
                }
                it.bytes = f.size
                if let t = f.expectedTotal { it.expectedTotal = t }
                items[i] = it
            } else {
                let it = IslDlItem(id: "t|" + f.name, name: IslDlRules.displayName(forTemp: f.name), tempName: f.name, browser: IslDlRules.browser(forTemp: f.name), state: .downloading,
                                   bytes: f.size, expectedTotal: f.expectedTotal, startedAt: now, lastGrowthAt: now, finishedAt: nil, speed: 0)
                items.removeAll { $0.id == it.id }
                items.append(it)
                events.append(.started(it))
            }
        }

        for i in items.indices where items[i].isActive {
            guard let temp = items[i].tempName, byName[temp] == nil else { continue }
            var it = items[i]
            if let done = completionCandidate(for: it, byName: byName) {
                it.name = done.name
                it.bytes = done.size
                it.state = .completed
                it.finishedAt = now
                it.expectedTotal = done.size
                consumed.insert(done.name)
                items[i] = it
                events.append(.finished(it))
            } else {
                it.state = .cancelled
                it.finishedAt = now
                items[i] = it
                events.append(.cancelled(it))
            }
        }

        if config.trackPlainFiles {
            for f in files where !IslDlRules.isTemp(f.name) && !IslDlRules.isIgnored(f.name) {
                if baseline.contains(f.name) || consumed.contains(f.name) { continue }
                if items.contains(where: { $0.id == "f|" + f.name }) { continue }
                if previous[f.name] != nil || plainSeen[f.name] != nil {
                    var seen = plainSeen[f.name] ?? (f.size, now)
                    if seen.size != f.size { seen = (f.size, now) }
                    plainSeen[f.name] = seen
                    if now.timeIntervalSince(seen.since) >= config.plainStableAfter, f.size >= config.minPlainBytes {
                        var it = IslDlItem(id: "f|" + f.name, name: f.name, tempName: nil, browser: .other, state: .completed, bytes: f.size, expectedTotal: f.size,
                                           startedAt: seen.since, lastGrowthAt: seen.since, finishedAt: now, speed: 0)
                        it.finishedAt = now
                        items.append(it)
                        events.append(.finished(it))
                        plainSeen[f.name] = nil
                    } else if now.timeIntervalSince(seen.since) >= config.plainStableAfter {
                        plainSeen[f.name] = nil
                        baseline.insert(f.name)
                    }
                } else {
                    plainSeen[f.name] = (f.size, now)
                }
            }
        }

        for i in items.indices where items[i].isActive && now.timeIntervalSince(items[i].lastGrowthAt) >= config.dropAfter {
            items[i].state = .cancelled
            items[i].finishedAt = now
            events.append(.cancelled(items[i]))
        }

        items.removeAll { $0.state == .cancelled && ($0.finishedAt.map { now.timeIntervalSince($0) >= config.cancelledLifetime } ?? true) }
        trimHistory()
        previous = byName
        for k in plainSeen.keys where byName[k] == nil { plainSeen[k] = nil }
        consumed = consumed.filter { byName[$0] != nil }
        return events
    }

    private func completionCandidate(for it: IslDlItem, byName: [String: IslDlFile]) -> IslDlFile? {
        if let n = it.tempName.flatMap(IslDlRules.finalName(ofTemp:)), let f = byName[n], !IslDlRules.isTemp(f.name) { return f }
        if it.tempName.flatMap(IslDlRules.finalName(ofTemp:)) != nil { return nil }
        let candidates = byName.values.filter { f in
            !IslDlRules.isTemp(f.name) && !IslDlRules.isIgnored(f.name) && previous[f.name] == nil && !baseline.contains(f.name) && !consumed.contains(f.name)
                && f.modified >= it.startedAt.addingTimeInterval(-2)
        }
        return candidates.max { $0.modified < $1.modified }
    }

    private mutating func trimHistory() {
        let done = items.filter { !$0.isActive }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        let keep = Set(done.prefix(config.historyLimit).map(\.id))
        items.removeAll { !$0.isActive && !keep.contains($0.id) }
    }
}

public struct IslDlSummary: Equatable, Sendable {
    public var count: Int
    public var bytes: Int64
    public var speed: Double
    public var progress: Double?
    public var title: String
}

public enum IslDlActivityFactory {
    public static let doneLifetime: TimeInterval = 6

    public static func summary(_ items: [IslDlItem]) -> IslDlSummary? {
        let active = items.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        let bytes = active.reduce(Int64(0)) { $0 + $1.bytes }
        let speed = active.reduce(0) { $0 + $1.speed }
        var progress: Double?
        let totals = active.compactMap(\.expectedTotal)
        if totals.count == active.count, totals.reduce(0, +) > 0 { progress = min(Double(bytes) / Double(totals.reduce(0, +)), 1) }
        let title = active.count == 1 ? active[0].name : "\(active.count) загрузки"
        return IslDlSummary(count: active.count, bytes: bytes, speed: speed, progress: progress, title: title)
    }

    public static func activity(_ items: [IslDlItem], now: Date) -> IslActivity? {
        if let s = summary(items) {
            let first = items.filter(\.isActive).min { $0.startedAt < $1.startedAt }
            return IslActivity(id: "download", section: IslSectionIDs.downloads, priority: IslPriority.download, startedAt: first?.startedAt ?? now, peeks: true,
                               token: "run|" + items.filter(\.isActive).map(\.id).sorted().joined(separator: ","), title: s.title)
        }
        guard let done = items.filter({ $0.state == .completed }).max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }),
              let at = done.finishedAt, now >= at, now.timeIntervalSince(at) < doneLifetime else { return nil }
        return IslActivity(id: "download", section: IslSectionIDs.downloads, priority: IslPriority.download, startedAt: at, expiresAt: at.addingTimeInterval(doneLifetime), peeks: true,
                           token: "done|" + done.id, title: done.name)
    }
}

public struct IslDlSettings: Equatable, Sendable {
    public var folder = ""
    public var showCompleted = true
    public var trackPlainFiles = true
    public var minPlainKB = 64

    public init() {}

    public var sanitized: IslDlSettings {
        var s = self
        s.minPlainKB = ToolsClamp.int(minPlainKB, 0...102_400)
        s.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    public func resolvedFolder(home: String = NSHomeDirectory()) -> String {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return home + "/Downloads" }
        if f == "~" { return home }
        if f.hasPrefix("~/") { return home + String(f.dropFirst(1)) }
        return f
    }

    public var detectorConfig: IslDlDetectorConfig {
        var c = IslDlDetectorConfig()
        c.trackPlainFiles = trackPlainFiles
        c.minPlainBytes = Int64(minPlainKB) * 1024
        return c
    }
}

public final class IslDlSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.downloads."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslDlSettings {
        var s = IslDlSettings()
        let p = Self.prefix
        s.folder = a.string(p + "folder") ?? s.folder
        s.showCompleted = a.bool(p + "showCompleted", s.showCompleted)
        s.trackPlainFiles = a.bool(p + "trackPlainFiles", s.trackPlainFiles)
        s.minPlainKB = a.int(p + "minPlainKB", s.minPlainKB)
        return s.sanitized
    }

    public func save(_ settings: IslDlSettings) {
        let s = settings.sanitized
        let b = IslDlSettings()
        let p = Self.prefix
        a.put(p + "folder", s.folder, b.folder)
        a.put(p + "showCompleted", s.showCompleted, b.showCompleted)
        a.put(p + "trackPlainFiles", s.trackPlainFiles, b.trackPlainFiles)
        a.put(p + "minPlainKB", s.minPlainKB, b.minPlainKB)
    }
}

public protocol IslDlListing: AnyObject {
    func list(_ folder: String) -> [IslDlFile]?
}

public protocol IslDlWatching: AnyObject {
    func start(path: String, onChange: @escaping () -> Void)
    func stop()
}

public final class IslDlMonitor {
    public private(set) var detector: IslDlDetector
    public private(set) var settings: IslDlSettings
    public private(set) var readable = true
    public var onEvents: (([IslDlEvent]) -> Void)?
    private let lister: IslDlListing
    private let watcher: IslDlWatching
    private let clock: () -> Date
    private var running = false
    private var lastTick = Date.distantPast
    public var idleInterval: TimeInterval = 5
    public var activeInterval: TimeInterval = 1

    public init(lister: IslDlListing, watcher: IslDlWatching, settings: IslDlSettings = IslDlSettings(), clock: @escaping () -> Date = Date.init) {
        self.lister = lister
        self.watcher = watcher
        self.settings = settings.sanitized
        self.clock = clock
        detector = IslDlDetector(config: settings.sanitized.detectorConfig)
    }

    public func start() {
        guard !running else { return }
        running = true
        detector = IslDlDetector(config: settings.detectorConfig)
        scan()
        watcher.start(path: settings.resolvedFolder()) { [weak self] in self?.scan() }
    }

    public func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        detector.reset()
    }

    public func update(_ s: IslDlSettings) {
        let old = settings
        settings = s.sanitized
        guard running, old.resolvedFolder() != settings.resolvedFolder() || old.detectorConfig != settings.detectorConfig else { return }
        stop()
        start()
    }

    public func tick() {
        guard running else { return }
        let now = clock()
        let interval = detector.active.isEmpty ? idleInterval : activeInterval
        if now.timeIntervalSince(lastTick) >= interval || now < lastTick { scan() }
    }

    public func scan() {
        guard running else { return }
        let now = clock()
        lastTick = now
        guard let files = lister.list(settings.resolvedFolder()) else {
            readable = false
            return
        }
        readable = true
        let events = detector.scan(files, now: now)
        if !events.isEmpty { onEvents?(events) }
    }

    public func activity(now: Date) -> IslActivity? {
        IslDlActivityFactory.activity(detector.items.filter { settings.showCompleted || $0.isActive }, now: now)
    }
}
