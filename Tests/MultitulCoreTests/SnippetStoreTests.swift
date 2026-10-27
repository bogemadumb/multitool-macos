import Testing
import Foundation
@testable import MultitulCore

@Suite struct SnippetStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func addAndReadBack() throws {
        let db = ActDB()
        let s = db.snippets(now: { self.t0 })
        let a = try s.add(trigger: " ;адрес ", body: "ул. Бутлерова, 11", title: "Адрес")
        #expect(a.trigger == ";адрес" && a.enabled && a.uses == 0)
        #expect(a.created == t0)
        #expect(try s.all().map(\.trigger) == [";адрес"])
        #expect(try s.snippet(id: a.id)?.body == "ул. Бутлерова, 11")
    }

    @Test func invalidInputIsRejectedWithReason() throws {
        let s = ActDB().snippets()
        #expect(throws: SnippetError.invalid(.triggerTooShort)) { try s.add(trigger: ";", body: "x") }
        #expect(throws: SnippetError.invalid(.triggerHasWhitespace)) { try s.add(trigger: "a b", body: "x") }
        #expect(throws: SnippetError.invalid(.bodyEmpty)) { try s.add(trigger: "ab", body: "") }
        #expect(try s.count() == 0)
    }

    @Test func duplicateTriggerIsCaseInsensitive() throws {
        let s = ActDB().snippets()
        try s.add(trigger: ";Addr", body: "1")
        #expect(throws: SnippetError.invalid(.duplicate(";ADDR"))) { try s.add(trigger: ";ADDR", body: "2") }
        #expect(try s.find(trigger: ";addr")?.body == "1")
    }

    @Test func updateChangesFieldsAndGuardsDuplicates() throws {
        let s = ActDB().snippets()
        var a = try s.add(trigger: ";one", body: "1")
        let b = try s.add(trigger: ";two", body: "2")
        a.body = "11"
        a.title = "T"
        try s.update(a)
        #expect(try s.snippet(id: a.id)?.body == "11")
        a.trigger = b.trigger
        #expect(throws: SnippetError.invalid(.duplicate(";two"))) { try s.update(a) }
        a.id = 999
        a.trigger = ";zzz"
        #expect(throws: SnippetError.notFound) { try s.update(a) }
    }

    @Test func enableDisableDeleteAndUses() throws {
        let s = ActDB().snippets()
        let a = try s.add(trigger: ";one", body: "1")
        try s.setEnabled(id: a.id, false)
        #expect(try s.enabled().isEmpty)
        try s.setEnabled(id: a.id, true)
        try s.markUsed(id: a.id)
        try s.markUsed(id: a.id)
        #expect(try s.enabled().first?.uses == 2)
        try s.delete(id: a.id)
        #expect(try s.count() == 0)
    }

    @Test func survivesReopen() throws {
        let db = ActDB()
        try db.snippets().add(trigger: ";keep", body: "text")
        #expect(try db.snippets().find(trigger: ";keep")?.body == "text")
    }

    @Test func multilineAndUnicodeBodyRoundTrip() throws {
        let s = ActDB().snippets()
        let body = "Строка 1\nСтрока 2\t{{date}} 🙂"
        let a = try s.add(trigger: ";multi", body: body)
        #expect(try s.snippet(id: a.id)?.body == body)
    }

    @Test func exportThenImportIntoEmptyStore() throws {
        let src = ActDB().snippets()
        try src.add(trigger: ";a1", body: "один", title: "A")
        let off = try src.add(trigger: ";b2", body: "два")
        try src.setEnabled(id: off.id, false)
        let data = try src.exportJSON()
        let dst = ActDB().snippets()
        let r = try dst.importJSON(data, overwrite: false)
        #expect(r.added == 2 && r.updated == 0 && r.skipped == 0)
        #expect(try dst.find(trigger: ";a1")?.title == "A")
        #expect(try dst.find(trigger: ";b2")?.enabled == false)
    }

    @Test func importKeepsOrOverwritesExisting() throws {
        let s = ActDB().snippets()
        try s.add(trigger: ";a1", body: "старый")
        let json = #"{"version":1,"snippets":[{"trigger":";a1","body":"новый"},{"trigger":";c3","body":"три"}]}"#
        let keep = try s.importJSON(Data(json.utf8), overwrite: false)
        #expect(keep.added == 1 && keep.skipped == 1)
        #expect(try s.find(trigger: ";a1")?.body == "старый")
        let over = try s.importJSON(Data(json.utf8), overwrite: true)
        #expect(over.updated == 2 && over.added == 0)
        #expect(try s.find(trigger: ";a1")?.body == "новый")
    }

    @Test func importSkipsInvalidAndRejectsGarbage() throws {
        let s = ActDB().snippets()
        let json = #"{"version":1,"snippets":[{"trigger":"x","body":"short"},{"trigger":"ok","body":""},{"trigger":"fine","body":"yes"}]}"#
        let r = try s.importJSON(Data(json.utf8), overwrite: false)
        #expect(r.added == 1 && r.skipped == 2)
        #expect(throws: SnippetError.badFormat) { try s.importJSON(Data("not json".utf8), overwrite: false) }
    }

    @Test func exportUsesLatinKeysOnly() throws {
        let s = ActDB().snippets()
        try s.add(trigger: ";ключ", body: "значение")
        let text = String(data: try s.exportJSON(), encoding: .utf8) ?? ""
        #expect(text.contains("\"trigger\"") && text.contains("\"body\"") && text.contains("\"version\""))
    }

    @Test func schemaScopeIsOwnMigration() throws {
        let store = try SnippetSchema.openStore(path: ActDB().path)
        #expect(try store.appliedMigrations().contains { $0.scope == SnippetSchema.scope && $0.version == 1 })
    }
}

@Suite struct SnippetLibraryModelTests {
    private let list = [
        Snippet(id: 1, trigger: ";addr", title: "Адрес", body: "ул. Бутлерова", uses: 1),
        Snippet(id: 2, trigger: ";mail", title: "", body: "name@example.com", uses: 5),
        Snippet(id: 3, trigger: ";off", body: "hidden", enabled: false),
        Snippet(id: 4, trigger: ";tel", title: "Телефон", body: "+7 931", uses: 0)
    ]

    @Test func hidesDisabledAndOrdersByUse() {
        let m = SnippetLibraryModel(snippets: list)
        #expect(m.filtered.map(\.id) == [2, 1, 4])
    }

    @Test func searchesTriggerTitleAndBodyCaseInsensitively() {
        let m = SnippetLibraryModel(snippets: list)
        m.query = "АДРЕС"
        #expect(m.filtered.map(\.id) == [1])
        m.query = "example.com"
        #expect(m.filtered.map(\.id) == [2])
        m.query = ";t"
        #expect(m.filtered.map(\.id) == [4])
        m.query = "nothing"
        #expect(m.selected == nil)
    }

    @Test func prefixMatchesRankFirst() {
        let m = SnippetLibraryModel(snippets: [Snippet(id: 1, trigger: "xxmail", body: "a"), Snippet(id: 2, trigger: "mail", body: "b")])
        m.query = "mail"
        #expect(m.filtered.map(\.id) == [2, 1])
    }

    @Test func selectionClampsAndResetsOnQuery() {
        let m = SnippetLibraryModel(snippets: list)
        m.move(10)
        #expect(m.selection == 2)
        m.move(-10)
        #expect(m.selection == 0)
        m.move(1)
        m.query = "а"
        #expect(m.selection == 0)
    }
}
