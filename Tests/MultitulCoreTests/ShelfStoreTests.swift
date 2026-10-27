import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShelfStoreTests {
    private func cand(_ text: String) -> ShelfCandidate {
        ShelfIngest.candidate(.text(text), fs: ShfFS())!
    }

    @Test func roundTripTextWithPayload() throws {
        let st = Shf.store()
        let r = try st.insert(cand("привет, полка"))
        #expect(!r.deduped)
        let it = try #require(try st.item(id: r.id))
        #expect(it.kind == .text)
        #expect(it.title == "привет, полка")
        #expect(it.detail == "13 симв.")
        #expect(!it.pinned)
        #expect(try st.payload(id: r.id)?.body == "привет, полка")
        #expect(try st.count() == 1)
    }

    @Test func roundTripImageBlob() throws {
        let st = Shf.store()
        let data = Data((0..<2048).map { UInt8($0 % 251) })
        let c = try #require(ShelfIngest.candidate(.image(data, ext: "png", name: "снимок"), fs: ShfFS()))
        let r = try st.insert(c)
        let it = try #require(try st.item(id: r.id))
        #expect(it.kind == .image)
        #expect(it.ext == "png")
        #expect(it.size == 2048)
        #expect(try st.payload(id: r.id)?.data == data)
    }

    @Test func roundTripFileKeepsBookmarkAndPath() throws {
        let fs = ShfFS()
        fs.addFile("/Users/x/a.txt", size: 5)
        let c = try #require(ShelfIngest.candidate(.file(path: "/Users/x/a.txt", owned: false), fs: fs))
        let st = Shf.store()
        let r = try st.insert(c)
        let it = try #require(try st.item(id: r.id))
        #expect(it.path == "/Users/x/a.txt")
        #expect(it.kind == .file)
        #expect(try st.payload(id: r.id)?.bookmark == c.payload.bookmark)
    }

    @Test func itemsSurviveReopeningTheDatabase() throws {
        let path = tempDBPath()
        let st = Shf.store(path: path)
        let a = try st.insert(cand("one"))
        try st.setPinned(id: a.id, true)
        _ = try st.insert(cand("two"))
        let again = Shf.store(path: path)
        let list = try again.items()
        #expect(list.map(\.title) == ["one", "two"])
        #expect(list[0].pinned)
        #expect(try again.payload(id: a.id)?.body == "one")
    }

    @Test func duplicateMovesToTopAndKeepsOneRow() throws {
        let clock = ShfClock()
        let st = Shf.store(clock: clock)
        let a = try st.insert(cand("alpha"))
        clock.advance(5)
        _ = try st.insert(cand("beta"))
        clock.advance(5)
        let again = try st.insert(cand("alpha"))
        #expect(again.deduped)
        #expect(again.id == a.id)
        #expect(try st.items().map(\.title) == ["alpha", "beta"])
        #expect(try st.count() == 2)
    }

    @Test func duplicateKeepsThePin() throws {
        let st = Shf.store()
        let a = try st.insert(cand("keep"))
        try st.setPinned(id: a.id, true)
        _ = try st.insert(cand("keep"))
        #expect(try st.item(id: a.id)?.pinned == true)
    }

    @Test func pinnedComeFirstThenNewest() throws {
        let clock = ShfClock()
        let st = Shf.store(clock: clock)
        let a = try st.insert(cand("old"))
        clock.advance(1)
        _ = try st.insert(cand("mid"))
        clock.advance(1)
        _ = try st.insert(cand("new"))
        try st.setPinned(id: a.id, true)
        #expect(try st.items().map(\.title) == ["old", "new", "mid"])
        try st.setPinned(id: a.id, false)
        #expect(try st.items().map(\.title) == ["new", "mid", "old"])
    }

    @Test func insertsInTheSameMillisecondStayOrdered() throws {
        let st = Shf.store()
        for t in ["a", "b", "c", "d"] { _ = try st.insert(cand(t)) }
        #expect(try st.items().map(\.title) == ["d", "c", "b", "a"])
    }

    @Test func deleteRemovesRowsAndPayloads() throws {
        let st = Shf.store()
        let a = try st.insert(cand("x1"))
        let b = try st.insert(cand("x2"))
        try st.delete(ids: [a.id])
        #expect(try st.count() == 1)
        #expect(try st.payload(id: a.id) == nil)
        #expect(try st.item(id: b.id) != nil)
    }

    @Test func rowsOfAnUnknownKindAreSkippedButNotLost() throws {
        let path = tempDBPath()
        let st = Shf.store(path: path)
        _ = try st.insert(cand("good"))
        try st.store.run("INSERT INTO shelf_items(kind, hash, title, created) VALUES('hologram', 'h', 'future', 1)")
        #expect(try st.items().map(\.title) == ["good"])
        #expect(try st.count() == 2)
    }

    @Test func updateLocationRewritesPathAndBookmark() throws {
        let fs = ShfFS()
        fs.addFile("/old/a.txt")
        let st = Shf.store()
        let r = try st.insert(try #require(ShelfIngest.candidate(.file(path: "/old/a.txt", owned: false), fs: fs)))
        try st.updateLocation(id: r.id, path: "/new/a.txt", bookmark: Data([7]))
        let it = try #require(try st.item(id: r.id))
        #expect(it.path == "/new/a.txt")
        #expect(it.detail == "/new")
        #expect(try st.payload(id: r.id)?.bookmark == Data([7]))
    }

    @Test func updateLocationKeepsBookmarkWhenNoneGiven() throws {
        let fs = ShfFS()
        fs.addFile("/old/a.txt")
        let st = Shf.store()
        let r = try st.insert(try #require(ShelfIngest.candidate(.file(path: "/old/a.txt", owned: false), fs: fs)))
        let before = try st.payload(id: r.id)?.bookmark
        try st.updateLocation(id: r.id, path: "/new/a.txt", bookmark: nil)
        #expect(try st.payload(id: r.id)?.bookmark == before)
    }

    @Test func oldestUnpinnedBeyondTheLimit() throws {
        let clock = ShfClock()
        let st = Shf.store(clock: clock)
        let first = try st.insert(cand("1"))
        try st.setPinned(id: first.id, true)
        for t in ["2", "3", "4", "5"] { clock.advance(1); _ = try st.insert(cand(t)) }
        let extra = try st.oldestUnpinned(beyond: 2)
        #expect(Set(extra.map(\.title)) == ["2", "3"])
    }

    @Test func ownedPathsListsOnlyOwned() throws {
        let fs = ShfFS()
        fs.addFile("/shelf/files/u/a.png")
        fs.addFile("/Users/x/b.png")
        let st = Shf.store()
        _ = try st.insert(try #require(ShelfIngest.candidate(.file(path: "/shelf/files/u/a.png", owned: true), fs: fs)))
        _ = try st.insert(try #require(ShelfIngest.candidate(.file(path: "/Users/x/b.png", owned: false), fs: fs)))
        #expect(try st.ownedPaths() == ["/shelf/files/u/a.png"])
    }

    @Test func schemaUsesAsciiNames() {
        for m in ShelfSchema.migrations { #expect(m.sql.unicodeScalars.allSatisfy { $0.isASCII }) }
    }
}
