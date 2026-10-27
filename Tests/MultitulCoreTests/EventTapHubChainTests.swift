import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct EventTapHubChainTests {
    private func hub() -> (EventTapHub, InpTapBackend) {
        let be = InpTapBackend()
        return (EventTapHub(backend: be), be)
    }

    private func keyEvent() -> CGEvent { InpEvents.key(0, down: true) }

    @Test func higherPriorityRunsFirst() {
        let (h, be) = hub()
        var order: [String] = []
        _ = h.subscribe(types: [.keyDown], priority: 1) { _, _ in order.append("low"); return .pass }
        _ = h.subscribe(types: [.keyDown], priority: 9) { _, _ in order.append("high"); return .pass }
        _ = h.subscribe(types: [.keyDown], priority: 5) { _, _ in order.append("mid"); return .pass }
        be.fire(.keyDown, keyEvent())
        #expect(order == ["high", "mid", "low"])
    }

    @Test func equalPriorityKeepsSubscriptionOrder() {
        let (h, be) = hub()
        var order: [Int] = []
        for i in 0..<4 { _ = h.subscribe(types: [.keyDown]) { _, _ in order.append(i); return .pass } }
        be.fire(.keyDown, keyEvent())
        #expect(order == [0, 1, 2, 3])
    }

    @Test func dropStopsFilteringSubscribers() {
        let (h, be) = hub()
        var laterSaw = false
        _ = h.subscribe(types: [.keyDown], priority: 10) { _, _ in .drop }
        _ = h.subscribe(types: [.keyDown], priority: 1, seesDropped: false) { _, _ in laterSaw = true; return .pass }
        #expect(be.fire(.keyDown, keyEvent()) == .drop)
        #expect(!laterSaw)
    }

    @Test func legacyObserverStillSeesDroppedEvents() {
        let (h, be) = hub()
        var observed = false
        _ = h.subscribe(types: [.keyDown], priority: 10) { _, _ in .drop }
        _ = h.subscribe(types: [.keyDown]) { _, _ in observed = true; return .pass }
        #expect(be.fire(.keyDown, keyEvent()) == .drop)
        #expect(observed)
    }

    @Test func resultAggregationDropBeatsModifiedBeatsPass() {
        let (h, be) = hub()
        let t1 = h.subscribe(types: [.keyDown]) { _, _ in .pass }
        #expect(be.fire(.keyDown, keyEvent()) == .pass)
        let t2 = h.subscribe(types: [.keyDown]) { _, _ in .modified }
        #expect(be.fire(.keyDown, keyEvent()) == .modified)
        _ = h.subscribe(types: [.keyDown], priority: -5) { _, _ in .drop }
        #expect(be.fire(.keyDown, keyEvent()) == .drop)
        h.unsubscribe(t1)
        h.unsubscribe(t2)
        #expect(be.fire(.keyDown, keyEvent()) == .drop)
    }

    @Test func mutationIsVisibleDownstream() {
        let (h, be) = hub()
        var seen: Int64 = -1
        _ = h.subscribe(types: [.scrollWheel], priority: 10) { _, e in
            e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 7)
            return .modified
        }
        _ = h.subscribe(types: [.scrollWheel], priority: 1) { _, e in
            seen = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            return .pass
        }
        let e = InpEvents.wheel(line: 1)
        #expect(be.fire(.scrollWheel, e) == .modified)
        #expect(seen == 7)
    }

    @Test func subscriptionIsPerEventType() {
        let (h, be) = hub()
        var keys = 0, scrolls = 0
        _ = h.subscribe(types: [.keyDown]) { _, _ in keys += 1; return .pass }
        _ = h.subscribe(types: [.scrollWheel]) { _, _ in scrolls += 1; return .pass }
        be.fire(.keyDown, keyEvent())
        be.fire(.scrollWheel, InpEvents.wheel(line: 1))
        be.fire(.scrollWheel, InpEvents.wheel(line: 1))
        #expect(keys == 1 && scrolls == 2)
    }

    @Test func syntheticEventsSkippedUnlessRequested() {
        let (h, be) = hub()
        var plain = 0, aware = 0
        _ = h.subscribe(types: [.scrollWheel]) { _, _ in plain += 1; return .pass }
        _ = h.subscribe(types: [.scrollWheel], includeSynthesized: true) { _, _ in aware += 1; return .pass }
        let e = InpEvents.wheel(line: 1)
        EventTapHub.markSynthetic(e)
        #expect(EventTapHub.isSynthetic(e))
        be.fire(.scrollWheel, e)
        #expect(plain == 0 && aware == 1)
        be.fire(.scrollWheel, InpEvents.wheel(line: 1))
        #expect(plain == 1 && aware == 2)
    }

    @Test func foreignUserDataIsNotSynthetic() {
        let e = keyEvent()
        e.setIntegerValueField(.eventSourceUserData, value: 12345)
        #expect(!EventTapHub.isSynthetic(e))
    }

    @Test func tapDisabledResetsEverySubscriber() {
        let (h, be) = hub()
        var resets = 0
        _ = h.subscribe(types: [.keyDown], onReset: { resets += 1 }) { _, _ in .pass }
        _ = h.subscribe(types: [.scrollWheel], onReset: { resets += 1 }) { _, _ in .pass }
        _ = h.subscribe(types: [.keyUp]) { _, _ in .pass }
        be.onDisabled?(.tapDisabledByTimeout)
        #expect(resets == 2 && h.disabledCount == 1 && h.lastDisabledType == .tapDisabledByTimeout)
        be.onDisabled?(.tapDisabledByUserInput)
        #expect(resets == 4 && h.disabledCount == 2 && h.lastDisabledType == .tapDisabledByUserInput)
    }

    @Test func unsubscribeInsideDispatchSkipsRemovedSubscriber() {
        let (h, be) = hub()
        var second = 0
        var token: EventTapHub.Token?
        _ = h.subscribe(types: [.keyDown], priority: 5) { _, _ in
            if let t = token { h.unsubscribe(t) }
            return .pass
        }
        token = h.subscribe(types: [.keyDown], priority: 1) { _, _ in second += 1; return .pass }
        be.fire(.keyDown, keyEvent())
        #expect(second == 0)
        #expect(h.subscriberCount == 1)
    }

    @Test func maskIsUnionAndRestartsOnlyWhenItChanges() {
        let (h, be) = hub()
        let a = h.subscribe(types: [.keyDown]) { _, _ in .pass }
        let b = h.subscribe(types: [.keyDown]) { _, _ in .pass }
        #expect(be.starts.count == 1)
        let c = h.subscribe(types: [.scrollWheel, .mouseMoved]) { _, _ in .pass }
        #expect(be.starts.count == 2)
        #expect(be.starts[1] == EventTapHub.mask([.keyDown, .scrollWheel, .mouseMoved]))
        h.unsubscribe(c)
        #expect(be.starts.last == EventTapHub.mask([.keyDown]))
        h.unsubscribe(a)
        #expect(h.isRunning)
        h.unsubscribe(b)
        #expect(!h.isRunning)
    }

    @Test func startFailureIsReportedAndRetryWorks() {
        let (h, be) = hub()
        be.startResult = false
        _ = h.subscribe(types: [.keyDown]) { _, _ in .pass }
        #expect(!h.isRunning && h.lastStartFailed)
        be.startResult = true
        h.retryStart()
        #expect(h.isRunning && !h.lastStartFailed)
    }

    @Test func isSubscribedTracksTokens() {
        let (h, _) = hub()
        let t = h.subscribe(types: [.keyDown]) { _, _ in .pass }
        #expect(h.isSubscribed(t))
        h.unsubscribe(t)
        #expect(!h.isSubscribed(t))
    }

    @Test func sevenTapStagesShareOneBackendTap() {
        let (h, be) = hub()
        let gate = ExceptionGate(resolver: InpResolver())
        let ticker = InpTicker()
        let runner = SmoothScrollRunner(ticker: ticker, poster: InpPoster())
        let engine = FocusFollowsEngine(settings: FocusFollowsSettings(), driver: InpFocusDriver())
        let hs = HorizontalScrollStage(hub: h, gate: gate), inv = ScrollInverterStage(hub: h, gate: gate), lin = LinearScrollStage(hub: h, gate: gate)
        let sm = SmoothScrollStage(hub: h, gate: gate, runner: runner), cl = ClickDebounceStage(hub: h), kd = KeyDebounceStage(hub: h), ff = FocusFollowsStage(hub: h, engine: engine)
        hs.start(); inv.start(); lin.start(); sm.start(); cl.start(); kd.start(); ff.start()
        #expect(h.subscriberCount == 7)
        #expect(be.starts.count == 4)
        let mask = be.starts.last ?? 0
        for t in [CGEventType.scrollWheel, .keyDown, .keyUp, .leftMouseDown, .rightMouseUp, .otherMouseDragged, .mouseMoved] {
            #expect(mask & (1 << CGEventMask(t.rawValue)) != 0)
        }
        hs.stop(); inv.stop(); lin.stop(); sm.stop(); cl.stop(); kd.stop(); ff.stop()
        #expect(h.subscriberCount == 0 && !h.isRunning)
    }
}
