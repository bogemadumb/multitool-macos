import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func machine(_ f: (inout IslMachineConfig) -> Void = { _ in }) -> IslStateMachine {
    var c = IslMachineConfig()
    f(&c)
    return IslStateMachine(config: c)
}

private func at(_ s: TimeInterval) -> Date { IslFix.at(s) }

@Suite struct IslHoverTests {
    @Test func startsClosed() {
        let m = machine()
        #expect(m.state == .closed && !m.pinned && !m.pointerInside && m.nextDeadline == nil)
    }

    @Test func enteringArmsTheHoverTimer() {
        let m = machine()
        #expect(m.handle(.pointerEntered, now: at(0)).isEmpty)
        #expect(m.nextDeadline == at(0.25))
        #expect(m.state == .closed)
    }

    @Test func tickBeforeTheDelayDoesNothing() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        #expect(m.tick(now: at(0.2)).isEmpty)
        #expect(m.state == .closed)
    }

    @Test func tickAfterTheDelayOpens() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        let t = m.tick(now: at(0.26))
        #expect(t == [IslTransition(from: .closed, to: .open, trigger: .hover)])
        #expect(m.state == .open && m.openedBy == .hover)
    }

    @Test func leavingBeforeTheDelayCancels() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.handle(.pointerLeft, now: at(0.1))
        #expect(m.tick(now: at(1)).isEmpty)
        #expect(m.state == .closed)
        #expect(m.nextDeadline == nil)
    }

    @Test func customHoverDelayIsUsed() {
        let m = machine { $0.hoverDelay = 0.6 }
        _ = m.handle(.pointerEntered, now: at(0))
        #expect(m.nextDeadline == at(0.6))
    }

    @Test func hoverDisabledNeverArms() {
        let m = machine { $0.openOnHover = false }
        _ = m.handle(.pointerEntered, now: at(0))
        #expect(m.nextDeadline == nil)
        #expect(m.tick(now: at(5)).isEmpty)
    }

    @Test func turningHoverOffCancelsAPendingOpen() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        var c = m.config
        c.openOnHover = false
        m.config = c
        #expect(m.tick(now: at(1)).isEmpty)
    }

    @Test func reEnteringDoesNotRestartTheTimer() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.handle(.pointerEntered, now: at(0.2))
        #expect(m.nextDeadline == at(0.25))
    }

    @Test func pointerGoneAtTheDeadlineKeepsItClosed() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.handle(.pointerLeft, now: at(0.24))
        #expect(m.tick(now: at(0.3)).isEmpty)
    }
}

@Suite struct IslLeaveTests {
    private func opened(_ f: (inout IslMachineConfig) -> Void = { _ in }) -> IslStateMachine {
        let m = machine(f)
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.tick(now: at(0.3))
        return m
    }

    @Test func leavingArmsTheGraceTimer() {
        let m = opened()
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.nextDeadline == at(1.4))
    }

    @Test func graceExpiryCloses() {
        let m = opened()
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.tick(now: at(1.3)).isEmpty)
        #expect(m.tick(now: at(1.41)) == [IslTransition(from: .open, to: .closed, trigger: .leave)])
    }

    @Test func comingBackWithinTheGraceKeepsItOpen() {
        let m = opened()
        _ = m.handle(.pointerLeft, now: at(1))
        _ = m.handle(.pointerEntered, now: at(1.2))
        #expect(m.tick(now: at(2)).isEmpty)
        #expect(m.state == .open)
    }

    @Test func customGrace() {
        let m = opened { $0.leaveGrace = 1.5 }
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.nextDeadline == at(2.5))
    }

    @Test func outsideClickModeIgnoresLeaving() {
        let m = opened { $0.closeBehavior = .onOutsideClick }
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.nextDeadline == nil)
        #expect(m.tick(now: at(10)).isEmpty)
        #expect(m.state == .open)
    }

    @Test func manualModeIgnoresLeavingAndOutsideClicks() {
        let m = opened { $0.closeBehavior = .manual }
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.handle(.outsideClick, now: at(2)).isEmpty)
        #expect(m.state == .open)
    }

    @Test func outsideClickClosesInTheOtherModes() {
        for b in [IslCloseBehavior.onLeave, .onOutsideClick] {
            let m = opened { $0.closeBehavior = b }
            #expect(m.handle(.outsideClick, now: at(1)) == [IslTransition(from: .open, to: .closed, trigger: .outsideClick)])
        }
    }

    @Test func pinnedIslandSurvivesLeavingAndOutsideClicks() {
        let m = opened()
        _ = m.handle(.setPinned(true), now: at(1))
        _ = m.handle(.pointerLeft, now: at(1.1))
        #expect(m.nextDeadline == nil)
        #expect(m.handle(.outsideClick, now: at(2)).isEmpty)
        #expect(m.tick(now: at(9)).isEmpty)
        #expect(m.state == .open && m.pinned)
    }

    @Test func unpinningWhileOutsideStartsTheGrace() {
        let m = opened()
        _ = m.handle(.setPinned(true), now: at(1))
        _ = m.handle(.pointerLeft, now: at(1.1))
        _ = m.handle(.setPinned(false), now: at(5))
        #expect(m.nextDeadline == at(5.4))
    }

    @Test func pinningCancelsAPendingClose() {
        let m = opened()
        _ = m.handle(.pointerLeft, now: at(1))
        _ = m.handle(.setPinned(true), now: at(1.1))
        #expect(m.tick(now: at(3)).isEmpty)
    }

    @Test func pinOnlyAppliesToAnOpenIsland() {
        let m = machine()
        _ = m.handle(.setPinned(true), now: at(0))
        #expect(!m.pinned)
    }

    @Test func closingClearsThePin() {
        let m = opened()
        _ = m.handle(.setPinned(true), now: at(1))
        _ = m.handle(.escape, now: at(2))
        #expect(m.state == .closed && !m.pinned)
    }

    @Test func hotkeyOpenedIslandStaysUntilThePointerHasBeenInside() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.nextDeadline == nil)
        _ = m.handle(.pointerEntered, now: at(2))
        _ = m.handle(.pointerLeft, now: at(3))
        #expect(m.nextDeadline == at(3.4))
    }
}

@Suite struct IslExplicitEventTests {
    @Test func hotkeyToggles() {
        let m = machine()
        #expect(m.handle(.hotkey, now: at(0)) == [IslTransition(from: .closed, to: .open, trigger: .hotkey)])
        #expect(m.handle(.hotkey, now: at(1)) == [IslTransition(from: .open, to: .closed, trigger: .hotkey)])
    }

    @Test func clickOpensAndCloses() {
        let m = machine()
        #expect(m.handle(.clicked, now: at(0)).first?.to == .open)
        #expect(m.handle(.clicked, now: at(1)).first?.to == .closed)
    }

    @Test func clickWhenDisabledDoesNothing() {
        let m = machine { $0.openOnClick = false }
        #expect(m.handle(.clicked, now: at(0)).isEmpty)
    }

    @Test func clickDoesNotCloseAPinnedIsland() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.setPinned(true), now: at(1))
        #expect(m.handle(.clicked, now: at(2)).isEmpty)
    }

    @Test func scrollOpens() {
        let m = machine()
        #expect(m.handle(.scrollOpen, now: at(0)) == [IslTransition(from: .closed, to: .open, trigger: .scroll)])
    }

    @Test func scrollOpenCanBeDisabled() {
        let m = machine { $0.openOnScroll = false }
        #expect(m.handle(.scrollOpen, now: at(0)).isEmpty)
    }

    @Test func scrollCloseOnlyWorksWhenOpenAndEnabled() {
        let m = machine()
        #expect(m.handle(.scrollClose, now: at(0)).isEmpty)
        _ = m.handle(.hotkey, now: at(1))
        #expect(m.handle(.scrollClose, now: at(2)).first?.to == .closed)
        let n = machine { $0.closeOnScrollUp = false }
        _ = n.handle(.hotkey, now: at(0))
        #expect(n.handle(.scrollClose, now: at(1)).isEmpty)
    }

    @Test func scrollCloseRespectsThePin() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.setPinned(true), now: at(1))
        #expect(m.handle(.scrollClose, now: at(2)).isEmpty)
    }

    @Test func escapeClosesEvenAPinnedIsland() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.setPinned(true), now: at(1))
        #expect(m.handle(.escape, now: at(2)).first?.to == .closed)
        #expect(m.handle(.escape, now: at(3)).isEmpty)
    }

    @Test func dragEntryOpens() {
        let m = machine()
        #expect(m.handle(.dragEntered, now: at(0)).first == IslTransition(from: .closed, to: .open, trigger: .drag))
        #expect(m.handle(.dragEntered, now: at(1)).isEmpty)
    }

    @Test func forceCloseAlwaysCloses() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.setPinned(true), now: at(1))
        #expect(m.handle(.forceClose, now: at(2)).first?.to == .closed)
    }

    @Test func openingClearsPendingTimers() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.handle(.hotkey, now: at(0.1))
        #expect(m.nextDeadline == nil)
    }
}

@Suite struct IslPeekTests {
    @Test func peekRequestShowsThePeekState() {
        let m = machine()
        #expect(m.handle(.peek(duration: nil), now: at(0)) == [IslTransition(from: .closed, to: .peek, trigger: .peekRequest)])
        #expect(m.nextDeadline == at(3))
    }

    @Test func peekEndsByTimeout() {
        let m = machine()
        _ = m.handle(.peek(duration: 2), now: at(0))
        #expect(m.tick(now: at(1.9)).isEmpty)
        #expect(m.tick(now: at(2.1)) == [IslTransition(from: .peek, to: .closed, trigger: .timeout)])
    }

    @Test func repeatedPeekExtendsTheDeadline() {
        let m = machine()
        _ = m.handle(.peek(duration: 2), now: at(0))
        #expect(m.handle(.peek(duration: 2), now: at(1)).isEmpty)
        #expect(m.nextDeadline == at(3))
    }

    @Test func peekDoesNotDisturbAnOpenIsland() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        #expect(m.handle(.peek(duration: nil), now: at(1)).isEmpty)
        #expect(m.state == .open)
    }

    @Test func hoveringHoldsThePeek() {
        let m = machine()
        _ = m.handle(.peek(duration: 1), now: at(0))
        _ = m.handle(.pointerEntered, now: at(0.5))
        #expect(m.tick(now: at(0.6)).isEmpty)
        #expect(m.state == .peek)
    }

    @Test func hoveringOverAPeekOpensIt() {
        let m = machine()
        _ = m.handle(.peek(duration: 3), now: at(0))
        _ = m.handle(.pointerEntered, now: at(0.5))
        #expect(m.tick(now: at(0.8)).first == IslTransition(from: .peek, to: .open, trigger: .hover))
    }

    @Test func leavingAPeekEndsItSoon() {
        let m = machine()
        _ = m.handle(.peek(duration: 3), now: at(0))
        _ = m.handle(.pointerEntered, now: at(0.5))
        _ = m.handle(.pointerLeft, now: at(1))
        #expect(m.nextDeadline == at(1.4))
        #expect(m.tick(now: at(1.5)).first?.to == .closed)
    }

    @Test func clickOnAPeekOpens() {
        let m = machine()
        _ = m.handle(.peek(duration: 3), now: at(0))
        #expect(m.handle(.clicked, now: at(1)).first == IslTransition(from: .peek, to: .open, trigger: .click))
    }

    @Test func outsideClickEndsAPeek() {
        let m = machine()
        _ = m.handle(.peek(duration: 3), now: at(0))
        #expect(m.handle(.outsideClick, now: at(1)).first?.to == .closed)
    }
}

@Suite struct IslSuppressionTests {
    @Test func fullscreenForcesClosedAndBlocksAutoOpen() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        let t = m.handle(.suppressed([.fullscreen]), now: at(1))
        #expect(t == [IslTransition(from: .open, to: .closed, trigger: .suppression)])
        #expect(m.handle(.scrollOpen, now: at(2)).isEmpty)
        _ = m.handle(.pointerEntered, now: at(3))
        #expect(m.nextDeadline == nil)
        #expect(m.handle(.peek(duration: nil), now: at(4)).isEmpty)
        #expect(m.handle(.dragEntered, now: at(5)).isEmpty)
    }

    @Test func hotkeyBypassesFullscreenAndMenuSuppression() {
        for s in [IslSuppression.fullscreen, .menuOpen] {
            let m = machine()
            _ = m.handle(.suppressed([s]), now: at(0))
            #expect(m.handle(.hotkey, now: at(1)).first?.to == .open, "\(s)")
        }
    }

    @Test func lockedAndDisabledBlockEverything() {
        for s in [IslSuppression.locked, .disabled] {
            let m = machine()
            _ = m.handle(.suppressed([s]), now: at(0))
            #expect(m.handle(.hotkey, now: at(1)).isEmpty, "\(s)")
            #expect(m.handle(.clicked, now: at(1)).isEmpty, "\(s)")
        }
    }

    @Test func menuOpenStopsHoverButNotClick() {
        let m = machine()
        _ = m.handle(.suppressed([.menuOpen]), now: at(0))
        _ = m.handle(.pointerEntered, now: at(0))
        #expect(m.nextDeadline == nil)
        #expect(m.handle(.clicked, now: at(1)).first?.to == .open)
    }

    @Test func fullscreenBlocksClicks() {
        let m = machine()
        _ = m.handle(.suppressed([.fullscreen]), now: at(0))
        #expect(m.handle(.clicked, now: at(1)).isEmpty)
    }

    @Test func clearingSuppressionAllowsOpeningAgain() {
        let m = machine()
        _ = m.handle(.suppressed([.fullscreen]), now: at(0))
        _ = m.handle(.suppressed([]), now: at(1))
        #expect(!m.isSuppressed)
        #expect(m.handle(.scrollOpen, now: at(2)).first?.to == .open)
    }

    @Test func suppressionDuringAPendingHoverCancelsIt() {
        let m = machine()
        _ = m.handle(.pointerEntered, now: at(0))
        _ = m.handle(.suppressed([.menuOpen]), now: at(0.1))
        #expect(m.tick(now: at(1)).isEmpty)
    }

    @Test func suppressionClearsThePin() {
        let m = machine()
        _ = m.handle(.hotkey, now: at(0))
        _ = m.handle(.setPinned(true), now: at(1))
        _ = m.handle(.suppressed([.fullscreen]), now: at(2))
        #expect(!m.pinned && m.state == .closed)
    }
}

@Suite struct IslPointerTrackerTests {
    private let f = IslLayoutMath.frames(screen: IslFix.notchScreen, notch: IslNotchDetector.notch(for: IslFix.notchScreen), preset: .standard)

    @Test func producesEnterAndLeaveOnce() {
        var t = IslPointerTracker()
        let inside = CGPoint(x: f.notch.midX, y: f.notch.midY)
        let outside = CGPoint(x: 100, y: 100)
        #expect(t.update(outside, state: .closed, frames: f) == nil)
        #expect(t.update(inside, state: .closed, frames: f) == .pointerEntered)
        #expect(t.update(inside, state: .closed, frames: f) == nil)
        #expect(t.update(outside, state: .closed, frames: f) == .pointerLeft)
        #expect(t.update(outside, state: .closed, frames: f) == nil)
    }

    @Test func movingFromTheNotchIntoTheOpenAreaStaysInside() {
        var t = IslPointerTracker()
        _ = t.update(CGPoint(x: f.notch.midX, y: f.notch.midY), state: .closed, frames: f)
        let deep = CGPoint(x: f.open.midX, y: f.open.minY + 20)
        #expect(t.update(deep, state: .open, frames: f) == nil)
        #expect(t.inside)
    }

    @Test func syncSetsTheFlagWithoutAnEvent() {
        var t = IslPointerTracker()
        t.sync(CGPoint(x: f.notch.midX, y: f.notch.midY), state: .closed, frames: f)
        #expect(t.inside)
        #expect(t.update(CGPoint(x: f.notch.midX, y: f.notch.midY), state: .closed, frames: f) == nil)
        t.reset()
        #expect(!t.inside)
    }
}

@Suite struct IslMachineConfigTests {
    @Test func configIsBuiltFromSettings() {
        var s = IslSettings()
        s.hoverDelay = 0.5
        s.closeBehavior = .manual
        s.openOnScroll = false
        s.peekDuration = 6
        let c = IslMachineConfig(s)
        #expect(c.hoverDelay == 0.5 && c.closeBehavior == .manual && !c.openOnScroll && c.peekDuration == 6)
    }

    @Test func transitionsAreOnlyReportedOnRealChanges() {
        let m = machine()
        #expect(m.handle(.forceClose, now: at(0)).isEmpty)
        #expect(m.handle(.escape, now: at(0)).isEmpty)
        #expect(m.handle(.outsideClick, now: at(0)).isEmpty)
    }
}
