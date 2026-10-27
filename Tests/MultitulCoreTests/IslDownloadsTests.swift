import Testing
import Foundation
@testable import MultitulCore

private typealias F = ExtFix

private func file(_ name: String, _ size: Int64, at t: TimeInterval = 0, dir: Bool = false, total: Int64? = nil) -> IslDlFile {
    IslDlFile(name: name, size: size, modified: F.at(t), isDirectory: dir, expectedTotal: total)
}

private func prime(_ d: inout IslDlDetector, _ files: [IslDlFile] = [], at t: TimeInterval = 0) {
    _ = d.scan(files, now: F.at(t))
}

@Suite struct IslDlRulesTests {
    @Test func everyBrowserSuffixIsATempFile() {
        for n in ["a.zip.crdownload", "a.dmg.download", "a.iso.part", "a.exe.opdownload", "a.bin.partial", "a.mkv.!ut"] { #expect(IslDlRules.isTemp(n), "\(n)") }
    }

    @Test func suffixMatchingIgnoresCase() {
        #expect(IslDlRules.isTemp("A.ZIP.CRDOWNLOAD") && IslDlRules.isTemp("movie.Part"))
    }

    @Test func ordinaryFilesAreNotTemp() {
        for n in ["a.zip", "download", "part.txt", "notes.downloaded", ".crdownload", "report.pdf"] { #expect(!IslDlRules.isTemp(n), "\(n)") }
    }

    @Test func browserIsGuessedFromTheSuffix() {
        #expect(IslDlRules.browser(forTemp: "a.crdownload") == .chromium)
        #expect(IslDlRules.browser(forTemp: "a.download") == .safari)
        #expect(IslDlRules.browser(forTemp: "a.part") == .firefox)
        #expect(IslDlRules.browser(forTemp: "a.opdownload") == .opera)
        #expect(IslDlRules.browser(forTemp: "a.partial") == .other)
        #expect(IslDlRules.browser(forTemp: ".com.google.Chrome.x1y2") == .chromium)
    }

    @Test func finalNameStripsTheSuffix() {
        #expect(IslDlRules.finalName(ofTemp: "Фото отпуск.zip.crdownload") == "Фото отпуск.zip")
        #expect(IslDlRules.finalName(ofTemp: "a.dmg.download") == "a.dmg")
        #expect(IslDlRules.finalName(ofTemp: "a.iso.part") == "a.iso")
    }

    @Test func unconfirmedAndHiddenTempsHaveNoFinalName() {
        #expect(IslDlRules.finalName(ofTemp: "Unconfirmed 123456.crdownload") == nil)
        #expect(IslDlRules.finalName(ofTemp: ".com.google.Chrome.AbC123") == nil)
        #expect(IslDlRules.displayName(forTemp: "Unconfirmed 1.crdownload") == "Загрузка…")
    }

    @Test func chromiumHiddenTempsComeFromAllChromiumBrowsers() {
        for n in [".com.google.Chrome.X", ".com.microsoft.Edge.X", ".com.brave.Browser.X", ".org.chromium.Chromium.X", ".company.thebrowser.Browser.X", ".com.vivaldi.Vivaldi.X"] {
            #expect(IslDlRules.isTemp(n), "\(n)")
        }
        #expect(!IslDlRules.isChromiumHiddenTemp(".com.other.App.X"))
    }

    @Test func hiddenAndSystemFilesAreIgnored() {
        #expect(IslDlRules.isIgnored(".DS_Store") && IslDlRules.isIgnored(".hidden") && IslDlRules.isIgnored(".localized") && IslDlRules.isIgnored("~$doc.docx"))
        #expect(!IslDlRules.isIgnored("report.pdf") && !IslDlRules.isIgnored("a.crdownload"))
    }

    @Test func safariInfoPlistGivesTotalAndProgress() {
        let data = try! PropertyListSerialization.data(fromPropertyList: ["DownloadEntryProgressTotalToLoad": 1000, "DownloadEntryProgressBytesSoFar": 250], format: .xml, options: 0)
        #expect(IslDlSafariInfo.parse(data) == IslDlSafariInfo.Info(total: 1000, soFar: 250))
    }

    @Test func safariInfoWithoutTheKeysOrWithZeroTotal() {
        let none = try! PropertyListSerialization.data(fromPropertyList: ["x": 1], format: .xml, options: 0)
        #expect(IslDlSafariInfo.parse(none) == nil && IslDlSafariInfo.parse(Data("junk".utf8)) == nil)
        let zero = try! PropertyListSerialization.data(fromPropertyList: ["DownloadEntryProgressTotalToLoad": 0, "DownloadEntryProgressBytesSoFar": 5], format: .xml, options: 0)
        #expect(IslDlSafariInfo.parse(zero)?.total == nil)
    }

    @Test func byteFormatting() {
        #expect(IslDlFormat.bytes(0) == "0 Б" && IslDlFormat.bytes(900) == "900 Б")
        #expect(IslDlFormat.bytes(1536) == "1,5 КБ" && IslDlFormat.bytes(5 * 1024 * 1024) == "5,0 МБ")
        #expect(IslDlFormat.bytes(250 * 1024 * 1024) == "250 МБ" && IslDlFormat.bytes(-4) == "0 Б")
        #expect(IslDlFormat.speed(2 * 1024 * 1024) == "2,0 МБ/с")
    }

    @Test func etaNeedsAUsefulSpeed() {
        #expect(IslDlFormat.eta(remaining: 600_000, speed: 10_000) == "1 мин")
        #expect(IslDlFormat.eta(remaining: 6000, speed: 1000) == nil)
        #expect(IslDlFormat.eta(remaining: 0, speed: 1_000_000) == nil)
        #expect(IslDlFormat.eta(remaining: 100_000_000, speed: 20_000) == "1 ч 23 мин")
    }
}

@Suite struct IslDlDetectorTests {
    @Test func chromeDownloadFromStartToRename() {
        var d = IslDlDetector()
        prime(&d)
        let started = d.scan([file("a.zip.crdownload", 1000, at: 1)], now: F.at(1))
        #expect(started.count == 1 && started[0] == .started(d.items[0]) && d.items[0].name == "a.zip" && d.items[0].browser == .chromium)
        _ = d.scan([file("a.zip.crdownload", 5000, at: 2)], now: F.at(2))
        #expect(d.items[0].bytes == 5000 && d.items[0].speed == 4000 && d.items[0].state == .downloading)
        let done = d.scan([file("a.zip", 9000, at: 3)], now: F.at(3))
        #expect(done.count == 1)
        if case .finished(let it) = done[0] { #expect(it.name == "a.zip" && it.bytes == 9000 && it.state == .completed) } else { Issue.record("not finished") }
        #expect(d.active.isEmpty && d.recentFinished.count == 1)
    }

    @Test func finishedFileIsNotReportedAgainAsAPlainFile() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 10, at: 1)], now: F.at(1))
        _ = d.scan([file("a.zip", 9_000_000, at: 2)], now: F.at(2))
        for t in 3...12 { #expect(d.scan([file("a.zip", 9_000_000, at: 2)], now: F.at(Double(t))).isEmpty) }
        #expect(d.items.count == 1)
    }

    @Test func unconfirmedDownloadIsMatchedToTheNewFile() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("Unconfirmed 99.crdownload", 100, at: 1)], now: F.at(1))
        #expect(d.items[0].name == "Загрузка…")
        let e = d.scan([file("invoice.pdf", 4000, at: 3)], now: F.at(3))
        if case .finished(let it)? = e.first { #expect(it.name == "invoice.pdf") } else { Issue.record("not finished") }
    }

    @Test func safariDownloadReportsTheExpectedTotalAndProgress() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("big.dmg.download", 2500, at: 1, dir: true, total: 10_000)], now: F.at(1))
        #expect(d.items[0].browser == .safari && d.items[0].progress == 0.25)
        _ = d.scan([file("big.dmg.download", 7500, at: 2, dir: true, total: 10_000)], now: F.at(2))
        #expect(d.items[0].progress == 0.75)
    }

    @Test func downloadWithoutKnownTotalHasNoProgressFraction() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 500, at: 1)], now: F.at(1))
        #expect(d.items[0].progress == nil)
    }

    @Test func firefoxPartFileIsTrackedAndCompletes() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("movie.mkv.part", 100, at: 1)], now: F.at(1))
        #expect(d.items[0].browser == .firefox)
        let e = d.scan([file("movie.mkv", 5000, at: 2)], now: F.at(2))
        #expect(e.count == 1)
    }

    @Test func disappearingTempWithoutAResultIsACancellation() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 100, at: 1)], now: F.at(1))
        let e = d.scan([], now: F.at(2))
        if case .cancelled(let it)? = e.first { #expect(it.name == "a.zip") } else { Issue.record("not cancelled") }
        #expect(d.active.isEmpty)
        _ = d.scan([], now: F.at(10))
        #expect(d.items.isEmpty)
    }

    @Test func stalledDownloadIsReportedOnceAndRecovers() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 100, at: 1)], now: F.at(1))
        #expect(d.scan([file("a.zip.crdownload", 100)], now: F.at(10)).isEmpty)
        let e = d.scan([file("a.zip.crdownload", 100)], now: F.at(17))
        #expect(e.count == 1 && d.items[0].state == .stalled && d.items[0].speed == 0)
        #expect(d.scan([file("a.zip.crdownload", 100)], now: F.at(20)).isEmpty)
        _ = d.scan([file("a.zip.crdownload", 900)], now: F.at(21))
        #expect(d.items[0].state == .downloading)
    }

    @Test func stalledItemsStillCountAsActiveUntilDropped() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 100, at: 1)], now: F.at(1))
        _ = d.scan([file("a.zip.crdownload", 100)], now: F.at(30))
        #expect(d.active.count == 1)
    }

    @Test func abandonedDownloadIsDroppedAfterTheStaleWindow() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 100, at: 1)], now: F.at(1))
        _ = d.scan([file("a.zip.crdownload", 100)], now: F.at(300))
        let e = d.scan([file("a.zip.crdownload", 100)], now: F.at(602))
        #expect(e.contains { if case .cancelled = $0 { true } else { false } })
        #expect(d.active.isEmpty)
    }

    @Test func filesPresentAtStartAreIgnored() {
        var d = IslDlDetector()
        prime(&d, [file("old.pdf", 5_000_000), file("older.zip", 9_000_000)])
        for t in 1...6 { #expect(d.scan([file("old.pdf", 5_000_000), file("older.zip", 9_000_000)], now: F.at(Double(t))).isEmpty) }
        #expect(d.items.isEmpty)
    }

    @Test func tempFilePresentAtStartIsTracked() {
        var d = IslDlDetector()
        let e = d.scan([file("half.zip.crdownload", 777)], now: F.at(0))
        #expect(e.count == 1 && d.active.count == 1)
    }

    @Test func parallelDownloadsAreTrackedIndependently() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 10, at: 1), file("b.iso.part", 20, at: 1)], now: F.at(1))
        #expect(d.active.count == 2)
        _ = d.scan([file("a.zip", 1000, at: 2), file("b.iso.part", 40, at: 2)], now: F.at(2))
        #expect(d.active.map(\.name) == ["b.iso"] && d.recentFinished.map(\.name) == ["a.zip"])
    }

    @Test func plainFileThatStopsGrowingIsReportedAsDone() {
        var d = IslDlDetector()
        prime(&d)
        #expect(d.scan([file("clip.mp4", 100_000, at: 1)], now: F.at(1)).isEmpty)
        #expect(d.scan([file("clip.mp4", 100_000, at: 1)], now: F.at(2)).isEmpty)
        let e = d.scan([file("clip.mp4", 100_000, at: 1)], now: F.at(3))
        if case .finished(let it)? = e.first { #expect(it.name == "clip.mp4" && it.browser == .other) } else { Issue.record("not finished") }
    }

    @Test func growingPlainFileKeepsWaiting() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("clip.mp4", 100_000)], now: F.at(1))
        _ = d.scan([file("clip.mp4", 200_000)], now: F.at(2))
        #expect(d.scan([file("clip.mp4", 300_000)], now: F.at(3)).isEmpty)
        #expect(d.scan([file("clip.mp4", 300_000)], now: F.at(4)).isEmpty)
        #expect(d.scan([file("clip.mp4", 300_000)], now: F.at(5)).count == 1)
    }

    @Test func tinyPlainFilesAreIgnored() {
        var d = IslDlDetector()
        prime(&d)
        for t in 1...6 { #expect(d.scan([file("note.txt", 120)], now: F.at(Double(t))).isEmpty) }
        #expect(d.items.isEmpty)
    }

    @Test func plainFileTrackingCanBeSwitchedOff() {
        var c = IslDlDetectorConfig()
        c.trackPlainFiles = false
        var d = IslDlDetector(config: c)
        prime(&d)
        for t in 1...6 { #expect(d.scan([file("clip.mp4", 100_000)], now: F.at(Double(t))).isEmpty) }
    }

    @Test func hiddenFilesNeverBecomeDownloads() {
        var d = IslDlDetector()
        prime(&d)
        for t in 1...6 { #expect(d.scan([file(".DS_Store", 9_000_000), file(".secret", 9_000_000)], now: F.at(Double(t))).isEmpty) }
    }

    @Test func chromiumHiddenTempIsTrackedAsAnUnnamedDownload() {
        var d = IslDlDetector()
        prime(&d)
        let e = d.scan([file(".com.google.Chrome.Ab12Cd", 300, at: 1)], now: F.at(1))
        #expect(e.count == 1 && d.items[0].name == "Загрузка…")
    }

    @Test func historyIsTrimmedToTheLimit() {
        var c = IslDlDetectorConfig()
        c.historyLimit = 3
        var d = IslDlDetector(config: c)
        prime(&d)
        for i in 0..<6 {
            let t = Double(i * 2 + 1)
            _ = d.scan([file("f\(i).zip.crdownload", 10, at: t)], now: F.at(t))
            _ = d.scan([file("f\(i).zip", 1000, at: t + 1)], now: F.at(t + 1))
        }
        #expect(d.recentFinished.count == 3 && d.recentFinished.first?.name == "f5.zip")
    }

    @Test func redownloadingTheSameNameStartsAFreshItem() {
        var d = IslDlDetector()
        prime(&d)
        _ = d.scan([file("a.zip.crdownload", 10, at: 1)], now: F.at(1))
        _ = d.scan([file("a.zip", 1000, at: 2)], now: F.at(2))
        _ = d.scan([], now: F.at(3))
        let e = d.scan([file("a.zip.crdownload", 10, at: 4)], now: F.at(4))
        #expect(e.count == 1 && d.active.count == 1)
    }

    @Test func resetForgetsEverything() {
        var d = IslDlDetector()
        _ = d.scan([file("a.zip.crdownload", 10)], now: F.at(1))
        d.reset()
        #expect(d.items.isEmpty)
    }
}

@Suite struct IslDlActivityTests {
    private func item(_ name: String, state: IslDlState = .downloading, bytes: Int64 = 100, total: Int64? = nil, speed: Double = 0, finished: TimeInterval? = nil) -> IslDlItem {
        IslDlItem(id: "t|" + name, name: name, tempName: name, browser: .chromium, state: state, bytes: bytes, expectedTotal: total, startedAt: F.at(0), lastGrowthAt: F.at(0),
                  finishedAt: finished.map(F.at), speed: speed)
    }

    @Test func summaryOfOneDownloadUsesItsName() {
        let s = IslDlActivityFactory.summary([item("a.zip", bytes: 50, total: 100, speed: 10)])
        #expect(s?.title == "a.zip" && s?.progress == 0.5 && s?.speed == 10 && s?.count == 1)
    }

    @Test func summaryOfSeveralDownloadsCountsThem() {
        let s = IslDlActivityFactory.summary([item("a", bytes: 50, total: 100), item("b", bytes: 50, total: 300)])
        #expect(s?.title == "2 загрузки" && s?.progress == 0.25)
    }

    @Test func summaryProgressNeedsEveryTotal() {
        #expect(IslDlActivityFactory.summary([item("a", bytes: 50, total: 100), item("b")])?.progress == nil)
    }

    @Test func noActiveDownloadsMeansNoSummary() {
        #expect(IslDlActivityFactory.summary([item("a", state: .completed)]) == nil)
    }

    @Test func runningActivityHasDownloadPriority() {
        let a = IslDlActivityFactory.activity([item("a.zip")], now: F.at(5))
        #expect(a?.priority == IslPriority.download && a?.section == IslSectionIDs.downloads && a?.expiresAt == nil && a?.token.hasPrefix("run|") == true)
    }

    @Test func tokenChangesWhenTheSetOfDownloadsChanges() {
        let one = IslDlActivityFactory.activity([item("a")], now: F.at(1))?.token
        let two = IslDlActivityFactory.activity([item("a"), item("b")], now: F.at(1))?.token
        #expect(one != two)
    }

    @Test func completionActivityLastsSixSeconds() {
        let done = item("a.zip", state: .completed, finished: 10)
        #expect(IslDlActivityFactory.activity([done], now: F.at(15.9)) != nil)
        #expect(IslDlActivityFactory.activity([done], now: F.at(16.1)) == nil)
        #expect(IslDlActivityFactory.activity([done], now: F.at(15))?.token == "done|t|a.zip")
    }

    @Test func activeDownloadBeatsTheCompletionOfAnother() {
        let a = IslDlActivityFactory.activity([item("a.zip", state: .completed, finished: 10), item("b.zip")], now: F.at(11))
        #expect(a?.token.hasPrefix("run|") == true)
    }

    @Test func downloadsRankBetweenMusicAndTimer() {
        let dl = IslDlActivityFactory.activity([item("a")], now: F.at(1))!
        var one = IslArbiter()
        #expect(one.resolve([IslFix.activity("music", "music", priority: IslPriority.music, started: 5), dl], now: IslFix.at(1)).winner?.id == "download")
        var two = IslArbiter()
        #expect(two.resolve([IslFix.activity("timer", "timer", priority: IslPriority.timer), dl], now: IslFix.at(1)).winner?.id == "timer")
    }
}

final class ExtFakeLister: IslDlListing {
    var folders: [String: [IslDlFile]] = [:]
    var calls: [String] = []
    func list(_ folder: String) -> [IslDlFile]? {
        calls.append(folder)
        return folders[folder]
    }
}

final class ExtFakeWatcher: IslDlWatching {
    var path: String?
    var handler: (() -> Void)?
    var starts = 0
    var stops = 0
    func start(path: String, onChange: @escaping () -> Void) {
        starts += 1
        self.path = path
        handler = onChange
    }
    func stop() {
        stops += 1
        handler = nil
    }
    func fire() { handler?() }
}

@Suite struct IslDlMonitorTests {
    private final class Clock { var now = F.now }

    private func make(folder: String = "/tmp/dl") -> (IslDlMonitor, ExtFakeLister, ExtFakeWatcher, Clock) {
        let l = ExtFakeLister(), w = ExtFakeWatcher(), c = Clock()
        var s = IslDlSettings()
        s.folder = folder
        l.folders[folder] = []
        return (IslDlMonitor(lister: l, watcher: w, settings: s, clock: { c.now }), l, w, c)
    }

    @Test func startScansOnceAndWatchesTheFolder() {
        let (m, l, w, _) = make()
        m.start()
        #expect(l.calls == ["/tmp/dl"] && w.path == "/tmp/dl" && w.starts == 1)
    }

    @Test func filesystemEventsTriggerAScan() {
        let (m, l, w, c) = make()
        m.start()
        l.folders["/tmp/dl"] = [file("a.zip.crdownload", 10)]
        c.now = F.at(1)
        w.fire()
        #expect(m.detector.active.count == 1)
    }

    @Test func eventsAreForwardedToTheListener() {
        let (m, l, w, _) = make()
        var got: [IslDlEvent] = []
        m.onEvents = { got += $0 }
        m.start()
        l.folders["/tmp/dl"] = [file("a.zip.crdownload", 10)]
        w.fire()
        #expect(got.count == 1)
    }

    @Test func idlePollingIsSlowAndActivePollingIsFast() {
        let (m, l, _, c) = make()
        m.start()
        let base = l.calls.count
        c.now = F.at(2)
        m.tick()
        #expect(l.calls.count == base)
        c.now = F.at(6)
        m.tick()
        #expect(l.calls.count == base + 1)
        l.folders["/tmp/dl"] = [file("a.zip.crdownload", 10)]
        c.now = F.at(12)
        m.tick()
        let active = l.calls.count
        c.now = F.at(13.1)
        m.tick()
        #expect(l.calls.count == active + 1)
    }

    @Test func unreadableFolderIsReportedAndRecovers() {
        let (m, l, w, _) = make()
        m.start()
        l.folders["/tmp/dl"] = nil
        w.fire()
        #expect(!m.readable)
        l.folders["/tmp/dl"] = []
        w.fire()
        #expect(m.readable)
    }

    @Test func stopTearsDownTheWatcherAndForgetsState() {
        let (m, l, w, _) = make()
        m.start()
        l.folders["/tmp/dl"] = [file("a.zip.crdownload", 10)]
        w.fire()
        m.stop()
        #expect(w.stops == 1 && m.detector.items.isEmpty)
        let calls = l.calls.count
        m.scan()
        m.tick()
        #expect(l.calls.count == calls)
    }

    @Test func changingTheFolderRestartsWatching() {
        let (m, l, w, _) = make()
        m.start()
        l.folders["/other"] = []
        var s = m.settings
        s.folder = "/other"
        m.update(s)
        #expect(w.starts == 2 && w.stops == 1 && w.path == "/other")
    }

    @Test func updatingUnrelatedSettingsKeepsTheWatcher() {
        let (m, _, w, _) = make()
        m.start()
        var s = m.settings
        s.showCompleted = false
        m.update(s)
        #expect(w.starts == 1 && w.stops == 0)
    }

    @Test func startingTwiceDoesNothingTheSecondTime() {
        let (m, _, w, _) = make()
        m.start()
        m.start()
        #expect(w.starts == 1)
    }

    @Test func completedDownloadsCanBeHiddenFromActivities() {
        let (m, l, w, c) = make()
        var s = m.settings
        s.showCompleted = false
        m.update(s)
        m.start()
        l.folders["/tmp/dl"] = [file("a.zip.crdownload", 10)]
        c.now = F.at(1)
        w.fire()
        l.folders["/tmp/dl"] = [file("a.zip", 1000)]
        c.now = F.at(2)
        w.fire()
        #expect(m.activity(now: F.at(3)) == nil)
    }

    @Test func defaultFolderIsDownloadsInHome() {
        #expect(IslDlSettings().resolvedFolder(home: "/Users/x") == "/Users/x/Downloads")
        var s = IslDlSettings()
        s.folder = "~/Загрузки браузера"
        #expect(s.resolvedFolder(home: "/Users/x") == "/Users/x/Загрузки браузера")
        s.folder = "/Volumes/D"
        #expect(s.resolvedFolder(home: "/Users/x") == "/Volumes/D")
    }

    @Test func settingsRoundTrip() {
        let kv = WndMemoryStore()
        var s = IslDlSettings()
        s.folder = "/tmp/x"
        s.showCompleted = false
        s.minPlainKB = 512
        IslDlSettingsStore(kv).save(s)
        #expect(IslDlSettingsStore(kv).load() == s)
        IslDlSettingsStore(kv).save(IslDlSettings())
        #expect(kv.values.isEmpty)
        #expect(s.detectorConfig.minPlainBytes == 512 * 1024)
    }
}
