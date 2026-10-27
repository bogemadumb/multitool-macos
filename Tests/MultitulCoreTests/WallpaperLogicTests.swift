import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func wpTmpDir() -> String {
    let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
    let p = base + "/multitul-wallpaper-test/" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func wpTouch(_ path: String, bytes: Int = 10, age: TimeInterval = 100) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes))
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
}

@Suite struct WallpaperSelectionTests {
    private let all: Set<String> = ["cls-white-night", "cls-black-night", "cls-white-day", "cls-black-day"]

    @Test func exactMatchWinsForEveryColourAndTime() {
        for c in WallpaperColor.allCases {
            for day in [false, true] {
                #expect(WallpaperSelection.resolveName(color: c, day: day, available: all) == "cls-\(c.rawValue)-\(day ? "day" : "night")")
            }
        }
    }

    @Test func fallbackOrderMatchesOldApp() {
        let night: Set<String> = ["cls-white-night", "cls-black-night"]
        #expect(WallpaperSelection.resolveName(color: .white, day: true, available: night) == "cls-white-night")
        #expect(WallpaperSelection.resolveName(color: .black, day: true, available: night) == "cls-black-night")
        #expect(WallpaperSelection.resolveName(color: .black, day: false, available: ["cls-black-night"]) == "cls-black-night")
        #expect(WallpaperSelection.resolveName(color: .black, day: true, available: ["cls-black-night"]) == "cls-black-night")
        #expect(WallpaperSelection.resolveName(color: .white, day: false, available: ["cls-black-night"]) == "cls-black-night")
        #expect(WallpaperSelection.resolveName(color: .black, day: false, available: ["cls-white-day"]) == "cls-white-day")
        #expect(WallpaperSelection.resolveName(color: .black, day: false, available: []) == nil)
        #expect(WallpaperSelection.resolveName(color: .white, day: true, available: ["cls-black-night", "cls-black-day"]) == "cls-black-day")
    }

    @Test func pickUsesStandardThenFirstByNaturalOrder() {
        let u = { (n: String) in URL(fileURLWithPath: "/x/\(n).mov") }
        var videos = [String: URL]()
        for n in ["clip10", "clip2", "clip1"] { videos[n] = u(n) }
        let legacy = WallpaperSelection.pick(color: .black, day: true, videos: videos)
        #expect(legacy?.name == "clip1" && legacy?.standard == false)

        videos["cls-black-night"] = u("cls-black-night")
        let std = WallpaperSelection.pick(color: .white, day: true, videos: videos)
        #expect(std?.name == "cls-black-night" && std?.standard == true)
        #expect(WallpaperSelection.pick(color: .white, day: true, videos: [:]) == nil)
    }

    @Test func dayModeOverridesSun() {
        let noon = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00+03:00")!
        let midnight = ISO8601DateFormatter().date(from: "2026-12-21T02:00:00+03:00")!
        #expect(WallpaperSelection.isDay(mode: .day, sun: .spb, now: midnight))
        #expect(!WallpaperSelection.isDay(mode: .night, sun: .spb, now: noon))
        #expect(WallpaperSelection.isDay(mode: .auto, sun: .spb, now: noon))
        #expect(!WallpaperSelection.isDay(mode: .auto, sun: .spb, now: midnight))
    }

    @Test func scanSkipsNonVideosHiddenAndFolders() {
        let d = wpTmpDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        for n in ["cls-black-day.mov", "b.MP4", "c.m4v", "notes.txt", ".hidden.mov"] { wpTouch(d + "/" + n) }
        try? FileManager.default.createDirectory(atPath: d + "/folder.mov", withIntermediateDirectories: true)
        wpTouch(d + "/aerial/x.mov")
        #expect(Set(WallpaperFiles.scanNames(d).keys) == ["cls-black-day", "b", "c"])
    }

    @Test func titlesLoadAndTolerateGarbage() {
        let d = wpTmpDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        try? Data(#"{"cls-black-day":"Чёрный день"}"#.utf8).write(to: URL(fileURLWithPath: d + "/t.json"))
        #expect(WallpaperFiles.loadTitles(path: d + "/t.json") == ["cls-black-day": "Чёрный день"])
        try? Data("nope".utf8).write(to: URL(fileURLWithPath: d + "/bad.json"))
        #expect(WallpaperFiles.loadTitles(path: d + "/bad.json").isEmpty)
        #expect(WallpaperFiles.loadTitles(path: d + "/missing.json").isEmpty)
    }
}

@Suite struct WallpaperFileAgeTests {
    @Test func settleThresholdIsStrictlyThreeSeconds() {
        #expect(!FileStamp(stamp: "a", age: 0).isSettled)
        #expect(!FileStamp(stamp: "a", age: 2.99).isSettled)
        #expect(!FileStamp(stamp: "a", age: 3.0).isSettled)
        #expect(FileStamp(stamp: "a", age: 3.01).isSettled)
    }

    @Test func freshFileIsNotSettledOldFileIs() throws {
        let d = wpTmpDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        wpTouch(d + "/fresh.mov", age: 1)
        wpTouch(d + "/old.mov", age: 60)
        let fresh = try #require(FileStamp.of(URL(fileURLWithPath: d + "/fresh.mov")))
        let old = try #require(FileStamp.of(URL(fileURLWithPath: d + "/old.mov")))
        #expect(!fresh.isSettled)
        #expect(old.isSettled)
        #expect(fresh.stamp != old.stamp)
        #expect(FileStamp.of(URL(fileURLWithPath: d + "/none.mov")) == nil)
    }

    @Test func stampChangesWhenFileIsRewritten() throws {
        let d = wpTmpDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        wpTouch(d + "/a.mov", bytes: 10, age: 50)
        let before = try #require(FileStamp.of(URL(fileURLWithPath: d + "/a.mov")))
        wpTouch(d + "/a.mov", bytes: 20, age: 50)
        let after = try #require(FileStamp.of(URL(fileURLWithPath: d + "/a.mov")))
        #expect(before.stamp != after.stamp)
    }
}

@Suite struct WallpaperOcclusionTests {
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func noWindowsMeansNotCovered() {
        #expect(!Occlusion.isCovered(area: area, rects: []))
    }

    @Test func fullWindowCovers() {
        #expect(Occlusion.isCovered(area: area, rects: [CGRect(x: -10, y: -10, width: 1500, height: 1000)]))
    }

    @Test func exactVisibleFrameCovers() {
        #expect(Occlusion.isCovered(area: area, rects: [area]))
    }

    @Test func twoHalvesCoverButAGapDoesNot() {
        let left = CGRect(x: 0, y: 0, width: 720, height: 900)
        #expect(Occlusion.isCovered(area: area, rects: [left, CGRect(x: 720, y: 0, width: 720, height: 900)]))
        #expect(!Occlusion.isCovered(area: area, rects: [left, CGRect(x: 760, y: 0, width: 680, height: 900)]))
    }

    @Test func aThinUncoveredStripBreaksCoverage() {
        #expect(!Occlusion.isCovered(area: area, rects: [CGRect(x: 0, y: 0, width: 1440, height: 800)]))
        #expect(!Occlusion.isCovered(area: area, rects: [CGRect(x: 100, y: 0, width: 1340, height: 900)]))
    }

    @Test func windowListEntryFilter() {
        #expect(Occlusion.countsAsCover(layer: 0, ownerPID: 5, alpha: 1, ownPID: 9))
        #expect(Occlusion.countsAsCover(layer: 0, ownerPID: 5, alpha: nil, ownPID: 9))
        #expect(Occlusion.countsAsCover(layer: 0, ownerPID: 5, alpha: 0.98, ownPID: 9))
        #expect(!Occlusion.countsAsCover(layer: 0, ownerPID: 5, alpha: 0.9, ownPID: 9))
        #expect(!Occlusion.countsAsCover(layer: 25, ownerPID: 5, alpha: 1, ownPID: 9))
        #expect(!Occlusion.countsAsCover(layer: nil, ownerPID: 5, alpha: 1, ownPID: 9))
        #expect(!Occlusion.countsAsCover(layer: 0, ownerPID: 9, alpha: 1, ownPID: 9))
    }

    @Test func visibleFrameConvertsToTopLeftSpace() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let a = Occlusion.topLeftArea(visibleFrame: v, primaryHeight: 900)
        #expect(a == CGRect(x: 0, y: 25, width: 1440, height: 850))
        let secondary = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        #expect(Occlusion.topLeftArea(visibleFrame: secondary, primaryHeight: 900) == CGRect(x: 1440, y: -80, width: 1920, height: 1080))
    }
}

@Suite struct WallpaperPauseTests {
    @Test func idleInputsPlay() {
        #expect(PauseInputs().shouldPlay)
        #expect(PauseInputs().reason == nil)
    }

    @Test func globalReasonsHavePriority() {
        var i = PauseInputs()
        i.occluded = true; i.onBattery = true; i.screensAsleep = true; i.locked = true; i.manual = true
        #expect(i.reason == .manual)
        i.manual = false
        #expect(i.reason == .locked)
        i.locked = false
        #expect(i.reason == .asleep)
        i.screensAsleep = false
        #expect(i.reason == .battery)
        i.onBattery = false
        #expect(i.reason == .occluded)
        i.occluded = false; i.covered = true
        #expect(i.reason == .covered)
    }

    @Test func batteryPauseRespectsTheOption() {
        var i = PauseInputs()
        i.onBattery = true
        #expect(!i.shouldPlay)
        i.pauseOnBattery = false
        #expect(i.shouldPlay)
    }

    @Test func darkWakeKeepsScreensAsleepAndPaused() {
        var i = PauseInputs()
        i.systemAsleep = true; i.screensAsleep = true
        i.systemAsleep = false
        #expect(!i.shouldPlay && i.reason == .asleep)
        i.screensAsleep = false
        #expect(i.shouldPlay)
    }

    @Test func occlusionIsNotAGlobalReason() {
        var i = PauseInputs()
        i.occluded = true
        #expect(i.globalReason == nil)
        #expect(!i.shouldPlay)
    }
}

@Suite struct WallpaperSettingsTests {
    @Test func defaultsAndRoundTrip() {
        let d = InMemoryKeyValueStore()
        let s = WallpaperSettings(d)
        #expect(s.color == .black && s.dayMode == .auto && s.pauseOnBattery && !s.manualPause && !s.lockFollows)
        #expect(s.lockVideo == nil && s.excludedScreens.isEmpty)
        s.color = .white; s.dayMode = .night; s.pauseOnBattery = false; s.manualPause = true; s.lockFollows = true
        s.lockVideo = "cls-white-night"; s.excludedScreens = ["B", "A"]
        let t = WallpaperSettings(d)
        #expect(t.color == .white && t.dayMode == .night && !t.pauseOnBattery && t.manualPause && t.lockFollows)
        #expect(t.lockVideo == "cls-white-night" && t.excludedScreens == ["A", "B"])
        t.lockVideo = nil
        #expect(WallpaperSettings(d).lockVideo == nil)
    }

    @Test func garbageValuesFallBackToDefaults() {
        let d = InMemoryKeyValueStore()
        d.set("purple", forKey: WallpaperKeys.color)
        d.set("whenever", forKey: WallpaperKeys.dayMode)
        #expect(WallpaperSettings(d).color == .black && WallpaperSettings(d).dayMode == .auto)
    }
}

@Suite struct WallpaperExclusionTests {
    @Test func staticBlockedWhereLiveRuns() {
        #expect(WallpaperExclusion.staticDecision(screenID: "A", liveEnabled: true, excluded: []) == .blockedByLive)
        #expect(WallpaperExclusion.staticDecision(screenID: "A", liveEnabled: true, excluded: ["B"]) == .blockedByLive)
    }

    @Test func staticAllowedWhenLiveOffOrScreenExcluded() {
        #expect(WallpaperExclusion.staticDecision(screenID: "A", liveEnabled: false, excluded: []) == .allowed)
        #expect(WallpaperExclusion.staticDecision(screenID: "A", liveEnabled: true, excluded: ["A"]) == .allowed)
        #expect(!WallpaperExclusion.liveRuns(on: "A", liveEnabled: true, excluded: ["A"]))
        #expect(WallpaperExclusion.liveRuns(on: "B", liveEnabled: true, excluded: ["A"]))
    }
}

@Suite struct StaticWallpaperLibraryTests {
    @Test func collectsImagesFromFilesAndFoldersWithoutDuplicates() {
        let d = wpTmpDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        for n in ["pics/img10.jpg", "pics/img2.PNG", "pics/img1.heic", "pics/readme.txt", "pics/.hidden.jpg", "single/one.jpeg", "single/clip.mov"] { wpTouch(d + "/" + n) }
        let sources = StaticWallpaperLibrary.adding([URL(fileURLWithPath: d + "/pics"), URL(fileURLWithPath: d + "/single/one.jpeg"),
                                                     URL(fileURLWithPath: d + "/single/clip.mov"), URL(fileURLWithPath: d + "/none.jpg"),
                                                     URL(fileURLWithPath: d + "/pics")], to: [])
        #expect(sources.count == 2)
        let imgs = StaticWallpaperLibrary.images(from: sources + [StaticWallpaperSource(path: d + "/pics/img1.heic", isFolder: false)])
        #expect(imgs.map(\.lastPathComponent) == ["img1.heic", "img2.PNG", "img10.jpg", "one.jpeg"])
    }

    @Test func sourcesPersist() {
        let d = InMemoryKeyValueStore()
        let list = [StaticWallpaperSource(path: "/a", isFolder: true), StaticWallpaperSource(path: "/b.jpg", isFolder: false)]
        StaticWallpaperLibrary.saveSources(list, d)
        #expect(StaticWallpaperLibrary.loadSources(d) == list)
        #expect(StaticWallpaperLibrary.loadSources(InMemoryKeyValueStore()).isEmpty)
    }
}
