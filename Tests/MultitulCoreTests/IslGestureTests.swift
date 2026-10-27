import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func ctx(_ state: IslState = .closed, zone: IslGestureZone = .notch, music: Bool = false, current: Bool = false, swipe: IslSwipeAction = .track,
                 open: Bool = true, close: Bool = true) -> IslGestureContext {
    IslGestureContext(state: state, zone: zone, musicActive: music, musicIsCurrent: current, swipe: swipe, openOnScroll: open, closeOnScrollUp: close)
}

private struct Pad {
    var c = IslGestureClassifier()
    var t = 0.0

    mutating func swipe(dx: Double = 0, dy: Double = 0, steps: Int = 6, context: IslGestureContext, natural: Bool = true, end: Bool = true) -> [IslGestureOutput] {
        var out: [IslGestureOutput] = []
        for i in 0..<steps {
            let phase: IslScrollPhase = i == 0 ? .began : .changed
            t += 0.01
            out.append(c.feed(IslScrollSample(dx: dx / Double(steps), dy: dy / Double(steps), precise: true, phase: phase, time: t, invertedFromDevice: natural), context: context))
        }
        if end {
            t += 0.01
            out.append(c.feed(IslScrollSample(dx: 0, dy: 0, precise: true, phase: .ended, time: t, invertedFromDevice: natural), context: context))
        }
        return out
    }
}

private func intents(_ o: [IslGestureOutput]) -> [IslGestureIntent] { o.compactMap(\.intent) }

@Suite struct IslFingerSpaceTests {
    @Test func naturalDevicesKeepTheSign() {
        let s = IslScrollSample(dx: 3, dy: -4, time: 0, invertedFromDevice: true)
        #expect(s.finger == CGVector(dx: 3, dy: -4))
    }

    @Test func classicDevicesFlipTheSign() {
        let s = IslScrollSample(dx: 3, dy: -4, time: 0, invertedFromDevice: false)
        #expect(s.finger == CGVector(dx: -3, dy: 4))
    }

    @Test func wheelTicksAreScaledToPoints() {
        let s = IslScrollSample(dx: 0, dy: 1, precise: false, time: 0, invertedFromDevice: true)
        #expect(s.finger.dy == CGFloat(IslGestureConfig.wheelScale))
    }
}

@Suite struct IslVerticalGestureTests {
    @Test func pullingDownOnTheClosedIslandOpensIt() {
        var p = Pad()
        let o = p.swipe(dy: 80, context: ctx())
        #expect(intents(o) == [.open])
    }

    @Test func pullingDownOnAPeekOpensIt() {
        var p = Pad()
        #expect(intents(p.swipe(dy: 80, context: ctx(.peek))) == [.open])
    }

    @Test func openOnScrollCanBeDisabled() {
        var p = Pad()
        #expect(intents(p.swipe(dy: 80, context: ctx(open: false))).isEmpty)
    }

    @Test func pullingDownOnAnOpenIslandIsLeftToTheList() {
        var p = Pad()
        let o = p.swipe(dy: 120, context: ctx(.open, zone: .body))
        #expect(intents(o).isEmpty)
        #expect(o.allSatisfy { !$0.consumed || $0.intent != nil })
    }

    @Test func pushingUpOnTheTopRowCloses() {
        var p = Pad()
        #expect(intents(p.swipe(dy: -80, context: ctx(.open, zone: .topRow))) == [.close])
    }

    @Test func pushingUpOverTheBodyScrollsTheList() {
        var p = Pad()
        let o = p.swipe(dy: -200, context: ctx(.open, zone: .body))
        #expect(intents(o).isEmpty && o.allSatisfy { !$0.consumed })
    }

    @Test func closeOnScrollUpCanBeDisabled() {
        var p = Pad()
        #expect(intents(p.swipe(dy: -80, context: ctx(.open, zone: .topRow, close: false))).isEmpty)
    }

    @Test func pushingUpOnTheClosedIslandDoesNothing() {
        var p = Pad()
        #expect(intents(p.swipe(dy: -80, context: ctx())).isEmpty)
    }

    @Test func shortPullsBelowTheThresholdDoNothing() {
        var p = Pad()
        #expect(intents(p.swipe(dy: 20, context: ctx())).isEmpty)
    }

    @Test func oneGestureFiresOnlyOnce() {
        var p = Pad()
        #expect(intents(p.swipe(dy: 400, steps: 20, context: ctx())).count == 1)
    }

    @Test func aSecondGestureFiresAgain() {
        var p = Pad()
        _ = p.swipe(dy: 80, context: ctx())
        p.t += 1
        #expect(intents(p.swipe(dy: 80, context: ctx())) == [.open])
    }

    @Test func momentumAfterTheGestureDoesNotRefire() {
        var p = Pad()
        _ = p.swipe(dy: 80, context: ctx(), end: false)
        var fired = 0
        for i in 0..<10 {
            p.t += 0.01
            if p.c.feed(IslScrollSample(dx: 0, dy: 30, precise: true, phase: .momentum, time: p.t + Double(i) * 0.001), context: ctx()).intent != nil { fired += 1 }
        }
        #expect(fired == 0)
    }

    @Test func classicWheelRolledTowardTheUserOpens() {
        var c = IslGestureClassifier()
        var t = 0.0
        var got: IslGestureIntent?
        for _ in 0..<4 {
            t += 0.02
            if let i = c.feed(IslScrollSample(dx: 0, dy: -1, precise: false, phase: .none, time: t, invertedFromDevice: false), context: ctx()).intent { got = i }
        }
        #expect(got == .open)
    }

    @Test func naturalTrackpadSwipeDownIsPositiveY() {
        var p = Pad()
        #expect(intents(p.swipe(dy: 80, context: ctx(), natural: true)) == [.open])
        p.t += 1
        #expect(intents(p.swipe(dy: -80, context: ctx(), natural: true)).isEmpty)
    }

    @Test func classicPadFlipsTheDirection() {
        var p = Pad()
        #expect(intents(p.swipe(dy: -80, context: ctx(), natural: false)) == [.open])
    }
}

@Suite struct IslHorizontalGestureTests {
    @Test func swipeLeftOverActiveMusicOnTheClosedIslandSkipsForward() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -120, context: ctx(music: true))) == [.nextTrack])
    }

    @Test func swipeRightGoesBack() {
        var p = Pad()
        #expect(intents(p.swipe(dx: 120, context: ctx(music: true))) == [.previousTrack])
    }

    @Test func withoutMusicTheClosedIslandIgnoresHorizontalSwipes() {
        var p = Pad()
        let o = p.swipe(dx: -200, context: ctx(music: false))
        #expect(intents(o).isEmpty && o.allSatisfy { !$0.consumed })
    }

    @Test func sectionSwipeSettingKeepsTheClosedIslandQuiet() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -200, context: ctx(music: true, swipe: .section))).isEmpty)
    }

    @Test func openIslandOnTheMusicSectionSwitchesTracks() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -120, context: ctx(.open, zone: .body, music: true, current: true))) == [.nextTrack])
    }

    @Test func openIslandOnOtherSectionsSwitchesSections() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -120, context: ctx(.open, zone: .body))) == [.nextSection])
        p.t += 1
        #expect(intents(p.swipe(dx: 120, context: ctx(.open, zone: .body))) == [.previousSection])
    }

    @Test func sectionModeOnMusicAlsoSwitchesSections() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -120, context: ctx(.open, zone: .body, music: true, current: true, swipe: .section))) == [.nextSection])
    }

    @Test func shortHorizontalMovesDoNothing() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -30, context: ctx(.open, zone: .body))).isEmpty)
    }

    @Test func horizontalGesturesAreConsumedOnceTheAxisIsLocked() {
        var p = Pad()
        let o = p.swipe(dx: -120, context: ctx(music: true))
        #expect(o.last?.consumed == true)
        #expect(o.dropFirst().contains { $0.consumed })
    }

    @Test func horizontalSwipeFiresOncePerGesture() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -600, steps: 30, context: ctx(.open, zone: .body))).count == 1)
    }

    @Test func diagonalMovementIsNotLocked() {
        var p = Pad()
        let o = p.swipe(dx: -100, dy: 95, context: ctx(.open, zone: .body))
        #expect(intents(o).isEmpty)
    }

    @Test func mostlyVerticalMovementDoesNotChangeSections() {
        var p = Pad()
        #expect(intents(p.swipe(dx: -30, dy: 200, context: ctx(.open, zone: .body))).isEmpty)
    }

    @Test func idleGapStartsANewGesture() {
        var c = IslGestureClassifier()
        var t = 0.0
        func feed(_ dy: Double) -> IslGestureIntent? {
            t += 0.02
            return c.feed(IslScrollSample(dx: 0, dy: dy, precise: false, phase: .none, time: t, invertedFromDevice: true), context: ctx()).intent
        }
        #expect(feed(1) == nil)
        t += 1
        #expect(feed(1) == nil)
        t += 1
        #expect(feed(1) == nil)
    }

    @Test func wheelTicksAccumulateWithinAGesture() {
        var c = IslGestureClassifier()
        var t = 0.0
        var got: [IslGestureIntent] = []
        for _ in 0..<5 {
            t += 0.03
            if let i = c.feed(IslScrollSample(dx: 0, dy: 1, precise: false, phase: .none, time: t, invertedFromDevice: true), context: ctx()).intent { got.append(i) }
        }
        #expect(got == [.open])
    }

    @Test func resetForgetsAPartialGesture() {
        var c = IslGestureClassifier()
        _ = c.feed(IslScrollSample(dx: 0, dy: 30, phase: .began, time: 0.01), context: ctx())
        c.reset()
        #expect(c.feed(IslScrollSample(dx: 0, dy: 10, phase: .began, time: 0.02), context: ctx()).intent == nil)
    }
}
