import Testing
import Foundation
@testable import MultitulCore

private func wpTmp() -> String {
    let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
    let p = base + "/multitul-wallpaper-mig/" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

@discardableResult
private func wpPut(_ path: String, _ bytes: Int, byte: UInt8 = 1) -> String {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: byte, count: bytes))
    return path
}

private func oldTree(_ root: String) {
    for n in ["cls-black-day", "cls-black-night", "cls-white-day", "cls-white-night"] {
        wpPut("\(root)/videos/\(n).mov", 100)
        wpPut("\(root)/aerial/\(n).mov", 200)
    }
    wpPut("\(root)/videos/readme.txt", 5)
    wpPut("\(root)/videos/.hidden.mov", 5)
    wpPut("\(root)/aerial-original/AAA.mov", 1000)
    wpPut("\(root)/aerial-original/AAA.png", 50)
    wpPut("\(root)/titles.json", 20)
    try? FileManager.default.createDirectory(atPath: "\(root)/videos/sub.mov", withIntermediateDirectories: true)
}

@Suite struct WallpaperMigrationTests {
    @Test func planMapsOldLayoutToNew() {
        let old = wpTmp(), new = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        let plan = WallpaperMigration.plan(oldRoot: old, newRoot: new)
        #expect(!plan.missingSource)
        #expect(plan.items.count == 4 + 4 + 2 + 1)
        #expect(plan.items.allSatisfy { $0.action == .copy })
        let dsts = Set(plan.items.map { $0.dst.replacingOccurrences(of: new + "/", with: "") })
        #expect(dsts.contains("cls-black-day.mov") && dsts.contains("aerial/cls-white-night.mov"))
        #expect(dsts.contains("aerial-original/AAA.mov") && dsts.contains("aerial-original/AAA.png") && dsts.contains("titles.json"))
        #expect(!dsts.contains("readme.txt") && !dsts.contains(".hidden.mov") && !dsts.contains("sub.mov"))
        #expect(plan.copyBytes == 4 * 100 + 4 * 200 + 1000 + 50 + 20)
    }

    @Test func existingSameSizeIsSkippedDifferentSizeIsAConflict() {
        let old = wpTmp(), new = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        wpPut(new + "/cls-black-day.mov", 100)
        wpPut(new + "/cls-white-day.mov", 77)
        let plan = WallpaperMigration.plan(oldRoot: old, newRoot: new)
        func action(_ n: String) -> WallpaperMigrationAction? { plan.items.first { $0.dst == new + "/" + n }?.action }
        #expect(action("cls-black-day.mov") == .skipSame)
        #expect(action("cls-white-day.mov") == .conflict)
        #expect(action("cls-black-night.mov") == .copy)
        #expect(plan.conflicts.count == 1)
        #expect(plan.toCopy.count == plan.items.count - 2)
    }

    @Test func missingSourceIsReported() {
        let plan = WallpaperMigration.plan(oldRoot: "/nonexistent/\(UUID().uuidString)", newRoot: wpTmp())
        #expect(plan.missingSource && plan.items.isEmpty)
    }

    @Test func spaceCheckUsesMargin() {
        let old = wpTmp(), new = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        #expect(WallpaperMigration.plan(oldRoot: old, newRoot: new, freeBytes: nil).enoughSpace)
        #expect(!WallpaperMigration.plan(oldRoot: old, newRoot: new, freeBytes: 1000).enoughSpace)
        #expect(WallpaperMigration.plan(oldRoot: old, newRoot: new, freeBytes: 1 << 30).enoughSpace)
        var big = WallpaperMigrationPlan()
        big.items = [WallpaperMigrationItem(src: "a", dst: "b", bytes: 10 << 30, action: .copy)]
        big.freeBytes = 10 << 30
        #expect(!big.enoughSpace)
        big.freeBytes = 11 << 30
        #expect(big.enoughSpace)
    }

    @Test func executeCopiesKeepsSourceAndXattrsAndIsIdempotent() throws {
        let old = wpTmp(), new = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        try AerialLockscreen.writeXattr(old + "/aerial-original/AAA.mov", "LastETag", Data("etag-1".utf8))
        let before = try FileManager.default.attributesOfItem(atPath: old + "/videos/cls-black-day.mov")[.modificationDate] as? Date

        let plan = WallpaperMigration.plan(oldRoot: old, newRoot: new + "/wallpapers", freeBytes: WallpaperMigration.freeBytes(at: new))
        let r = WallpaperMigration.execute(plan)
        #expect(r.failed.isEmpty && r.copied.count == 11)
        #expect(FileManager.default.contents(atPath: new + "/wallpapers/aerial/cls-black-night.mov")?.count == 200)
        #expect(AerialLockscreen.readXattr(new + "/wallpapers/aerial-original/AAA.mov", "LastETag") == Data("etag-1".utf8))
        #expect(FileManager.default.fileExists(atPath: old + "/videos/cls-black-day.mov"))
        #expect(try FileManager.default.attributesOfItem(atPath: old + "/videos/cls-black-day.mov")[.modificationDate] as? Date == before)
        #expect(!FileManager.default.fileExists(atPath: new + "/wallpapers/cls-black-day.mov.part"))

        let again = WallpaperMigration.plan(oldRoot: old, newRoot: new + "/wallpapers")
        #expect(again.toCopy.isEmpty && again.items.allSatisfy { $0.action == .skipSame })
    }

    @Test func executeReportsFailuresAndContinues() {
        let old = wpTmp(), new = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        let plan = WallpaperMigration.plan(oldRoot: old, newRoot: new)
        let r = WallpaperMigration.execute(plan) { src, _ in
            if src.hasSuffix("cls-white-day.mov") && src.contains("/videos/") { throw AerialError("boom") }
        }
        #expect(r.failed.count == 1 && r.copied.count == plan.toCopy.count - 1)
    }

    @Test func executeRefusesWithoutSpace() {
        var plan = WallpaperMigrationPlan()
        plan.items = [WallpaperMigrationItem(src: "a", dst: "b", bytes: 1 << 30, action: .copy)]
        plan.freeBytes = 1000
        var called = false
        let r = WallpaperMigration.execute(plan) { _, _ in called = true }
        #expect(!called && r.copied.isEmpty && r.failed.count == 1)
    }

    @Test func cliDryRunWritesNothingAndRealRunNeedsFlag() {
        let old = wpTmp(), new = wpTmp() + "/w"
        defer { try? FileManager.default.removeItem(atPath: old); try? FileManager.default.removeItem(atPath: new) }
        oldTree(old)
        var lines: [String] = [], errs: [String] = []
        let dry = WallpaperCLI.run(arguments: ["--migrate-wallpapers", "--dry-run", "--from", old, "--to", new], out: { lines.append($0) }, err: { errs.append($0) })
        #expect(dry == 0)
        #expect(lines.count == 11 + 1 && lines.last?.contains("копировать: 11") == true)
        #expect(!FileManager.default.fileExists(atPath: new))
        let refused = WallpaperCLI.run(arguments: ["--migrate-wallpapers", "--from", old, "--to", new], out: { _ in }, err: { errs.append($0) })
        #expect(refused == 2 && !FileManager.default.fileExists(atPath: new))
        let missing = WallpaperCLI.run(arguments: ["--migrate-wallpapers", "--dry-run", "--from", old + "/nope", "--to", new], out: { _ in }, err: { _ in })
        #expect(missing == 1)
        let real = WallpaperCLI.run(arguments: ["--migrate-wallpapers", "--yes", "--from", old, "--to", new], out: { _ in }, err: { _ in })
        #expect(real == 0 && FileManager.default.fileExists(atPath: new + "/aerial-original/AAA.png"))
    }
}

@Suite struct AerialLockscreenTests {
    private struct Rig {
        let home: String, store: String
        let paths: AerialPaths
        let reloads = Box()
        init() {
            let root = wpTmp()
            home = root + "/home"
            store = root + "/store"
            paths = AerialPaths(home: home, storeDir: store, assetID: "ASSET")
            wpPut(paths.targetVideo, 300, byte: 9)
            wpPut(paths.targetThumb, 30, byte: 9)
            wpPut(paths.originalVideo, 300, byte: 9)
            wpPut(paths.originalThumb, 30, byte: 9)
            wpPut(paths.clip("cls-black-night"), 500, byte: 5)
            try? AerialLockscreen.writeXattr(paths.originalVideo, "LastETag", Data("orig-etag".utf8))
            try? AerialLockscreen.writeXattr(paths.targetVideo, "LastETag", Data("orig-etag".utf8))
        }
        final class Box: @unchecked Sendable { var n = 0 }
        func env(major: Int = 27) -> AerialEnv {
            let box = reloads
            return AerialEnv(paths: paths, osMajor: { major },
                             makeThumbnail: { _, dst in wpPut(dst, 44, byte: 4) },
                             reload: { box.n += 1 })
        }
        func cleanup() { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
    }

    @Test func applyReplacesVideoKeepsETagMakesThumbAndReloadsOnce() throws {
        let r = Rig(); defer { r.cleanup() }
        try AerialLockscreen.apply(name: "cls-black-night", env: r.env())
        let data = try #require(FileManager.default.contents(atPath: r.paths.targetVideo))
        #expect(data.count == 500 && data.allSatisfy { $0 == 5 })
        #expect(AerialLockscreen.readXattr(r.paths.targetVideo, "LastETag") == Data("orig-etag".utf8))
        #expect(FileManager.default.contents(atPath: r.paths.targetThumb)?.count == 44)
        let mode = try FileManager.default.attributesOfItem(atPath: r.paths.targetVideo)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(r.reloads.n == 1)
        #expect(!FileManager.default.fileExists(atPath: r.paths.targetVideo + ".tmp"))
        #expect(FileManager.default.contents(atPath: r.paths.originalVideo)?.count == 300)
    }

    @Test func unsupportedSystemVersionTouchesNothing() {
        let r = Rig(); defer { r.cleanup() }
        #expect(throws: AerialError.self) { try AerialLockscreen.apply(name: "cls-black-night", env: r.env(major: 15)) }
        #expect(throws: AerialError.self) { try AerialLockscreen.restore(env: r.env(major: 15)) }
        #expect(FileManager.default.contents(atPath: r.paths.targetVideo)?.count == 300)
        #expect(r.reloads.n == 0)
        #expect(AerialLockscreen.versionError(major: 26) == nil && AerialLockscreen.versionError(major: 27) == nil)
        #expect(AerialLockscreen.versionError(major: 25) != nil && AerialLockscreen.versionError(major: 28) != nil)
    }

    @Test func missingOriginalOrClipRefusesWithoutChanges() {
        let r = Rig(); defer { r.cleanup() }
        #expect(throws: AerialError.self) { try AerialLockscreen.apply(name: "nope", env: r.env()) }
        try? FileManager.default.removeItem(atPath: r.paths.originalVideo)
        #expect(throws: AerialError.self) { try AerialLockscreen.apply(name: "cls-black-night", env: r.env()) }
        #expect(throws: AerialError.self) { try AerialLockscreen.restore(env: r.env()) }
        #expect(FileManager.default.contents(atPath: r.paths.targetVideo)?.count == 300)
        #expect(r.reloads.n == 0)
    }

    @Test func thumbnailFailureLeavesNoTempFileAndNoReload() {
        let r = Rig(); defer { r.cleanup() }
        var env = r.env()
        env.makeThumbnail = { _, _ in throw AerialError("no frame") }
        #expect(throws: AerialError.self) { try AerialLockscreen.apply(name: "cls-black-night", env: env) }
        #expect(r.reloads.n == 0)
        #expect(!FileManager.default.fileExists(atPath: r.paths.targetThumb + ".tmp.png"))
    }

    @Test func restoreBringsBackOriginalVideoThumbAndETag() throws {
        let r = Rig(); defer { r.cleanup() }
        try AerialLockscreen.apply(name: "cls-black-night", env: r.env())
        try AerialLockscreen.restore(env: r.env())
        let v = try #require(FileManager.default.contents(atPath: r.paths.targetVideo))
        #expect(v.count == 300 && v.allSatisfy { $0 == 9 })
        #expect(FileManager.default.contents(atPath: r.paths.targetThumb)?.count == 30)
        #expect(AerialLockscreen.readXattr(r.paths.targetVideo, "LastETag") == Data("orig-etag".utf8))
        #expect(r.reloads.n == 2)
    }

    @Test func syncTargetDecision() {
        let has: (String) -> Bool = { _ in true }
        #expect(AerialLockscreen.syncTarget(follows: true, busy: false, desired: "cls-black-day", current: nil, hasClip: has) == "cls-black-day")
        #expect(AerialLockscreen.syncTarget(follows: false, busy: false, desired: "cls-black-day", current: nil, hasClip: has) == nil)
        #expect(AerialLockscreen.syncTarget(follows: true, busy: true, desired: "cls-black-day", current: nil, hasClip: has) == nil)
        #expect(AerialLockscreen.syncTarget(follows: true, busy: false, desired: "cls-black-day", current: "cls-black-day", hasClip: has) == nil)
        #expect(AerialLockscreen.syncTarget(follows: true, busy: false, desired: nil, current: nil, hasClip: has) == nil)
        #expect(AerialLockscreen.syncTarget(follows: true, busy: false, desired: "my-clip", current: nil, hasClip: has) == nil)
        #expect(AerialLockscreen.syncTarget(follows: true, busy: false, desired: "cls-black-day", current: nil, hasClip: { _ in false }) == nil)
    }
}

@Suite struct WallpaperCLITests {
    @Test func sunPrintsPeterburgTimesForADate() {
        var lines: [String] = []
        let code = WallpaperCLI.run(arguments: ["--sun", "--date", "2026-01-15"], out: { lines.append($0) }, err: { _ in })
        #expect(code == 0)
        #expect(lines.count == 3)
        #expect(lines[0].contains("2026-01-15"))
        #expect(lines[1] == "рассвет 09:46:02, закат 16:30:46")
        var bad: [String] = []
        #expect(WallpaperCLI.run(arguments: ["--sun", "--date", "xx"], out: { _ in }, err: { bad.append($0) }) == 2 && bad.count == 1)
    }

    @Test func statusReadsSettingsAndFolder() {
        let d = InMemoryKeyValueStore()
        WallpaperSettings(d).color = .white
        WallpaperSettings(d).dayMode = .night
        let dir = wpTmp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        wpPut(dir + "/cls-white-night.mov", 10)
        var lines: [String] = []
        let code = WallpaperCLI.run(arguments: ["--wallpaper-status"], defaults: d, dir: dir, out: { lines.append($0) }, err: { _ in })
        #expect(code == 0)
        #expect(lines[0].hasPrefix("color=white dayMode=night pauseOnBattery=true manualPause=false lockFollows=false"))
        #expect(lines[1].contains("cls-white-night") && lines[1].contains("ночь"))
        #expect(lines[3].contains("копия оригинала: нет"))
    }

    @Test func selftestPassesAndPrintsTable() {
        var lines: [String] = []
        let code = WallpaperCLI.run(arguments: ["--wallpaper-selftest"], out: { lines.append($0) }, err: { _ in })
        #expect(code == 0)
        #expect(lines.first?.hasPrefix("все четыре: white/ночь=cls-white-night") == true)
        #expect(lines.contains { $0.hasPrefix("полярный день") && $0.hasSuffix("ок") })
        #expect(WallpaperCLI.handles(["--sun"]) && WallpaperCLI.handles(["x", "--migrate-wallpapers"]) && !WallpaperCLI.handles(["--agent"]))
    }
}
