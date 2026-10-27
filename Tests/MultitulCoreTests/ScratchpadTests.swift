import Testing
import Foundation
@testable import MultitulCore

private struct Rig {
    let model: ScratchpadModel
    let store: TlsScratchStore
    let clock: TlsClock
    let sched: TlsScheduler
}

private func rig(_ s: ScratchpadSettings = ScratchpadSettings(), seed: [String] = []) -> Rig {
    let store = TlsScratchStore(), clock = TlsClock(), sched = TlsScheduler()
    for t in seed { _ = try! store.insert(title: "", text: t, at: clock.now) }
    let m = ScratchpadModel(store: store, settings: s, clock: clock, scheduler: sched)
    m.load()
    return Rig(model: m, store: store, clock: clock, sched: sched)
}

@Suite struct ScratchNoteTests {
    private func note(_ title: String = "", _ text: String = "") -> ScratchNote {
        ScratchNote(id: 1, title: title, text: text, created: Date(), updated: Date())
    }

    @Test func customTitleWins() {
        #expect(note("  Список дел  ", "x").displayTitle(index: 0) == "Список дел")
        #expect(note(String(repeating: "я", count: 40)).displayTitle(index: 0).count == 24)
    }

    @Test func firstLineBecomesTheTitleWithoutMarkdownMarks() {
        #expect(note("", "\n\n# Заголовок\nтекст").displayTitle(index: 3) == "Заголовок")
        #expect(note("", "- пункт").displayTitle(index: 0) == "пункт")
        #expect(note("", String(repeating: "ы", count: 50)).displayTitle(index: 0).count == 22)
    }

    @Test func emptyNoteGetsAnOrdinal() {
        #expect(note().displayTitle(index: 0) == "Заметка 1")
        #expect(note("", "###").displayTitle(index: 4) == "Заметка 5")
    }
}

@Suite struct ScratchpadSettingsTests {
    @Test func defaults() {
        let s = ScratchpadSettings()
        #expect(s.autoClear == .off && !s.closeOnOutsideClick && s.autosaveDelay == 1 && s.fontSize == 14 && s.maxTabs == 12 && !s.startInPreview)
    }

    @Test func sanitizeClamps() {
        var s = ScratchpadSettings()
        s.fontSize = 99; s.autosaveDelay = 0; s.maxTabs = 0
        let c = s.sanitized
        #expect(c.fontSize == 28 && c.autosaveDelay == 0.2 && c.maxTabs == 1)
    }

    @Test func storeRoundTrip() {
        let kv = WndMemoryStore()
        let store = ScratchpadSettingsStore(kv)
        store.save(ScratchpadSettings())
        #expect(kv.values.isEmpty)
        var s = ScratchpadSettings()
        s.autoClear = .day; s.closeOnOutsideClick = true; s.autosaveDelay = 2; s.fontSize = 18; s.maxTabs = 5; s.startInPreview = true
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("scratchpad.") })
    }

    @Test func unknownPeriodFallsBackToOff() {
        let kv = WndMemoryStore()
        kv.set(7, forKey: "scratchpad.autoClear")
        #expect(ScratchpadSettingsStore(kv).load().autoClear == .off)
    }

    @Test func everyPeriodHasATitleAndTheMinutesAreAscending() {
        let mins = AutoClearPeriod.allCases.map(\.rawValue)
        #expect(mins == mins.sorted() && AutoClearPeriod.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite struct ScratchpadModelTests {
    @Test func firstLoadCreatesOneEmptyNote() {
        let r = rig()
        #expect(r.model.notes.count == 1 && r.model.active?.text == "" && r.store.notes.count == 1)
    }

    @Test func loadKeepsExistingNotesInOrder() {
        let r = rig(seed: ["один", "два"])
        #expect(r.model.notes.map(\.text) == ["один", "два"] && r.model.activeIndex == 0)
    }

    @Test func editingSchedulesAnAutosaveWithoutWritingYet() {
        let r = rig()
        r.model.edit("привет")
        #expect(r.model.hasUnsaved && r.store.saves == 0)
        #expect(r.sched.lastDelay == 1 && r.sched.action != nil)
    }

    @Test func schedulerFireWritesToTheStore() {
        let r = rig()
        r.model.edit("привет")
        r.sched.fire()
        #expect(r.store.saves == 1 && r.store.notes[0].text == "привет" && !r.model.hasUnsaved)
    }

    @Test func burstOfEditsWritesOnce() {
        let r = rig()
        for t in ["а", "аб", "абв", "абвг"] { r.model.edit(t) }
        r.sched.fire()
        #expect(r.store.saves == 1 && r.store.notes[0].text == "абвг")
    }

    @Test func autosaveDelayComesFromSettings() {
        var s = ScratchpadSettings()
        s.autosaveDelay = 3
        let r = rig(s)
        r.model.edit("x")
        #expect(r.sched.lastDelay == 3)
    }

    @Test func identicalTextIsNotADirtyEdit() {
        let r = rig(seed: ["то же"])
        r.model.edit("то же")
        #expect(!r.model.hasUnsaved && r.sched.action == nil)
    }

    @Test func switchingTabsFlushesImmediately() {
        let r = rig(seed: ["a", "b"])
        r.model.edit("a2")
        r.model.select(1)
        #expect(r.store.notes[0].text == "a2" && r.model.activeIndex == 1 && !r.model.hasUnsaved)
    }

    @Test func flushOnCloseWritesPendingText() {
        let r = rig()
        r.model.edit("не потерять")
        r.model.flush()
        #expect(r.store.notes[0].text == "не потерять")
        r.model.flush()
        #expect(r.store.saves == 1)
    }

    @Test func updatedTimestampFollowsEdits() {
        let r = rig()
        r.clock.advance(60)
        r.model.edit("x")
        #expect(r.model.active?.updated == r.clock.now)
    }

    @Test func newTabBecomesActiveAndRespectsTheLimit() {
        var s = ScratchpadSettings()
        s.maxTabs = 3
        let r = rig(s)
        #expect(r.model.addNote() && r.model.addNote())
        #expect(r.model.notes.count == 3 && r.model.activeIndex == 2)
        #expect(!r.model.addNote() && r.model.notes.count == 3)
    }

    @Test func closingTheActiveMiddleTabKeepsTheNeighbour() {
        let r = rig(seed: ["a", "b", "c"])
        r.model.select(1)
        r.model.closeNote(at: 1)
        #expect(r.model.notes.map(\.text) == ["a", "c"] && r.model.active?.text == "c")
        #expect(r.store.notes.map(\.text) == ["a", "c"])
    }

    @Test func closingBeforeTheActiveTabShiftsTheIndex() {
        let r = rig(seed: ["a", "b", "c"])
        r.model.select(2)
        r.model.closeNote(at: 0)
        #expect(r.model.active?.text == "c" && r.model.activeIndex == 1)
    }

    @Test func closingTheLastTabInTheListSelectsThePrevious() {
        let r = rig(seed: ["a", "b"])
        r.model.select(1)
        r.model.closeNote(at: 1)
        #expect(r.model.active?.text == "a" && r.model.activeIndex == 0)
    }

    @Test func closingTheOnlyTabJustEmptiesIt() {
        let r = rig(seed: ["важное"])
        r.model.closeNote(at: 0)
        #expect(r.model.notes.count == 1 && r.model.active?.text == "" && r.store.notes[0].text == "")
    }

    @Test func renameIsPersistedOnFlush() {
        let r = rig()
        r.model.rename(at: 0, to: "  Идеи ")
        r.sched.fire()
        #expect(r.store.notes[0].title == "Идеи")
    }

    @Test func movingTabsKeepsTheActiveNote() {
        let r = rig(seed: ["a", "b", "c"])
        r.model.select(0)
        r.model.moveNote(from: 0, to: 2)
        #expect(r.model.notes.map(\.text) == ["b", "c", "a"] && r.model.active?.text == "a")
        #expect(r.store.notes.map(\.text) == ["b", "c", "a"])
    }

    @Test func clearActiveEmptiesAndSaves() {
        let r = rig(seed: ["много текста"])
        r.model.clearActive()
        #expect(r.store.notes[0].text == "")
    }

    @Test func storeFailureIsReportedNotSwallowed() {
        let r = rig()
        r.store.fail = true
        r.model.edit("x")
        r.model.flush()
        #expect(r.model.lastError != nil)
        #expect(!r.model.addNote())
    }

    @Test func brokenStoreStillGivesAWorkingInMemoryNote() {
        let store = TlsScratchStore()
        store.fail = true
        let m = ScratchpadModel(store: store, clock: TlsClock(), scheduler: TlsScheduler())
        m.load()
        #expect(m.notes.count == 1 && m.lastError != nil)
        m.edit("текст")
        #expect(m.active?.text == "текст")
    }
}

@Suite struct ScratchpadAutoClearTests {
    @Test func staleNotesAreEmptied() {
        var s = ScratchpadSettings()
        s.autoClear = .hour
        let r = rig(s, seed: ["старое", "свежее"])
        r.clock.advance(3 * 3600)
        r.model.edit("правка")
        r.model.flush()
        r.clock.advance(30 * 60)
        r.model.applyAutoClear()
        #expect(r.model.notes.map(\.text) == ["правка"])
        #expect(r.store.notes.contains { $0.text == "правка" })
        #expect(!r.store.notes.contains { $0.text == "старое" || $0.text == "свежее" })
    }

    @Test func freshNotesSurvive() {
        var s = ScratchpadSettings()
        s.autoClear = .day
        let r = rig(s, seed: ["держи"])
        r.clock.advance(3600)
        r.model.applyAutoClear()
        #expect(r.model.active?.text == "держи")
    }

    @Test func offMeansNever() {
        let r = rig(seed: ["вечное"])
        r.clock.advance(365 * 86400)
        r.model.applyAutoClear()
        #expect(r.model.active?.text == "вечное")
    }

    @Test func emptyTrailingTabsAreRemovedButOneStays() {
        var s = ScratchpadSettings()
        s.autoClear = .quarterHour
        let r = rig(s, seed: ["a", "b", "c"])
        r.clock.advance(3600)
        r.model.applyAutoClear()
        #expect(r.model.notes.count == 1 && r.model.active?.text == "")
        #expect(r.store.notes.count == 1)
    }

    @Test func loadAppliesTheClear() {
        var s = ScratchpadSettings()
        s.autoClear = .quarterHour
        let store = TlsScratchStore(), clock = TlsClock()
        _ = try! store.insert(title: "", text: "давно", at: clock.now)
        clock.advance(7200)
        let m = ScratchpadModel(store: store, settings: s, clock: clock, scheduler: TlsScheduler())
        m.load()
        #expect(m.active?.text == "")
    }
}

@Suite struct ScratchExportTests {
    private func note(_ title: String, _ text: String = "") -> ScratchNote { ScratchNote(id: 1, title: title, text: text, created: Date(), updated: Date()) }

    @Test func fileNamesAreSafe() {
        #expect(ScratchExport.fileName(for: note("a/b:c*d?"), index: 0) == "a b c d.md")
        #expect(ScratchExport.fileName(for: note("Список дел"), index: 0, ext: "txt") == "Список дел.txt")
        #expect(ScratchExport.fileName(for: note("..."), index: 2) == "Заметка.md")
        #expect(ScratchExport.fileName(for: note("", "строка\nвторая"), index: 0) == "строка.md")
    }

    @Test func combinedExportHasTitlesAndSeparators() {
        let out = ScratchExport.combined([note("Первая", "один"), note("Вторая", "два")])
        #expect(out == "# Первая\n\nодин\n\n---\n\n# Вторая\n\nдва")
    }

    @Test func statistics() {
        #expect(ScratchStats.of("") == ScratchStats(characters: 0, words: 0, lines: 0))
        #expect(ScratchStats.of("раз два\nтри") == ScratchStats(characters: 11, words: 3, lines: 2))
        #expect(ScratchStats.of("  \n ").words == 0)
    }
}

@Suite struct SQLiteScratchStoreTests {
    private func make() throws -> SQLiteScratchStore { try SQLiteScratchStore(store: ScratchSchema.openStore(path: ":memory:")) }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func insertAndLoadKeepsOrder() throws {
        let s = try make()
        let a = try s.insert(title: "A", text: "один", at: t0)
        let b = try s.insert(title: "", text: "два", at: t0)
        let all = try s.loadAll()
        #expect(all.map(\.id) == [a.id, b.id] && all.map(\.text) == ["один", "два"] && all[0].title == "A")
        #expect(all[0].created == t0)
    }

    @Test func saveUpdatesTextTitleAndTime() throws {
        let s = try make()
        var n = try s.insert(title: "", text: "x", at: t0)
        n.text = "новый текст\nс переносом и «кавычками» ' \""
        n.title = "T"
        n.updated = t0.addingTimeInterval(500)
        try s.save(n)
        let back = try #require(try s.loadAll().first)
        #expect(back.text == n.text && back.title == "T" && back.updated == n.updated && back.created == t0)
    }

    @Test func deleteRemovesOnlyThatNote() throws {
        let s = try make()
        let a = try s.insert(title: "", text: "a", at: t0)
        _ = try s.insert(title: "", text: "b", at: t0)
        try s.delete(id: a.id)
        #expect(try s.loadAll().map(\.text) == ["b"])
    }

    @Test func positionsReorder() throws {
        let s = try make()
        let ids = try (0..<3).map { try s.insert(title: "", text: "\($0)", at: t0).id }
        try s.savePositions([ids[2], ids[0], ids[1]])
        #expect(try s.loadAll().map(\.text) == ["2", "0", "1"])
        let d = try s.insert(title: "", text: "3", at: t0)
        #expect(try s.loadAll().last?.id == d.id)
    }

    @Test func largeTextRoundTrips() throws {
        let s = try make()
        let big = String(repeating: "Привет, мир! ", count: 20_000)
        _ = try s.insert(title: "", text: big, at: t0)
        #expect(try s.loadAll().first?.text == big)
    }

    @Test func modelOverRealStoreSurvivesARestart() throws {
        let sql = try make()
        let m1 = ScratchpadModel(store: sql, clock: TlsClock(), scheduler: TlsScheduler())
        m1.load()
        m1.edit("после перезапуска")
        m1.addNote()
        m1.edit("вторая")
        m1.flush()
        let m2 = ScratchpadModel(store: sql, clock: TlsClock(), scheduler: TlsScheduler())
        m2.load()
        #expect(m2.notes.map(\.text) == ["после перезапуска", "вторая"])
    }
}

@Suite struct MarkdownParserTests {
    @Test func headingsListsAndParagraphs() {
        let md = "# Заголовок\n\nпервая строка\nвторая строка\n\n- пункт\n  - вложенный\n1. раз\n2) два\n- [ ] дело\n- [x] готово\n> цитата\n---\n"
        #expect(MarkdownParser.blocks(md) == [
            .heading(level: 1, text: "Заголовок"),
            .paragraph("первая строка вторая строка"),
            .bullet(text: "пункт", indent: 0), .bullet(text: "вложенный", indent: 1),
            .numbered(number: 1, text: "раз"), .numbered(number: 2, text: "два"),
            .checkbox(done: false, text: "дело"), .checkbox(done: true, text: "готово"),
            .quote("цитата"), .rule
        ])
    }

    @Test func codeFencesKeepContentVerbatim() {
        let md = "до\n```swift\nlet a = 1\n\n# не заголовок\n```\nпосле"
        #expect(MarkdownParser.blocks(md) == [.paragraph("до"), .code(language: "swift", text: "let a = 1\n\n# не заголовок"), .paragraph("после")])
    }

    @Test func unclosedFenceIsClosedAtTheEnd() {
        #expect(MarkdownParser.blocks("```\nкод") == [.code(language: "", text: "код")])
    }

    @Test func hashWithoutSpaceIsPlainText() {
        #expect(MarkdownParser.blocks("#тег") == [.paragraph("#тег")])
        #expect(MarkdownParser.blocks("####### семь") == [.paragraph("####### семь")])
    }

    @Test func windowsLineEndingsAreHandled() {
        #expect(MarkdownParser.blocks("# A\r\nтекст") == [.heading(level: 1, text: "A"), .paragraph("текст")])
    }

    @Test func emptyInputHasNoBlocks() {
        #expect(MarkdownParser.blocks("").isEmpty)
        #expect(MarkdownParser.blocks("\n\n  \n").isEmpty)
    }

    @Test func numbersNeedAMarker() {
        #expect(MarkdownParser.blocks("2024 год") == [.paragraph("2024 год")])
    }
}
