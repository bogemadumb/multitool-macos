import Foundation

// Multitul --sun [--date YYYY-MM-DD] | --wallpaper-status | --wallpaper-selftest
//          | --migrate-wallpapers (--dry-run | --yes) [--from DIR] [--to DIR]
public enum WallpaperCLI {
    public static let flags = ["--sun", "--wallpaper-status", "--wallpaper-selftest", "--migrate-wallpapers"]

    public static func handles(_ args: [String]) -> Bool { args.contains { flags.contains($0) } }

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let k = args.firstIndex(of: flag), args.count > k + 1 else { return nil }
        return args[k + 1]
    }

    public static func run(arguments a: [String], defaults: KeyValueStoring = UserDefaults.standard, now: Date = Date(), dir: String = WallpaperFiles.dir,
                           out: (String) -> Void, err: (String) -> Void) -> Int32 {
        if a.contains("--sun") { return sun(a, now: now, out: out, err: err) }
        if a.contains("--wallpaper-status") { return status(defaults: defaults, now: now, dir: dir, out: out) }
        if a.contains("--wallpaper-selftest") { return selfTest(now: now, out: out) }
        if a.contains("--migrate-wallpapers") { return migrate(a, dir: dir, out: out, err: err) }
        return 2
    }

    static func sun(_ a: [String], now: Date, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let s = SunCalc.spb
        var at = now
        if let ds = value(a, "--date") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = s.location.timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let d = f.date(from: ds + " 12:00") else {
                err("usage: Multitul --sun [--date YYYY-MM-DD]")
                return 2
            }
            at = d
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = s.location.timeZone
        f.dateFormat = "yyyy-MM-dd"
        out("Санкт-Петербург (59.94 N, 30.31 E), \(f.string(from: at)) MSK")
        guard let e = s.events(on: at) else {
            out(s.polarState(on: at) == .midnightSun ? "полярный день: солнце не заходит" : "полярная ночь: солнце не восходит")
            return 0
        }
        out("рассвет \(s.hhmmss(e.rise)), закат \(s.hhmmss(e.set))")
        out("сейчас: \(s.isDay(at) ? "день" : "ночь"), следующее переключение: \(s.nextEvent(after: at).map(s.hhmmss) ?? "—")")
        return 0
    }

    static func status(defaults: KeyValueStoring, now: Date, dir: String, out: (String) -> Void) -> Int32 {
        let st = WallpaperSettings(defaults)
        let sun = SunCalc.spb
        let day = WallpaperSelection.isDay(mode: st.dayMode, sun: sun, now: now)
        let videos = WallpaperFiles.scanNames(dir)
        let aerial = WallpaperFiles.scanNames(dir + "/aerial")
        let pick = WallpaperSelection.pick(color: st.color, day: day, videos: videos)
        out("color=\(st.color.rawValue) dayMode=\(st.dayMode.rawValue) pauseOnBattery=\(st.pauseOnBattery) manualPause=\(st.manualPause) lockFollows=\(st.lockFollows)")
        out("сейчас \(day ? "день" : "ночь"); ролик обоев: \(pick.map { $0.name + ($0.standard ? "" : " (не стандартный, первый по имени)") } ?? "нет роликов")")
        out("папка: \(dir) — роликов: \(videos.count); стандартные: \(videos.keys.filter(WallpaperFiles.standardNames.contains).sorted())")
        let paths = AerialPaths(storeDir: dir)
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        out("экран блокировки: записано «\(st.lockVideo ?? "—")»; клипы aerial: \(aerial.keys.filter(WallpaperFiles.standardNames.contains).sorted()); копия оригинала: \(FileManager.default.fileExists(atPath: paths.originalVideo) ? "есть" : "нет"); macOS \(osMajor) \(AerialLockscreen.versionError(major: osMajor) == nil ? "поддерживается" : "не поддерживается")")
        out("выключенные экраны: \(st.excludedScreens.sorted())")
        return 0
    }

    static func selfTest(now: Date, out: (String) -> Void) -> Int32 {
        let std = ["cls-white-night", "cls-black-night", "cls-white-day", "cls-black-day"]
        let sets: [(String, Set<String>)] = [
            ("все четыре", Set(std)),
            ("только ночные", ["cls-white-night", "cls-black-night"]),
            ("только cls-black-night", ["cls-black-night"]),
            ("только cls-white-day", ["cls-white-day"]),
            ("ни одного", [])
        ]
        for (label, set) in sets {
            var row: [String] = []
            for c in WallpaperColor.allCases {
                for day in [false, true] {
                    row.append("\(c.rawValue)/\(day ? "день" : "ночь")=\(WallpaperSelection.resolveName(color: c, day: day, available: set) ?? "legacy")")
                }
            }
            out("\(label): " + row.joined(separator: "  "))
        }
        let sun = SunCalc.spb
        var ok = true
        if let e = sun.events(on: now), let n = sun.nextEvent(after: now) {
            let sane = e.rise < e.set && n > now
            ok = ok && sane
            out("солнце: рассвет \(sun.hhmm(e.rise)), закат \(sun.hhmm(e.set)), следующее \(sun.hhmmss(n)) — \(sane ? "ок" : "ОШИБКА")")
        } else {
            ok = false
            out("солнце: нет событий для СПб — ОШИБКА")
        }
        let polar = SunCalc(location: SunLocation(lat: 69.65, lon: 18.96, tzIdentifier: "Europe/Oslo"))
        var comps = DateComponents(year: 2026, month: 6, day: 21, hour: 12)
        comps.timeZone = polar.location.timeZone
        if let d = Calendar(identifier: .gregorian).date(from: comps) {
            let good = polar.events(on: d) == nil && polar.isDay(d) && polar.nextRefresh(after: d) <= d.addingTimeInterval(86400)
            ok = ok && good
            out("полярный день (Тромсё, 21.06): \(good ? "ок" : "ОШИБКА")")
        }
        let r = PauseInputs()
        out("пауза: чистый вход играет=\(r.shouldPlay)")
        return ok ? 0 : 1
    }

    static func migrate(_ a: [String], dir: String, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let dry = a.contains("--dry-run")
        guard dry || a.contains("--yes") else {
            err("refused: --migrate-wallpapers needs --dry-run or --yes")
            return 2
        }
        let from = value(a, "--from") ?? WallpaperMigration.defaultOldRoot
        let to = value(a, "--to") ?? dir
        let plan = WallpaperMigration.plan(oldRoot: from, newRoot: to, freeBytes: WallpaperMigration.freeBytes(at: to))
        if plan.missingSource {
            err("нет папки старых обоев: \(from)")
            return 1
        }
        for it in plan.items { out(WallpaperMigration.describe(it)) }
        out("копировать: \(plan.toCopy.count) файлов, \(plan.copyBytes) Б; уже на месте: \(plan.items.filter { $0.action == .skipSame }.count); конфликтов: \(plan.conflicts.count); места хватает: \(plan.enoughSpace ? "да" : "нет")")
        if dry { return 0 }
        guard plan.enoughSpace else {
            err("мало места")
            return 1
        }
        let r = WallpaperMigration.execute(plan)
        for f in r.failed { out("failed: " + f) }
        out("скопировано: \(r.copied.count), ошибок: \(r.failed.count)")
        return r.failed.isEmpty ? 0 : 1
    }
}
