import Foundation

public enum UpdateSource: String, CaseIterable, Sendable {
    case sparkle, appStore, homebrewCask

    public var title: String {
        switch self {
        case .sparkle: "Сайт приложения"
        case .appStore: "Mac App Store"
        case .homebrewCask: "Homebrew"
        }
    }
}

public struct UpdateAppBundle: Identifiable, Equatable, Sendable {
    public var path: String
    public var bundleId: String
    public var name: String
    public var shortVersion: String
    public var build: String
    public var feedURL: String?
    public var hasStoreReceipt: Bool

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var isSystem: Bool { path.hasPrefix("/System/") || bundleId.hasPrefix("com.apple.") }

    public init(path: String, bundleId: String, name: String, shortVersion: String = "", build: String = "", feedURL: String? = nil, hasStoreReceipt: Bool = false) {
        self.path = path
        self.bundleId = bundleId
        self.name = name
        self.shortVersion = shortVersion
        self.build = build
        self.feedURL = feedURL
        self.hasStoreReceipt = hasStoreReceipt
    }
}

public enum UpdateAppBundleReader {
    public static func parse(plist d: [String: Any], path: String, hasStoreReceipt: Bool) -> UpdateAppBundle? {
        guard let id = d["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (d["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (d["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file
        var feed = d["SUFeedURL"] as? String
        if let f = feed?.trimmingCharacters(in: .whitespacesAndNewlines) { feed = f.isEmpty ? nil : f }
        return UpdateAppBundle(path: path, bundleId: id, name: name, shortVersion: (d["CFBundleShortVersionString"] as? String) ?? "",
                             build: (d["CFBundleVersion"] as? String) ?? "", feedURL: feed, hasStoreReceipt: hasStoreReceipt)
    }
}

public protocol AppCataloging: AnyObject {
    func installedApps() -> [UpdateAppBundle]
}

public protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int)
}

@MainActor
public protocol CaskInfoProviding: AnyObject {
    func caskData() async -> (installed: [BrewPackage], outdated: [BrewOutdatedItem])
}

@MainActor
public protocol UpdateInstalling: AnyObject {
    func upgradeCask(token: String) -> Int?
    func openApp(path: String)
    func openURL(_ url: URL)
}

public struct MasOutdatedEntry: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var installed: String
    public var latest: String
}

public struct ItunesLookupResult: Equatable, Sendable {
    public var trackId: Int
    public var version: String
    public var minimumOS: String?
    public var viewURL: URL?
    public var releaseNotes: String?
    public var name: String
}

public enum AppStoreParsers {
    // `mas outdated`: "497799835 Xcode (14.0 -> 14.1)"
    public static func parseMasOutdated(_ text: String) -> [MasOutdatedEntry] {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\s+(.+?)\s+\(([^()]*?)\s*->\s*([^()]*?)\)\s*$"#) else { return [] }
        var out: [MasOutdatedEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 5, let id = Int(ns.substring(with: m.range(at: 1))) else { continue }
            out.append(MasOutdatedEntry(id: id, name: ns.substring(with: m.range(at: 2)), installed: ns.substring(with: m.range(at: 3)), latest: ns.substring(with: m.range(at: 4))))
        }
        return out
    }

    public static func lookupURL(bundleId: String, country: String) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [URLQueryItem(name: "bundleId", value: bundleId), URLQueryItem(name: "country", value: country), URLQueryItem(name: "entity", value: "macSoftware")]
        return c?.url
    }

    public static func parseLookup(_ data: Data) -> ItunesLookupResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]], let first = results.first,
              let version = first["version"] as? String, !version.isEmpty else { return nil }
        let trackId = (first["trackId"] as? NSNumber)?.intValue ?? 0
        return ItunesLookupResult(trackId: trackId, version: version, minimumOS: first["minimumOsVersion"] as? String,
                                  viewURL: (first["trackViewUrl"] as? String).flatMap(URL.init(string:)), releaseNotes: first["releaseNotes"] as? String,
                                  name: (first["trackName"] as? String) ?? "")
    }
}

public enum UpdateAction: Equatable, Sendable {
    case brewCask(token: String)
    case appStore(id: Int, masAvailable: Bool)
    case sparkle(appPath: String, download: URL?)
}

public struct AppUpdate: Identifiable, Equatable, Sendable {
    public var app: UpdateAppBundle
    public var source: UpdateSource
    public var installedVersion: String
    public var newVersion: String
    public var notesURL: URL?
    public var notesText: String?
    public var downloadURL: URL?
    public var minimumOS: String?
    public var published: Date?
    public var critical: Bool
    public var action: UpdateAction

    public var id: String { app.bundleId + "@" + newVersion }
    public var skipKey: String { app.bundleId + "@" + newVersion }
}

public struct AppUpdateSettings: Equatable, Sendable {
    public var includeAppStore = true
    public var includeBrewCasks = true
    public var includeOther = true
    public var notifyNew = true
    public var includePrerelease = false
    public var betaChannels = ""
    public var checkIntervalHours = 24
    public var storefront = "ru"
    public var maxConcurrent = 4
    public var extraFolders = ""

    public static let intervalRange = 0...168
    public static let concurrentRange = 1...8

    public init() {}

    public var sanitized: AppUpdateSettings {
        var s = self
        s.checkIntervalHours = ToolsClamp.int(s.checkIntervalHours, AppUpdateSettings.intervalRange)
        s.maxConcurrent = ToolsClamp.int(s.maxConcurrent, AppUpdateSettings.concurrentRange)
        let sf = s.storefront.lowercased().filter { $0.isASCII && $0.isLetter }
        s.storefront = sf.count == 2 ? sf : "ru"
        return s
    }

    public var channels: Set<String> {
        Set(betaChannels.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty })
    }

    public var folders: [String] {
        extraFolders.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }
}

public final class AppUpdateStore {
    private let kv: KeyValueStoring
    private let a: KVAccess
    public static let notifiedLimit = 500

    public init(_ kv: KeyValueStoring = UserDefaults.standard) {
        self.kv = kv
        a = KVAccess(kv: kv)
    }

    public func loadSettings() -> AppUpdateSettings {
        var s = AppUpdateSettings()
        let p = "appUpdates."
        s.includeAppStore = a.bool(p + "appStore", s.includeAppStore)
        s.includeBrewCasks = a.bool(p + "brewCasks", s.includeBrewCasks)
        s.includeOther = a.bool(p + "other", s.includeOther)
        s.notifyNew = a.bool(p + "notify", s.notifyNew)
        s.includePrerelease = a.bool(p + "prerelease", s.includePrerelease)
        s.betaChannels = a.string(p + "channels") ?? s.betaChannels
        s.checkIntervalHours = a.int(p + "interval", s.checkIntervalHours)
        s.storefront = a.string(p + "storefront") ?? s.storefront
        s.maxConcurrent = a.int(p + "concurrent", s.maxConcurrent)
        s.extraFolders = a.string(p + "folders") ?? s.extraFolders
        return s.sanitized
    }

    public func saveSettings(_ settings: AppUpdateSettings) {
        let b = AppUpdateSettings()
        let s = settings.sanitized
        let p = "appUpdates."
        a.put(p + "appStore", s.includeAppStore, b.includeAppStore)
        a.put(p + "brewCasks", s.includeBrewCasks, b.includeBrewCasks)
        a.put(p + "other", s.includeOther, b.includeOther)
        a.put(p + "notify", s.notifyNew, b.notifyNew)
        a.put(p + "prerelease", s.includePrerelease, b.includePrerelease)
        a.put(p + "channels", s.betaChannels, b.betaChannels)
        a.put(p + "interval", s.checkIntervalHours, b.checkIntervalHours)
        a.put(p + "storefront", s.storefront, b.storefront)
        a.put(p + "concurrent", s.maxConcurrent, b.maxConcurrent)
        a.put(p + "folders", s.extraFolders, b.extraFolders)
    }

    public var ignoredApps: Set<String> {
        get { Set(a.strings("appUpdates.ignored") ?? []) }
        set { if newValue.isEmpty { kv.removeObject(forKey: "appUpdates.ignored") } else { kv.set(newValue.sorted(), forKey: "appUpdates.ignored") } }
    }

    public var skippedVersions: Set<String> {
        get { Set(a.strings("appUpdates.skipped") ?? []) }
        set { if newValue.isEmpty { kv.removeObject(forKey: "appUpdates.skipped") } else { kv.set(newValue.sorted(), forKey: "appUpdates.skipped") } }
    }

    public var notified: [String] {
        get { a.strings("appUpdates.notified") ?? [] }
        set {
            let trimmed = Array(newValue.suffix(Self.notifiedLimit))
            if trimmed.isEmpty { kv.removeObject(forKey: "appUpdates.notified") } else { kv.set(trimmed, forKey: "appUpdates.notified") }
        }
    }

    public var lastChecked: Date? {
        get { (kv.object(forKey: "appUpdates.lastChecked") as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { if let d = newValue { kv.set(d.timeIntervalSince1970, forKey: "appUpdates.lastChecked") } else { kv.removeObject(forKey: "appUpdates.lastChecked") } }
    }
}

public struct AppUpdateReport: Equatable, Sendable {
    public var checked = 0
    public var updates: [AppUpdate] = []
    public var failures: [String: String] = [:]
    public var withoutSource = 0
    public var finishedAt: Date?

    public init() {}
}

private struct AppCheckOutcome: Sendable {
    var app: UpdateAppBundle
    var update: AppUpdate?
    var failure: String?
    var checked: Bool
}

@MainActor
public final class AppUpdateService {
    public private(set) var report = AppUpdateReport()
    public private(set) var isChecking = false
    public var settings: AppUpdateSettings
    public var onChange: (() -> Void)?
    public let queue: JobQueue
    public weak var installer: UpdateInstalling?

    private let catalog: AppCataloging
    private let http: HTTPFetching
    private let runner: ManagerRunning
    private let locator: ToolLocator
    private let casks: CaskInfoProviding?
    private let store: AppUpdateStore
    private let clock: ToolsClock
    private let osVersion: String

    public init(catalog: AppCataloging, http: HTTPFetching, runner: ManagerRunning, locator: ToolLocator, casks: CaskInfoProviding? = nil, store: AppUpdateStore,
                clock: ToolsClock = SystemToolsClock(), osVersion: String = AppUpdateService.currentOSVersion(), queue: JobQueue? = nil) {
        self.catalog = catalog
        self.http = http
        self.runner = runner
        self.locator = locator
        self.casks = casks
        self.store = store
        self.clock = clock
        self.osVersion = osVersion
        self.settings = store.loadSettings()
        self.queue = queue ?? JobQueue(maxConcurrent: 1)
    }

    public nonisolated static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public var masPath: String? { locator.find("mas") }

    public func saveSettings() { store.saveSettings(settings) }

    public var isDue: Bool {
        guard settings.checkIntervalHours > 0 else { return false }
        guard let last = store.lastChecked else { return true }
        return clock.now.timeIntervalSince(last) >= Double(settings.checkIntervalHours) * 3600
    }

    public var visibleUpdates: [AppUpdate] {
        let skipped = store.skippedVersions
        let ignored = store.ignoredApps
        return report.updates.filter { !skipped.contains($0.skipKey) && !ignored.contains($0.app.bundleId) }
    }

    public func skip(_ u: AppUpdate) {
        var s = store.skippedVersions
        s.insert(u.skipKey)
        store.skippedVersions = s
        onChange?()
    }

    public func ignoreApp(_ bundleId: String) {
        var s = store.ignoredApps
        s.insert(bundleId)
        store.ignoredApps = s
        onChange?()
    }

    public func unignoreApp(_ bundleId: String) {
        var s = store.ignoredApps
        s.remove(bundleId)
        store.ignoredApps = s
        onChange?()
    }

    public var ignoredBundleIds: [String] { store.ignoredApps.sorted() }

    public func unreportedForNotification() -> [AppUpdate] {
        guard settings.notifyNew else { return [] }
        let seen = Set(store.notified)
        return visibleUpdates.filter { !seen.contains($0.skipKey) }
    }

    public func markNotified(_ updates: [AppUpdate]) {
        store.notified = store.notified + updates.map(\.skipKey)
    }

    public static func notificationText(for updates: [AppUpdate]) -> (title: String, body: String)? {
        guard !updates.isEmpty else { return nil }
        let names = updates.prefix(4).map { "\($0.app.name) \($0.newVersion)" }.joined(separator: ", ")
        let more = updates.count > 4 ? " и ещё \(updates.count - 4)" : ""
        let title = updates.count == 1 ? "Вышло обновление" : "Вышло обновлений: \(updates.count)"
        return (title, names + more)
    }

    // MARK: checking

    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        onChange?()
        var rep = AppUpdateReport()
        var apps = catalog.installedApps().filter { !$0.isSystem }
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.path).inserted }
        let cask = (settings.includeBrewCasks && casks != nil) ? await casks?.caskData() : nil
        var masEntries: [MasOutdatedEntry]?
        if settings.includeAppStore, let mas = masPath {
            let r = await runner.run(ManagerCommand(mas, ["outdated"], timeout: 120))
            if r.ok { masEntries = AppStoreParsers.parseMasOutdated(r.stdout) }
        }
        let jobs = apps.map { plan(for: $0, cask: cask, mas: masEntries) }
        var outcomes: [AppCheckOutcome] = []
        let limit = settings.maxConcurrent
        let http = self.http, os = osVersion, st = settings
        await withTaskGroup(of: AppCheckOutcome.self) { group in
            var iterator = jobs.makeIterator()
            var active = 0
            while active < limit, let j = iterator.next() { group.addTask { await Self.run(j, http: http, os: os, settings: st) }; active += 1 }
            while let r = await group.next() {
                outcomes.append(r)
                if let j = iterator.next() { group.addTask { await Self.run(j, http: http, os: os, settings: st) } }
            }
        }
        for o in outcomes {
            if o.checked { rep.checked += 1 } else { rep.withoutSource += 1 }
            if let u = o.update { rep.updates.append(u) }
            if let f = o.failure { rep.failures[o.app.bundleId] = f }
        }
        for e in masEntries ?? [] where !rep.updates.contains(where: { $0.action == .appStore(id: e.id, masAvailable: true) }) {
            if let app = apps.first(where: { $0.name.lowercased() == e.name.lowercased() }) {
                if rep.updates.contains(where: { $0.app.path == app.path }) { continue }
                rep.updates.append(AppUpdate(app: app, source: .appStore, installedVersion: e.installed, newVersion: e.latest, notesURL: nil, notesText: nil, downloadURL: nil,
                                             minimumOS: nil, published: nil, critical: false, action: .appStore(id: e.id, masAvailable: true)))
            }
        }
        rep.updates.sort { l, r in
            if l.critical != r.critical { return l.critical }
            return l.app.name.localizedCaseInsensitiveCompare(r.app.name) == .orderedAscending
        }
        rep.finishedAt = clock.now
        store.lastChecked = clock.now
        report = rep
        isChecking = false
        onChange?()
    }

    private enum Plan: Sendable {
        case sparkle(UpdateAppBundle, URL)
        case store(UpdateAppBundle, usesMas: Bool)
        case cask(UpdateAppBundle, BrewPackage, BrewOutdatedItem?)
        case skipped(UpdateAppBundle)
    }

    private func plan(for app: UpdateAppBundle, cask: (installed: [BrewPackage], outdated: [BrewOutdatedItem])?, mas: [MasOutdatedEntry]?) -> Plan {
        if app.hasStoreReceipt {
            return settings.includeAppStore ? .store(app, usesMas: mas != nil) : .skipped(app)
        }
        if let cask, let pkg = cask.installed.first(where: { $0.kind == .cask && $0.appNames.contains(app.fileName) }) {
            let out = cask.outdated.first { $0.kind == .cask && $0.name == pkg.name }
            if out != nil || !pkg.autoUpdates { return .cask(app, pkg, out) }
        }
        if settings.includeOther, let f = app.feedURL, let u = URL(string: f), u.scheme?.hasPrefix("http") == true { return .sparkle(app, u) }
        return .skipped(app)
    }

    nonisolated private static func run(_ plan: Plan, http: HTTPFetching, os: String, settings: AppUpdateSettings) async -> AppCheckOutcome {
        switch plan {
        case .skipped(let app):
            return AppCheckOutcome(app: app, update: nil, failure: nil, checked: false)
        case .cask(let app, let pkg, let outdated):
            guard let o = outdated else { return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true) }
            let u = AppUpdate(app: app, source: .homebrewCask, installedVersion: o.installedVersion.isEmpty ? app.shortVersion : o.installedVersion, newVersion: o.currentVersion,
                              notesURL: URL(string: pkg.homepage), notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .brewCask(token: pkg.name))
            return AppCheckOutcome(app: app, update: u, failure: nil, checked: true)
        case .sparkle(let app, let url):
            do {
                let (data, status) = try await http.get(url, timeout: 20)
                guard (200..<300).contains(status) else { return AppCheckOutcome(app: app, update: nil, failure: "HTTP \(status)", checked: true) }
                let items = try AppcastParser.parse(data)
                guard let item = AppcastSelector.latest(items, osVersion: os, allowedChannels: settings.channels, includePrerelease: settings.includePrerelease) else {
                    return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true)
                }
                guard UpdateDecision.isNewer(item, installedBuild: app.build, installedShort: app.shortVersion) else {
                    return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true)
                }
                let u = AppUpdate(app: app, source: .sparkle, installedVersion: app.shortVersion.isEmpty ? app.build : app.shortVersion, newVersion: item.displayVersion,
                                  notesURL: item.releaseNotesURL ?? item.link, notesText: item.descriptionHTML, downloadURL: item.downloadURL, minimumOS: item.minimumSystemVersion,
                                  published: item.pubDate, critical: item.isCritical, action: .sparkle(appPath: app.path, download: item.downloadURL))
                return AppCheckOutcome(app: app, update: u, failure: nil, checked: true)
            } catch {
                return AppCheckOutcome(app: app, update: nil, failure: "\(error.localizedDescription)", checked: true)
            }
        case .store(let app, let usesMas):
            if usesMas { return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true) }
            guard let url = AppStoreParsers.lookupURL(bundleId: app.bundleId, country: settings.storefront) else {
                return AppCheckOutcome(app: app, update: nil, failure: "ссылка поиска", checked: true)
            }
            do {
                let (data, status) = try await http.get(url, timeout: 20)
                guard (200..<300).contains(status) else { return AppCheckOutcome(app: app, update: nil, failure: "HTTP \(status)", checked: true) }
                guard let r = AppStoreParsers.parseLookup(data) else { return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true) }
                if let min = r.minimumOS, AppVersion.isNewer(min, than: os) { return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true) }
                guard AppVersion.isNewer(r.version, than: app.shortVersion.isEmpty ? app.build : app.shortVersion) else {
                    return AppCheckOutcome(app: app, update: nil, failure: nil, checked: true)
                }
                let u = AppUpdate(app: app, source: .appStore, installedVersion: app.shortVersion, newVersion: r.version, notesURL: r.viewURL, notesText: r.releaseNotes, downloadURL: r.viewURL,
                                  minimumOS: r.minimumOS, published: nil, critical: false, action: .appStore(id: r.trackId, masAvailable: false))
                return AppCheckOutcome(app: app, update: u, failure: nil, checked: true)
            } catch {
                return AppCheckOutcome(app: app, update: nil, failure: "\(error.localizedDescription)", checked: true)
            }
        }
    }

    // MARK: installing

    public enum InstallResult: Equatable, Sendable {
        case queued(jobId: Int)
        case opened
        case unavailable(String)
    }

    @discardableResult
    public func install(_ u: AppUpdate) -> InstallResult {
        switch u.action {
        case .brewCask(let token):
            guard let id = installer?.upgradeCask(token: token) else { return .unavailable("Homebrew недоступен") }
            return .queued(jobId: id)
        case .appStore(let appId, _):
            if let mas = masPath, appId > 0 {
                let runner = self.runner
                let id = queue.enqueue(title: "App Store: \(u.app.name)", kind: "mas") { ctx in
                    let r = await runner.stream(ManagerCommand(mas, ["upgrade", String(appId)], timeout: 3600)) { line in
                        if !line.text.isEmpty { ctx.log(line.text) }
                    }
                    if r.cancelled { return .cancelled }
                    if r.ok { return .success("\(u.app.name) обновлён") }
                    let tail = r.combined.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
                    return .failure(tail.isEmpty ? "mas завершился с кодом \(r.status)" : tail)
                }
                return .queued(jobId: id)
            }
            let link = u.downloadURL ?? (appId > 0 ? URL(string: "macappstore://apps.apple.com/app/id\(appId)") : nil)
            guard let link else { return .unavailable("Нет ссылки на App Store") }
            installer?.openURL(link)
            return .opened
        case .sparkle(let path, let download):
            if let download { installer?.openURL(download) } else { installer?.openApp(path: path) }
            return .opened
        }
    }

    public func openInOwnUpdater(_ u: AppUpdate) { installer?.openApp(path: u.app.path) }
}
