import Testing
import Foundation
@testable import MultitulCore

@Suite struct ClipStoreTests {
    @Test func insertAndReadBack() throws {
        let st = Clp.store()
        let r = try st.insert(Clp.candidate("первая запись"))
        #expect(!r.deduped)
        let it = try #require(try st.item(id: r.id))
        #expect(it.title == "первая запись")
        #expect(it.kind == .text)
        #expect(it.sourceBundle == "com.apple.Safari")
        #expect(it.sourceName == "Safari")
        #expect(it.useCount == 0)
        #expect(try st.text(id: r.id) == "первая запись")
        #expect(try st.count() == 1)
    }

    @Test func dedupeBumpsToTopAndKeepsOneRow() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        let a = try st.insert(Clp.candidate("a one"))
        clock.advance(10)
        _ = try st.insert(Clp.candidate("b two"))
        clock.advance(10)
        let again = try st.insert(Clp.candidate("a one", source: Clp.notes))
        #expect(again.deduped)
        #expect(again.id == a.id)
        let list = try st.items()
        #expect(list.map(\.title) == ["a one", "b two"])
        #expect(list[0].sourceName == "Заметки")
        #expect(list[0].created < list[0].used)
        #expect(try st.count() == 2)
    }

    @Test func dedupeReplacesRepresentationsWithTheNewestOnes() throws {
        let st = Clp.store()
        let plain = try st.insert(Clp.candidate("same text"))
        var s = ClipSettings()
        s.keepRich = true
        let rtf = Data("{\\rtf1 same text}".utf8)
        guard case .record(let rich) = ClipCapture.evaluate(Clp.snap([Clp.text("same text", extra: [PBType.rtf: rtf])]), settings: s) else { Issue.record("x"); return }
        let r = try st.insert(rich)
        #expect(r.id == plain.id)
        #expect(try st.item(id: r.id)?.kind == .rich)
        #expect(Set(try st.reps(id: r.id).map(\.type)) == [PBType.utf8, PBType.rtf])
    }

    @Test func pinnedItemsComeFirstThenNewest() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        let a = try st.insert(Clp.candidate("old pinned"))
        clock.advance(5)
        _ = try st.insert(Clp.candidate("middle"))
        clock.advance(5)
        _ = try st.insert(Clp.candidate("newest"))
        try st.setPinned(id: a.id, true)
        #expect(try st.items().map(\.title) == ["old pinned", "newest", "middle"])
        try st.setPinned(id: a.id, false)
        #expect(try st.items().map(\.title) == ["newest", "middle", "old pinned"])
    }

    @Test func searchIsCaseInsensitiveForCyrillicAndMatchesAllWords() throws {
        let st = Clp.store()
        _ = try st.insert(Clp.candidate("Адрес: Санкт-Петербург, Бутлерова 11"))
        _ = try st.insert(Clp.candidate("Телефон +7 931"))
        _ = try st.insert(Clp.candidate("Hello World"))
        #expect(try st.search("петербург").map(\.title) == ["Адрес: Санкт-Петербург, Бутлерова 11"])
        #expect(try st.search("БУТЛЕРОВА адрес").count == 1)
        #expect(try st.search("бутлерова телефон").isEmpty)
        #expect(try st.search("hello").count == 1)
        #expect(try st.search("").count == 3)
    }

    @Test func searchTreatsLikeWildcardsLiterally() throws {
        let st = Clp.store()
        _ = try st.insert(Clp.candidate("скидка 50% сегодня"))
        _ = try st.insert(Clp.candidate("файл_имя тест"))
        _ = try st.insert(Clp.candidate("обычный текст"))
        #expect(try st.search("50%").count == 1)
        #expect(try st.search("%").count == 1)
        #expect(try st.search("_").count == 1)
    }

    @Test func searchFiltersByKind() throws {
        let st = Clp.store()
        _ = try st.insert(Clp.candidate("текст про картинку"))
        var s = ClipSettings()
        s.keepImages = true
        guard case .record(let img) = ClipCapture.evaluate(Clp.snap([PasteboardItemData(reps: [PBType.png: Clp.png()])]), settings: s) else { Issue.record("x"); return }
        _ = try st.insert(img)
        #expect(try st.search("", kinds: [.image]).map(\.kind) == [.image])
        #expect(try st.search("картинк", kinds: [.text, .rich]).count == 1)
        #expect(try st.search("картинк").count == 2)
    }

    @Test func blobRoundTripsBinaryData() throws {
        let st = Clp.store()
        var s = ClipSettings()
        s.keepImages = true
        let png = Clp.png(width: 20, height: 20)
        guard case .record(let img) = ClipCapture.evaluate(Clp.snap([PasteboardItemData(reps: [PBType.png: png])]), settings: s) else { Issue.record("x"); return }
        let r = try st.insert(img)
        let reps = try st.reps(id: r.id)
        #expect(reps.count == 1)
        #expect(reps[0].data == png)
        #expect(try st.item(id: r.id)?.size == png.count)
    }

    @Test func deleteRemovesRepresentationsToo() throws {
        let st = Clp.store()
        let a = try st.insert(Clp.candidate("one one"))
        let b = try st.insert(Clp.candidate("two two"))
        try st.delete(ids: [a.id])
        #expect(try st.count() == 1)
        #expect(try st.reps(id: a.id).isEmpty)
        #expect(!(try st.reps(id: b.id).isEmpty))
    }

    @Test func clearKeepsPinnedWhenAsked() throws {
        let st = Clp.store()
        let a = try st.insert(Clp.candidate("pinned one"))
        _ = try st.insert(Clp.candidate("loose one"))
        try st.setPinned(id: a.id, true)
        #expect(try st.clear(keepPinned: true) == 1)
        #expect(try st.items().map(\.title) == ["pinned one"])
        #expect(try st.clear(keepPinned: false) == 1)
        #expect(try st.count() == 0)
        #expect(try st.store.scalarInt("SELECT count(*) FROM clip_reps") == 0)
    }

    @Test func touchRaisesUseCountAndMovesUp() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        let a = try st.insert(Clp.candidate("first one"))
        clock.advance(1)
        _ = try st.insert(Clp.candidate("second one"))
        clock.advance(1)
        try st.touch(id: a.id)
        try st.touch(id: a.id)
        #expect(try st.items().first?.title == "first one")
        #expect(try st.item(id: a.id)?.useCount == 2)
    }

    @Test func pruneByCountKeepsNewestAndPinned() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        var ids: [Int64] = []
        for i in 1...8 {
            clock.advance(1)
            ids.append(try st.insert(Clp.candidate("item number \(i)")).id)
        }
        try st.setPinned(id: ids[0], true)
        var s = ClipSettings()
        s.maxItems = 5
        s.maxAgeDays = 0
        let r = try st.prune(s)
        #expect(r.byCount == 2)
        let titles = try st.items().map(\.title)
        #expect(titles.count == 6)
        #expect(titles.first == "item number 1")
        #expect(Set(titles).isSuperset(of: ["item number 8", "item number 4"]))
        #expect(!titles.contains("item number 3"))
        #expect(try st.store.scalarInt("SELECT count(*) FROM clip_reps") == 6)
    }

    @Test func pruneByAgeSkipsPinned() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        let old = try st.insert(Clp.candidate("ancient pinned"))
        _ = try st.insert(Clp.candidate("ancient loose"))
        try st.setPinned(id: old.id, true)
        clock.advance(40 * 86400)
        _ = try st.insert(Clp.candidate("fresh one"))
        var s = ClipSettings()
        s.maxAgeDays = 30
        let r = try st.prune(s)
        #expect(r.byAge == 1)
        #expect(Set(try st.items().map(\.title)) == ["ancient pinned", "fresh one"])
    }

    @Test func pruneBySizeDropsOldestUnpinnedFirst() throws {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        var s = ClipSettings()
        s.keepImages = true
        s.maxTotalMB = 8
        var pngs: [Data] = []
        for i in 0..<3 {
            clock.advance(1)
            let data = Data(repeating: UInt8(i), count: 4 * 1024 * 1024)
            pngs.append(data)
            guard case .record(let c) = ClipCapture.evaluate(Clp.snap([PasteboardItemData(reps: [PBType.png: data])]), settings: s) else { Issue.record("x"); return }
            _ = try st.insert(c)
        }
        let r = try st.prune(s)
        #expect(r.bySize == 1)
        #expect(try st.count() == 2)
        #expect(try st.totalBytes() == 8 * 1024 * 1024)
    }

    @Test func migrationV2PreservesExistingRowsAndAddsColumn() throws {
        let path = tempDBPath()
        let v1 = Array(ClipSchema.migrations.prefix(1))
        do {
            let s = try Store(path: path, migrations: v1, retention: [])
            try s.run("INSERT INTO clip_items(kind, hash, title, search, created, used, pinned, size) VALUES('text','h1','старая','старая',1000,2000,1,5)")
            try s.run("INSERT INTO clip_reps(item_id, idx, type, data) VALUES(1,0,'public.utf8-plain-text',?)", [.blob(Data("старая".utf8))])
            #expect(try s.appliedMigrations().filter { $0.scope == "clip" }.map(\.version) == [1])
        }
        let st = try ClipStore.open(path: path)
        #expect(try st.store.appliedMigrations().filter { $0.scope == "clip" }.map(\.version) == [1, 2])
        let it = try #require(try st.items().first)
        #expect(it.title == "старая")
        #expect(it.pinned)
        #expect(it.useCount == 0)
        #expect(try st.text(id: it.id) == "старая")
        _ = try st.insert(Clp.candidate("новая запись"))
        #expect(try st.count() == 2)
    }

    @Test func reopeningKeepsDataAndDoesNotReapplyMigrations() throws {
        let path = tempDBPath()
        do { _ = try Clp.store(path: path).insert(Clp.candidate("persisted text")) }
        let again = Clp.store(path: path)
        #expect(try again.items().map(\.title) == ["persisted text"])
        #expect(try again.store.scalarInt("SELECT count(*) FROM schema_migrations WHERE scope='clip'") == 2)
    }

    @Test func clipTablesLiveNextToOtherScopes() throws {
        let path = tempDBPath()
        let s = try Store(path: path, migrations: Store.coreMigrations + ClipSchema.migrations, retention: Store.coreRetention)
        let applied = try s.appliedMigrations()
        #expect(applied.contains { $0.scope == "core" })
        #expect(applied.contains { $0.scope == "clip" && $0.version == 2 })
    }
}
