import Foundation

// "Cleaner": everything is listed first, everything but the Trash goes to the Trash and stays there.
public enum CleanerRules {
    static let bundleLike = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$"#)

    static func looksLikeBundleId(_ s: String) -> Bool {
        bundleLike.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // "ABCDE12345.com.foo.app" and "group.com.foo.app" -> "com.foo.app"; ".plist"/".savedState"/".binarycookies" are cut off.
    public static func ownerId(ofEntry name: String) -> String? {
        var n = name
        for ext in [".plist", ".savedState", ".binarycookies-journal", ".binarycookies", ".lockfile"] where n.hasSuffix(ext) {
            n = String(n.dropLast(ext.count))
        }
        if n.hasPrefix("group.") { n = String(n.dropFirst(6)) }
        if let r = n.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) { n = String(n[r.upperBound...]) }
        return looksLikeBundleId(n) ? n : nil
    }

    static func vendorKey(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    // True when the id belongs to something that is still installed or running (the app itself, its helper, a same-vendor sibling).
    public static func isAlive(_ id: String, installed: [InstalledApp], running: [RunningApp]) -> Bool {
        let i = id.lowercased()
        let vendors = Set(installed.map { vendorKey($0.bundleId) })
        if vendors.contains(vendorKey(i)) { return true }
        for a in installed {
            let b = a.bundleId.lowercased()
            if i == b || i.hasPrefix(b + ".") || b.hasPrefix(i + ".") { return true }
        }
        return running.contains { r in
            let b = r.bundleId.lowercased()
            return i == b || i.hasPrefix(b + ".") || b.hasPrefix(i + ".")
        }
    }

    static let leftoverDirs = ["Library/Containers", "Library/Group Containers", "Library/Application Support", "Library/Caches", "Library/Preferences",
                               "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/Logs"]

    static let skipPrefixes = ["com.apple.", "dev.multitool.", "group.com.apple.", "systemgroup.", "com.openai.", "com.anthropic."]

    static let screenshotPrefixes = ["screenshot", "screen shot", "снимок экрана", "screen recording", "запись экрана"]
    static let screenshotExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "mp4"]

    static let interpreters: Set<String> = ["bash", "sh", "zsh", "env", "python", "python3", "node", "osascript", "open", "ruby", "perl", "caffeinate"]
}

func scanLeftovers(_ e: CleanEnv) -> [CleanItem] {
    let installed = InstalledApps.live(env: e)
    let limit = e.now.addingTimeInterval(-Double(e.leftoverMinAgeDays) * 86400)
    var groups: [String: (paths: [String], bytes: Int64)] = [:]
    for rel in CleanerRules.leftoverDirs {
        let dir = e.path(rel)
        for n in childNames(dir) {
            guard let id = CleanerRules.ownerId(ofEntry: n) else { continue }
            let l = id.lowercased()
            if CleanerRules.skipPrefixes.contains(where: { l.hasPrefix($0) }) { continue }
            if CleanerRules.isAlive(id, installed: installed, running: e.running) { continue }
            let p = dir + "/" + n
            let st = scanTree(p)
            if st.newestFile > limit { continue }
            var g = groups[l] ?? ([], 0)
            g.paths.append(p)
            g.bytes += st.bytes
            groups[l] = g
        }
    }
    return groups.map { id, g in
        CleanItem(id: "left-" + id, title: id, subtitle: "приложения нет, осталось: \(g.paths.count)", bytes: g.bytes, paths: g.paths)
    }.sorted { $0.bytes > $1.bytes }
}

func orphanProgramPath(_ plist: [String: Any]) -> String? {
    var args = plist["ProgramArguments"] as? [String] ?? []
    if let prog = plist["Program"] as? String { args.insert(prog, at: 0) }
    for a in args {
        guard a.hasPrefix("/"), !a.contains(" ") else { continue }
        if CleanerRules.interpreters.contains((a as NSString).lastPathComponent) { continue }
        return a
    }
    return nil
}

func scanOrphanLoginItems(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Library/LaunchAgents")
    var items: [CleanItem] = []
    for n in childNames(dir) where n.hasSuffix(".plist") {
        let label = String(n.dropLast(6))
        let l = label.lowercased()
        if l.hasPrefix("com.apple.") || l.hasPrefix("dev.multitool.") { continue }
        let p = dir + "/" + n
        guard let d = NSDictionary(contentsOfFile: p) as? [String: Any], let prog = orphanProgramPath(d), !exists(prog) else { continue }
        items.append(CleanItem(id: "login-" + label, title: label, subtitle: "нет файла \(prog)", bytes: scanTree(p).bytes, paths: [p]))
    }
    return items
}

func scanIosBackups(_ e: CleanEnv) -> [CleanItem] {
    let dir = e.path("Library/Application Support/MobileSync/Backup")
    let limit = e.now.addingTimeInterval(-Double(e.iosBackupDays) * 86400)
    var items: [CleanItem] = []
    for n in childNames(dir) where !n.hasPrefix(".") {
        let p = dir + "/" + n
        guard isRealDir(p) else { continue }
        let info = NSDictionary(contentsOfFile: p + "/Info.plist") as? [String: Any]
        let last = (info?["Last Backup Date"] as? Date) ?? scanTree(p).newestFile
        guard last < limit else { continue }
        let device = (info?["Device Name"] as? String) ?? n
        items.append(CleanItem(id: "ios-" + n, title: device, subtitle: "копия \(days(last, e.now)) дн. назад", bytes: scanTree(p).bytes, paths: [p]))
    }
    return items.sorted { $0.bytes > $1.bytes }
}

func isScreenshotName(_ name: String) -> Bool {
    let l = norm(name)
    guard CleanerRules.screenshotPrefixes.contains(where: { l.hasPrefix($0) }) else { return false }
    return CleanerRules.screenshotExts.contains((l as NSString).pathExtension)
}

func scanScreenshots(_ e: CleanEnv) -> [CleanItem] {
    let limit = e.now.addingTimeInterval(-Double(e.screenshotDays) * 86400)
    var items: [CleanItem] = []
    for dir in e.screenshotDirs {
        for n in childNames(dir) where isScreenshotName(n) {
            let p = dir + "/" + n
            guard !isRealDir(p), let st = lstatInfo(p), !st.isLink else { continue }
            let opened = e.lastOpened(p) ?? Date(timeIntervalSince1970: max(st.atime, st.mtime))
            guard opened < limit else { continue }
            items.append(CleanItem(id: "shot-" + n, title: n, subtitle: "не открывали \(days(opened, e.now)) дн.", bytes: st.alloc, paths: [p]))
        }
    }
    return items.sorted { $0.bytes > $1.bytes }
}

func scanXcodeJunk(_ e: CleanEnv) -> [CleanItem] {
    var items: [CleanItem] = []
    for (id, title, rel) in [("derived", "DerivedData", "Library/Developer/Xcode/DerivedData"),
                             ("devsupport", "iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport"),
                             ("simcache", "CoreSimulator: кэши", "Library/Developer/CoreSimulator/Caches")] {
        let dir = e.path(rel)
        var paths: [String] = []
        var bytes: Int64 = 0
        for n in childNames(dir) {
            paths.append(dir + "/" + n)
            bytes += scanTree(dir + "/" + n).bytes
        }
        if !paths.isEmpty { items.append(CleanItem(id: "xc-" + id, title: title, bytes: bytes, paths: paths)) }
    }
    return items
}

private func renamed(_ prefix: String, _ items: [CleanItem]) -> [CleanItem] {
    items.map { var i = $0; i.id = prefix + i.id; return i }
}

public let cleanerDefs: [CleanDef] = [
    CleanDef(id: "cl-leftovers", title: "Остатки удалённых приложений", subtitle: "контейнеры, настройки и кэши без приложения; свежие и запущенные не трогаются",
             level: .review, action: .trash(purge: false), scan: scanLeftovers),
    CleanDef(id: "cl-caches", title: "Кэши приложений", subtitle: "кроме запущенных и системных", level: .safe, action: .trash(purge: false),
             scan: { renamed("cl-", scanSystemCaches($0)) }),
    CleanDef(id: "cl-logs", title: "Логи старше 7 дней", subtitle: "~/Library/Logs", level: .safe, action: .trash(purge: false),
             scan: { renamed("cl-", scanOldLogs($0)) }),
    CleanDef(id: "cl-login", title: "Бесхозные пункты автозапуска", subtitle: "LaunchAgents, у которых нет программы", level: .review, action: .trash(purge: false),
             scan: scanOrphanLoginItems),
    CleanDef(id: "cl-ios", title: "Старые бэкапы iPhone и iPad", subtitle: "старше срока в настройках", level: .review, action: .trash(purge: false), scan: scanIosBackups),
    CleanDef(id: "cl-shots", title: "Забытые скриншоты", subtitle: "не открывались дольше срока в настройках", level: .review, action: .trash(purge: false), scan: scanScreenshots),
    CleanDef(id: "cl-whatsapp", title: "Скачанное из WhatsApp", subtitle: "фото, видео, голосовые и документы старше срока хранения по типам; свежие и недавно открытые не трогаются",
             level: .review, action: .trash(purge: false), scan: scanWhatsApp),
    CleanDef(id: "cl-xcode", title: "Мусор Xcode", subtitle: "DerivedData, DeviceSupport, кэши симулятора", level: .safe, action: .trash(purge: false), scan: scanXcodeJunk),
    CleanDef(id: "cl-trash", title: "Корзина", subtitle: "удаляется насовсем", level: .review, action: .emptyTrash,
             scan: { renamed("cl-", scanTrash($0)) }),
]

// MARK: schedule

public struct CleanerSchedule: Equatable, Sendable {
    public var enabled = false
    public var intervalDays = 7
    public var lastRun: Double = 0

    public init(enabled: Bool = false, intervalDays: Int = 7, lastRun: Double = 0) {
        self.enabled = enabled
        self.intervalDays = intervalDays
        self.lastRun = lastRun
    }

    public static let enabledKey = "cleaner.auto.enabled"
    public static let intervalKey = "cleaner.auto.intervalDays"
    public static let lastRunKey = "cleaner.auto.lastRun"
    // Auto-clean touches only what comes back by itself; the Trash is never emptied on a timer.
    public static let autoCategories: Set<String> = ["cl-caches", "cl-logs", "cl-xcode"]

    public static func load(_ d: KeyValueStoring = UserDefaults.standard) -> CleanerSchedule {
        let days = (d.object(forKey: intervalKey) as? Int) ?? 7
        return CleanerSchedule(enabled: d.bool(forKey: enabledKey), intervalDays: max(days, 1), lastRun: d.double(forKey: lastRunKey))
    }

    public func save(_ d: KeyValueStoring = UserDefaults.standard) {
        d.set(enabled, forKey: Self.enabledKey)
        d.set(intervalDays, forKey: Self.intervalKey)
        d.set(lastRun, forKey: Self.lastRunKey)
    }

    public func isDue(now: Date) -> Bool {
        enabled && now.timeIntervalSince1970 - lastRun >= Double(intervalDays) * 86400
    }
}

public struct AutoCleanOutcome: Sendable {
    public var report: CleanReport
    public var title: String
    public var body: String
}

public enum CleanerAuto {
    // Blocking. Scans the safe categories, moves everything unblocked to the Trash, returns the text for a notification.
    public static func run(env: CleanEnv) -> AutoCleanOutcome {
        let defs = cleanerDefs.filter { CleanerSchedule.autoCategories.contains($0.id) }
        let cats = scanCategoriesSorted(env: env, defs: defs)
        let picked = defaultPicked(cats)
        let rep = executeClean(cats, picked: picked, env: env)
        if rep.aborted {
            return AutoCleanOutcome(report: rep, title: "Автоочистка остановлена", body: "После переноса в Корзину упали службы: " + rep.died.joined(separator: ", "))
        }
        return AutoCleanOutcome(report: rep, title: "Автоочистка Мака",
                                body: rep.movedCount == 0 ? "Убирать было нечего" : "В Корзину ушло ~\(fmtBytes(rep.trashedBytes)), файлов: \(rep.movedCount)")
    }
}
