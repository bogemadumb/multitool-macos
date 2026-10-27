import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct FocusFollowsLogicTests {
    private let win = FocusWindowInfo(pid: 100, bundleID: "com.apple.Safari", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

    private func decide(_ s: FocusFollowsSettings = FocusFollowsSettings(), target: FocusWindowInfo?? = nil, front: Int32? = 200, focused: CGRect? = nil,
                        buttons: Bool = false, mods: Bool = false) -> FocusDecision {
        FocusFollowsLogic.decide(settings: s, target: target ?? win, frontmostPID: front, focusedBounds: focused, buttonsPressed: buttons, modifiersHeld: mods)
    }

    @Test func differentAppIsActivatedWithRaise() {
        #expect(decide() == .activate(raise: true))
    }

    @Test func raiseFlagFollowsSettings() {
        var s = FocusFollowsSettings()
        s.raise = false
        #expect(decide(s) == .activate(raise: false))
    }

    @Test func nothingUnderPointerMeansNothing() {
        #expect(FocusFollowsLogic.decide(settings: FocusFollowsSettings(), target: nil, frontmostPID: 1, focusedBounds: nil, buttonsPressed: false, modifiersHeld: false) == .skip(.noWindow))
    }

    @Test func dockMenuBarAndOverlaysAreSkipped() {
        var w = win
        w.layer = 20
        #expect(decide(target: w) == .skip(.wrongLayer))
        w.layer = 25
        #expect(decide(target: w) == .skip(.wrongLayer))
        w.layer = 3
        #expect(decide(target: w) == .activate(raise: true))
    }

    @Test func excludedAppsAreSkipped() {
        var s = FocusFollowsSettings()
        s.exceptions = AppExceptionList(["com.apple.Safari"])
        #expect(decide(s) == .skip(.excepted))
        s.exceptions = AppExceptionList(["com.apple.*"])
        #expect(decide(s) == .skip(.excepted))
        s.exceptions = AppExceptionList(["com.apple.Mail"])
        #expect(decide(s) == .activate(raise: true))
    }

    @Test func ownWindowsAreSkipped() {
        var w = win
        w.isOwn = true
        #expect(decide(target: w) == .skip(.own))
    }

    @Test func pressedButtonsAndShortcutModifiersBlock() {
        #expect(decide(buttons: true) == .skip(.buttonsPressed))
        #expect(decide(mods: true) == .skip(.modifiersHeld))
    }

    @Test func sameAppSameWindowIsAlreadyFocused() {
        #expect(decide(front: 100, focused: win.bounds) == .skip(.alreadyFocused))
        #expect(decide(front: 100, focused: win.bounds.offsetBy(dx: 1, dy: -1.5)) == .skip(.alreadyFocused))
    }

    @Test func sameAppOtherWindowIsActivated() {
        #expect(decide(front: 100, focused: CGRect(x: 900, y: 0, width: 800, height: 600)) == .activate(raise: true))
    }

    @Test func unknownFocusOfFrontAppIsLeftAlone() {
        #expect(decide(front: 100, focused: nil) == .skip(.focusUnknown))
    }

    @Test func boundsToleranceIsTwoPoints() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(FocusFollowsLogic.sameWindow(a, a.insetBy(dx: -1, dy: -1)))
        #expect(!FocusFollowsLogic.sameWindow(a, a.insetBy(dx: -2, dy: -2)))
    }

    @Test func raiseAlwaysWaitsForStop() {
        var s = FocusFollowsSettings()
        s.raise = true
        s.waitForStop = false
        #expect(FocusFollowsLogic.waitsForStop(s))
        s.raise = false
        #expect(!FocusFollowsLogic.waitsForStop(s))
        s.waitForStop = true
        #expect(FocusFollowsLogic.waitsForStop(s))
    }

    @Test func delayIsSanitized() {
        var s = FocusFollowsSettings()
        s.delayMs = 5
        #expect(s.sanitized.delayMs == 100)
        s.delayMs = 99999
        #expect(s.sanitized.delayMs == 3000)
        #expect(FocusFollowsSettings().delayMs == 250)
    }
}

@Suite struct FocusFollowsEngineTests {
    private func make(raise: Bool = true, wait: Bool = true, delay: Int = 250) -> (FocusFollowsEngine, InpFocusDriver) {
        var s = FocusFollowsSettings()
        s.raise = raise
        s.waitForStop = wait
        s.delayMs = delay
        let d = InpFocusDriver()
        d.window = FocusWindowInfo(pid: 100, bundleID: "com.apple.Safari", bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        d.front = 200
        return (FocusFollowsEngine(settings: s, driver: d), d)
    }

    @Test func nothingHappensWithoutMovement() {
        let (e, d) = make()
        #expect(e.tick(now: 10) == .idle && d.lookups == 0)
    }

    @Test func focusWaitsForTheDelay() {
        let (e, d) = make(delay: 250)
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 10.1) == .waiting)
        #expect(e.tick(now: 10.24) == .waiting)
        #expect(e.tick(now: 10.26) == .focused(raise: true))
        #expect(d.focusCalls.count == 1 && e.focusCount == 1)
    }

    @Test func movementRestartsTheDelayWhenWaitingForStop() {
        let (e, d) = make(delay: 250)
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        e.pointerMoved(to: CGPoint(x: 9, y: 5), at: 10.2, dragging: false)
        #expect(e.tick(now: 10.3) == .waiting)
        #expect(e.tick(now: 10.46) == .focused(raise: true))
        #expect(d.focusCalls.first?.0.pid == 100)
    }

    @Test func withoutWaitingMovementInsideTheSameWindowKeepsTheClock() {
        let (e, _) = make(raise: false, wait: false, delay: 250)
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 10.0) == .waiting)
        e.pointerMoved(to: CGPoint(x: 50, y: 50), at: 10.2, dragging: false)
        #expect(e.tick(now: 10.26) == .focused(raise: false))
    }

    @Test func withoutWaitingEnteringAnotherWindowRestartsTheClock() {
        let (e, d) = make(raise: false, wait: false, delay: 250)
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 10.0) == .waiting)
        d.window = FocusWindowInfo(pid: 101, bundleID: "com.apple.Notes", bounds: CGRect(x: 600, y: 0, width: 300, height: 300))
        e.pointerMoved(to: CGPoint(x: 650, y: 5), at: 10.2, dragging: false)
        #expect(e.tick(now: 10.26) == .waiting)
        #expect(e.tick(now: 10.52) == .focused(raise: false))
        #expect(d.focusCalls.last?.0.pid == 101)
    }

    @Test func draggingCancelsPendingFocus() {
        let (e, d) = make()
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        e.pointerMoved(to: CGPoint(x: 9, y: 9), at: 10.1, dragging: true)
        #expect(!e.hasPending && e.tick(now: 11) == .idle && d.focusCalls.isEmpty)
    }

    @Test func decisionIsFinalSoItDoesNotRepeat() {
        let (e, d) = make()
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        _ = e.tick(now: 11)
        #expect(e.tick(now: 12) == .idle && d.focusCalls.count == 1 && !e.hasPending)
    }

    @Test func failedFocusIsReportedNotCounted() {
        let (e, d) = make()
        d.focusOK = false
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 11) == .failed && e.focusCount == 0)
    }

    @Test func skipReasonsComeFromDriverState() {
        let (e, d) = make()
        d.buttons = true
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 11) == .skipped(.buttonsPressed) && d.focusCalls.isEmpty)
        d.buttons = false
        d.modifiers = true
        e.pointerMoved(to: CGPoint(x: 6, y: 5), at: 12, dragging: false)
        #expect(e.tick(now: 13) == .skipped(.modifiersHeld))
    }

    @Test func alreadyFocusedWindowIsNotTouched() {
        let (e, d) = make()
        d.front = 100
        d.focusedBounds = d.window?.bounds
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 11) == .skipped(.alreadyFocused) && d.focusCalls.isEmpty)
    }

    @Test func settingsCanBeSwappedLive() {
        let (e, _) = make(delay: 3000)
        var s = e.settings
        s.delayMs = 100
        e.settings = s
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 10.2) == .focused(raise: true))
    }

    @Test func resetDropsPendingWork() {
        let (e, _) = make()
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        e.reset()
        #expect(e.tick(now: 20) == .idle)
    }

    @Test func nothingUnderPointerEndsPendingWithSkip() {
        let (e, d) = make()
        d.window = nil
        e.pointerMoved(to: CGPoint(x: 5, y: 5), at: 10, dragging: false)
        #expect(e.tick(now: 11) == .skipped(.noWindow) && !e.hasPending)
    }
}
