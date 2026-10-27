import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct InputStageTests {
    private final class Rig {
        let hub: EventTapHub
        let backend: InpTapBackend
        let resolver = InpResolver()
        var keep: [AnyObject] = []
        var gate: ExceptionGate { ExceptionGate(list: AppExceptionList(), resolver: resolver) }

        func hold<T: AnyObject>(_ o: T) -> T {
            keep.append(o)
            return o
        }

        init() {
            backend = InpTapBackend()
            hub = EventTapHub(backend: backend)
        }
    }

    private func read(_ e: CGEvent) -> ScrollSample { CGScrollBridge.read(e) }

    @Test func inverterFlipsMouseWheelButNotTrackpad() {
        let rig = Rig()
        let st = rig.hold(ScrollInverterStage(hub: rig.hub, gate: rig.gate, vertical: true, horizontal: false))
        st.start()
        let wheel = InpEvents.wheel(line: 2)
        #expect(rig.backend.fire(.scrollWheel, wheel) == .modified)
        #expect(read(wheel).vertical.line == -2)
        let touch = InpEvents.pixelWheel(v: 30, phase: 2)
        #expect(rig.backend.fire(.scrollWheel, touch) == .pass)
        #expect(read(touch).vertical.point == 30)
        let momentum = InpEvents.pixelWheel(v: 9, momentum: 1)
        #expect(rig.backend.fire(.scrollWheel, momentum) == .pass)
    }

    @Test func inverterTreatsPhaselessContinuousWheelAsMouse() {
        let rig = Rig()
        rig.hold(ScrollInverterStage(hub: rig.hub, gate: rig.gate)).start()
        let e = InpEvents.pixelWheel(v: 14)
        #expect(rig.backend.fire(.scrollWheel, e) == .modified)
        #expect(read(e).vertical.point == -14)
    }

    @Test func inverterHonoursPerAxisSettings() {
        let rig = Rig()
        let st = rig.hold(ScrollInverterStage(hub: rig.hub, gate: rig.gate, vertical: false, horizontal: true))
        st.start()
        let e = InpEvents.wheel(line: 3, lineH: 2)
        rig.backend.fire(.scrollWheel, e)
        #expect(read(e).vertical.line == 3 && read(e).horizontal.line == -2)
        st.vertical = true
        st.horizontal = false
        let e2 = InpEvents.wheel(line: 3, lineH: 2)
        rig.backend.fire(.scrollWheel, e2)
        #expect(read(e2).vertical.line == -3 && read(e2).horizontal.line == 2)
    }

    @Test func inverterSkipsExceptedApps() {
        let rig = Rig()
        rig.resolver.bundle = "com.figma.Desktop"
        let gate = ExceptionGate(list: AppExceptionList(["com.figma.Desktop"]), resolver: rig.resolver)
        rig.hold(ScrollInverterStage(hub: rig.hub, gate: gate)).start()
        let e = InpEvents.wheel(line: 2)
        #expect(rig.backend.fire(.scrollWheel, e) == .pass && read(e).vertical.line == 2)
    }

    @Test func stoppedStageIsSilentAndReleasesTheTap() {
        let rig = Rig()
        let st = rig.hold(ScrollInverterStage(hub: rig.hub, gate: rig.gate))
        st.start()
        #expect(st.isRunning && rig.hub.isRunning)
        st.stop()
        #expect(!st.isRunning && !rig.hub.isRunning && rig.hub.subscriberCount == 0)
        st.start()
        st.start()
        #expect(rig.hub.subscriberCount == 1)
    }

    @Test func horizontalStageTurnsShiftWheelSideways() {
        let rig = Rig()
        rig.hold(HorizontalScrollStage(hub: rig.hub, gate: rig.gate, modifier: .shift)).start()
        let e = InpEvents.wheel(line: 3, flags: .maskShift)
        #expect(rig.backend.fire(.scrollWheel, e) == .modified)
        let s = read(e)
        #expect(s.vertical.line == 0 && s.horizontal.line == 3 && !e.flags.contains(.maskShift))
        let plain = InpEvents.wheel(line: 3)
        #expect(rig.backend.fire(.scrollWheel, plain) == .pass && read(plain).vertical.line == 3)
    }

    @Test func horizontalStageIgnoresTrackpad() {
        let rig = Rig()
        rig.hold(HorizontalScrollStage(hub: rig.hub, gate: rig.gate)).start()
        let e = InpEvents.pixelWheel(v: 20, phase: 2)
        e.flags = .maskShift
        #expect(rig.backend.fire(.scrollWheel, e) == .pass && read(e).vertical.point == 20)
    }

    @Test func linearStageCapsAFastSpin() {
        let rig = Rig()
        rig.hold(LinearScrollStage(hub: rig.hub, gate: rig.gate, linesPerNotch: 4)).start()
        let e = InpEvents.wheel(line: 12)
        #expect(rig.backend.fire(.scrollWheel, e) == .modified)
        #expect(read(e).vertical.line == 4)
    }

    @Test func linearStageKeepsStateResetOnTapReset() {
        let rig = Rig()
        let st = rig.hold(LinearScrollStage(hub: rig.hub, gate: rig.gate, linesPerNotch: 3))
        st.start()
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.5)
        rig.backend.fire(.scrollWheel, e)
        #expect(st.linear.carryVertical != 0)
        rig.backend.onDisabled?(.tapDisabledByTimeout)
        #expect(st.linear.carryVertical == 0)
    }

    @Test func chainRunsHorizontalThenInverterThenLinear() {
        let rig = Rig()
        let linear = rig.hold(LinearScrollStage(hub: rig.hub, gate: rig.gate, linesPerNotch: 3))
        let inverter = rig.hold(ScrollInverterStage(hub: rig.hub, gate: rig.gate, vertical: false, horizontal: true))
        let horizontal = rig.hold(HorizontalScrollStage(hub: rig.hub, gate: rig.gate, modifier: .shift))
        linear.start(); inverter.start(); horizontal.start()
        let e = InpEvents.wheel(line: 5, flags: .maskShift)
        #expect(rig.backend.fire(.scrollWheel, e) == .modified)
        let s = read(e)
        #expect(s.vertical.line == 0)
        #expect(s.horizontal.line == -3)
    }

    @Test func smoothStageSwallowsWheelAndFeedsTheRunner() {
        let rig = Rig()
        let ticker = InpTicker(), poster = InpPoster()
        let runner = SmoothScrollRunner(ticker: ticker, poster: poster)
        let st = rig.hold(SmoothScrollStage(hub: rig.hub, gate: rig.gate, runner: runner, step: 40))
        st.start()
        #expect(rig.backend.fire(.scrollWheel, InpEvents.wheel(line: 1)) == .drop)
        #expect(runner.running && runner.engine.remainingVertical == 40)
        #expect(rig.backend.fire(.scrollWheel, InpEvents.wheel(line: -1)) == .drop)
        #expect(runner.engine.remainingVertical == -40)
    }

    @Test func smoothStageLeavesTrackpadAndSyntheticAlone() {
        let rig = Rig()
        let runner = SmoothScrollRunner(ticker: InpTicker(), poster: InpPoster())
        rig.hold(SmoothScrollStage(hub: rig.hub, gate: rig.gate, runner: runner)).start()
        #expect(rig.backend.fire(.scrollWheel, InpEvents.pixelWheel(v: 20, phase: 2)) == .pass)
        let own = InpEvents.wheel(line: 1)
        EventTapHub.markSynthetic(own)
        #expect(rig.backend.fire(.scrollWheel, own) == .pass)
        #expect(!runner.running)
    }

    @Test func smoothStageCancelsGlideOnTapResetAndStop() {
        let rig = Rig()
        let runner = SmoothScrollRunner(ticker: InpTicker(), poster: InpPoster())
        let st = rig.hold(SmoothScrollStage(hub: rig.hub, gate: rig.gate, runner: runner))
        st.start()
        rig.backend.fire(.scrollWheel, InpEvents.wheel(line: 1))
        rig.backend.onDisabled?(.tapDisabledByUserInput)
        #expect(!runner.running)
        rig.backend.fire(.scrollWheel, InpEvents.wheel(line: 1))
        st.stop()
        #expect(!runner.running && !runner.engine.isActive)
    }

    @Test func smoothStageUsesLinearNotchesWhenLinearIsOn() {
        let rig = Rig()
        let runner = SmoothScrollRunner(ticker: InpTicker(), poster: InpPoster())
        let smooth = rig.hold(SmoothScrollStage(hub: rig.hub, gate: rig.gate, runner: runner, step: 40, linearLines: { 3 }))
        let linear = rig.hold(LinearScrollStage(hub: rig.hub, gate: rig.gate, linesPerNotch: 3))
        smooth.start(); linear.start()
        rig.backend.fire(.scrollWheel, InpEvents.wheel(line: 9))
        #expect(runner.engine.remainingVertical == 40)
    }

    @Test func smoothStageShiftSendsGlideSideways() {
        let rig = Rig()
        let runner = SmoothScrollRunner(ticker: InpTicker(), poster: InpPoster())
        rig.hold(SmoothScrollStage(hub: rig.hub, gate: rig.gate, runner: runner)).start()
        rig.backend.fire(.scrollWheel, InpEvents.wheel(line: 1, flags: .maskShift))
        #expect(runner.engine.remainingVertical == 0 && runner.engine.remainingHorizontal == 40)
    }

    @Test func clickStageDropsBounceThroughTheHub() {
        let rig = Rig()
        let st = rig.hold(ClickDebounceStage(hub: rig.hub, settings: ClickDebounceSettings()))
        st.start()
        let base = ProcessInfo.processInfo.systemUptime
        #expect(rig.backend.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown, at: base)) == .pass)
        #expect(rig.backend.fire(.leftMouseUp, InpEvents.mouse(.leftMouseUp, at: base + 0.05)) == .pass)
        #expect(rig.backend.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown, at: base + 0.06)) == .drop)
        #expect(rig.backend.fire(.leftMouseUp, InpEvents.mouse(.leftMouseUp, at: base + 0.07)) == .drop)
        #expect(rig.backend.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown, at: base + 0.30)) == .pass)
        #expect(st.suppressedCount == 2)
    }

    @Test func clickStageIgnoresSideButtonsAndDisabledButtons() {
        let rig = Rig()
        var s = ClickDebounceSettings()
        s.right = false
        let st = rig.hold(ClickDebounceStage(hub: rig.hub, settings: s))
        st.start()
        let base = ProcessInfo.processInfo.systemUptime
        for i in 0..<2 {
            let t = base + Double(i) * 0.01
            #expect(rig.backend.fire(.otherMouseDown, InpEvents.mouse(.otherMouseDown, button: .init(rawValue: 3)!, at: t)) == .pass)
            #expect(rig.backend.fire(.otherMouseUp, InpEvents.mouse(.otherMouseUp, button: .init(rawValue: 3)!, at: t + 0.001)) == .pass)
        }
        #expect(rig.backend.fire(.rightMouseDown, InpEvents.mouse(.rightMouseDown, button: .right, at: base + 1)) == .pass)
        #expect(rig.backend.fire(.rightMouseUp, InpEvents.mouse(.rightMouseUp, button: .right, at: base + 1.01)) == .pass)
        #expect(rig.backend.fire(.rightMouseDown, InpEvents.mouse(.rightMouseDown, button: .right, at: base + 1.02)) == .pass)
    }

    @Test func clickStageResetsOnTapDisabled() {
        let rig = Rig()
        rig.hold(ClickDebounceStage(hub: rig.hub)).start()
        let base = ProcessInfo.processInfo.systemUptime
        rig.backend.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown, at: base))
        rig.backend.fire(.leftMouseUp, InpEvents.mouse(.leftMouseUp, at: base + 0.05))
        rig.backend.onDisabled?(.tapDisabledByTimeout)
        #expect(rig.backend.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown, at: base + 0.06)) == .pass)
    }

    @Test func keyStageFiltersChatterButNotAutorepeat() {
        let rig = Rig()
        var s = KeyDebounceSettings()
        s.globalWindowMs = 40
        let st = rig.hold(KeyDebounceStage(hub: rig.hub, settings: s))
        st.start()
        let b = ProcessInfo.processInfo.systemUptime
        #expect(rig.backend.fire(.keyDown, InpEvents.key(35, down: true, at: b)) == .pass)
        #expect(rig.backend.fire(.keyUp, InpEvents.key(35, down: false, at: b + 0.08)) == .pass)
        #expect(rig.backend.fire(.keyDown, InpEvents.key(35, down: true, at: b + 0.09)) == .drop)
        #expect(rig.backend.fire(.keyUp, InpEvents.key(35, down: false, at: b + 0.10)) == .drop)
        #expect(rig.backend.fire(.keyDown, InpEvents.key(51, down: true, at: b + 1)) == .pass)
        #expect(rig.backend.fire(.keyDown, InpEvents.key(51, down: true, repeating: true, at: b + 1.01)) == .pass)
        #expect(st.suppressedCount == 2)
    }

    @Test func keyStageRespectsIgnoredFrontmostApp() {
        let rig = Rig()
        var s = KeyDebounceSettings()
        s.globalWindowMs = 200
        s.ignoredApps = AppExceptionList(["com.game.x"])
        var front: String? = "com.game.x"
        rig.hold(KeyDebounceStage(hub: rig.hub, settings: s, frontmost: { front })).start()
        let b = ProcessInfo.processInfo.systemUptime
        rig.backend.fire(.keyDown, InpEvents.key(2, down: true, at: b))
        rig.backend.fire(.keyUp, InpEvents.key(2, down: false, at: b + 0.01))
        #expect(rig.backend.fire(.keyDown, InpEvents.key(2, down: true, at: b + 0.02)) == .pass)
        rig.backend.fire(.keyUp, InpEvents.key(2, down: false, at: b + 0.03))
        front = "com.apple.TextEdit"
        rig.backend.fire(.keyDown, InpEvents.key(3, down: true, at: b + 1))
        rig.backend.fire(.keyUp, InpEvents.key(3, down: false, at: b + 1.01))
        #expect(rig.backend.fire(.keyDown, InpEvents.key(3, down: true, at: b + 1.02)) == .drop)
    }

    @Test func debounceDropWinsOverLegacyObserversThatOptOut() {
        let rig = Rig()
        rig.hold(KeyDebounceStage(hub: rig.hub, settings: KeyDebounceSettings())).start()
        var finderSaw = 0
        _ = rig.hub.subscribe(types: [.keyDown], seesDropped: false) { _, _ in finderSaw += 1; return .pass }
        let b = ProcessInfo.processInfo.systemUptime
        rig.backend.fire(.keyDown, InpEvents.key(9, down: true, at: b))
        rig.backend.fire(.keyUp, InpEvents.key(9, down: false, at: b + 0.005))
        #expect(rig.backend.fire(.keyDown, InpEvents.key(9, down: true, at: b + 0.006)) == .drop)
        #expect(finderSaw == 1)
    }

    @Test func focusStageFeedsEngineAndPassesEvents() {
        let rig = Rig()
        let driver = InpFocusDriver()
        driver.window = FocusWindowInfo(pid: 5, bundleID: "a.b", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let engine = FocusFollowsEngine(settings: FocusFollowsSettings(), driver: driver)
        let clock = InpClock()
        let st = rig.hold(FocusFollowsStage(hub: rig.hub, engine: engine, clock: { clock.now }))
        var woke = 0
        st.onMove = { woke += 1 }
        st.start()
        #expect(rig.backend.fire(.mouseMoved, InpEvents.moved(CGPoint(x: 3, y: 3))) == .pass)
        #expect(engine.hasPending && woke == 1)
        clock.now += 0.3
        #expect(engine.tick(now: clock.now) == .focused(raise: true))
        _ = rig.backend.fire(.leftMouseDragged, InpEvents.mouse(.leftMouseDragged))
        #expect(!engine.hasPending)
        st.stop()
        #expect(!rig.hub.isRunning)
    }
}
