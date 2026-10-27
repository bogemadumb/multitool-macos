import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private final class Clk { var t: TimeInterval = 100 }

@Suite struct CleaningCounterTests {
    @Test func reachesTargetAndResets() {
        var c = CleaningExitCounter(needed: 3, window: 4)
        let a = c.press(at: 0), b = c.press(at: 1)
        #expect(!a && !b)
        #expect(c.count == 2)
        let done = c.press(at: 2)
        #expect(done)
        #expect(c.count == 0)
    }

    @Test func slowPressesDoNotAccumulate() {
        var c = CleaningExitCounter(needed: 3, window: 2)
        _ = c.press(at: 0); _ = c.press(at: 1)
        let late = c.press(at: 3.5)
        #expect(!late)
        #expect(c.count == 1)
        #expect(c.visibleCount(at: 10) == 0)
    }

    @Test func resetClearsProgress() {
        var c = CleaningExitCounter(needed: 5, window: 4)
        _ = c.press(at: 0)
        c.reset()
        #expect(c.count == 0)
    }
}

@Suite struct CleaningSettingsTests {
    @Test func defaultsMatchTheCatalog() {
        let s = CleaningSettings()
        #expect(s.exitPresses == 5 && s.screenMode == .blackout && !s.blockMouse && s.autoEndMinutes == 0)
    }

    @Test func sanitizeClamps() {
        var s = CleaningSettings()
        s.exitPresses = 1
        s.pressWindow = 99
        s.autoEndMinutes = -3
        let c = s.sanitized
        #expect(c.exitPresses == 3 && c.pressWindow == 15 && c.autoEndMinutes == 0)
        s.exitPresses = 50
        #expect(s.sanitized.exitPresses == 10)
    }

    @Test func storeRoundTrip() {
        let kv = WndMemoryStore()
        let store = CleaningSettingsStore(kv)
        store.save(CleaningSettings())
        #expect(kv.values.isEmpty)
        var s = CleaningSettings()
        s.screenMode = .indicator
        s.exitPresses = 7
        s.pressWindow = 6
        s.blockMouse = true
        s.autoEndMinutes = 15
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("cleaningMode.") })
    }

    @Test func priorityBeatsEveryOtherInputStage() {
        let others = [InputPriority.debounce, InputPriority.superKey, InputPriority.middleClick, InputPriority.buttonShortcuts, InputPriority.horizontal,
                      InputPriority.inverter, InputPriority.navigation, InputPriority.quitProtection, InputPriority.snippets, InputPriority.linear,
                      InputPriority.smooth, InputPriority.focus, InputPriority.switcher, InputPriority.windowRing, InputPriority.windowGesture,
                      InputPriority.dockClick, InputPriority.dockPreview, InputPriority.zoomButton, InputPriority.edgeSnap]
        #expect(others.allSatisfy { InputPriority.cleaning > $0 })
    }
}

@Suite struct CleaningSessionTests {
    private struct Rig {
        let session: CleaningSession
        let hub: EventTapHub
        let be: InpTapBackend
        let overlay: TlsOverlay
        let clock: Clk
        var finished: Box<[CleaningSession.FinishReason]>
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func rig(_ s: CleaningSettings = CleaningSettings(), tap: Bool = true) -> Rig {
        let be = InpTapBackend()
        be.startResult = tap
        let hub = EventTapHub(backend: be)
        let overlay = TlsOverlay()
        let clock = Clk()
        let session = CleaningSession(hub: hub, overlay: overlay, settings: s, clock: { clock.t }, deferred: { $0() })
        let finished = Box<[CleaningSession.FinishReason]>([])
        session.onFinish = { finished.value.append($0) }
        return Rig(session: session, hub: hub, be: be, overlay: overlay, clock: clock, finished: finished)
    }

    private func key(_ code: UInt16, down: Bool = true, repeating: Bool = false) -> CGEvent { InpEvents.key(code, down: down, repeating: repeating) }

    @Test func startShowsOverlayAndSubscribes() {
        let r = rig()
        #expect(r.session.start() == .started)
        #expect(r.session.isActive && r.hub.subscriberCount == 1 && r.hub.isRunning)
        #expect(r.overlay.shown.count == 1 && r.overlay.shown[0].0 == .blackout && r.overlay.shown[0].1 == 5)
    }

    @Test func keyboardEventsAreSwallowed() {
        let r = rig()
        r.session.start()
        #expect(r.be.fire(.keyDown, key(0)) == .drop)
        #expect(r.be.fire(.keyUp, key(0, down: false)) == .drop)
        #expect(r.be.fire(.flagsChanged, key(55)) == .drop)
        #expect(r.be.fire(CGEventType(rawValue: 14)!, key(0)) == .drop)
        #expect(r.session.swallowed == 4)
    }

    @Test func tapMaskCoversKeyboardAndSystemKeysButNotMouseByDefault() {
        let r = rig()
        r.session.start()
        let mask = r.be.starts.last ?? 0
        func has(_ t: CGEventType) -> Bool { mask & (1 << CGEventMask(t.rawValue)) != 0 }
        #expect(has(.keyDown) && has(.keyUp) && has(.flagsChanged) && has(CGEventType(rawValue: 14)!))
        #expect(!has(.leftMouseDown) && !has(.mouseMoved) && !has(.scrollWheel))
    }

    @Test func mouseKeepsWorkingByDefault() {
        let r = rig()
        r.session.start()
        #expect(r.be.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown)) == .pass)
        #expect(r.be.fire(.scrollWheel, InpEvents.wheel(line: 3)) == .pass)
    }

    @Test func mouseIsBlockedWhenAsked() {
        var s = CleaningSettings()
        s.blockMouse = true
        let r = rig(s)
        r.session.start()
        #expect(r.be.fire(.leftMouseDown, InpEvents.mouse(.leftMouseDown)) == .drop)
        #expect(r.be.fire(.scrollWheel, InpEvents.wheel(line: 3)) == .drop)
        #expect(r.be.fire(.keyDown, key(0)) == .drop)
    }

    @Test func fiveEscapesExit() {
        let r = rig()
        r.session.start()
        for i in 1...4 {
            #expect(r.be.fire(.keyDown, key(53)) == .drop)
            #expect(r.session.presses == i && r.session.isActive)
            r.clock.t += 0.5
        }
        #expect(r.be.fire(.keyDown, key(53)) == .drop)
        #expect(!r.session.isActive)
        #expect(r.finished.value == [.exitKeys])
        #expect(r.overlay.hides == 1 && r.hub.subscriberCount == 0)
        #expect(r.overlay.updates == [1, 2, 3, 4])
    }

    @Test func eventsPassAgainAfterExit() {
        let r = rig()
        r.session.start()
        for _ in 0..<5 { r.be.fire(.keyDown, key(53)) }
        #expect(r.be.fire(.keyDown, key(0)) == .pass)
    }

    @Test func autorepeatedEscapeIsNotCounted() {
        let r = rig()
        r.session.start()
        for _ in 0..<20 { r.be.fire(.keyDown, key(53, repeating: true)) }
        #expect(r.session.presses == 0 && r.session.isActive)
    }

    @Test func otherKeysDoNotResetTheCount() {
        let r = rig()
        r.session.start()
        r.be.fire(.keyDown, key(53)); r.be.fire(.keyDown, key(0)); r.be.fire(.keyDown, key(53))
        #expect(r.session.presses == 2)
    }

    @Test func slowEscapesDoNotExit() {
        let r = rig()
        r.session.start()
        for _ in 0..<8 { r.be.fire(.keyDown, key(53)); r.clock.t += 3 }
        #expect(r.session.isActive)
    }

    @Test func customExitCountIsHonoured() {
        var s = CleaningSettings()
        s.exitPresses = 3
        let r = rig(s)
        r.session.start()
        for _ in 0..<3 { r.be.fire(.keyDown, key(53)) }
        #expect(!r.session.isActive)
        #expect(r.overlay.shown[0].1 == 3)
    }

    @Test func missingTapMeansNoOverlayAndNoSubscription() {
        let r = rig(tap: false)
        #expect(r.session.start() == .noTap)
        #expect(!r.session.isActive && r.hub.subscriberCount == 0 && r.overlay.shown.isEmpty)
    }

    @Test func secondStartIsRejected() {
        let r = rig()
        r.session.start()
        #expect(r.session.start() == .alreadyRunning)
        #expect(r.hub.subscriberCount == 1 && r.overlay.shown.count == 1)
    }

    @Test func manualStopRestoresInput() {
        let r = rig()
        r.session.start()
        r.session.stop()
        #expect(r.finished.value == [.stopped] && r.overlay.hides == 1)
        #expect(r.be.stops >= 1)
        r.session.stop()
        #expect(r.overlay.hides == 1)
    }

    @Test func autoEndTimerStopsTheSession() {
        var s = CleaningSettings()
        s.autoEndMinutes = 2
        let r = rig(s)
        r.session.start()
        r.clock.t += 100
        r.session.tick()
        #expect(r.session.isActive)
        r.clock.t += 30
        r.session.tick()
        #expect(!r.session.isActive && r.finished.value == [.timeout])
    }

    @Test func autoEndOffNeverStops() {
        let r = rig()
        r.session.start()
        r.clock.t += 100_000
        r.session.tick()
        #expect(r.session.isActive)
    }

    @Test func settingsCannotChangeWhileActive() {
        let r = rig()
        r.session.start()
        var s = CleaningSettings()
        s.exitPresses = 9
        r.session.updateSettings(s)
        #expect(r.session.settings.exitPresses == 5)
        r.session.stop()
        r.session.updateSettings(s)
        #expect(r.session.settings.exitPresses == 9)
    }

    @Test func swallowsEverythingLowerStagesWouldSee() {
        let r = rig()
        var lowerSaw = 0
        _ = r.hub.subscribe(types: [.keyDown], priority: InputPriority.debounce, seesDropped: false) { _, _ in lowerSaw += 1; return .pass }
        r.session.start()
        r.be.fire(.keyDown, key(0))
        #expect(lowerSaw == 0)
        r.session.stop()
        r.be.fire(.keyDown, key(0))
        #expect(lowerSaw == 1)
    }

    @Test func indicatorModeIsPassedToTheOverlay() {
        var s = CleaningSettings()
        s.screenMode = .indicator
        let r = rig(s)
        r.session.start()
        #expect(r.overlay.shown[0].0 == .indicator)
    }

    @Test func stuckSessionCanBeRestarted() {
        let r = rig()
        r.session.start()
        for _ in 0..<5 { r.be.fire(.keyDown, key(53)) }
        #expect(r.session.start() == .started)
        #expect(r.session.presses == 0)
    }
}
