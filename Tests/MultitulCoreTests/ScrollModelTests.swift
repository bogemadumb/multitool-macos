import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ScrollClassifierTests {
    private func sample(continuous: Bool, phase: Int64 = 0, momentum: Int64 = 0, count: Int64 = 0) -> ScrollSample {
        ScrollSample(vertical: ScrollAxisDelta(line: 1, point: 10, fixed: 1), isContinuous: continuous, scrollPhase: phase, momentumPhase: momentum, scrollCount: count)
    }

    @Test func discreteIsAlwaysAWheel() {
        var c = WheelClassifier()
        let r1 = c.isMouseWheel(sample(continuous: false), now: 1)
        #expect(r1)
    }

    @Test func phasedContinuousIsTouch() {
        var c = WheelClassifier()
        let r2 = c.isMouseWheel(sample(continuous: true, phase: 2), now: 1)
        #expect(!r2)
        let r3 = c.isMouseWheel(sample(continuous: true, momentum: 1), now: 2)
        #expect(!r3)
    }

    @Test func phaselessContinuousIsAWheel() {
        var c = WheelClassifier()
        let r4 = c.isMouseWheel(sample(continuous: true), now: 1)
        #expect(r4)
    }

    @Test func phaselessTransitionRightAfterGestureIsTouch() {
        var c = WheelClassifier()
        _ = c.isMouseWheel(sample(continuous: true, phase: 4), now: 10)
        let r5 = c.isMouseWheel(sample(continuous: true, count: 3), now: 10.2)
        #expect(!r5)
    }

    @Test func graceWindowExpires() {
        var c = WheelClassifier()
        _ = c.isMouseWheel(sample(continuous: true, phase: 4), now: 10)
        let r6 = c.isMouseWheel(sample(continuous: true, count: 3), now: 10 + WheelClassifier.touchGraceSeconds + 0.1)
        #expect(r6)
    }

    @Test func phaselessWithoutScrollCountIsAWheelEvenInsideGrace() {
        var c = WheelClassifier()
        _ = c.isMouseWheel(sample(continuous: true, phase: 4), now: 10)
        let r7 = c.isMouseWheel(sample(continuous: true, count: 0), now: 10.1)
        #expect(r7)
    }

    @Test func resetForgetsTheGesture() {
        var c = WheelClassifier()
        _ = c.isMouseWheel(sample(continuous: true, phase: 4), now: 10)
        c.reset()
        let r8 = c.isMouseWheel(sample(continuous: true, count: 3), now: 10.1)
        #expect(r8)
    }

    @Test func realEventsRoundTripThroughBridge() {
        let wheel = CGScrollBridge.read(InpEvents.wheel(line: 2))
        #expect(!wheel.isContinuous && wheel.vertical.line == 2 && wheel.horizontal.line == 0)
        let touch = CGScrollBridge.read(InpEvents.pixelWheel(v: 12, phase: 2))
        #expect(touch.isContinuous && touch.scrollPhase == 2 && touch.vertical.point == 12)
        var c = WheelClassifier()
        let r9 = c.isMouseWheel(wheel, now: 1)
        #expect(r9)
        let r10 = c.isMouseWheel(touch, now: 1)
        #expect(!r10)
    }
}

@Suite struct ScrollDirectionTests {
    private func wheel(v: Int64 = 0, h: Int64 = 0, continuous: Bool = false, flags: CGEventFlags = []) -> ScrollSample {
        ScrollSample(vertical: ScrollAxisDelta(line: v, point: v * 10, fixed: Double(v)), horizontal: ScrollAxisDelta(line: h, point: h * 10, fixed: Double(h)), isContinuous: continuous, flags: flags)
    }

    @Test func redirectMovesVerticalToHorizontalAndDropsTheKey() throws {
        let out = try #require(ScrollMath.redirectToHorizontal(wheel(v: 3, flags: .maskShift), modifier: .shift))
        #expect(out.vertical == ScrollAxisDelta() && out.horizontal.line == 3 && out.horizontal.point == 30 && out.horizontal.fixed == 3)
        #expect(!out.flags.contains(.maskShift))
    }

    @Test func redirectKeepsSignAndOtherFlags() throws {
        let out = try #require(ScrollMath.redirectToHorizontal(wheel(v: -2, flags: [.maskAlternate, .maskNonCoalesced]), modifier: .option))
        #expect(out.horizontal.line == -2)
        #expect(out.flags.contains(.maskNonCoalesced) && !out.flags.contains(.maskAlternate))
    }

    @Test func redirectNeedsExactlyTheChosenModifier() {
        #expect(ScrollMath.redirectToHorizontal(wheel(v: 1), modifier: .shift) == nil)
        #expect(ScrollMath.redirectToHorizontal(wheel(v: 1, flags: [.maskShift, .maskCommand]), modifier: .shift) == nil)
        #expect(ScrollMath.redirectToHorizontal(wheel(v: 1, flags: .maskCommand), modifier: .shift) == nil)
    }

    @Test func redirectLeavesTwoAxisAndHorizontalWheelsAlone() {
        #expect(ScrollMath.redirectToHorizontal(wheel(v: 1, h: 1, flags: .maskShift), modifier: .shift) == nil)
        #expect(ScrollMath.redirectToHorizontal(wheel(h: 2, flags: .maskShift), modifier: .shift) == nil)
    }

    @Test func everyModifierKeyHasItsOwnFlag() {
        for m in ScrollModifierKey.allCases {
            #expect(ScrollMath.redirectToHorizontal(wheel(v: 1, flags: m.flag), modifier: m) != nil)
        }
        #expect(Set(ScrollModifierKey.allCases.map { $0.flag.rawValue }).count == 4)
    }

    @Test func inverterNegatesAllThreeFieldsPerAxis() {
        let out = ScrollMath.inverted(wheel(v: 2, h: -1, continuous: true), invertVertical: true, invertHorizontal: false)
        #expect(out.vertical == ScrollAxisDelta(line: -2, point: -20, fixed: -2))
        #expect(out.horizontal == ScrollAxisDelta(line: -1, point: -10, fixed: -1))
    }

    @Test func inverterAxesAreIndependent() {
        let s = wheel(v: 2, h: 3)
        let onlyH = ScrollMath.inverted(s, invertVertical: false, invertHorizontal: true)
        #expect(onlyH.vertical.line == 2 && onlyH.horizontal.line == -3)
        let onlyV = ScrollMath.inverted(s, invertVertical: true, invertHorizontal: false)
        #expect(onlyV.vertical.line == -2 && onlyV.horizontal.line == 3)
        #expect(ScrollMath.inverted(s, invertVertical: false, invertHorizontal: false) == s)
    }

    @Test func inverterDoesNotInventMovementOnIdleAxis() {
        let out = ScrollMath.inverted(wheel(v: 1), invertVertical: true, invertHorizontal: true)
        #expect(out.horizontal == ScrollAxisDelta())
    }

    @Test func nativeShiftRedirectUsesTheHorizontalSetting() {
        let s = wheel(v: 1, flags: .maskShift)
        let plan = ScrollMath.inversionPlan(s, invertVertical: true, invertHorizontal: false)
        #expect(!plan.vertical)
        #expect(ScrollMath.inversionPlan(s, invertVertical: false, invertHorizontal: true).vertical)
    }

    @Test func shiftDoesNotRedirectContinuousEvents() {
        let s = wheel(v: 1, continuous: true, flags: .maskShift)
        #expect(ScrollMath.inversionPlan(s, invertVertical: true, invertHorizontal: false).vertical)
    }

    @Test func invertingTwiceIsIdentity() {
        let s = wheel(v: 4, h: -2, continuous: true)
        let once = ScrollMath.inverted(s, invertVertical: true, invertHorizontal: true)
        #expect(ScrollMath.inverted(once, invertVertical: true, invertHorizontal: true) == s)
    }

    @Test func bridgeWritesInvertedValuesBackIntoRealEvent() {
        let e = InpEvents.wheel(line: 3, lineH: 1)
        let s = CGScrollBridge.read(e)
        CGScrollBridge.write(ScrollMath.inverted(s, invertVertical: true, invertHorizontal: true), to: e)
        let back = CGScrollBridge.read(e)
        #expect(back.vertical.line == -3 && back.horizontal.line == -1)
        #expect(back.vertical.fixed < 0 && back.vertical.point < 0)
    }
}

@Suite struct LinearScrollTests {
    private func wheel(v: Int64, fixed: Double? = nil, continuous: Bool = false) -> ScrollSample {
        ScrollSample(vertical: ScrollAxisDelta(line: v, point: continuous ? v * 10 : 0, fixed: fixed ?? Double(v)), isContinuous: continuous)
    }

    @Test func oneNotchIsAlwaysLinesPerNotch() {
        var l = LinearScroll(linesPerNotch: 3)
        let r11 = l.apply(wheel(v: 1))
        #expect(r11.vertical.line == 3)
        let r12 = l.apply(wheel(v: -1))
        #expect(r12.vertical.line == -3)
    }

    @Test func fastSpinIsCappedToOneNotch() {
        var l = LinearScroll(linesPerNotch: 4)
        let r13 = l.apply(wheel(v: 9))
        #expect(r13.vertical.line == 4)
        let r14 = l.apply(wheel(v: -27))
        #expect(r14.vertical.line == -4)
    }

    @Test func configuredLinesAreClamped() {
        #expect(LinearScroll(linesPerNotch: 99).linesPerNotch == 10)
        #expect(LinearScroll(linesPerNotch: 0).linesPerNotch == 1)
        #expect(LinearScrollSettings().sanitized.linesPerNotch == 3)
    }

    @Test func conversionHelperIsSignedAndCapped() {
        #expect(LinearScroll.lines(forTicks: 5, linesPerNotch: 3) == 3)
        #expect(LinearScroll.lines(forTicks: -0.5, linesPerNotch: 4) == -2)
        #expect(LinearScroll.lines(forTicks: 0, linesPerNotch: 4) == 0)
        #expect(LinearScroll.lines(forTicks: .nan, linesPerNotch: 4) == 0)
    }

    @Test func highResolutionFractionsAccumulateIntoWholeLines() {
        var l = LinearScroll(linesPerNotch: 3)
        var total = 0
        for _ in 0..<10 { total += Int(l.apply(wheel(v: 0, fixed: 0.1)).vertical.line) }
        #expect(total == 3)
    }

    @Test func reversalDropsTheCarry() {
        var l = LinearScroll(linesPerNotch: 3)
        _ = l.apply(wheel(v: 0, fixed: 0.5))
        #expect(l.carryVertical == 1.5 - 1)
        let out = l.apply(wheel(v: 0, fixed: -0.5))
        #expect(out.vertical.line == -1)
        #expect(abs(l.carryVertical + 0.5) < 1e-9)
    }

    @Test func axesKeepSeparateCarry() {
        var l = LinearScroll(linesPerNotch: 3)
        var s = ScrollSample(vertical: ScrollAxisDelta(fixed: 0.5), horizontal: ScrollAxisDelta(fixed: -0.5))
        s = l.apply(s)
        #expect(l.carryVertical == 0.5 && l.carryHorizontal == -0.5)
        #expect(s.vertical.line == 1 && s.horizontal.line == -1)
    }

    @Test func continuousEventsKeepPointsConsistentWithLines() {
        var l = LinearScroll(linesPerNotch: 3)
        let out = l.apply(wheel(v: 2, continuous: true))
        #expect(out.vertical.line == 3 && out.vertical.point == 30 && out.vertical.fixed == 3)
    }

    @Test func idleAxisIsUntouched() {
        var l = LinearScroll()
        let out = l.apply(wheel(v: 1))
        #expect(out.horizontal == ScrollAxisDelta())
    }

    @Test func discreteTicksPreferLineThenFixedThenPoint() {
        #expect(ScrollMath.discreteTicks(ScrollAxisDelta(line: 5, point: 1, fixed: 1)) == 1)
        #expect(ScrollMath.discreteTicks(ScrollAxisDelta(line: -2)) == -1)
        #expect(ScrollMath.discreteTicks(ScrollAxisDelta(line: 0, point: 0, fixed: 0.25)) == 0.25)
        #expect(ScrollMath.discreteTicks(ScrollAxisDelta(line: 0, point: 5, fixed: 0)) == 0.5)
    }

    @Test func continuousTicksPreferPoints() {
        #expect(ScrollMath.continuousTicks(ScrollAxisDelta(line: 0, point: 20, fixed: 9)) == 2)
        #expect(ScrollMath.continuousTicks(ScrollAxisDelta(line: 0, point: 0, fixed: 0.3)) == 0.3)
    }

    @Test func bridgeCarriesLinearResultIntoRealEvent() {
        let e = InpEvents.wheel(line: 7)
        var l = LinearScroll(linesPerNotch: 3)
        CGScrollBridge.write(l.apply(CGScrollBridge.read(e)), to: e)
        #expect(CGScrollBridge.read(e).vertical.line == 3)
    }
}
