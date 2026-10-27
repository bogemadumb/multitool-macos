import Testing
import Foundation
@testable import MultitulCore

private let moment = Date(timeIntervalSince1970: 1_792_792_800)

private func ctx(_ tz: String = "UTC", clip: String? = nil, locale: String = "ru_RU") -> SnippetContext {
    SnippetContext(now: moment, timeZone: TimeZone(identifier: tz)!, locale: Locale(identifier: locale), clipboard: clip)
}

@Suite struct SnippetTemplateTests {
    @Test func plainTextIsUntouched() {
        #expect(SnippetTemplate.render("Привет, мир", context: ctx()) == RenderedSnippet(text: "Привет, мир", cursorFromEnd: nil))
    }

    @Test func defaultFormats() {
        #expect(SnippetTemplate.render("{{date}}", context: ctx()).text == "23.10.2026")
        #expect(SnippetTemplate.render("{{time}}", context: ctx()).text == "22:00")
        #expect(SnippetTemplate.render("{{datetime}}", context: ctx()).text == "23.10.2026 22:00")
    }

    @Test func customFormatAfterColon() {
        #expect(SnippetTemplate.render("{{date:yyyy-MM-dd}}", context: ctx()).text == "2026-10-23")
        #expect(SnippetTemplate.render("{{time:HH:mm:ss}}", context: ctx()).text == "22:00:00")
        #expect(SnippetTemplate.render("{{date:d MMMM yyyy}}", context: ctx()).text == "23 октября 2026")
    }

    @Test func timeZoneAfterBar() {
        #expect(SnippetTemplate.render("{{time|Europe/Moscow}}", context: ctx()).text == "01:00")
        #expect(SnippetTemplate.render("{{datetime:dd.MM HH:mm|Asia/Tokyo}}", context: ctx()).text == "24.10 07:00")
        #expect(SnippetTemplate.render("{{date|Europe/Moscow}}", context: ctx()).text == "24.10.2026")
    }

    @Test func unknownTimeZoneLeavesPlaceholderLiteral() {
        #expect(SnippetTemplate.render("{{time|Nowhere/City}}", context: ctx()).text == "{{time|Nowhere/City}}")
    }

    @Test func contextTimeZoneIsTheDefault() {
        #expect(SnippetTemplate.render("{{time}}", context: ctx("Europe/Moscow")).text == "01:00")
    }

    @Test func clipboardSubstitutesOrBecomesEmpty() {
        #expect(SnippetTemplate.render("[{{clipboard}}]", context: ctx(clip: "буфер")).text == "[буфер]")
        #expect(SnippetTemplate.render("[{{clipboard}}]", context: ctx(clip: nil)).text == "[]")
    }

    @Test func nameIsCaseAndSpaceTolerant() {
        #expect(SnippetTemplate.render("{{ Date }}", context: ctx()).text == "23.10.2026")
    }

    @Test func cursorMarkerReportsCharsAfterIt() {
        let r = SnippetTemplate.render("Dear {{cursor}},\nBye", context: ctx())
        #expect(r.text == "Dear ,\nBye" && r.cursorFromEnd == 5)
        let none = SnippetTemplate.render("abc{{cursor}}", context: ctx())
        #expect(none.text == "abc" && none.cursorFromEnd == 0)
    }

    @Test func onlyFirstCursorCounts() {
        let r = SnippetTemplate.render("a{{cursor}}b{{cursor}}c", context: ctx())
        #expect(r.text == "abc" && r.cursorFromEnd == 2)
    }

    @Test func cursorCountsSubstitutedTextAfterIt() {
        let r = SnippetTemplate.render("{{cursor}}{{clipboard}}", context: ctx(clip: "xyz"))
        #expect(r.text == "xyz" && r.cursorFromEnd == 3)
    }

    @Test func unknownAndBrokenPlaceholdersStayLiteral() {
        #expect(SnippetTemplate.render("{{nope}} {{date", context: ctx()).text == "{{nope}} {{date")
        #expect(SnippetTemplate.render("{single} }}", context: ctx()).text == "{single} }}")
    }

    @Test func backslashEscapesTheOpeningBraces() {
        #expect(SnippetTemplate.render("\\{{date}}", context: ctx()).text == "{{date}}")
    }

    @Test func variableNamesListsKnownOnce() {
        #expect(SnippetTemplate.variableNames(in: "{{date}} {{date:yyyy}} {{clipboard}} {{x}}") == ["date", "clipboard"])
    }

    @Test func englishLocaleNames() {
        #expect(SnippetTemplate.render("{{date:MMMM}}", context: ctx(locale: "en_US")).text == "October")
    }

    @Test func multilineBodyKeepsNewlines() {
        #expect(SnippetTemplate.render("a\nb\n{{date:yyyy}}", context: ctx()).text == "a\nb\n2026")
    }
}
