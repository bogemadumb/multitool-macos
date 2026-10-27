import Testing
import Foundation
@testable import MultitulCore

private func ctx(_ ts: Double = 1_792_760_733, counter: Int = 1, app: String? = nil, title: String? = nil, mode: ShotMode = .area) -> ShotNameContext {
    ShotNameContext(date: Date(timeIntervalSince1970: ts), mode: mode, appName: app, windowTitle: title, width: 1440, height: 900, counter: counter, timeZone: TimeZone(identifier: "UTC")!)
}

@Suite struct ShotNamingTests {
    @Test func defaultTemplateMatchesTheSystemLook() {
        let name = ShotNaming.render(template: ShotNaming.defaultTemplate, context: ctx())
        #expect(name == "Снимок экрана 2026-10-23 в 13.05.33")
    }

    @Test func dateTokensArePaddedAndUseTheContextTimeZone() {
        let c = ShotNameContext(date: Date(timeIntervalSince1970: 1_767_225_605), timeZone: TimeZone(identifier: "UTC")!)
        #expect(ShotNaming.render(template: "{yyyy}{yy}{MM}{dd}-{HH}{mm}{ss}", context: c) == "2026" + "26" + "0101-000005")
        let msk = ShotNameContext(date: Date(timeIntervalSince1970: 1_767_225_605), timeZone: TimeZone(identifier: "Europe/Moscow")!)
        #expect(ShotNaming.render(template: "{HH}", context: msk) == "03")
    }

    @Test func dateAndTimeShortcuts() {
        #expect(ShotNaming.render(template: "{date} {time}", context: ctx()) == "2026-10-23 13.05.33")
        #expect(ShotNaming.render(template: "{unix}", context: ctx()) == "1792760733")
    }

    @Test func counterSupportsPadding() {
        #expect(ShotNaming.render(template: "s{counter}", context: ctx(counter: 7)) == "s7")
        #expect(ShotNaming.render(template: "s{counter:4}", context: ctx(counter: 7)) == "s0007")
        #expect(ShotNaming.render(template: "s{counter:2}", context: ctx(counter: 1234)) == "s1234")
        #expect(ShotNaming.render(template: "s{counter:0}", context: ctx(counter: 7)) == "s{counter:0}")
    }

    @Test func appTitleModeAndSizeTokens() {
        let c = ctx(app: "Safari", title: "Новости", mode: .window)
        #expect(ShotNaming.render(template: "{app}|{title}|{mode}|{w}|{h}|{size}", context: c) == "Safari|Новости|окно|1440|900|1440x900")
    }

    @Test func unknownAndBrokenTokensStayAsText() {
        #expect(ShotNaming.render(template: "a{nope}b{", context: ctx()) == "a{nope}b{")
        #expect(ShotNaming.render(template: "{{yyyy}}", context: ctx()) == "{2026}")
    }

    @Test func missingAppRendersEmpty() {
        #expect(ShotNaming.render(template: "[{app}]", context: ctx()) == "[]")
    }

    @Test func sanitizeReplacesSlashAndColon() {
        #expect(ShotNaming.sanitize("a/b:c\\d") == "a-b-c-d")
        #expect(ShotNaming.sanitize("  .hidden  ") == "hidden")
        #expect(ShotNaming.sanitize("two   spaces") == "two spaces")
    }

    @Test func sanitizeStripsControlCharacters() {
        #expect(ShotNaming.sanitize("a\nb\tc") == "a-b-c")
    }

    @Test func sanitizeCutsLongNamesByBytes() {
        let long = String(repeating: "я", count: 300)
        let s = ShotNaming.sanitize(long)
        #expect(s.utf8.count <= ShotNaming.maxNameBytes)
        #expect(!s.isEmpty && s.allSatisfy { $0 == "я" })
    }

    @Test func emptyTemplateFallsBackToTheDefaultLook() {
        #expect(ShotNaming.baseName(template: "///", context: ctx()) == "Снимок экрана 2026-10-23 в 13.05.33")
        #expect(ShotNaming.baseName(template: "{app}", context: ctx()) == "Снимок экрана 2026-10-23 в 13.05.33")
    }

    @Test func uniqueFileNameAppendsANumber() {
        let taken: Set<String> = ["a.png", "a 2.png", "a 3.png"]
        #expect(ShotNaming.uniqueFileName(base: "a", ext: "png") { taken.contains($0) } == "a 4.png")
        #expect(ShotNaming.uniqueFileName(base: "b", ext: "png") { taken.contains($0) } == "b.png")
    }

    @Test func fileNameUsesTheFormatExtension() {
        let n = ShotNaming.fileName(template: "x", context: ctx(), format: .jpeg, exists: { _ in false })
        #expect(n == "x.jpg")
        #expect(ShotNaming.fileName(template: "x", context: ctx(), format: .heic, exists: { $0 == "x.heic" }) == "x 2.heic")
    }

    @Test func usesCounterDetectsBothForms() {
        #expect(ShotNaming.usesCounter("a{counter}"))
        #expect(ShotNaming.usesCounter("a{counter:3}"))
        #expect(!ShotNaming.usesCounter("a{date}"))
    }

    @Test func counterIsPersistentAndResettable() {
        let kv = WndMemoryStore()
        let c = ShotCounter(kv)
        #expect(c.current == 0)
        #expect(c.next() == 1 && c.next() == 2)
        #expect(ShotCounter(kv).current == 2)
        c.reset()
        #expect(c.next() == 1)
        #expect(kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test func everyDocumentedTokenRenders() {
        for t in ShotNaming.tokens {
            let key = t.token.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            let out = ShotNaming.render(template: t.token, context: ctx(app: "A", title: "T"))
            #expect(out != t.token || key.isEmpty, "\(t.token)")
        }
    }
}
