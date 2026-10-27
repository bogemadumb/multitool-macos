import Foundation

public enum LeftoverKind: String, Sendable, CaseIterable {
    case app, container, groupContainer, appSupport, caches, preferences, logs, launchAgent
    case savedState, httpStorage, webkit, cookies, appScripts, receipt, system

    public var title: String {
        switch self {
        case .app: "Приложение"
        case .container: "Контейнер"
        case .groupContainer: "Общий контейнер"
        case .appSupport: "Application Support"
        case .caches: "Кэши"
        case .preferences: "Настройки"
        case .logs: "Логи"
        case .launchAgent: "LaunchAgent"
        case .savedState: "Сохранённое состояние"
        case .httpStorage: "HTTPStorages"
        case .webkit: "WebKit"
        case .cookies: "Cookies"
        case .appScripts: "Скрипты"
        case .receipt: "Чек установки"
        case .system: "Системная папка"
        }
    }
}

public struct Leftover: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var kind: LeftoverKind
    public var path: String
    public var bytes: Int64
    public var blocked: String?

    public var title: String { (path as NSString).lastPathComponent }
}

public struct UninstallReport: Sendable {
    public var freeBefore: Int64 = 0
    public var freeAfter: Int64 = 0
    public var movedCount = 0
    public var movedBytes: Int64 = 0
    public var failed: [String] = []
    public var denied: [String] = []
    public var skipped: [String] = []
    public var diedServices: [String] = []
}

public enum Uninstaller {
    // Folders whose name equals a common word must not be claimed by an app only because of its display name.
    static let systemSupportNames: Set<String> = [
        "addressbook", "calendars", "caches", "clouddocs", "knowledge", "mobilesync", "crashreporter", "icloud", "dock", "safari", "mail",
        "messages", "notes", "photos", "music", "tv", "podcasts", "books", "maps", "reminders", "contacts", "calendar", "finder", "preview",
        "quicklook", "siri", "spotlight", "animoji", "networkserviceproxy", "differentialprivacy", "fileprovider", "homekit", "metadata",
        "code", "google", "microsoft", "adobe", "jetbrains", "docker", "default", "shared", "temp", "tmp", "logs", "data", "app", "apps",
    ]

    private typealias Spec = (rel: String, kind: LeftoverKind, byName: Bool)

    private static let userSpecs: [Spec] = [
        ("Library/Containers", .container, false),
        ("Library/Group Containers", .groupContainer, false),
        ("Library/Application Support", .appSupport, true),
        ("Library/Caches", .caches, true),
        ("Library/Preferences", .preferences, false),
        ("Library/Preferences/ByHost", .preferences, false),
        ("Library/Logs", .logs, true),
        ("Library/LaunchAgents", .launchAgent, false),
        ("Library/Saved Application State", .savedState, false),
        ("Library/HTTPStorages", .httpStorage, false),
        ("Library/WebKit", .webkit, false),
        ("Library/Cookies", .cookies, false),
        ("Library/Application Scripts", .appScripts, false),
    ]

    private static let systemSpecs: [Spec] = [
        ("Library/LaunchAgents", .system, false),
        ("Library/LaunchDaemons", .system, false),
        ("Library/PrivilegedHelperTools", .system, false),
        ("Library/Application Support", .system, true),
        ("private/var/db/receipts", .receipt, false),
    ]

    // Bundle id as the whole name, as a dotted prefix (id.plist, id.savedState, id.helper), as a team-prefixed suffix
    // (ABCDE12345.id) or as the group.id form. Ids without a dot are too loose to match by.
    static func idMatches(_ name: String, id: String) -> Bool {
        let n = norm(name), i = norm(id)
        guard i.contains(".") else { return false }
        return n == i || n.hasPrefix(i + ".") || n.hasSuffix("." + i) || n == "group." + i || n.hasPrefix("group." + i + ".")
    }

    // A longer id of another installed app that claims the same name wins (com.foo.app vs com.foo.app.pro).
    static func claimedByOther(_ name: String, id: String, others: [InstalledApp]) -> Bool {
        let i = norm(id)
        return others.contains { o in
            let oi = norm(o.bundleId)
            return oi != i && oi.count > i.count && idMatches(name, id: oi)
        }
    }

    static func nameMatches(_ entry: String, app: InstalledApp) -> Bool {
        let n = norm(entry), a = norm(app.name)
        guard a.count >= 3, n == a, !systemSupportNames.contains(a) else { return false }
        return true
    }

    public static func findRelated(app: InstalledApp, installed: [InstalledApp], env: CleanEnv, systemRoot: String = "") -> [Leftover] {
        var out: [Leftover] = []
        let running = env.running.contains { $0.bundleId.lowercased() == app.bundleId.lowercased() }
        let appBlocked: String? = app.protection ?? (running ? "закрой приложение" : nil)
        out.append(Leftover(kind: .app, path: app.path, bytes: scanTree(app.path).bytes, blocked: appBlocked))
        let others = installed.filter { $0.path != app.path && norm($0.bundleId) != norm(app.bundleId) }
        let sameName = others.contains { norm($0.name) == norm(app.name) }
        let blockAll: String? = app.protection ?? (running ? "закрой приложение" : nil)

        func collect(_ dir: String, _ specs: Spec, system: Bool) {
            for n in childNames(dir) {
                let byId = idMatches(n, id: app.bundleId) && !claimedByOther(n, id: app.bundleId, others: others)
                let byName = specs.byName && !sameName && nameMatches(n, app: app)
                guard byId || byName else { continue }
                let p = dir + "/" + n
                out.append(Leftover(kind: specs.kind, path: p, bytes: scanTree(p).bytes,
                                    blocked: system ? "нужен администратор, убери вручную" : blockAll))
            }
        }
        for s in userSpecs { collect(env.home + "/" + s.rel, s, system: false) }
        for s in systemSpecs { collect(systemRoot + "/" + s.rel, s, system: true) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    // Everything the uninstaller may move: the app bundle in an applications folder, or an entry inside ~/Library.
    public static func isDenied(_ path: String, home: String, appDirs: [String]) -> Bool {
        let std = URL(fileURLWithPath: path).standardized.path
        let name = (std as NSString).lastPathComponent
        if name.lowercased().hasPrefix("com.apple.") { return true }
        if std.hasSuffix(".app") {
            let parent = (std as NSString).deletingLastPathComponent
            let allowed = appDirs.filter { !$0.hasPrefix("/System/") }
            guard allowed.contains(where: { URL(fileURLWithPath: $0).standardized.path == parent }) else { return true }
            guard let a = InstalledApps.read(appPath: std) else { return true }
            return a.protection != nil
        }
        let h = canonicalPath(home)
        let c = canonicalPath(std)
        guard c.hasPrefix(h + "/Library/") else { return true }
        let rel = norm(String(c.dropFirst(h.count + 1)))
        if rel.split(separator: "/").count < 3 && !rel.hasPrefix("library/preferences/") { return true }
        return isDeniedPath(std, home: home)
    }

    public static func execute(_ items: [Leftover], app: InstalledApp, env: CleanEnv,
                               progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) -> UninstallReport {
        var rep = UninstallReport()
        rep.freeBefore = freeSpaceBytes(env.home)
        var moves: [(path: String, id: String)] = []
        for it in items {
            if let b = it.blocked { rep.skipped.append("\(it.title): \(b)"); continue }
            moves.append((it.path, it.path))
        }
        let before = moves.isEmpty ? [:] : parseLaunchctl(env.launchctlList())
        let r = moveToTrash(moves, env: env, isDenied: { isDenied($0, home: env.home, appDirs: env.appDirs) }, progress: progress)
        rep.denied = r.denied
        rep.failed = r.failed
        rep.movedCount = r.moved.count
        let bytes = Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        rep.movedBytes = r.moved.reduce(0) { $0 + (bytes[$1.src] ?? 0) }
        if !r.moved.isEmpty { rep.diedServices = verifyServices(before: before, env: env).died }
        rep.freeAfter = freeSpaceBytes(env.home)
        return rep
    }

    public static func reportLines(_ r: UninstallReport) -> [String] {
        var l = ["Перенесено в Корзину: \(r.movedCount), ~\(fmtBytes(r.movedBytes))"]
        if !r.diedServices.isEmpty { l.append("ВНИМАНИЕ: после переноса остановились службы: " + r.diedServices.joined(separator: ", ")) }
        if !r.failed.isEmpty { l.append("Не вышло: \(r.failed.count)") }
        if !r.denied.isEmpty { l.append("Отказано защитой: \(r.denied.count)") }
        if !r.skipped.isEmpty { l.append("Пропущено: \(r.skipped.count)") }
        return l
    }
}
