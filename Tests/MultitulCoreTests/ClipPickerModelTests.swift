import Testing
import Foundation
@testable import MultitulCore

@Suite struct ClipPickerModelTests {
    private func make(_ texts: [String]) throws -> (ClipPickerModel, ClipStore, ClpFakePasteboard, ClpFakeKeys, ClpFakeScheduler) {
        let clock = ClpClock()
        let st = Clp.store(clock: clock)
        for t in texts {
            clock.advance(1)
            try st.insert(Clp.candidate(t))
        }
        let pb = ClpFakePasteboard()
        let keys = ClpFakeKeys()
        let sch = ClpFakeScheduler()
        let eng = ClipPasteEngine(pasteboard: pb, keys: keys, activator: ClpFakeActivator(), scheduler: sch) {}
        let m = ClipPickerModel(store: st, engine: eng)
        m.reload()
        return (m, st, pb, keys, sch)
    }

    @Test func listsNewestFirstAndHighlightsTheTop() throws {
        let (m, _, _, _, _) = try make(["раз", "два", "три"])
        #expect(m.items.map(\.title) == ["три", "два", "раз"])
        #expect(m.highlighted?.title == "три")
    }

    @Test func queryFiltersAndKeepsSelectionInRange() throws {
        let (m, _, _, _, _) = try make(["apple pie", "banana split", "apple tart"])
        m.move(2)
        m.query = "apple"
        #expect(m.items.count == 2)
        #expect(m.highlighted?.title == "apple pie")
        m.query = "banana"
        #expect(m.selection == 0)
        m.query = "nothing here"
        #expect(m.items.isEmpty)
        #expect(m.highlighted == nil)
    }

    @Test func moveClampsAtBothEnds() throws {
        let (m, _, _, _, _) = try make(["a1", "b2", "c3"])
        m.move(-5)
        #expect(m.selection == 0)
        m.move(10)
        #expect(m.selection == 2)
    }

    @Test func quickKeysMapToTheFirstNine() throws {
        let (m, _, _, _, _) = try make((1...12).map { "item \($0)" })
        #expect(m.item(quickKey: 1)?.title == "item 12")
        #expect(m.item(quickKey: 9)?.title == "item 4")
        #expect(m.item(quickKey: 0) == nil)
        #expect(m.item(quickKey: 10) == nil)
        let (small, _, _, _, _) = try make(["only"])
        #expect(small.item(quickKey: 2) == nil)
    }

    @Test func multiSelectionOverridesHighlightAndKeepsListOrder() throws {
        let (m, _, _, _, _) = try make(["one", "two", "three"])
        let ids = m.items.map(\.id)
        m.toggleMulti(id: ids[2])
        m.toggleMulti(id: ids[0])
        #expect(m.chosen.map(\.title) == ["three", "one"])
        m.toggleMulti(id: ids[0])
        #expect(m.chosen.map(\.title) == ["one"])
    }

    @Test func pinAndDeleteReloadTheList() throws {
        let (m, _, _, _, _) = try make(["alpha", "beta", "gamma"])
        let first = try #require(m.items.last)
        m.togglePin(first)
        #expect(m.items.first?.title == "alpha")
        #expect(m.items.first?.pinned == true)
        m.delete([m.items[1]])
        #expect(m.items.count == 2)
    }

    @Test func kindFilterNarrowsTheList() throws {
        let (m, st, _, _, _) = try make(["текст один"])
        var s = ClipSettings()
        s.keepFiles = true
        guard case .record(let f) = ClipCapture.evaluate(Clp.snap([Clp.fileItem("/tmp/x.txt")]), settings: s) else { Issue.record("x"); return }
        try st.insert(f)
        m.reload()
        #expect(m.items.count == 2)
        m.kindFilter = [.files]
        #expect(m.items.map(\.kind) == [.files])
    }

    @Test func activateWritesPastesAndCountsUsage() throws {
        let (m, st, pb, keys, sch) = try make(["первое", "второе"])
        let target = m.items[1]
        let out = m.activate([target], plain: false, copyOnly: false, target: Clp.notes)
        sch.runAll()
        #expect(out == .pasted)
        #expect(pb.items.first?.string == "первое")
        #expect(keys.pastes == 1)
        #expect(try st.item(id: target.id)?.useCount == 1)
        m.reload()
        #expect(m.items.first?.title == "первое")
    }

    @Test func previewTextOnlyForTextKinds() throws {
        let (m, _, _, _, _) = try make(["длинный текст для предпросмотра"])
        #expect(m.previewText(m.items[0]) == "длинный текст для предпросмотра")
        #expect(m.previewText(m.items[0], limit: 5) == "длинн…")
    }
}
