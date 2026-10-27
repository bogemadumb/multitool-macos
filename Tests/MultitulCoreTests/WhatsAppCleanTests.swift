import Testing
import Foundation
@testable import MultitulCore

private func cat(_ e: CleanEnv) -> CleanCategory { cleanerDefs.first { $0.id == "cl-whatsapp" }!.run(e) }

private func dateString(daysAgo: Int) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400))
}

private let box = WhatsAppRules.groupContainer

@Suite struct WhatsAppNamesTests {
    @Test(arguments: [
        ("WhatsApp Image 2024-03-05 at 12.34.56.jpeg", WhatsAppKind.image), ("WhatsApp Image 2024-03-05 at 12.34.56 (1).jpeg", .image), ("WhatsApp Video 2024-03-05 at 12.34.56.mp4", .video),
        ("WhatsApp Audio 2024-03-05 at 12.34.56.opus", .audio), ("WhatsApp Ptt 2024-03-05 at 12.34.56.ogg", .voice), ("WhatsApp Sticker 2024-03-05.webp", .sticker),
        ("WhatsApp Animation 2024-03-05.mp4", .video), ("WhatsApp Unknown 2024-03-05 at 12.00.00", .other), ("whatsapp image 2024-03-05.jpg", .image),
        ("IMG-20240305-WA0001.jpg", .image), ("VID-20240305-WA0003.mp4", .video), ("AUD-20240305-WA0002.m4a", .audio), ("PTT-20240305-WA0009.opus", .voice), ("STK-20240305-WA0001.webp", .sticker),
        ("DOC-20240305-WA0007.pdf", .document)
    ])
    func recognisedNames(_ name: String, _ kind: WhatsAppKind) {
        #expect(WhatsAppNames.parse(name)?.kind == kind, "\(name)")
    }

    @Test(arguments: ["photo.jpg", "WhatsApp.dmg", "WhatsApp-Installer.zip", "MyWhatsApp Image.jpg", "IMG_1234.jpg", "IMG-2024-WA.jpg", "Screenshot 2024-03-05.png", "whatsapp", "WhatsApp Chat - Mom.zip"])
    func ignoredNames(_ name: String) {
        #expect(WhatsAppNames.parse(name) == nil, "\(name)")
    }

    @Test func receivedDayIsReadFromTheName() {
        let d = WhatsAppNames.parse("WhatsApp Image 2024-03-05 at 12.34.56.jpeg")?.date
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(d.map { utc.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2024, month: 3, day: 5))
        let a = WhatsAppNames.parse("VID-20231231-WA0001.mp4")?.date
        #expect(a.map { utc.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2023, month: 12, day: 31))
    }

    @Test func impossibleDatesAreIgnored() {
        #expect(WhatsAppNames.parse("WhatsApp Image 2024-13-45 at 1.jpg")?.date == nil)
        #expect(WhatsAppNames.parse("WhatsApp Image 1999-01-01 at 1.jpg")?.date == nil)
        #expect(WhatsAppNames.parse("WhatsApp Image without date.jpg")?.kind == .image)
    }

    @Test(arguments: [("jpg", WhatsAppKind.image), ("HEIC", .image), ("mp4", .video), ("mov", .video), ("opus", .voice), ("m4a", .audio), ("webp", .sticker), ("pdf", .document), ("xlsx", .document), ("bin", .other), ("", .other)])
    func extensionKinds(_ ext: String, _ kind: WhatsAppKind) {
        #expect(WhatsAppNames.kind(ofExtension: ext) == kind)
    }
}

@Suite struct WhatsAppRulesTests {
    @Test func defaultsKeepLongLivedThingsLonger() {
        let r = WhatsAppRules()
        #expect(r.days(.document) > r.days(.image) && r.days(.image) > r.days(.video) && r.days(.sticker) < r.days(.voice))
        #expect(WhatsAppKind.allCases.allSatisfy { r.days($0) == $0.defaultKeepDays })
    }

    @Test func loadReadsAndClampsStoredDays() {
        let kv = WndMemoryStore()
        kv.values["cleaner.whatsapp.imageDays"] = 45
        kv.values["cleaner.whatsapp.videoDays"] = -5
        kv.values["cleaner.whatsapp.audioDays"] = 99999
        kv.values["cleaner.whatsapp.voiceDays"] = 0
        let r = WhatsAppRules.load(kv)
        #expect(r.days(.image) == 45 && r.days(.video) == 0 && r.days(.audio) == 1095 && r.days(.voice) == 0 && r.days(.document) == 180)
    }

    @Test func defaultsKeysAreLatin() {
        #expect(WhatsAppKind.allCases.allSatisfy { $0.defaultsKey.allSatisfy(\.isASCII) && $0.defaultsKey.hasPrefix("cleaner.whatsapp.") })
        #expect(Set(WhatsAppKind.allCases.map(\.defaultsKey)).count == WhatsAppKind.allCases.count)
    }

    @Test func categoryIsInTheCleanerCatalogAndNeverAutomatic() {
        let d = cleanerDefs.first { $0.id == "cl-whatsapp" }
        #expect(d != nil && d?.level == .review)
        if case .trash(let purge)? = d?.action { #expect(!purge) } else { Issue.record("must go to the Trash") }
        #expect(!CleanerSchedule.autoCategories.contains("cl-whatsapp"))
        #expect(WhatsAppKind.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite struct WhatsAppScanTests {
    @Test func oldDownloadsAreGroupedPerKind() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.34.56.jpeg", bytes: 20_000)
        f.file("Downloads/WhatsApp Image 2024-03-06 at 12.34.56.jpeg", bytes: 20_000)
        f.file("Downloads/WhatsApp Video 2024-03-05 at 12.34.56.mp4", bytes: 50_000)
        f.file("Downloads/IMG-20230105-WA0001.jpg", bytes: 10_000)
        f.file("Downloads/report.pdf", bytes: 10_000)
        let c = cat(f.env())
        #expect(Set(c.items.map(\.id)) == ["wa-dl-image", "wa-dl-video"])
        let img = c.items.first { $0.id == "wa-dl-image" }!
        #expect(img.paths.count == 3 && img.subtitle.contains("файлов: 3") && img.subtitle.contains("старше 90 дн."))
        #expect(c.items.allSatisfy { !$0.paths.contains { $0.hasSuffix("report.pdf") } })
        #expect(c.items[0].bytes >= c.items[1].bytes)
    }

    @Test func recentFilesStay() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image \(dateString(daysAgo: 5)) at 10.00.00.jpeg")
        f.file("Downloads/WhatsApp Video \(dateString(daysAgo: 29)) at 10.00.00.mp4")
        f.file("Downloads/WhatsApp Image \(dateString(daysAgo: 91)) at 10.00.00.jpeg")
        let c = cat(f.env())
        #expect(c.items.map(\.id) == ["wa-dl-image"] && c.items[0].paths.count == 1 && c.items[0].paths[0].contains(dateString(daysAgo: 91)))
    }

    @Test func eachKindHasItsOwnClock() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Video \(dateString(daysAgo: 40)) at 10.00.00.mp4")
        f.file("Downloads/WhatsApp Image \(dateString(daysAgo: 40)) at 10.00.00.jpeg")
        f.file("Downloads/WhatsApp Ptt \(dateString(daysAgo: 40)) at 10.00.00.ogg")
        f.file("Downloads/WhatsApp Sticker \(dateString(daysAgo: 20)) at 10.00.00.webp")
        let c = cat(f.env())
        #expect(Set(c.items.map(\.id)) == ["wa-dl-video", "wa-dl-voice", "wa-dl-sticker"])
    }

    @Test func zeroDaysMeansDoNotTouchThatKind() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg")
        f.file("Downloads/WhatsApp Video 2024-03-05 at 12.00.00.mp4")
        var e = f.env()
        e.whatsapp.keepDays[.image] = 0
        #expect(cat(e).items.map(\.id) == ["wa-dl-video"])
    }

    @Test func customDaysApply() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image \(dateString(daysAgo: 20)) at 10.00.00.jpeg")
        var e = f.env()
        #expect(cat(e).items.isEmpty)
        e.whatsapp.keepDays[.image] = 7
        #expect(cat(e).items.count == 1)
    }

    @Test func aRecentlyOpenedOldFileIsKept() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg")
        var e = f.env()
        e.lastOpened = { _ in Date() }
        #expect(cat(e).items.isEmpty)
        e.lastOpened = { _ in Date().addingTimeInterval(-400 * 86400) }
        #expect(cat(e).items.count == 1)
    }

    @Test func fileWithoutADateFallsBackToItsModificationTime() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image no date.jpeg", daysAgo: 200)
        f.file("Downloads/WhatsApp Video no date.mp4", daysAgo: 2)
        #expect(cat(f.env()).items.map(\.id) == ["wa-dl-image"])
    }

    @Test func foldersAndSymlinksAreNotListed() {
        let f = CleanFixture()
        f.dir("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg")
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg/inner.jpg")
        let target = f.file("Documents/real.jpg")
        f.link("Downloads/WhatsApp Image 2024-03-06 at 12.00.00.jpeg", to: target)
        #expect(cat(f.env()).items.isEmpty)
        #expect(f.existsAbs(target))
    }

    @Test func downloadsSourceCanBeSwitchedOff() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg")
        var e = f.env()
        e.whatsapp.includeDownloads = false
        #expect(cat(e).items.isEmpty)
    }

    @Test func appContainerMediaIsJudgedByModificationTime() {
        let f = CleanFixture()
        f.file(box + "/chat1/a.jpg", bytes: 30_000, daysAgo: 200)
        f.file(box + "/chat1/b.mp4", bytes: 30_000, daysAgo: 10)
        f.file(box + "/chat2/c.opus", bytes: 30_000, daysAgo: 40)
        f.file(box + "/chat2/d.pdf", bytes: 30_000, daysAgo: 100)
        f.file(box + "/chat2/e.jpg.thumb", bytes: 30_000, daysAgo: 300)
        f.file(box + "/chat2/.hidden.jpg", bytes: 30_000, daysAgo: 300)
        let c = cat(f.env())
        #expect(Set(c.items.map(\.id)) == ["wa-box-image", "wa-box-voice"])
        #expect(c.items.allSatisfy { $0.title.hasPrefix("Медиа в приложении WhatsApp") })
        #expect(c.items.flatMap(\.paths).count == 2)
    }

    @Test func runningWhatsAppBlocksOnlyTheAppContainer() {
        let f = CleanFixture()
        f.file(box + "/chat1/a.jpg", daysAgo: 200)
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg")
        let c = cat(f.env(running: [RunningApp(bundleId: "net.whatsapp.WhatsApp", name: "WhatsApp")]))
        #expect(c.items.first { $0.id == "wa-box-image" }?.blocked != nil)
        #expect(c.items.first { $0.id == "wa-dl-image" }?.blocked == nil)
    }

    @Test func missingContainerIsFine() {
        let f = CleanFixture()
        #expect(cat(f.env()).items.isEmpty)
    }

    @Test func trashFlowMovesFilesAndKeepsThemRecoverable() {
        let f = CleanFixture()
        f.file("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg", bytes: 20_000)
        f.file("Downloads/keep.pdf", bytes: 20_000)
        let e = f.env()
        let cats = scanCategoriesSorted(env: e, defs: cleanerDefs.filter { $0.id == "cl-whatsapp" })
        let rep = executeClean(cats, picked: Set(cats[0].items.map(\.id)), env: e)
        #expect(rep.movedCount == 1 && rep.purgedCount == 0)
        #expect(!f.exists("Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg") && f.exists("Downloads/keep.pdf"))
        #expect(f.trashContents().count == 1)
    }

    @Test func blockedItemsAreNotMoved() {
        let f = CleanFixture()
        f.file(box + "/chat1/a.jpg", bytes: 20_000, daysAgo: 200)
        let e = f.env(running: [RunningApp(bundleId: "net.whatsapp.WhatsApp", name: "WhatsApp")])
        let cats = scanCategoriesSorted(env: e, defs: cleanerDefs.filter { $0.id == "cl-whatsapp" })
        let rep = executeClean(cats, picked: Set(cats[0].items.map(\.id)), env: e)
        #expect(rep.movedCount == 0 && f.exists(box + "/chat1/a.jpg"))
    }

    @Test func deniedPathsStayUntouchable() {
        let f = CleanFixture()
        #expect(!isDeniedPath(f.home + "/Downloads/WhatsApp Image 2024-03-05 at 12.00.00.jpeg", home: f.home))
        #expect(isDeniedPath(f.home + "/Downloads", home: f.home))
        #expect(isDeniedPath(f.home + "/Library/Group Containers", home: f.home))
        #expect(!isDeniedPath(f.home + "/" + box + "/chat/a.jpg", home: f.home))
    }
}

private final class CbFakeSwitcherSource: SwitcherSource {
    var snap = SwitcherSnapshot()
    func snapshot() -> SwitcherSnapshot { snap }
    func refresh(_ completion: @escaping (SwitcherSnapshot) -> Void) { completion(snap) }
}

@Suite struct CbLiveAdaptersTests {
    @Test func windowSourceBuildsTheSwitcherListWithoutOurOwnWindows() {
        let src = CbFakeSwitcherSource()
        src.snap = SwitcherSnapshot(windows: [SwitchWindow(key: 1, windowID: 11, pid: 10, bundleID: "a", appName: "Safari", title: "Apple"), SwitchWindow(key: 2, windowID: 12, pid: 77, bundleID: "me", appName: "Multitul", title: "Window"),
                                              SwitchWindow(key: 3, windowID: 13, pid: 10, bundleID: "a", appName: "Safari", title: "Tiny", frame: CGRect(x: 0, y: 0, width: 10, height: 10))],
                                    apps: [SwitchApp(pid: 10, bundleID: "a", name: "Safari")])
        let list = SwitcherCbWindowSource(source: src, ownPID: 77).windows()
        #expect(list.map(\.title) == ["Apple"] && list.allSatisfy { $0.kind == .window })
    }

    @Test func spotlightPredicateRequiresEveryWord() {
        let p = SpotlightFileSearcher.predicate(for: "annual  report 2024")
        #expect((p as? NSCompoundPredicate)?.subpredicates.count == 3)
        #expect(SpotlightFileSearcher.predicate(for: "   ") == nil)
        #expect(p?.predicateFormat.contains("CONTAINS[cd]") == true)
    }

    @Test func spotlightPredicateDoesNotInterpretQuotesOrWildcards() {
        let p = SpotlightFileSearcher.predicate(for: "a\" OR 1==1 *")
        #expect((p as? NSCompoundPredicate)?.subpredicates.count == 4)
    }

    @Test func folderScriptSourceListsOnlyVisibleEntriesOfAFolder() throws {
        let dir = NSTemporaryDirectory() + "cb-scripts-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for n in ["b.sh", "a.py", ".hidden.sh"] { FileManager.default.createFile(atPath: dir + "/" + n, contents: Data()) }
        let list = FolderCbScriptSource().scripts(in: dir)
        #expect(list == [dir + "/a.py", dir + "/b.sh"])
        #expect(FolderCbScriptSource().scripts(in: dir + "/missing").isEmpty)
    }

    @Test func quickLauncherSourceReadsTheStoredItems() {
        let kv = WndMemoryStore()
        let store = QuickLauncherSettingsStore(kv)
        var s = QuickLauncherSettings()
        s.items = [LauncherItem(id: "x", title: "X", target: .url("https://x.y"))]
        store.save(s)
        #expect(QuickLauncherCbSource(store: store).items().map(\.id) == ["x"])
    }
}
