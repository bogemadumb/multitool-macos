import Testing
import Foundation
@testable import MultitulCore

@Suite struct PasteboardWatcherTests {
    private func make() -> (ClpFakePasteboard, PasteboardWatcher, ClpFakeFront) {
        let pb = ClpFakePasteboard()
        let front = ClpFakeFront(Clp.safari)
        return (pb, PasteboardWatcher(pasteboard: pb, frontmost: front), front)
    }

    @Test func noChangeMeansNoCallback() {
        let (_, w, _) = make()
        var calls = 0
        _ = w.subscribe(priority: 0) { _ in calls += 1; return false }
        w.tick(); w.tick()
        #expect(calls == 0)
    }

    @Test func changeDeliversCountAndSource() {
        let (pb, w, _) = make()
        var got: [PasteboardChange] = []
        _ = w.subscribe(priority: 0) { got.append($0); return false }
        pb.externalText("a")
        w.tick(); w.tick()
        #expect(got.count == 1)
        #expect(got[0].changeCount == pb.changeCount)
        #expect(got[0].source == Clp.safari)
    }

    @Test func subscribersRunInPriorityOrder() {
        let (pb, w, _) = make()
        var order: [Int] = []
        _ = w.subscribe(priority: 20) { _ in order.append(20); return false }
        _ = w.subscribe(priority: 0) { _ in order.append(0); return false }
        _ = w.subscribe(priority: 10) { _ in order.append(10); return false }
        pb.externalText("a")
        w.tick()
        #expect(order == [0, 10, 20])
    }

    @Test func handlerThatWritesIsNotReplayedNextTick() {
        let (pb, w, _) = make()
        var firstCalls = 0
        _ = w.subscribe(priority: 0) { _ in firstCalls += 1; pb.write([PasteboardItemData(text: "cleaned")]); return true }
        var laterSaw: [String?] = []
        _ = w.subscribe(priority: 10) { _ in laterSaw.append(pb.items.first?.string); return false }
        pb.externalText("dirty")
        w.tick(); w.tick()
        #expect(firstCalls == 1)
        #expect(laterSaw == ["cleaned"])
    }

    @Test func acknowledgedOwnWriteIsInvisible() {
        let (pb, w, _) = make()
        var calls = 0
        _ = w.subscribe(priority: 0) { _ in calls += 1; return false }
        pb.write([PasteboardItemData(text: "mine")])
        w.acknowledgeOwnWrite()
        w.tick()
        #expect(calls == 0)
        pb.externalText("theirs")
        w.tick()
        #expect(calls == 1)
    }

    @Test func activeCallbackFiresOnFirstAndLastSubscriber() {
        let (_, w, _) = make()
        var states: [Bool] = []
        w.onActiveChange = { states.append($0) }
        let a = w.subscribe(priority: 0) { _ in false }
        let b = w.subscribe(priority: 1) { _ in false }
        w.unsubscribe(a)
        #expect(states == [true])
        w.unsubscribe(b)
        #expect(states == [true, false])
        #expect(w.subscriberCount == 0)
    }

    @Test func startingWithExistingContentDoesNotReplayIt() {
        let (pb, w, _) = make()
        pb.externalText("already there")
        var calls = 0
        _ = w.subscribe(priority: 0) { _ in calls += 1; return false }
        w.tick()
        #expect(calls == 0)
    }
}

@Suite struct ClipboardRecorderTests {
    private func make(_ s: ClipSettings = ClipSettings()) -> (ClpFakePasteboard, ClipboardRecorder, ClipStore, PasteboardWatcher) {
        let pb = ClpFakePasteboard()
        let st = Clp.store()
        let rec = ClipboardRecorder(pasteboard: pb, store: st, settings: s, ownBundleID: "dev.multitool.app")
        let w = PasteboardWatcher(pasteboard: pb, frontmost: ClpFakeFront(Clp.safari))
        _ = w.subscribe(priority: 10) { rec.handle($0) }
        return (pb, rec, st, w)
    }

    @Test func recordsCopiedText() throws {
        let (pb, rec, st, w) = make()
        pb.externalText("скопированный текст")
        w.tick()
        #expect(rec.recorded == 1)
        #expect(try st.items().map(\.title) == ["скопированный текст"])
    }

    @Test func secretsAreNotRecorded() throws {
        let (pb, rec, st, w) = make()
        pb.externalText("x", extra: [PBType.concealed: Data()])
        w.tick()
        #expect(rec.lastSkip == .concealed)
        pb.externalText("ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        w.tick()
        #expect(rec.lastSkip == .sensitive)
        #expect(try st.count() == 0)
    }

    @Test func repeatedCopyDedupes() throws {
        let (pb, _, st, w) = make()
        pb.externalText("one more time")
        w.tick()
        pb.externalText("something else")
        w.tick()
        pb.externalText("one more time")
        w.tick()
        #expect(try st.count() == 2)
        #expect(try st.items().first?.title == "one more time")
    }

    @Test func limitsApplyOnEveryInsert() throws {
        var s = ClipSettings()
        s.maxItems = 5
        let (pb, _, st, w) = make(s)
        for i in 1...9 {
            pb.externalText("entry number \(i)")
            w.tick()
        }
        #expect(try st.count() == 5)
        #expect(try st.items().first?.title == "entry number 9")
    }

    @Test func imagesAreReadOnlyWhenWanted() throws {
        let (pb, rec, st, w) = make()
        pb.external([PasteboardItemData(reps: [PBType.png: Clp.png()])])
        w.tick()
        #expect(try st.count() == 0)
        #expect(rec.lastSkip == .empty)
        var s = ClipSettings()
        s.keepImages = true
        rec.settings = s
        pb.external([PasteboardItemData(reps: [PBType.png: Clp.png()])])
        w.tick()
        #expect(try st.items().first?.kind == .image)
    }

    @Test func onRecordedReportsTheStoredItem() {
        let (pb, rec, _, w) = make()
        var seen: [String] = []
        rec.onRecorded = { seen.append($0.title) }
        pb.externalText("reported")
        w.tick()
        #expect(seen == ["reported"])
    }
}

@Suite struct ClipAutoClearTests {
    private func make(seconds: Int) -> (ClpFakePasteboard, ClipAutoClear, ClpFakeScheduler, PasteboardWatcher, () -> Int) {
        let pb = ClpFakePasteboard()
        let sch = ClpFakeScheduler()
        var acks = 0
        let ac = ClipAutoClear(pasteboard: pb, scheduler: sch, seconds: seconds) { acks += 1 }
        let w = PasteboardWatcher(pasteboard: pb, frontmost: ClpFakeFront())
        _ = w.subscribe(priority: 0) { ac.handle($0) }
        return (pb, ac, sch, w, { acks })
    }

    @Test func clearsAfterDelayWhenUnchanged() {
        let (pb, ac, sch, w, acks) = make(seconds: 30)
        pb.externalText("secret")
        w.tick()
        #expect(sch.queue.first?.delay == 30)
        sch.runAll()
        #expect(pb.items.isEmpty)
        #expect(ac.clears == 1)
        #expect(acks() == 1)
    }

    @Test func doesNotClearSomethingNewer() {
        let (pb, _, sch, w, _) = make(seconds: 30)
        pb.externalText("first")
        w.tick()
        pb.externalText("second")
        w.tick()
        sch.runNext()
        #expect(pb.items.first?.string == "second")
        sch.runNext()
        #expect(pb.items.isEmpty)
    }

    @Test func disabledMeansNothingScheduled() {
        let (pb, _, sch, w, _) = make(seconds: 0)
        pb.externalText("x")
        w.tick()
        #expect(sch.queue.isEmpty)
    }

    @Test func clearNowSkipsEmptyPasteboard() {
        let (pb, ac, _, _, _) = make(seconds: 10)
        ac.clearNow()
        #expect(pb.clears == 0)
        pb.externalText("x")
        ac.clearNow()
        #expect(pb.clears == 1)
    }
}
