import Testing
import Foundation
@testable import MultitulCore

private func cat(_ id: String, _ e: CleanEnv) -> CleanCategory { cleanerDefs.first { $0.id == id }!.run(e) }

private func launchAgent(_ f: CleanFixture, _ label: String, args: [String]) {
    let body = args.map { "<string>\($0)</string>" }.joined()
    let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string><key>ProgramArguments</key><array>\(body)</array></dict></plist>"
    let p = f.home + "/Library/LaunchAgents/" + label + ".plist"
    try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? xml.write(toFile: p, atomically: true, encoding: .utf8)
}

@Suite struct CleanerTests {
    @Test func catalogShape() {
        #expect(Set(cleanerDefs.map(\.id)).count == cleanerDefs.count)
        #expect(cleanerDefs.allSatisfy { $0.id.allSatisfy(\.isASCII) && $0.id.hasPrefix("cl-") })
        #expect(Set(cleanerDefs.map(\.id)) == ["cl-leftovers", "cl-caches", "cl-logs", "cl-login", "cl-ios", "cl-shots", "cl-whatsapp", "cl-xcode", "cl-trash"])
        for d in cleanerDefs where d.id != "cl-trash" {
            if case .trash(let purge) = d.action { #expect(!purge, "\(d.id) must keep items in the Trash") } else { Issue.record("\(d.id) action") }
        }
        if case .emptyTrash = cleanerDefs.first(where: { $0.id == "cl-trash" })!.action {} else { Issue.record("trash action") }
    }

    // MARK: leftovers

    private func leftoverFixture() -> CleanFixture {
        let f = CleanFixture()
        f.app("Keeper", id: "com.keep.app")
        let old: [(String, String)] = [
            ("Library/Containers/com.gone.old", "a"), ("Library/Application Support/com.gone.old", "a"),
            ("Library/Group Containers/ABCDE12345.com.gone.old", "a"), ("Library/Caches/com.gone.old", "a"),
            ("Library/Preferences/com.gone.old.plist", ""), ("Library/Saved Application State/com.gone.old.savedState", "a"),
        ]
        for (rel, inner) in old {
            if inner.isEmpty { f.file(rel, bytes: 5000) } else { f.file(rel + "/" + inner, bytes: 5000) }
            f.ageTree(rel, 30)
        }
        let keep: [String] = [
            "Library/Caches/com.keep.app/x", "Library/Caches/com.keep.app.helper/x", "Library/Containers/com.keep.sibling/x",
            "Library/Caches/com.apple.thing/x", "Library/Caches/dev.multitool.mine/x", "Library/Caches/com.recent.thing/x",
            "Library/Caches/com.run.app/x", "Library/Application Support/Code/x", "Library/Application Support/Slack/x",
            "Library/Caches/two.part/x", "Library/Group Containers/group.com.apple.notes/x",
        ]
        for rel in keep {
            f.file(rel, bytes: 5000)
            if !rel.contains("recent") { f.ageTree((rel as NSString).deletingLastPathComponent, 30) }
        }
        f.file("Library/Preferences/com.keep.app.plist", bytes: 100)
        f.ageTree("Library/Preferences/com.keep.app.plist", 40)
        return f
    }

    @Test func leftoversOfUninstalledAppsAreGroupedPerOwner() {
        let f = leftoverFixture()
        let c = cat("cl-leftovers", f.env(running: [RunningApp(bundleId: "com.run.app", name: "Run")]))
        #expect(c.items.map(\.title) == ["com.gone.old"])
        let paths = Set(c.items[0].paths.map { $0.replacingOccurrences(of: f.home + "/", with: "") })
        #expect(paths == ["Library/Containers/com.gone.old", "Library/Application Support/com.gone.old", "Library/Group Containers/ABCDE12345.com.gone.old",
                          "Library/Caches/com.gone.old", "Library/Preferences/com.gone.old.plist", "Library/Saved Application State/com.gone.old.savedState"])
        #expect(c.items[0].bytes >= 25_000)
    }

    @Test func leftoverFalsePositivesAreAllRejected() {
        let f = leftoverFixture()
        let e = f.env(running: [RunningApp(bundleId: "com.run.app", name: "Run")])
        let all = Set(cat("cl-leftovers", e).items.flatMap(\.paths).map { ($0 as NSString).lastPathComponent })
        for bad in ["com.keep.app", "com.keep.app.helper", "com.keep.sibling", "com.apple.thing", "dev.multitool.mine", "com.recent.thing",
                    "com.run.app", "Code", "Slack", "two.part", "group.com.apple.notes", "com.keep.app.plist"] {
            #expect(!all.contains(bad), "must not flag \(bad)")
        }
    }

    @Test func ownerIdParsing() {
        #expect(CleanerRules.ownerId(ofEntry: "com.foo.app.plist") == "com.foo.app")
        #expect(CleanerRules.ownerId(ofEntry: "com.foo.app.savedState") == "com.foo.app")
        #expect(CleanerRules.ownerId(ofEntry: "ABCDE12345.com.foo.app") == "com.foo.app")
        #expect(CleanerRules.ownerId(ofEntry: "group.com.foo.app") == "com.foo.app")
        #expect(CleanerRules.ownerId(ofEntry: "Google") == nil)
        #expect(CleanerRules.ownerId(ofEntry: "com.foo") == nil)
        #expect(CleanerRules.ownerId(ofEntry: "Some Folder.name.x") == nil)
    }

    @Test func aliveRules() {
        let apps = [InstalledApp(path: "/A/Foo.app", bundleId: "com.vendor.foo", name: "Foo")]
        #expect(CleanerRules.isAlive("com.vendor.foo", installed: apps, running: []))
        #expect(CleanerRules.isAlive("com.vendor.foo.helper", installed: apps, running: []))
        #expect(CleanerRules.isAlive("com.vendor.other", installed: apps, running: []))
        #expect(!CleanerRules.isAlive("com.else.gone", installed: apps, running: []))
        #expect(CleanerRules.isAlive("com.else.gone", installed: apps, running: [RunningApp(bundleId: "com.else.gone", name: "")]))
    }

    // MARK: login items

    @Test func orphanLoginItems() {
        let f = CleanFixture()
        let alive = f.file("Tools/alive.sh", bytes: 10)
        launchAgent(f, "com.dead.agent", args: [f.home + "/Tools/missing.sh"])
        launchAgent(f, "com.alive.agent", args: [alive])
        launchAgent(f, "com.shell.agent", args: ["/bin/bash", "-c", "echo hi"])
        launchAgent(f, "com.interp.dead", args: ["/usr/bin/env", f.home + "/Tools/gone.py"])
        launchAgent(f, "dev.multitool.mine", args: [f.home + "/Tools/missing.sh"])
        launchAgent(f, "com.apple.thing", args: ["/nonexistent/apple"])
        let c = cat("cl-login", f.env())
        #expect(Set(c.items.map(\.title)) == ["com.dead.agent", "com.interp.dead"])
        #expect(c.items.allSatisfy { $0.paths.count == 1 && $0.paths[0].hasSuffix(".plist") })
    }

    // MARK: iOS backups

    @Test func oldIosBackupsOnly() {
        let f = CleanFixture()
        func backup(_ id: String, name: String, daysAgo: Double) {
            let dir = "Library/Application Support/MobileSync/Backup/\(id)"
            f.file(dir + "/data.bin", bytes: 20_000)
            let info: [String: Any] = ["Device Name": name, "Last Backup Date": Date().addingTimeInterval(-daysAgo * 86400)]
            (info as NSDictionary).write(toFile: f.home + "/" + dir + "/Info.plist", atomically: true)
        }
        backup("AAA", name: "iPhone Старый", daysAgo: 200)
        backup("BBB", name: "iPad Новый", daysAgo: 10)
        let c = cat("cl-ios", f.env())
        #expect(c.items.map(\.title) == ["iPhone Старый"])
        var e = f.env()
        e.iosBackupDays = 5
        #expect(cat("cl-ios", e).items.count == 2)
    }

    // MARK: screenshots

    @Test func screenshotAgeIsLastOpenedNotModified() {
        let f = CleanFixture()
        let old = f.file("Desktop/Screenshot 2026-01-01 at 10.00.00.png", bytes: 9000, daysAgo: 100)
        let openedRecently = f.file("Desktop/Снимок экрана 2026-02-02.png", bytes: 9000, daysAgo: 100)
        let fresh = f.file("Desktop/Screenshot fresh.png", bytes: 9000, daysAgo: 2)
        f.file("Desktop/photo.png", bytes: 9000, daysAgo: 100)
        f.file("Desktop/Screenshot notes.txt", bytes: 100, daysAgo: 100)
        f.dir("Desktop/Screenshot folder.png")
        var e = f.env()
        e.lastOpened = { p in p == openedRecently ? Date().addingTimeInterval(-3 * 86400) : nil }
        let c = cat("cl-shots", e)
        #expect(c.items.map(\.title) == ["Screenshot 2026-01-01 at 10.00.00.png"])
        _ = (old, fresh)
        e.screenshotDays = 1
        #expect(Set(cat("cl-shots", e).items.map(\.title)) == ["Screenshot 2026-01-01 at 10.00.00.png", "Снимок экрана 2026-02-02.png", "Screenshot fresh.png"])
        e.screenshotDays = 365
        #expect(cat("cl-shots", e).items.isEmpty)
    }

    @Test func screenshotNameRules() {
        for ok in ["Screenshot 1.png", "Screen Shot 2020.jpg", "Снимок экрана 1.png", "Screen Recording 1.mov", "Запись экрана 1.mov"] { #expect(isScreenshotName(ok), "\(ok)") }
        for bad in ["photo.png", "Screenshot.txt", "my Screenshot.png", "screenshots.zip"] { #expect(!isScreenshotName(bad), "\(bad)") }
    }

    // MARK: xcode

    @Test func xcodeJunk() {
        let f = CleanFixture()
        f.file("Library/Developer/Xcode/DerivedData/App-abc/x", bytes: 30_000)
        f.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (1)/x", bytes: 30_000)
        f.file("Library/Developer/CoreSimulator/Caches/c", bytes: 30_000)
        f.file("Library/Developer/Xcode/Archives/keep/x", bytes: 30_000)
        let c = cat("cl-xcode", f.env())
        #expect(Set(c.items.map(\.id)) == ["xc-derived", "xc-devsupport", "xc-simcache"])
        #expect(c.items.allSatisfy { !$0.paths.contains { $0.contains("Archives") } })
    }

    // MARK: flow + schedule

    @Test func cleanerMovesToTrashAndKeepsItThere() {
        let f = leftoverFixture()
        let e = f.env(running: [RunningApp(bundleId: "com.run.app", name: "Run")])
        let cats = scanCategoriesSorted(env: e, defs: cleanerDefs.filter { $0.id == "cl-leftovers" })
        let rep = executeClean(cats, picked: Set(cats[0].items.map(\.id)), env: e)
        #expect(rep.movedCount == 6 && rep.purgedCount == 0)
        #expect(f.trashContents().count == 6)
        #expect(!f.exists("Library/Containers/com.gone.old"))
        #expect(f.exists("Library/Caches/com.keep.app"))
    }

    @Test func scheduleDueLogicAndPersistence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var s = CleanerSchedule(enabled: false, intervalDays: 7, lastRun: 0)
        #expect(!s.isDue(now: now))
        s.enabled = true
        #expect(s.isDue(now: now))
        s.lastRun = now.timeIntervalSince1970 - 6 * 86400
        #expect(!s.isDue(now: now))
        s.lastRun = now.timeIntervalSince1970 - 7 * 86400
        #expect(s.isDue(now: now))
        let suite = "multitul.test." + UUID().uuidString
        let d = InMemoryKeyValueStore()
        #expect(CleanerSchedule.load(d) == CleanerSchedule(enabled: false, intervalDays: 7, lastRun: 0))
        CleanerSchedule(enabled: true, intervalDays: 3, lastRun: 42).save(d)
        #expect(CleanerSchedule.load(d) == CleanerSchedule(enabled: true, intervalDays: 3, lastRun: 42))
    }

    @Test func autoCleanTouchesOnlySafeCategoriesAndNeverEmptiesTheTrash() {
        let f = CleanFixture()
        f.file(".Trash/old-thing.txt", bytes: 5000)
        f.file("Library/Caches/com.stale.app/blob", bytes: 20_000)
        f.file("Library/Logs/old.log", bytes: 9000, daysAgo: 20)
        f.file("Library/Developer/Xcode/DerivedData/A/x", bytes: 30_000)
        f.file("Desktop/Screenshot old.png", bytes: 9000, daysAgo: 400)
        f.ageTree("Library/Caches/com.gone.old", 1)
        let out = CleanerAuto.run(env: f.env())
        #expect(!out.report.aborted)
        #expect(out.report.movedCount == 3)
        #expect(out.report.purgedCount == 0)
        #expect(f.exists(".Trash/old-thing.txt"))
        #expect(f.exists("Desktop/Screenshot old.png"))
        #expect(f.trashContents().count == 4)
        #expect(out.title == "Автоочистка Мака" && out.body.contains("файлов: 3"))
    }

    @Test func autoCleanReportsNothingToDo() {
        let out = CleanerAuto.run(env: CleanFixture().env())
        #expect(out.body == "Убирать было нечего")
    }

    @Test func autoCleanStopsAndSaysSoWhenAServiceDies() {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob")
        f.services(before: [("dev.multitool.singbox", 5, 0)], after: [("dev.multitool.singbox", nil, 1)])
        let out = CleanerAuto.run(env: f.env())
        #expect(out.report.aborted)
        #expect(out.title == "Автоочистка остановлена")
    }
}
