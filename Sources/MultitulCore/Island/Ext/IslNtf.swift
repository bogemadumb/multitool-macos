import Foundation

public struct IslNtfItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var date: Date

    public init(id: String, bundleID: String = "", appName: String = "", title: String = "", subtitle: String = "", body: String = "", date: Date = Date()) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
    }

    public var isEmpty: Bool {
        [title, subtitle, body].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var dedupeKey: String {
        [bundleID, title, subtitle, body].map { IslArtworkKey.normalize($0) }.joined(separator: "\u{1F}")
    }

    public var headline: String { title.isEmpty ? (appName.isEmpty ? bundleID : appName) : title }

    public var detail: String { [subtitle, body].map(IslExtText.oneLine).filter { !$0.isEmpty }.joined(separator: " · ") }
}

public enum IslNtfSourceChoice: String, CaseIterable, Sendable {
    case auto, database, banners

    public var title: String {
        switch self {
        case .auto: "Автоматически"
        case .database: "База уведомлений (нужен полный доступ к диску)"
        case .banners: "Баннеры на экране (нужен «Универсальный доступ»)"
        }
    }
}

public struct IslNtfSettings: Equatable, Sendable {
    public static let maxItemsRange = 5...100
    public static let lifetimeRange = 2...30

    public var hideSystemBanner = false
    public var maxItems = 30
    public var activityLifetime = 6
    public var dedupeSeconds = 10
    public var showBody = true
    public var source = IslNtfSourceChoice.auto
    public var hiddenApps = Set<String>()

    public init() {}

    public var sanitized: IslNtfSettings {
        var s = self
        s.maxItems = ToolsClamp.int(maxItems, Self.maxItemsRange)
        s.activityLifetime = ToolsClamp.int(activityLifetime, Self.lifetimeRange)
        s.dedupeSeconds = ToolsClamp.int(dedupeSeconds, 0...120)
        s.hiddenApps = hiddenApps.filter { !$0.isEmpty && $0.count <= 200 }
        return s
    }
}

public final class IslNtfSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.notifications."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslNtfSettings {
        var s = IslNtfSettings()
        let p = Self.prefix
        s.hideSystemBanner = a.bool(p + "hideSystemBanner", s.hideSystemBanner)
        s.maxItems = a.int(p + "maxItems", s.maxItems)
        s.activityLifetime = a.int(p + "activityLifetime", s.activityLifetime)
        s.dedupeSeconds = a.int(p + "dedupeSeconds", s.dedupeSeconds)
        s.showBody = a.bool(p + "showBody", s.showBody)
        if let v = a.string(p + "source"), let m = IslNtfSourceChoice(rawValue: v) { s.source = m }
        s.hiddenApps = Set(a.strings(p + "hiddenApps") ?? [])
        return s.sanitized
    }

    public func save(_ settings: IslNtfSettings) {
        let s = settings.sanitized
        let b = IslNtfSettings()
        let p = Self.prefix
        a.put(p + "hideSystemBanner", s.hideSystemBanner, b.hideSystemBanner)
        a.put(p + "maxItems", s.maxItems, b.maxItems)
        a.put(p + "activityLifetime", s.activityLifetime, b.activityLifetime)
        a.put(p + "dedupeSeconds", s.dedupeSeconds, b.dedupeSeconds)
        a.put(p + "source", s.source.rawValue, b.source.rawValue)
        a.put(p + "showBody", s.showBody, b.showBody)
        if s.hiddenApps.isEmpty { a.kv.removeObject(forKey: p + "hiddenApps") } else { a.kv.set(s.hiddenApps.sorted(), forKey: p + "hiddenApps") }
    }
}

public enum IslNtfSourceHealth: Equatable, Sendable {
    case ok
    case needsFullDiskAccess
    case missing
    case failed(String)
}

public protocol IslNtfSource: AnyObject {
    var health: IslNtfSourceHealth { get }
    func prime()
    func poll() -> [IslNtfItem]
}

// In-memory only: lock clears everything, nothing is persisted.
public struct IslNtfCenter: Sendable {
    public private(set) var items: [IslNtfItem] = []
    public private(set) var latest: IslNtfItem?
    public private(set) var latestAt: Date?
    private var recent: [String: Date] = [:]
    public var ownBundleIDs: Set<String> = ["dev.multitool.app"]

    public init() {}

    @discardableResult
    public mutating func ingest(_ incoming: [IslNtfItem], now: Date, settings: IslNtfSettings) -> [IslNtfItem] {
        var added: [IslNtfItem] = []
        recent = recent.filter { now.timeIntervalSince($0.value) < Double(max(settings.dedupeSeconds, 1)) }
        for item in incoming.sorted(by: { $0.date < $1.date }) {
            guard !item.isEmpty, !ownBundleIDs.contains(item.bundleID), !settings.hiddenApps.contains(item.bundleID) else { continue }
            if items.contains(where: { $0.id == item.id }) { continue }
            if settings.dedupeSeconds > 0, let last = recent[item.dedupeKey], now.timeIntervalSince(last) < Double(settings.dedupeSeconds) { continue }
            recent[item.dedupeKey] = now
            items.insert(item, at: 0)
            added.append(item)
            latest = item
            latestAt = now
        }
        if items.count > settings.maxItems { items.removeLast(items.count - settings.maxItems) }
        return added
    }

    public mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if latest?.id == id { latest = nil; latestAt = nil }
    }

    public mutating func clear() {
        items = []
        latest = nil
        latestAt = nil
        recent = [:]
    }

    public func activity(now: Date, settings: IslNtfSettings) -> IslActivity? {
        guard let l = latest, let at = latestAt, now >= at, now.timeIntervalSince(at) < Double(settings.activityLifetime) else { return nil }
        return IslActivity(id: "notification", section: IslSectionIDs.notifications, priority: IslPriority.notification, startedAt: at,
                           expiresAt: at.addingTimeInterval(Double(settings.activityLifetime)), peeks: true, token: l.id, title: l.headline)
    }

    public func grouped() -> [(bundleID: String, appName: String, items: [IslNtfItem])] {
        var order: [String] = []
        var map: [String: [IslNtfItem]] = [:]
        for i in items {
            if map[i.bundleID] == nil { order.append(i.bundleID) }
            map[i.bundleID, default: []].append(i)
        }
        return order.map { b in (b, map[b]?.first?.appName ?? b, map[b] ?? []) }
    }
}

public enum IslNtfPlist {
    static func string(_ any: Any?) -> String { (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    // usernoted record blob: a binary plist with the request ("req") holding titl / subt / body.
    public static func item(from blob: Data, recID: Int64, bundleID: String?, delivered: Double?) -> IslNtfItem? {
        guard let root = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any] else { return nil }
        let req = (root["req"] as? [String: Any]) ?? root
        let bundle = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? string(root["app"])
        var date = Date()
        if let d = delivered, d > 0 { date = Date(timeIntervalSinceReferenceDate: d) }
        else if let d = root["date"] as? Date { date = d }
        let item = IslNtfItem(id: "rec-\(recID)", bundleID: bundle, appName: "", title: string(req["titl"]), subtitle: string(req["subt"]), body: string(req["body"]), date: date)
        return item.isEmpty ? nil : item
    }
}

public final class IslNtfDBReader: IslNtfSource {
    public static let candidatePaths: [String] = [
        "Library/Group Containers/group.com.apple.usernoted/db2/db",
        "Library/Application Support/NotificationCenter/db2/db"
    ]

    public private(set) var health = IslNtfSourceHealth.ok
    public let path: String
    private let copyFirst: Bool
    private let scratch: String
    private var lastRecID: Int64 = 0
    private let fm = FileManager.default

    public init(path: String, copyFirst: Bool = true, scratchDir: String = NSTemporaryDirectory() + "multitul-ntf") {
        self.path = path
        self.copyFirst = copyFirst
        self.scratch = scratchDir
    }

    public static func defaultPath(home: String = NSHomeDirectory(), exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        candidatePaths.map { home + "/" + $0 }.first(where: exists)
    }

    private func openStore() -> (Store, cleanup: () -> Void)? {
        guard fm.fileExists(atPath: path) else { health = .missing; return nil }
        var target = path
        var cleanup: () -> Void = {}
        if copyFirst {
            let dir = scratch + "/" + UUID().uuidString
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                    try fm.copyItem(atPath: path + suffix, toPath: dir + "/db" + suffix)
                }
                target = dir + "/db"
                cleanup = { try? FileManager.default.removeItem(atPath: dir) }
            } catch {
                health = .needsFullDiskAccess
                return nil
            }
        }
        do {
            let s = try Store(path: target, migrations: [], retention: [], readOnly: copyFirst ? false : true)
            return (s, cleanup)
        } catch {
            cleanup()
            health = copyFirst ? .failed("\(error)") : .needsFullDiskAccess
            return nil
        }
    }

    public func prime() {
        guard let (store, cleanup) = openStore() else { return }
        defer { cleanup() }
        lastRecID = (try? store.scalarInt("SELECT COALESCE(MAX(rec_id), 0) FROM record")) ?? 0
        health = .ok
    }

    public func poll() -> [IslNtfItem] {
        guard let (store, cleanup) = openStore() else { return [] }
        defer { cleanup() }
        do {
            let rows = try store.query("""
                SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r LEFT JOIN app a ON a.app_id = r.app_id
                WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 100
                """, [.int(lastRecID)])
            health = .ok
            var out: [IslNtfItem] = []
            for r in rows {
                let id = r.int(0) ?? 0
                lastRecID = max(lastRecID, id)
                guard let blob = r.data(2), var item = IslNtfPlist.item(from: blob, recID: id, bundleID: r.string(1), delivered: r.double(3)) else { continue }
                item.appName = IslNtfNames.fallbackName(item.bundleID)
                out.append(item)
            }
            return out
        } catch {
            health = .failed("\(error)")
            return []
        }
    }
}

public enum IslNtfNames {
    // com.apple.MobileSMS -> MobileSMS; the live layer replaces this with the localized app name.
    public static func fallbackName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

public enum IslNtfBannerParser {
    // Static texts of a banner in reading order: [title, body], [title, subtitle, body] or a lone body.
    public static func item(texts: [String], appName: String, bundleID: String, now: Date, counter: Int) -> IslNtfItem? {
        let t = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !t.isEmpty else { return nil }
        var title = "", subtitle = "", body = ""
        switch t.count {
        case 1: body = t[0]
        case 2: (title, body) = (t[0], t[1])
        default: (title, subtitle, body) = (t[0], t[1], t[2...].joined(separator: " "))
        }
        if title == appName, !subtitle.isEmpty || !body.isEmpty { title = subtitle.isEmpty ? "" : subtitle; subtitle = "" }
        return IslNtfItem(id: "ax-\(Int(now.timeIntervalSince1970 * 1000))-\(counter)", bundleID: bundleID, appName: appName, title: title, subtitle: subtitle, body: body, date: now)
    }
}
