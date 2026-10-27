import Testing
import Foundation
@testable import MultitulCore

private func cat(_ id: String, _ e: CleanEnv) -> CleanCategory {
    (cleanDefs + cleanerDefs).first { $0.id == id }!.run(e)
}

@Suite struct DiskCleanTests {
    @Test func categoriesAreClassifiedIntoThreeLevels() {
        let by = Dictionary(grouping: cleanDefs, by: \.level)
        #expect(Set((by[.safe] ?? []).map(\.id)) == ["trash", "caches", "logs", "xcode", "vscode", "chrome", "claude-versions", "npm", "brew", "pip"])
        #expect(Set((by[.review] ?? []).map(\.id)) == ["docker", "telegram", "downloads", "hf", "playwright"])
        #expect(Set((by[.never] ?? []).map(\.id)) == ["never-uv", "never-system", "never-claude"])
        #expect(Set(cleanDefs.map(\.id)).count == cleanDefs.count)
        #expect(cleanDefs.allSatisfy { $0.id.allSatisfy(\.isASCII) })
        for d in by[.never] ?? [] { if case .none = d.action {} else { Issue.record("never category \(d.id) has an action") } }
        #expect(cleanDefs.first?.id == "trash")
    }

    @Test func userFilesLandInTrashAndStayThere() {
        func keeps(_ id: String) -> Bool {
            if case .trash(let purge) = cleanDefs.first(where: { $0.id == id })!.action { return !purge }
            return false
        }
        #expect(keeps("downloads"))
        #expect(keeps("hf"))
        #expect(!keeps("caches"))
        #expect(!keeps("telegram"))
    }

    @Test func denylistCoversProtectedPaths() {
        let f = CleanFixture()
        let h = f.home
        for rel in [".cache/uv", ".cache/uv/archive-v0/x", "Documents/Система", "Documents/Система/доступы/пароли.py", ".claude",
                    ".claude/projects/a", "Library/Mail", "Library/Mail/V10/x", "Documents", "Documents/Универ/работа.docx",
                    "Documents/Scratch", "Documents/Личное", "Library", "Library/Caches", "Downloads", ".local/bin/claude", ".ssh/id_rsa", "Desktop"] {
            #expect(isDeniedPath(h + "/" + rel, home: h), "must deny \(rel)")
        }
        for sys in ["/", "/System/Library", "/usr/bin/ls", "/etc/hosts", "/Applications/Safari.app", "/private/var/db", "/Users"] {
            #expect(isDeniedPath(sys, home: h), "must deny \(sys)")
        }
        #expect(isDeniedPath(h, home: h))
        #expect(isDeniedPath(h + "/documents/СИСТЕМА/x", home: h))
        for rel in ["Library/Caches/com.foo.bar", "Documents/Scratch/old-task", "Documents/Scratch/old-task/deep/file.txt",
                    "Downloads/archive.zip", ".cache/huggingface/hub/models--a--b", ".Trash/x", ".cache/other/x", "Desktop/Screenshot.png"] {
            #expect(!isDeniedPath(h + "/" + rel, home: h), "must allow \(rel)")
        }
    }

    @Test func denylistFollowsSymlinks() {
        let f = CleanFixture()
        f.file(".cache/uv/archive-v0/keep.bin")
        f.link("Library/Caches/evil", to: f.home + "/.cache/uv/archive-v0")
        f.link("Downloads/sneaky", to: f.home + "/Documents/Система")
        f.dir("Documents/Система/доступы")
        #expect(isDeniedPath(f.home + "/Library/Caches/evil", home: f.home))
        #expect(isDeniedPath(f.home + "/Library/Caches/evil/keep.bin", home: f.home))
        #expect(isDeniedPath(f.home + "/Downloads/sneaky", home: f.home))
        f.link("Library/Caches/outside", to: NSTemporaryDirectory())
        #expect(isDeniedPath(f.home + "/Library/Caches/outside", home: f.home))
    }

    @Test func neverCategoriesAreListedButNeverPlannedNorTouched() {
        let f = CleanFixture()
        let uv = f.file(".cache/uv/archive-v0/keep.bin", bytes: 8192)
        let sys = f.file("Documents/Система/доступы/пароли.py")
        let proj = f.file(".claude/projects/p/memory.md")
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.level == .never })
        #expect(cats.count == 3)
        for c in cats {
            #expect(c.items.count == 1)
            #expect(c.items[0].blocked == "никогда")
            #expect(c.bytes == 0 && c.blockedBytes > 0)
        }
        let all = Set(cats.flatMap { $0.items.map(\.id) })
        #expect(defaultPicked(cats).isEmpty)
        let plan = planClean(cats, picked: all, env: e)
        #expect(plan.ops.isEmpty)
        #expect(plan.skipped.count == 3)
        let rep = executeClean(cats, picked: all, env: e)
        #expect(rep.opsOk == 0 && rep.movedCount == 0)
        for p in [uv, sys, proj] { #expect(FileManager.default.fileExists(atPath: p)) }
    }

    @Test func forgedItemPointingIntoProtectedPathIsDeniedEvenIfCategoryIsSafe() {
        let f = CleanFixture()
        let uv = f.file(".cache/uv/archive-v0/keep.bin")
        f.link("Library/Caches/evil", to: f.home + "/.cache/uv/archive-v0")
        f.file("Library/Caches/com.stale.app/blob")
        let e = f.env()
        var c = cat("caches", e)
        #expect(c.items.flatMap(\.paths).contains(f.home + "/Library/Caches/com.stale.app"))
        c.items = [CleanItem(id: "x", title: "x", bytes: 1, paths: [f.home + "/Library/Caches/evil", uv])]
        let plan = planClean([c], picked: ["x"], env: e)
        #expect(plan.ops.isEmpty)
        #expect(plan.denied.count == 2)
        let rep = executeClean([c], picked: ["x"], env: e)
        #expect(FileManager.default.fileExists(atPath: uv))
        #expect(f.exists("Library/Caches/evil"))
        #expect(rep.opsOk == 0)
    }

    @Test func cachesScanSkipsRunningSystemAndExcludedFolders() {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob", bytes: 20_000)
        f.file("Library/Caches/com.running.app/blob")
        f.file("Library/Caches/com.apple.Safari/blob")
        f.file("Library/Caches/ms-playwright/chromium-1/blob")
        f.file("Library/Caches/dev.multitool.thing/blob")
        f.file("Library/Caches/claude-cli-nodejs/blob")
        f.file("Library/Caches/uv/blob")
        f.file("Library/Caches/loosefile.txt")
        let e = f.env(running: [RunningApp(bundleId: "com.running.app", name: "Run")])
        let c = cat("caches", e)
        let names = Set(c.items.flatMap(\.paths).map { ($0 as NSString).lastPathComponent })
        #expect(names == ["com.stale.app"])
        #expect(c.bytes >= 20_000)
    }

    @Test func logsKeepFreshAndSymlinks() {
        let f = CleanFixture()
        f.file("Library/Logs/old/a.log", bytes: 9000, daysAgo: 10)
        f.file("Library/Logs/new.log", daysAgo: 2)
        f.file("Library/Logs/old2.log", daysAgo: 8)
        let e = f.env()
        let c = cat("logs", e)
        let names = Set(c.items.flatMap(\.paths).map { ($0 as NSString).lastPathComponent })
        #expect(names == ["a.log", "old2.log"])
    }

    @Test func downloadsAgeFilterUsesNewestFileInside() {
        let f = CleanFixture()
        f.file("Downloads/old.zip", daysAgo: 40)
        f.file("Downloads/fresh.zip", daysAgo: 3)
        f.file("Downloads/folder/a.bin", daysAgo: 45)
        f.file("Downloads/mixed/a.bin", daysAgo: 45)
        f.file("Downloads/mixed/b.bin", daysAgo: 1)
        f.file("Downloads/.hidden", daysAgo: 90)
        let e = f.env()
        let c = cat("downloads", e)
        let names = Set(c.items.map(\.title))
        #expect(names == ["old.zip", "folder"])
        #expect(c.items.allSatisfy { $0.subtitle.hasSuffix("дн. назад") })
    }

    @Test func hfModelsNeedAgeAndSize() {
        let f = CleanFixture()
        f.file(".cache/huggingface/hub/models--a--old/snapshots/x/w.bin", bytes: 2_000_000)
        f.ageTree(".cache/huggingface/hub/models--a--old", 90)
        f.file(".cache/huggingface/hub/models--a--fresh/snapshots/x/w.bin", bytes: 2_000_000)
        f.file(".cache/huggingface/hub/models--a--tiny/snapshots/x/w.bin", bytes: 100)
        f.ageTree(".cache/huggingface/hub/models--a--tiny", 90)
        f.file(".cache/huggingface/hub/datasets--a--b/x.bin", bytes: 2_000_000)
        f.ageTree(".cache/huggingface/hub/datasets--a--b", 90)
        let c = cat("hf", f.env())
        #expect(c.items.map(\.title) == ["a/old"])
        #expect(c.items[0].bytes >= 2_000_000)
    }

    @Test func playwrightKeepsNewestRevisionAndFlagsRunning() {
        #expect(playwrightOld(["chromium-1100", "chromium-1200", "firefox-10", "ffmpeg-5", "ffmpeg-7", ".links", "chromium-"]).sorted() == ["chromium-1100", "ffmpeg-5"])
        let f = CleanFixture()
        f.file("Library/Caches/ms-playwright/chromium-1100/a")
        f.file("Library/Caches/ms-playwright/chromium-1200/a")
        var e = f.env()
        e.processBlob = f.home + "/Library/Caches/ms-playwright/chromium-1100/chrome --headless"
        let c = cat("playwright", e)
        #expect(c.items.count == 1)
        #expect(c.items[0].blocked == "используется")
        #expect(c.bytes == 0)
    }

    @Test func browserCachesBlockedWhileAppRuns() {
        let f = CleanFixture()
        f.file("Library/Caches/Google/Chrome/Default/Cache/x")
        f.file("Library/Application Support/Google/Chrome/Default/Cache/x")
        f.file("Library/Application Support/Code/Cache/x")
        f.file("Library/Application Support/Code/GPUCache/x")
        let c1 = cat("chrome", f.env())
        #expect(c1.items[0].blocked == nil && c1.items[0].paths.count == 2)
        let c2 = cat("chrome", f.env(running: [RunningApp(bundleId: "com.google.Chrome", name: "Google Chrome")]))
        #expect(c2.items[0].blocked == "закрой Chrome")
        let v = cat("vscode", f.env(running: [RunningApp(bundleId: "com.microsoft.VSCode", name: "Code")]))
        #expect(v.items.first { $0.id == "vscode-cache" }?.blocked == nil)
        #expect(v.items.first { $0.id == "vscode-gpu" }?.blocked == "закрой VS Code")
    }

    @Test func scanTreeDoesNotFollowSymlinksAndCountsHardlinksOnce() {
        let f = CleanFixture()
        f.file("big/a.bin", bytes: 1_000_000)
        f.file("tree/own.bin", bytes: 4096)
        f.link("tree/lnk", to: f.home + "/big")
        let s = scanTree(f.home + "/tree")
        #expect(s.bytes < 100_000)
        #expect(s.files == 1)
        let target = f.file("h/a.bin", bytes: 100_000)
        try? FileManager.default.linkItem(atPath: target, toPath: f.home + "/h/b.bin")
        let one = scanTree(f.home + "/h").bytes
        #expect(one >= 100_000 && one < 150_000)
    }

    @Test func sizeSumsMatchBetweenCategoryAndItems() {
        let f = CleanFixture()
        f.file("Library/Developer/Xcode/DerivedData/A/x", bytes: 50_000)
        f.file("Library/Developer/Xcode/DerivedData/B/y", bytes: 70_000)
        let c = cat("xcode", f.env())
        #expect(c.items.count == 1 && c.items[0].paths.count == 2)
        #expect(c.bytes == c.items[0].bytes)
        #expect(c.bytes >= 120_000)
        #expect(c.blockedBytes == 0)
    }

    @Test func defaultPickedIsSafeLevelAndUnblockedOnly() {
        let a = CleanCategory(id: "a", title: "a", subtitle: "", level: .safe, action: .trash(purge: true),
                              items: [CleanItem(id: "a1", title: "", bytes: 1), CleanItem(id: "a2", title: "", bytes: 1, blocked: "busy")])
        let b = CleanCategory(id: "b", title: "b", subtitle: "", level: .review, action: .trash(purge: false), items: [CleanItem(id: "b1", title: "", bytes: 1)])
        #expect(defaultPicked([a, b]) == ["a1"])
    }

    // MARK: trash flow

    @Test func movedItemsArePurgedFromTrashOnlyAfterServicesCheck() {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob")
        f.file("Library/Developer/Xcode/DerivedData/A/x")
        f.services(before: [("dev.multitool.singbox", 123, 0), ("dev.multitool.storozh", nil, 0)], after: [("dev.multitool.singbox", 123, 0), ("dev.multitool.storozh", nil, 0)])
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { ["caches", "xcode"].contains($0.id) })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(!rep.aborted)
        #expect(rep.movedCount == 2)
        #expect(rep.purgedCount == 2)
        #expect(!f.exists("Library/Caches/com.stale.app"))
        #expect(!f.exists("Library/Developer/Xcode/DerivedData/A"))
        #expect(f.trashContents().isEmpty)
        #expect(rep.doneItemIds.sorted() == ["caches", "xcode"])
        #expect(rep.removedBytes > 0)
    }

    @Test func deadServiceStopsPurgeAndLeavesEverythingInTrash() {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob")
        f.services(before: [("dev.multitool.singbox", 123, 0)], after: [("dev.multitool.singbox", nil, 1)])
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "caches" })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(rep.aborted)
        #expect(rep.died == ["dev.multitool.singbox"])
        #expect(rep.purgedCount == 0)
        #expect(f.trashContents().count == 1)
        #expect(reportLines(rep).contains { $0.hasPrefix("СТОП") })
    }

    @Test func serviceThatMerelyRestartedIsNotCountedDead() {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob")
        f.services(before: [("dev.multitool.singbox", 123, 0)], after: [("dev.multitool.singbox", nil, 0)])
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "caches" })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(!rep.aborted)
        #expect(rep.purgedCount == 1)
    }

    @Test func downloadsAndModelsStayInTrash() {
        let f = CleanFixture()
        f.file("Downloads/old.zip", daysAgo: 40)
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "downloads" })
        let rep = executeClean(cats, picked: Set(cats[0].items.map(\.id)), env: e)
        #expect(rep.movedCount == 1 && rep.purgedCount == 0)
        #expect(!f.exists("Downloads/old.zip"))
        #expect(f.trashContents().count == 1)
        #expect(rep.trashedBytes > 0 && rep.removedBytes == 0)
    }

    @Test func purgeRefusesAnythingOutsideTheTrash() {
        let f = CleanFixture()
        let keep = f.file("Library/Caches/com.stale.app/blob")
        var e = f.env()
        let elsewhere = f.dir("Somewhere")
        e.trasher = { p in
            let dst = elsewhere + "/" + (p as NSString).lastPathComponent
            return (try? FileManager.default.moveItem(atPath: p, toPath: dst)) != nil ? dst : nil
        }
        _ = keep
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "caches" })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(rep.purgedCount == 0)
        #expect(rep.failed.contains { $0.contains("не в Корзине") })
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/com.stale.app"))
        #expect(rep.doneItemIds.isEmpty)
    }

    @Test func failedMoveIsReportedAndItemNotDone() {
        let f = CleanFixture()
        let p = f.file("Library/Caches/com.stale.app/blob")
        _ = p
        let dirPath = f.home + "/Library/Caches/com.stale.app"
        f.trashFail.mutate { $0.insert(dirPath) }
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "caches" })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(rep.movedCount == 0)
        #expect(rep.failed.count == 1)
        #expect(f.exists("Library/Caches/com.stale.app"))
        #expect(rep.doneItemIds.isEmpty)
    }

    @Test func trashCategoryEmptiesOldContentButNotItemsMovedInThisRun() {
        let f = CleanFixture()
        f.file(".Trash/old-thing.txt", bytes: 5000)
        f.file("Library/Caches/com.stale.app/blob")
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { ["trash", "caches"].contains($0.id) })
        #expect(cats[0].id == "trash" && cats[0].bytes > 0)
        let plan = planClean(cats, picked: defaultPicked(cats), env: e)
        #expect(plan.ops.first.map { if case .emptyTrash = $0.op { true } else { false } } == true)
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(!f.exists(".Trash/old-thing.txt"))
        #expect(rep.purgedCount == 1)
        #expect(rep.opsOk == 2)
    }

    @Test func emptyTrashFailureFallsBackToFinderOnlyWhenExecAllowed() {
        let f = CleanFixture()
        f.file(".Trash/locked.txt")
        var e = f.env()
        e.purger = { _ in false }
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "trash" })
        let r1 = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(!r1.finderFallback && !r1.failed.isEmpty)
        e.allowExec = true
        let flag = LockedBox(false)
        e.finderEmptyTrash = { flag.mutate { $0 = true }; return true }
        let r2 = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(r2.finderFallback && flag.value && r2.failed.isEmpty)
    }

    @Test func toolCommandsNeedExecPermissionAndRunOnce() {
        let f = CleanFixture()
        f.tool("npm")
        f.file(".npm/_cacache/a", bytes: 50_000)
        var e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "npm" })
        #expect(cats[0].items.count == 1 && cats[0].bytes >= 50_000)
        let r1 = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(f.execLog.value.isEmpty)
        #expect(r1.skipped.contains { $0.hasPrefix("не запускаю") })
        e.allowExec = true
        let r2 = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(f.execLog.value == [f.root + "/bin/npm cache clean --force"])
        #expect(r2.opsOk == 1 && r2.failed.isEmpty)
    }

    @Test func missingToolMeansNoCategoryItems() {
        let f = CleanFixture()
        f.file(".npm/_cacache/a")
        #expect(cat("npm", f.env()).items.isEmpty)
        #expect(cat("brew", f.env()).items.isEmpty)
    }

    @Test func dockerSizeParsing() {
        #expect(parseDockerSize("1.5GB (30%)") == 1_500_000_000)
        #expect(parseDockerSize("200MB") == 200_000_000)
        #expect(parseDockerSize("0B") == 0)
        #expect(parseDockerSize("garbage") == 0)
    }

    @Test func claudeVersionsKeepTheOneTheSymlinkPointsAt() {
        let f = CleanFixture()
        f.file(".local/share/claude/versions/2.1.100/claude", bytes: 10_000)
        f.file(".local/share/claude/versions/2.1.200/claude", bytes: 10_000)
        f.file(".local/share/claude/versions/2.1.300/claude", bytes: 10_000)
        f.link(".local/bin/claude", to: f.home + "/.local/share/claude/versions/2.1.300/claude")
        var e = f.env()
        e.processBlob = "/x/.local/share/claude/versions/2.1.200/claude"
        let c = cat("claude-versions", e)
        let names = Set(c.items.flatMap(\.paths).map { ($0 as NSString).lastPathComponent })
        #expect(names == ["2.1.100"])
        let none = CleanFixture()
        none.file(".local/share/claude/versions/1/claude")
        #expect(cat("claude-versions", none.env()).items.isEmpty)
    }

    @Test func contentsOnlyItemsMoveChildrenNotTheFolder() {
        let f = CleanFixture()
        f.file("Library/Application Support/Code/Cache/a")
        f.file("Library/Application Support/Code/Cache/b")
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanDefs.filter { $0.id == "vscode" })
        let rep = executeClean(cats, picked: defaultPicked(cats), env: e)
        #expect(rep.purgedCount == 2)
        #expect(f.exists("Library/Application Support/Code/Cache"))
        #expect(!f.exists("Library/Application Support/Code/Cache/a"))
    }
}

@Suite struct CleanCLITests {
    func run(_ args: [String], _ f: CleanFixture) -> (code: Int32, out: [String], err: [String]) {
        let out = LockedBox<[String]>([]), err = LockedBox<[String]>([])
        let code = CleanCLI.run(arguments: args, makeEnv: { _ in f.env() }, out: { l in out.mutate { $0.append(l) } }, err: { l in err.mutate { $0.append(l) } })
        return (code, out.value, err.value)
    }

    @Test func recognisesOnlyItsOwnFlags() {
        #expect(CleanCLI.handles(["Multitul", "--disk-scan"]))
        #expect(CleanCLI.handles(["Multitul", "--analyze-clean", "all", "--dry-run"]))
        #expect(!CleanCLI.handles(["Multitul", "--agent"]))
        #expect(!CleanCLI.handles(["Multitul", "--migrate-storozh"]))
    }

    @Test func diskScanPrintsJSONWithAllLevels() throws {
        let f = CleanFixture()
        f.file("Library/Caches/com.stale.app/blob", bytes: 30_000)
        let r = run(["--disk-scan", "--home", f.home], f)
        #expect(r.code == 0)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(r.out.joined(separator: "\n").utf8)) as? [String: Any])
        let cats = try #require(obj["categories"] as? [[String: Any]])
        #expect(cats.count == cleanDefs.count)
        #expect(Set(cats.compactMap { $0["level"] as? String }) == ["safe", "review", "never"])
        #expect((cats.first { $0["id"] as? String == "caches" }?["bytes"] as? Int ?? 0) >= 30_000)
    }

    @Test func diskCleanDryRunListsOpsAndTouchesNothing() {
        let f = CleanFixture()
        let p = f.file("Library/Caches/com.stale.app/blob")
        f.file(".cache/uv/archive-v0/keep.bin")
        let r = run(["--disk-clean", "caches", "never-uv", "--dry-run"], f)
        #expect(r.code == 0)
        #expect(r.out.contains("trash+purge " + f.home + "/Library/Caches/com.stale.app"))
        #expect(r.out.contains { $0.hasPrefix("skip:") && $0.contains("никогда") })
        #expect(FileManager.default.fileExists(atPath: p))
        #expect(f.trashContents().isEmpty)
        #expect(r.err.last?.hasPrefix("ops: 1") == true)
    }

    @Test func diskCleanRefusesWithoutDryRunOrYes() {
        let f = CleanFixture()
        let p = f.file("Library/Caches/com.stale.app/blob")
        #expect(run(["--disk-clean", "caches"], f).code == 2)
        #expect(run(["--disk-clean", "--dry-run"], f).code == 2)
        #expect(FileManager.default.fileExists(atPath: p))
    }

    @Test func analyzeCleanWorksOnlyAsDryRun() {
        let f = CleanFixture()
        #expect(run(["--analyze-clean", "all"], f).code == 2)
    }
}
