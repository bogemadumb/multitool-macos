import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct SnippetRulesTests {
    @Test func triggerNeedsTwoCharactersAndNoWhitespace() {
        #expect(SnippetRules.validate(trigger: ";", body: "x") == .triggerTooShort)
        #expect(SnippetRules.validate(trigger: "ab", body: "x") == nil)
        #expect(SnippetRules.validate(trigger: "a b", body: "x") == .triggerHasWhitespace)
        #expect(SnippetRules.validate(trigger: "ab\n", body: "x") == nil)
        #expect(SnippetRules.validate(trigger: String(repeating: "a", count: 41), body: "x") == .triggerTooLong)
        #expect(SnippetRules.validate(trigger: "ab", body: "") == .bodyEmpty)
    }

    @Test func cyrillicTriggersAreValid() {
        #expect(SnippetRules.validate(trigger: ";адрес", body: "ул. Бутлерова") == nil)
    }

    @Test func keyFoldsCaseAndNormalization() {
        #expect(SnippetRules.key(" ;АДРЕС ") == ";адрес")
        #expect(SnippetRules.normalized("й") == SnippetRules.normalized("и\u{306}"))
    }
}

@Suite struct SnippetClassifierTests {
    private func c(_ code: UInt32, _ chars: String, _ flags: CGEventFlags = []) -> SnippetKey {
        SnippetKeyClassifier.classify(keyCode: code, flags: flags, characters: chars)
    }

    @Test func lettersAndSymbolsAreText() {
        #expect(c(0, "a") == .text("a"))
        #expect(c(41, ";") == .text(";"))
        #expect(c(0, "ф") == .text("ф"))
        #expect(c(0, "A", .maskShift) == .text("A"))
        #expect(c(0, "å", .maskAlternate) == .text("å"))
    }

    @Test func terminatorsAndBackspace() {
        #expect(c(Keys.space, " ") == .terminator(.space))
        #expect(c(Keys.tab, "\t") == .terminator(.tab))
        #expect(c(Keys.returnKey, "\r") == .terminator(.returnKey))
        #expect(c(Keys.enterKey, "\u{3}") == .terminator(.returnKey))
        #expect(c(Keys.backspace, "\u{7F}") == .backspace)
    }

    @Test func shortcutsAndNavigationReset() {
        #expect(c(8, "c", .maskCommand) == .reset)
        #expect(c(0, "a", .maskControl) == .reset)
        #expect(c(Keys.backspace, "\u{7F}", .maskAlternate) == .reset)
        #expect(c(117, "\u{F728}") == .reset)
        #expect(c(Keys.left, "\u{F702}") == .reset)
        #expect(c(Keys.escape, "\u{1B}") == .reset)
        #expect(c(122, "\u{F704}") == .reset)
    }

    @Test func emptyCharactersAreIgnoredNotReset() {
        #expect(c(0, "") == .ignore)
    }

    @Test func realEventsCarryUnicodeIndependentOfKeycode() {
        let e = ActEvents.key(0, down: true, chars: "ф")
        #expect(e.typedCharacters() == "ф")
        let latin = ActEvents.key(0, down: true, chars: "a")
        #expect(latin.typedCharacters() == "a")
    }
}

@Suite struct SnippetBufferTests {
    @Test func appendBackspaceReset() {
        var b = SnippetBuffer()
        b.append("ab")
        b.append("ц")
        #expect(b.text == "abц")
        b.backspace()
        #expect(b.text == "ab")
        b.reset()
        b.backspace()
        #expect(b.isEmpty)
    }

    @Test func capacityKeepsTheTail() {
        var b = SnippetBuffer()
        b.append(String(repeating: "x", count: SnippetBuffer.capacity + 10))
        b.append("end")
        #expect(b.chars.count == SnippetBuffer.capacity)
        #expect(b.text.hasSuffix("xend"))
    }
}

@Suite struct SnippetMatcherTests {
    private func m(_ list: [Snippet], cs: Bool = false, layout: Bool = false) -> SnippetMatcher { SnippetMatcher(snippets: list, caseSensitive: cs, layoutInsensitive: layout) }
    private func buf(_ s: String) -> [Character] { Array(s) }

    @Test func matchesTheTypedTail() {
        let match = m([actSnippet(1, ";addr")]).match(in: buf("hello ;addr"))
        #expect(match?.snippet.id == 1 && match?.typedLength == 5)
    }

    @Test func noMatchOnPartialOrPrefix() {
        let x = m([actSnippet(1, ";addr")])
        #expect(x.match(in: buf(";add")) == nil)
        #expect(x.match(in: buf(";addrx")) == nil)
        #expect(x.match(in: buf("")) == nil)
    }

    @Test func wordBoundaryBlocksGluedText() {
        let x = m([actSnippet(1, "sig")])
        #expect(x.match(in: buf("design")) == nil)
        #expect(x.match(in: buf("a sig")) != nil)
        #expect(x.match(in: buf("(sig")) != nil)
        #expect(x.match(in: buf("5sig")) == nil)
        #expect(x.match(in: buf("sig")) != nil)
    }

    @Test func symbolTriggersFollowTheSameBoundaryRule() {
        let x = m([actSnippet(1, ";a1")])
        #expect(x.match(in: buf("x;a1")) == nil)
        #expect(x.match(in: buf("x ;a1")) != nil)
    }

    @Test func longestTriggerWins() {
        let x = m([actSnippet(1, ";ab"), actSnippet(2, ";abc")])
        #expect(x.match(in: buf(";abc"))?.snippet.id == 2)
        #expect(x.match(in: buf(";ab"))?.snippet.id == 1)
    }

    @Test func disabledSnippetsAreIgnored() {
        let x = m([actSnippet(1, ";addr", enabled: false)])
        #expect(x.count == 0 && x.match(in: buf(";addr")) == nil)
    }

    @Test func caseInsensitiveByDefaultButStrictOnRequest() {
        let list = [actSnippet(1, ";Addr")]
        #expect(m(list).match(in: buf(";ADDR")) != nil)
        #expect(m(list, cs: true).match(in: buf(";ADDR")) == nil)
        #expect(m(list, cs: true).match(in: buf(";Addr")) != nil)
    }

    @Test func russianTriggerAndUppercase() {
        let list = [actSnippet(1, ";адрес")]
        #expect(m(list).match(in: buf(";АДРЕС")) != nil)
        #expect(m(list).match(in: buf("привет ;адрес"))?.typedLength == 6)
    }

    @Test func wrongLayoutMatchOnlyWhenEnabled() {
        let list = [actSnippet(1, ";адрес")]
        #expect(m(list).match(in: buf(";flhtc")) == nil)
        #expect(m(list, layout: true).match(in: buf(";flhtc")) != nil)
        #expect(m(list, layout: true).match(in: buf("жадрес")) != nil)
        let en = [actSnippet(2, ";addr")]
        #expect(m(en, layout: true).match(in: buf("жфввк")) != nil)
        #expect(m(en).match(in: buf("жфввк")) == nil)
    }

    @Test func layoutMapIsOneToOne() {
        let s = "йцукенгшщзхъфывапролджэячсмитьбюё"
        #expect(LayoutMap.toLatin(s).count == s.count)
        #expect(LayoutMap.toLatin("ПРИВЕТ") == "GHBDTN")
        #expect(LayoutMap.toLatin("abc;") == "abc;")
    }
}
