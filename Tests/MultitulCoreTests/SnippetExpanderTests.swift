import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let fixedNow = Date(timeIntervalSince1970: 1_792_792_800)

private struct ExpRig {
    let expander: SnippetExpander
    let pb: ClpFakePasteboard
    let keys: ActKeys
    let sched: ClpFakeScheduler
    let secure: ActSecure
    let focus: ActFocus
    let front: ActFront
    var acks: ExpAcks
}

private final class ExpAcks { var count = 0 }

private func expRig(_ settings: SnippetSettings = SnippetSettings(), bundle: String? = "com.example.editor") -> ExpRig {
    var s = settings
    s.timeZoneID = "UTC"
    let pb = ClpFakePasteboard()
    let keys = ActKeys()
    let sched = ClpFakeScheduler()
    let secure = ActSecure()
    let focus = ActFocus()
    let front = ActFront(bundle)
    let acks = ExpAcks()
    let e = SnippetExpander(pasteboard: pb, keys: keys, scheduler: sched, secure: secure, focus: focus, frontmost: front, settings: s, acknowledge: { acks.count += 1 }, now: { fixedNow })
    return ExpRig(expander: e, pb: pb, keys: keys, sched: sched, secure: secure, focus: focus, front: front, acks: acks)
}

@Suite struct SnippetExpanderTests {
    @Test func shortTextIsTypedAfterBackspaces() {
        let r = expRig()
        #expect(r.expander.expand(actSnippet(1, ";addr", "Москва"), deleting: 5, terminator: .tab) == .expanded)
        #expect(r.keys.log == Array(repeating: "key:51", count: 5) + ["type:Москва"])
        #expect(r.pb.writes == 0)
    }

    @Test func spaceTerminatorIsKeptAsTrailingSpace() {
        let r = expRig()
        r.expander.expand(actSnippet(1, ";a1", "Привет"), deleting: 3, terminator: .space)
        #expect(r.keys.typed == ["Привет "])
        let r2 = expRig()
        r2.expander.expand(actSnippet(1, ";a1", "Привет"), deleting: 3, terminator: .returnKey)
        #expect(r2.keys.typed == ["Привет"])
        var s = SnippetSettings()
        s.appendSpace = false
        let r3 = expRig(s)
        r3.expander.expand(actSnippet(1, ";a1", "Привет"), deleting: 3, terminator: .space)
        #expect(r3.keys.typed == ["Привет"])
    }

    @Test func longOrMultilineTextGoesThroughClipboard() {
        let r = expRig()
        let body = "Строка один\nСтрока два"
        r.pb.externalText("ОРИГИНАЛ")
        r.expander.expand(actSnippet(1, ";multi", body), deleting: 6, terminator: .tab)
        #expect(r.keys.codes() == Array(repeating: Keys.backspace, count: 6))
        #expect(r.keys.typed.isEmpty)
        #expect(r.pb.items.first?.string == body)
        #expect(r.pb.items.first?.reps[PBType.transient] != nil)
        r.sched.runAll()
        #expect(r.keys.codes().suffix(1) == [Keys.v] && r.keys.posts.last?.flags == .maskCommand)
    }

    @Test func clipboardIsRestoredAfterThePaste() {
        let r = expRig()
        var original = PasteboardItemData(text: "ОРИГИНАЛ")
        original.reps[PBType.rtf] = Data("rtf".utf8)
        r.pb.external([original])
        r.expander.expand(actSnippet(1, ";multi", "a\nb"), deleting: 0, terminator: nil)
        r.sched.runAll()
        #expect(r.pb.items == [original])
        #expect(r.acks.count == 2)
    }

    @Test func clipboardIsNotRestoredIfUserCopiedMeanwhile() {
        let r = expRig()
        r.pb.externalText("ОРИГИНАЛ")
        r.expander.expand(actSnippet(1, ";multi", "a\nb"), deleting: 0, terminator: nil)
        r.pb.externalText("НОВОЕ")
        r.sched.runAll()
        #expect(r.pb.items.first?.string == "НОВОЕ")
    }

    @Test func emptyClipboardIsClearedAfterwards() {
        let r = expRig()
        r.expander.expand(actSnippet(1, ";multi", "a\nb"), deleting: 0, terminator: nil)
        r.sched.runAll()
        #expect(r.pb.items.isEmpty && r.pb.clears == 1)
    }

    @Test func restoreCanBeSwitchedOff() {
        var s = SnippetSettings()
        s.restoreClipboard = false
        let r = expRig(s)
        r.pb.externalText("ОРИГИНАЛ")
        r.expander.expand(actSnippet(1, ";multi", "a\nb"), deleting: 0, terminator: nil)
        r.sched.runAll()
        #expect(r.pb.items.first?.string == "a\nb")
    }

    @Test func methodOverridesAreHonoured() {
        var s = SnippetSettings()
        s.method = .paste
        let r = expRig(s)
        r.expander.expand(actSnippet(1, ";ab", "коротко"), deleting: 0, terminator: nil)
        #expect(r.keys.typed.isEmpty && r.pb.writes == 1)
        s.method = .type
        let r2 = expRig(s)
        r2.expander.expand(actSnippet(1, ";ab", "a\nb"), deleting: 0, terminator: nil)
        #expect(r2.keys.typed == ["a\nb"] && r2.pb.writes == 0)
    }

    @Test func clipboardPlaceholderReadsBeforeOverwrite() {
        let r = expRig()
        r.pb.externalText("из буфера")
        r.expander.expand(actSnippet(1, ";cb", "Вставка: {{clipboard}}"), deleting: 0, terminator: nil)
        #expect(r.keys.typed == ["Вставка: из буфера"])
    }

    @Test func datePlaceholderUsesInjectedClockAndZone() {
        let r = expRig()
        r.expander.expand(actSnippet(1, ";dt", "{{date}} {{time|Europe/Moscow}}"), deleting: 0, terminator: nil)
        #expect(r.keys.typed == ["23.10.2026 01:00"])
    }

    @Test func cursorPlaceholderMovesLeftAfterTyping() {
        let r = expRig()
        r.expander.expand(actSnippet(1, ";br", "(){{cursor}}ab"), deleting: 3, terminator: .space)
        #expect(r.keys.log == Array(repeating: "key:51", count: 3) + ["type:()ab", "key:123", "key:123"])
    }

    @Test func cursorAfterPasteWaitsForTheSettleDelay() {
        let r = expRig()
        r.expander.expand(actSnippet(1, ";br", "a\n{{cursor}}b"), deleting: 0, terminator: nil)
        #expect(!r.keys.codes().contains(Keys.left))
        r.sched.runAll()
        let codes = r.keys.codes()
        let vAt = codes.firstIndex(of: Keys.v)!
        let leftAt = codes.firstIndex(of: Keys.left)!
        #expect(leftAt > vAt && codes.filter { $0 == Keys.left }.count == 1)
    }

    @Test func excludedAppSecureInputAndSecureFieldBlockEverything() {
        var s = SnippetSettings()
        s.exceptions = AppExceptionList(["com.bank.app"])
        let ex = expRig(s, bundle: "com.bank.app")
        #expect(ex.expander.expand(actSnippet(1, ";ab"), deleting: 3, terminator: .tab) == .excludedApp)
        let sec = expRig()
        sec.secure.active = true
        #expect(sec.expander.expand(actSnippet(1, ";ab"), deleting: 3, terminator: .tab) == .secureInput)
        let fld = expRig()
        fld.focus.secure = true
        #expect(fld.expander.expand(actSnippet(1, ";ab"), deleting: 3, terminator: .tab) == .secureField)
        #expect(ex.keys.log.isEmpty && sec.keys.log.isEmpty && fld.keys.log.isEmpty)
        #expect(fld.focus.asked == [100])
    }

    @Test func passwordManagersAreExcludedByDefault() {
        let r = expRig(SnippetSettings(), bundle: "com.1password.1password")
        #expect(r.expander.preflight() == .excludedApp)
        #expect(expRig(SnippetSettings(), bundle: "com.agilebits.onepassword7").expander.preflight() == .excludedApp)
        #expect(expRig(SnippetSettings(), bundle: "org.keepassxc.keepassxc").expander.preflight() == .excludedApp)
    }

    @Test func onExpandedCallbackReportsTheSnippet() {
        let r = expRig()
        var seen: Int64?
        r.expander.onExpanded = { seen = $0.id }
        r.expander.expand(actSnippet(7, ";ab"), deleting: 3, terminator: .tab)
        #expect(seen == 7)
    }
}

private struct EngRig {
    let engine: SnippetEngine
    let keys: ActKeys
    let sched: ClpFakeScheduler
    let secure: ActSecure
    let front: ActFront
    let pb: ClpFakePasteboard

    func type(_ s: String) {
        for ch in s { _ = engine.keyDown(keyCode: 0, flags: [], characters: String(ch)) }
    }

    func terminator(_ code: UInt32 = Keys.space, _ chars: String = " ") -> EventTapAction {
        engine.keyDown(keyCode: code, flags: [], characters: chars)
    }
}

private func engRig(_ list: [Snippet], settings: SnippetSettings = SnippetSettings(), bundle: String? = "com.example.editor") -> EngRig {
    var s = settings
    s.timeZoneID = "UTC"
    let pb = ClpFakePasteboard()
    let keys = ActKeys()
    let sched = ClpFakeScheduler()
    let secure = ActSecure()
    let focus = ActFocus()
    let front = ActFront(bundle)
    let exp = SnippetExpander(pasteboard: pb, keys: keys, scheduler: sched, secure: secure, focus: focus, frontmost: front, settings: s, now: { fixedNow })
    let eng = SnippetEngine(settings: s, expander: exp, secure: secure, frontmost: front, scheduler: sched)
    eng.load(list)
    return EngRig(engine: eng, keys: keys, sched: sched, secure: secure, front: front, pb: pb)
}

@Suite struct SnippetEngineTests {
    @Test func triggerPlusSpaceExpandsAndSwallowsTheSpace() {
        let r = engRig([actSnippet(1, ";addr", "Москва")])
        r.type(";addr")
        #expect(r.terminator() == .drop)
        #expect(r.keys.posts.isEmpty)
        r.sched.runAll()
        #expect(r.keys.log == Array(repeating: "key:51", count: 5) + ["type:Москва "])
        #expect(r.engine.keyUp(keyCode: Keys.space) == .drop)
        #expect(r.engine.keyUp(keyCode: Keys.space) == .pass)
        #expect(r.engine.expandedCount == 1)
    }

    @Test func tabAndReturnAlsoTrigger() {
        let r = engRig([actSnippet(1, ";addr", "X")])
        r.type(";addr")
        #expect(r.terminator(Keys.tab, "\t") == .drop)
        r.type(";addr")
        #expect(r.terminator(Keys.returnKey, "\r") == .drop)
        r.sched.runAll()
        #expect(r.keys.typed == ["X", "X"])
    }

    @Test func nothingHappensWithoutTerminator() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";addr")
        r.sched.runAll()
        #expect(r.keys.log.isEmpty)
    }

    @Test func nonMatchingWordPassesTheSpace() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";addx")
        #expect(r.terminator() == .pass)
        #expect(r.engine.buffer.isEmpty)
    }

    @Test func backspaceCorrectsATypo() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";addx")
        _ = r.engine.keyDown(keyCode: Keys.backspace, flags: [], characters: "\u{7F}")
        r.type("r")
        #expect(r.terminator() == .drop)
    }

    @Test func backspaceCannotConjureATriggerFromNothing() {
        let r = engRig([actSnippet(1, ";addr")])
        _ = r.engine.keyDown(keyCode: Keys.backspace, flags: [], characters: "\u{7F}")
        r.type(";addr")
        _ = r.engine.keyDown(keyCode: Keys.backspace, flags: [], characters: "\u{7F}")
        #expect(r.terminator() == .pass)
    }

    @Test func wordBoundaryNeedsSpaceOrPunctuationBefore() {
        let r = engRig([actSnippet(1, "sig", "Подпись")])
        r.type("design")
        #expect(r.terminator() == .pass)
        r.type("(sig")
        #expect(r.terminator() == .drop)
    }

    @Test func buffersAreSeparatedByTerminators() {
        let r = engRig([actSnippet(1, "ab")])
        r.type("a")
        _ = r.terminator()
        r.type("b")
        #expect(r.terminator() == .pass)
    }

    @Test func shortcutsAndArrowsResetTheBuffer() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";ad")
        _ = r.engine.keyDown(keyCode: 8, flags: .maskCommand, characters: "c")
        r.type("dr")
        #expect(r.terminator() == .pass)
        r.type(";addr")
        _ = r.engine.keyDown(keyCode: Keys.left, flags: [], characters: "\u{F702}")
        #expect(r.terminator() == .pass)
    }

    @Test func mouseClickResetsTheBuffer() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";ad")
        r.engine.pointerDown()
        r.type("dr")
        #expect(r.terminator() == .pass)
    }

    @Test func switchingAppsResetsTheBuffer() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";ad")
        r.front.set("com.example.other")
        r.type("dr")
        #expect(r.terminator() == .pass)
    }

    @Test func russianLayoutCharactersMatchCyrillicTriggers() {
        let r = engRig([actSnippet(1, ";адрес", "ул. Бутлерова, 11")])
        r.type(";адрес")
        #expect(r.terminator() == .drop)
        r.sched.runAll()
        #expect(r.keys.codes().filter { $0 == Keys.backspace }.count == 6)
        #expect(r.keys.typed == ["ул. Бутлерова, 11 "])
    }

    @Test func wrongLayoutTypingNeedsTheOption() {
        let off = engRig([actSnippet(1, ";адрес")])
        off.type("жадрес")
        #expect(off.terminator() == .pass)
        var s = SnippetSettings()
        s.layoutInsensitive = true
        let on = engRig([actSnippet(1, ";адрес")], settings: s)
        on.type("жадрес")
        #expect(on.terminator() == .drop)
    }

    @Test func caseInsensitiveTypingStillExpands() {
        let r = engRig([actSnippet(1, ";addr", "X")])
        r.type(";ADDR")
        #expect(r.terminator() == .drop)
    }

    @Test func disabledTerminatorsPass() {
        var s = SnippetSettings()
        s.useSpace = false
        let r = engRig([actSnippet(1, ";addr")], settings: s)
        r.type(";addr")
        #expect(r.terminator() == .pass)
        r.type(";addr")
        #expect(r.terminator(Keys.tab, "\t") == .drop)
    }

    @Test func secureInputStopsBufferingAndPassesTerminator() {
        let r = engRig([actSnippet(1, ";addr")])
        r.secure.active = true
        r.type(";addr")
        #expect(r.engine.buffer.isEmpty)
        #expect(r.terminator() == .pass)
        r.secure.active = false
        #expect(r.terminator() == .pass)
        r.sched.runAll()
        #expect(r.keys.log.isEmpty)
    }

    @Test func excludedAppDoesNotBufferOrExpand() {
        var s = SnippetSettings()
        s.exceptions = AppExceptionList(["com.example.editor"])
        let r = engRig([actSnippet(1, ";addr")], settings: s)
        r.type(";addr")
        #expect(r.engine.buffer.isEmpty)
        #expect(r.terminator() == .pass)
    }

    @Test func secureFieldBlockedAtTerminatorKeepsTheSpace() {
        let pb = ClpFakePasteboard()
        let keys = ActKeys()
        let sched = ClpFakeScheduler()
        let secure = ActSecure()
        let focus = ActFocus()
        focus.secure = true
        let front = ActFront("com.example.editor")
        let exp = SnippetExpander(pasteboard: pb, keys: keys, scheduler: sched, secure: secure, focus: focus, frontmost: front)
        let eng = SnippetEngine(expander: exp, secure: secure, frontmost: front, scheduler: sched)
        eng.load([actSnippet(1, ";addr")])
        for ch in ";addr" { _ = eng.keyDown(keyCode: 0, flags: [], characters: String(ch)) }
        #expect(eng.keyDown(keyCode: Keys.space, flags: [], characters: " ") == .pass)
        sched.runAll()
        #expect(keys.log.isEmpty)
    }

    @Test func disabledSnippetsAndReloadAreRespected() {
        let r = engRig([actSnippet(1, ";addr", enabled: false)])
        r.type(";addr")
        #expect(r.terminator() == .pass)
        r.engine.load([actSnippet(2, ";addr")])
        r.type(";addr")
        #expect(r.terminator() == .drop)
        #expect(r.engine.activeSnippetCount == 1)
    }

    @Test func optionHeldSpaceDoesNotTrigger() {
        let r = engRig([actSnippet(1, ";addr")])
        r.type(";addr")
        #expect(r.engine.keyDown(keyCode: Keys.space, flags: .maskAlternate, characters: " ") == .pass)
    }
}

@Suite struct SnippetStageTests {
    private func rig(_ list: [Snippet]) -> (InpTapBackend, ActKeys, ClpFakeScheduler) {
        let (hub, be) = actHub()
        let pb = ClpFakePasteboard()
        let keys = ActKeys()
        let sched = ClpFakeScheduler()
        let secure = ActSecure()
        let front = ActFront("com.example.editor")
        let exp = SnippetExpander(pasteboard: pb, keys: keys, scheduler: sched, secure: secure, focus: ActFocus(), frontmost: front)
        let eng = SnippetEngine(expander: exp, secure: secure, frontmost: front, scheduler: sched)
        eng.load(list)
        actKeep(SnippetStage(hub: hub, engine: eng)).start()
        return (be, keys, sched)
    }

    private func typeKey(_ be: InpTapBackend, _ ch: String, code: UInt16 = 0) {
        be.fire(.keyDown, ActEvents.key(code, down: true, chars: ch))
        be.fire(.keyUp, ActEvents.key(code, down: false, chars: ch))
    }

    @Test func eventsCarryingUnicodeDriveTheExpansion() {
        let (be, keys, sched) = rig([actSnippet(1, ";адрес", "ул. Бутлерова")])
        for ch in ";адрес" { typeKey(be, String(ch)) }
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.space), down: true, chars: " ")) == .drop)
        #expect(be.fire(.keyUp, ActEvents.key(UInt16(Keys.space), down: false, chars: " ")) == .drop)
        sched.runAll()
        #expect(keys.typed == ["ул. Бутлерова "])
    }

    @Test func ourOwnSyntheticKeystrokesNeverFeedTheBuffer() {
        let (be, keys, sched) = rig([actSnippet(1, ";ab", "X")])
        let synth = ActEvents.key(0, down: true, chars: ";")
        EventTapHub.markSynthetic(synth)
        be.fire(.keyDown, synth)
        typeKey(be, "a"); typeKey(be, "b")
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.space), down: true, chars: " ")) == .pass)
        sched.runAll()
        #expect(keys.log.isEmpty)
    }

    @Test func mouseDownResetsTheBufferThroughTheHub() {
        let (be, _, _) = rig([actSnippet(1, ";ab", "X")])
        typeKey(be, ";"); typeKey(be, "a")
        be.fire(.leftMouseDown, ActEvents.left(.leftMouseDown))
        typeKey(be, "b")
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.space), down: true, chars: " ")) == .pass)
    }

    @Test func commandShortcutsPassUntouched() {
        let (be, _, _) = rig([actSnippet(1, ";ab")])
        #expect(be.fire(.keyDown, ActEvents.key(8, down: true, flags: .maskCommand, chars: "c")) == .pass)
    }
}
