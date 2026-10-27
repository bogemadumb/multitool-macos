import Testing
import Foundation
import AppKit
@testable import MultitulCore

@Suite struct ClipComposerTests {
    private func stored(_ texts: [String]) throws -> (ClipStore, [ClipItem]) {
        let st = Clp.store()
        var items: [ClipItem] = []
        for t in texts { items.append(try st.item(id: try st.insert(Clp.candidate(t)).id)!) }
        return (st, items)
    }

    @Test func singleTextPastesItsOriginalRepresentations() throws {
        let st = Clp.store()
        var s = ClipSettings()
        s.keepRich = true
        guard case .record(let c) = ClipCapture.evaluate(Clp.snap([Clp.text("форматированный", extra: [PBType.rtf: Data("{\\rtf1 x}".utf8)])]), settings: s) else { Issue.record("x"); return }
        let it = try st.item(id: try st.insert(c).id)!
        let asIs = ClipComposer.compose(Clp.entries(st, [it]), plain: false)
        #expect(asIs.count == 1)
        #expect(Set(asIs[0].reps.keys) == [PBType.utf8, PBType.rtf])
        let plain = ClipComposer.compose(Clp.entries(st, [it]), plain: true)
        #expect(Set(plain[0].reps.keys) == [PBType.utf8])
        #expect(plain[0].string == "форматированный")
    }

    @Test func multipleTextsAreJoinedWithNewlines() throws {
        let (st, items) = try stored(["первая строка", "вторая строка", "третья строка"])
        let out = ClipComposer.compose(Clp.entries(st, items), plain: false)
        #expect(out.count == 1)
        #expect(out[0].string == "первая строка\nвторая строка\nтретья строка")
    }

    @Test func multipleFileItemsStaySeparatePasteboardItems() throws {
        let st = Clp.store()
        var s = ClipSettings()
        s.keepFiles = true
        var items: [ClipItem] = []
        for p in ["/tmp/a.txt", "/tmp/b.txt"] {
            guard case .record(let c) = ClipCapture.evaluate(Clp.snap([Clp.fileItem(p)]), settings: s) else { Issue.record("x"); return }
            items.append(try st.item(id: try st.insert(c).id)!)
        }
        let out = ClipComposer.compose(Clp.entries(st, items), plain: false)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.reps[PBType.fileURL] != nil })
    }

    @Test func mixedFilesAndTextFallBackToText() throws {
        let st = Clp.store()
        var s = ClipSettings()
        s.keepFiles = true
        guard case .record(let f) = ClipCapture.evaluate(Clp.snap([Clp.fileItem("/tmp/a.txt")]), settings: s) else { Issue.record("x"); return }
        let fi = try st.item(id: try st.insert(f).id)!
        let ti = try st.item(id: try st.insert(Clp.candidate("просто текст")).id)!
        let out = ClipComposer.compose(Clp.entries(st, [ti, fi]), plain: false)
        #expect(out.count == 1)
        #expect(out[0].string == "просто текст\n/tmp/a.txt")
    }

    @Test func emptyInputComposesNothing() {
        #expect(ClipComposer.compose([], plain: false).isEmpty)
    }
}

@Suite struct ClipPasteEngineTests {
    private func make() -> (ClpFakePasteboard, ClpFakeKeys, ClpFakeScheduler, ClpFakeActivator, ClipPasteEngine, ClipStore, () -> Int) {
        let pb = ClpFakePasteboard()
        let keys = ClpFakeKeys()
        let sch = ClpFakeScheduler()
        let act = ClpFakeActivator()
        var acks = 0
        let e = ClipPasteEngine(pasteboard: pb, keys: keys, activator: act, scheduler: sch) { acks += 1 }
        return (pb, keys, sch, act, e, Clp.store(), { acks })
    }

    private func entry(_ st: ClipStore, _ text: String) throws -> [(item: ClipItem, reps: [ClipRep])] {
        let it = try st.item(id: try st.insert(Clp.candidate(text)).id)!
        return Clp.entries(st, [it])
    }

    @Test func pasteWritesActivatesTargetThenSendsCommandV() throws {
        let (pb, keys, sch, act, e, st, acks) = make()
        let out = e.paste(try entry(st, "вставь меня"), plain: false, target: Clp.notes, copyOnly: false)
        #expect(out == .pasted)
        #expect(pb.items.first?.string == "вставь меня")
        #expect(acks() == 1)
        #expect(act.activated == [Clp.notes])
        #expect(keys.pastes == 0)
        sch.runAll()
        #expect(keys.pastes == 1)
    }

    @Test func copyOnlyNeverSendsKeys() throws {
        let (pb, keys, sch, act, e, st, _) = make()
        let out = e.paste(try entry(st, "только в буфер"), plain: false, target: Clp.notes, copyOnly: true)
        sch.runAll()
        #expect(out == .copiedOnly)
        #expect(pb.items.first?.string == "только в буфер")
        #expect(keys.pastes == 0)
        #expect(act.activated.isEmpty)
    }

    @Test func missingAccessibilityLeavesTextOnClipboard() throws {
        let (pb, keys, sch, _, e, st, _) = make()
        keys.canSend = false
        let out = e.paste(try entry(st, "нет доступа"), plain: false, target: nil, copyOnly: false)
        sch.runAll()
        #expect(out == .needsAccessibility)
        #expect(pb.items.first?.string == "нет доступа")
        #expect(keys.pastes == 0)
    }

    @Test func waitsUntilModifiersAreReleased() throws {
        let (_, keys, sch, _, e, st, _) = make()
        keys.heldPolls = [true, true, false]
        var result: PasteOutcome?
        e.paste(try entry(st, "после отпускания"), plain: false, target: nil, copyOnly: false) { result = $0 }
        sch.runAll()
        #expect(keys.pastes == 1)
        #expect(result == .pasted)
    }

    @Test func givesUpWaitingForModifiersAfterTheLimit() throws {
        let (_, keys, sch, _, e, st, _) = make()
        keys.heldPolls = Array(repeating: true, count: 100)
        e.paste(try entry(st, "застряла клавиша"), plain: false, target: nil, copyOnly: false)
        sch.runAll()
        #expect(keys.pastes == 1)
    }

    @Test func emptySelectionDoesNothing() {
        let (pb, keys, _, _, e, _, _) = make()
        #expect(e.paste([], plain: false, target: nil, copyOnly: false) == .nothing)
        #expect(pb.writes == 0)
        #expect(keys.pastes == 0)
    }
}

@Suite struct PastePlainTests {
    private func rtf(_ s: String) -> Data {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        return try! a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @Test func extractPrefersPlainStringThenRtfThenHtml() {
        #expect(PlainText.extract([Clp.text("plain", extra: [PBType.rtf: rtf("other")])]) == "plain")
        #expect(PlainText.extract([PasteboardItemData(reps: [PBType.rtf: rtf("из rtf")])]) == "из rtf")
        #expect(PlainText.extract([PasteboardItemData(reps: [PBType.html: Data("<p>из <b>html</b></p>".utf8)])])?.contains("из html") == true)
        #expect(PlainText.extract([PasteboardItemData(reps: [PBType.png: Clp.png()])]) == nil)
        #expect(PlainText.extract([]) == nil)
    }

    @Test func trimOptionStripsEdges() {
        #expect(PlainText.extract([Clp.text("  \n отступы \n\n")], trim: true) == "отступы")
        #expect(PlainText.extract([Clp.text("  \n отступы \n\n")], trim: false) == "  \n отступы \n\n")
        #expect(PlainText.extract([Clp.text("   ")], trim: true) == nil)
    }

    private func make() -> (ClpFakePasteboard, ClpFakeKeys, ClpFakeScheduler, PastePlainEngine, () -> Int) {
        let pb = ClpFakePasteboard()
        let keys = ClpFakeKeys()
        let sch = ClpFakeScheduler()
        var acks = 0
        let e = PastePlainEngine(pasteboard: pb, keys: keys, scheduler: sch) { acks += 1 }
        return (pb, keys, sch, e, { acks })
    }

    @Test func pastesPlainThenRestoresFormattedOriginal() {
        let (pb, keys, sch, e, acks) = make()
        let original = Clp.text("красивый", extra: [PBType.rtf: rtf("красивый")])
        pb.external([original])
        let out = e.run()
        #expect(out == .pasted)
        #expect(pb.items == [PasteboardItemData(text: "красивый")])
        sch.runNext()
        #expect(keys.pastes == 1)
        sch.runNext()
        #expect(pb.items == [original])
        #expect(acks() == 2)
    }

    @Test func doesNotRestoreIfUserCopiedSomethingMeanwhile() {
        let (pb, _, sch, e, _) = make()
        pb.external([Clp.text("старый", extra: [PBType.rtf: rtf("старый")])])
        e.run()
        sch.runNext()
        pb.externalText("новое копирование")
        sch.runNext()
        #expect(pb.items.first?.string == "новое копирование")
    }

    @Test func nothingToPasteLeavesClipboardAlone() {
        let (pb, keys, sch, e, _) = make()
        pb.external([PasteboardItemData(reps: [PBType.png: Clp.png()])])
        let before = pb.changeCount
        #expect(e.run() == .nothing)
        sch.runAll()
        #expect(pb.changeCount == before)
        #expect(keys.pastes == 0)
    }

    @Test func needsAccessibilityBeforeTouchingTheClipboard() {
        let (pb, keys, _, e, _) = make()
        keys.canSend = false
        pb.externalText("текст")
        let before = pb.changeCount
        #expect(e.run() == .needsAccessibility)
        #expect(pb.changeCount == before)
    }

    @Test func trimSettingIsApplied() {
        let (pb, _, _, e, _) = make()
        e.settings.trimEdges = true
        pb.externalText("\n  обрезать  \n")
        e.run()
        #expect(pb.items.first?.string == "обрезать")
    }
}
