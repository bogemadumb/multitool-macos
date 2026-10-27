import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func store() -> ShotHistoryStore { try! ShotHistoryStore(store: ShotHistorySchema.openStore(path: ":memory:")) }

private func rec(_ title: String, at t: Double, mode: ShotMode = .area, app: String = "", ocr: String = "", path: String? = nil, owned: Bool = false, pinned: Bool = false, bytes: Int = 100) -> ShotRecord {
    ShotRecord(created: Date(timeIntervalSince1970: t), mode: mode, title: title, app: app, path: path, owned: owned, width: 100, height: 50, bytes: bytes, ocr: ocr, pinned: pinned)
}

@Suite struct ShotHistoryTests {
    @Test func insertAndReadBack() throws {
        let s = store()
        let id = try s.insert(rec("Снимок 1", at: 1000, mode: .window, app: "Safari", path: "/tmp/a.png"), thumbnail: Data([1, 2, 3]))
        let r = try s.record(id: id)!
        #expect(r.title == "Снимок 1" && r.mode == .window && r.app == "Safari" && r.path == "/tmp/a.png" && r.width == 100 && r.bytes == 100)
        #expect(r.created == Date(timeIntervalSince1970: 1000) && !r.owned && !r.pinned && r.link == nil)
        #expect(try s.thumbnail(id: id) == Data([1, 2, 3]))
        #expect(try s.count() == 1)
    }

    @Test func recentIsNewestFirst() throws {
        let s = store()
        for i in 1...5 { try s.insert(rec("n\(i)", at: Double(i * 10))) }
        #expect(try s.recent(limit: 3).map(\.title) == ["n5", "n4", "n3"])
        #expect(try s.recent(limit: 3, offset: 3).map(\.title) == ["n2", "n1"])
        #expect(try s.latest()?.title == "n5")
    }

    @Test func recentCanFilterByMode() throws {
        let s = store()
        try s.insert(rec("a", at: 1, mode: .area))
        try s.insert(rec("w", at: 2, mode: .window))
        try s.insert(rec("s", at: 3, mode: .scroll))
        #expect(try s.recent(mode: .window).map(\.title) == ["w"])
    }

    @Test func searchMatchesTitleAppAndModeWithoutCase() throws {
        let s = store()
        try s.insert(rec("Отчёт по продажам", at: 1, app: "Numbers"))
        try s.insert(rec("Схема", at: 2, mode: .window, app: "Safari"))
        #expect(try s.search("ОТЧЁТ").map(\.title) == ["Отчёт по продажам"])
        #expect(try s.search("отчет").count == 1)
        #expect(try s.search("safari").map(\.title) == ["Схема"])
        #expect(try s.search("окно").map(\.title) == ["Схема"])
        #expect(try s.search("numbers продажам").count == 1)
        #expect(try s.search("numbers схема").isEmpty)
    }

    @Test func searchFindsTextRecognisedOnTheScreenshot() throws {
        let s = store()
        let id = try s.insert(rec("x", at: 1))
        #expect(try s.search("накладная").isEmpty)
        try s.setOcr(id: id, text: "Счёт-фактура № 15 Накладная от 12 октября")
        #expect(try s.search("накладная").map(\.id) == [id])
        #expect(try s.search("счет").map(\.id) == [id])
        #expect(try s.record(id: id)?.ocr.contains("Накладная") == true)
    }

    @Test func emptyQueryReturnsEverything() throws {
        let s = store()
        try s.insert(rec("a", at: 1))
        try s.insert(rec("b", at: 2))
        #expect(try s.search("   ").count == 2)
    }

    @Test func searchTreatsWildcardsLiterally() throws {
        let s = store()
        try s.insert(rec("100% готово", at: 1))
        try s.insert(rec("просто", at: 2))
        try s.insert(rec("a_b", at: 3))
        #expect(try s.search("%").map(\.title) == ["100% готово"])
        #expect(try s.search("a_b").count == 1)
        #expect(try s.search("_").count == 1)
        #expect(try s.search("'; drop table shot_items; --").isEmpty)
        #expect(try s.count() == 3)
    }

    @Test func searchLimitApplies() throws {
        let s = store()
        for i in 0..<10 { try s.insert(rec("кот \(i)", at: Double(i))) }
        #expect(try s.search("кот", limit: 4).count == 4)
    }

    @Test func insertingWithOcrIndexesItImmediately() throws {
        let s = store()
        try s.insert(rec("y", at: 1, ocr: "уникальное слово"))
        #expect(try s.search("уникальное").count == 1)
    }

    @Test func pruneByCountKeepsTheNewestAndPinned() throws {
        let s = store()
        for i in 1...6 { try s.insert(rec("n\(i)", at: Double(i), pinned: i == 1)) }
        let gone = try s.prune(ShotPrunePolicy(maxCount: 3, maxAgeDays: 0))
        #expect(Set(gone.map(\.title)) == ["n2", "n3"])
        #expect(Set(try s.recent().map(\.title)) == ["n1", "n4", "n5", "n6"])
    }

    @Test func pruneByAgeSkipsPinned() throws {
        let s = store()
        let now = Date(timeIntervalSince1970: 100 * 86400)
        try s.insert(rec("old", at: 10 * 86400))
        try s.insert(rec("oldPinned", at: 11 * 86400, pinned: true))
        try s.insert(rec("fresh", at: 99 * 86400))
        let gone = try s.prune(ShotPrunePolicy(maxCount: 0, maxAgeDays: 30), now: now)
        #expect(gone.map(\.title) == ["old"])
        #expect(try s.count() == 2)
    }

    @Test func pruneReturnsRecordsSoTheCallerCanRemoveOwnedFiles() throws {
        let s = store()
        try s.insert(rec("a", at: 1, path: "/cache/a.png", owned: true))
        try s.insert(rec("b", at: 2, path: "/user/b.png", owned: false))
        try s.insert(rec("c", at: 3))
        let gone = try s.prune(ShotPrunePolicy(maxCount: 1, maxAgeDays: 0))
        #expect(gone.map(\.path) == ["/cache/a.png", "/user/b.png"] && gone.map(\.owned) == [true, false])
    }

    @Test func zeroPolicyPrunesNothing() throws {
        let s = store()
        for i in 1...3 { try s.insert(rec("n\(i)", at: Double(i))) }
        #expect(try s.prune(ShotPrunePolicy(maxCount: 0, maxAgeDays: 0)).isEmpty)
    }

    @Test func deleteReturnsWhatItRemoved() throws {
        let s = store()
        let a = try s.insert(rec("a", at: 1, path: "/x/a.png"))
        let removed = try s.delete(ids: [a, 9999])
        #expect(removed.map(\.id) == [a])
        #expect(try s.count() == 0)
    }

    @Test func linksAreStoredAndExpire() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        try s.setLink(id: id, url: "https://x.example/a", expires: Date(timeIntervalSince1970: 5000))
        let r = try s.record(id: id)!
        #expect(r.link == "https://x.example/a" && r.linkIsAlive(now: Date(timeIntervalSince1970: 4000)) && !r.linkIsAlive(now: Date(timeIntervalSince1970: 6000)))
        #expect(try s.expiredLinks(now: Date(timeIntervalSince1970: 4000)).isEmpty)
        #expect(try s.expiredLinks(now: Date(timeIntervalSince1970: 6000)).map(\.id) == [id])
        try s.setLink(id: id, url: nil, expires: nil)
        #expect(try s.record(id: id)?.link == nil)
    }

    @Test func locationUpdateKeepsTheRowAndTheText() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1, ocr: "слово", path: "/c/a.png", owned: true))
        try s.setLocation(id: id, path: "/u/a.png", owned: false, bytes: 777, width: 10, height: 20, format: "jpeg")
        let r = try s.record(id: id)!
        #expect(r.path == "/u/a.png" && !r.owned && r.bytes == 777 && r.width == 10 && r.format == "jpeg")
        #expect(try s.search("слово").count == 1)
    }

    @Test func pinnedFlagAndDocumentRoundTrip() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        try s.setPinned(id: id, true)
        try s.setDocument(id: id, json: Data("{}".utf8))
        #expect(try s.record(id: id)?.pinned == true)
        #expect(try s.document(id: id) == Data("{}".utf8))
        try s.setDocument(id: id, json: nil)
        #expect(try s.document(id: id) == nil)
    }

    @Test func totalBytesSums() throws {
        let s = store()
        try s.insert(rec("a", at: 1, bytes: 10))
        try s.insert(rec("b", at: 2, bytes: 32))
        #expect(try s.totalBytes() == 42)
    }

    @Test func thumbnailCanBeReplaced() throws {
        let s = store()
        let id = try s.insert(rec("a", at: 1))
        #expect(try s.thumbnail(id: id) == nil)
        try s.setThumbnail(id: id, data: Data([9]))
        #expect(try s.thumbnail(id: id) == Data([9]))
    }

    @Test func migrationIsAppliedOnceAndSharesTheDatabase() throws {
        let path = NSTemporaryDirectory() + "shot-hist-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + "-wal"); try? FileManager.default.removeItem(atPath: path + "-shm") }
        let a = try ShotHistoryStore.open(path: path)
        try a.insert(rec("a", at: 1))
        let b = try ShotHistoryStore.open(path: path)
        #expect(try b.count() == 1)
        #expect(try b.store.appliedMigrations().filter { $0.scope == "shots" }.count == 1)
    }

    @Test func searchTextNormalisation() {
        #expect(ShotSearchText.normalize("ЁЖ Ёлка") == "еж елка")
        #expect(ShotSearchText.words("  a   B ") == ["a", "b"])
        #expect(ShotSearchText.likePattern("a%b_c\\") == "%a\\%b\\_c\\\\%")
        #expect(ShotSearchText.build(title: "T", app: "", ocr: "", mode: .scroll) == "t прокрутка")
    }
}
