import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShakeDetectorTests {
    @Test func firesOnFourFastLegs() {
        var d = ShakeDetector(sensitivity: .medium)
        let r = Shf.zigzag(&d, legs: 4, amp: 120)
        #expect(r.fired)
    }

    @Test func threeLegsAreNotEnoughForMedium() {
        var d = ShakeDetector(sensitivity: .medium)
        #expect(!Shf.zigzag(&d, legs: 3, amp: 120).fired)
    }

    @Test func straightLineNeverFires() {
        var d = ShakeDetector(sensitivity: .high)
        var fired = false
        for i in 0..<400 { if d.feed(x: Double(i) * 8, y: 100, at: Double(i) * 0.01) { fired = true } }
        #expect(!fired)
    }

    @Test func smallLegsDoNotFire() {
        var d = ShakeDetector(sensitivity: .medium)
        #expect(!Shf.zigzag(&d, legs: 10, amp: 40).fired)
    }

    @Test func slowWigglingDoesNotFire() {
        var d = ShakeDetector(sensitivity: .medium)
        #expect(!Shf.zigzag(&d, legs: 8, amp: 120, dt: 0.1).fired)
    }

    @Test func verticalShakeFires() {
        var d = ShakeDetector(sensitivity: .medium)
        #expect(Shf.zigzag(&d, legs: 4, amp: 120, vertical: true).fired)
    }

    @Test func jitterBelowThresholdIsIgnored() {
        var d = ShakeDetector(sensitivity: .high)
        var fired = false
        for i in 0..<300 { if d.feed(x: 500 + (i % 2 == 0 ? 2 : -2), y: 300, at: Double(i) * 0.01) { fired = true } }
        #expect(!fired)
    }

    @Test func sensitivityOrdersTheThresholds() {
        let amp = 85.0
        var low = ShakeDetector(sensitivity: .low), med = ShakeDetector(sensitivity: .medium), high = ShakeDetector(sensitivity: .high)
        #expect(!Shf.zigzag(&low, legs: 6, amp: amp, step: 5).fired)
        #expect(!Shf.zigzag(&med, legs: 6, amp: amp, step: 5).fired)
        #expect(Shf.zigzag(&high, legs: 6, amp: amp, step: 5).fired)
    }

    @Test func lowNeedsFiveLegsOfLongMovement() {
        var d = ShakeDetector(sensitivity: .low)
        #expect(!Shf.zigzag(&d, legs: 4, amp: 160).fired)
        var e = ShakeDetector(sensitivity: .low)
        #expect(Shf.zigzag(&e, legs: 6, amp: 160).fired)
    }

    @Test func cooldownSuppressesImmediateRepeat() {
        var d = ShakeDetector(sensitivity: .medium)
        let first = Shf.zigzag(&d, legs: 4, amp: 120)
        #expect(first.fired)
        let second = Shf.zigzag(&d, legs: 6, amp: 120, t0: first.end + 0.02)
        #expect(!second.fired)
    }

    @Test func firesAgainAfterCooldown() {
        var d = ShakeDetector(sensitivity: .medium)
        let first = Shf.zigzag(&d, legs: 4, amp: 120)
        #expect(first.fired)
        let later = Shf.zigzag(&d, legs: 4, amp: 120, t0: first.end + 3)
        #expect(later.fired)
    }

    @Test func pauseBreaksTheGesture() {
        var d = ShakeDetector(sensitivity: .medium)
        let a = Shf.zigzag(&d, legs: 2, amp: 120)
        #expect(!a.fired)
        let b = Shf.zigzag(&d, legs: 2, amp: 120, t0: a.end + 0.6)
        #expect(!b.fired)
    }

    @Test func timeGoingBackwardsResets() {
        var d = ShakeDetector(sensitivity: .medium)
        _ = Shf.zigzag(&d, legs: 3, amp: 120, t0: 10)
        let r = Shf.zigzag(&d, legs: 2, amp: 120, t0: 1)
        #expect(!r.fired)
    }

    @Test func resetDropsProgress() {
        var d = ShakeDetector(sensitivity: .medium)
        _ = Shf.zigzag(&d, legs: 3, amp: 120)
        d.reset()
        #expect(!Shf.zigzag(&d, legs: 2, amp: 120, t0: 0.5).fired)
    }

    @Test func shortWiggleInTheMiddleResetsTheCount() {
        var d = ShakeDetector(sensitivity: .medium)
        let a = Shf.zigzag(&d, legs: 2, amp: 120)
        #expect(!a.fired)
        let w1 = d.feed(x: 530, y: 300, at: a.end + 0.01)
        let w2 = d.feed(x: 500, y: 300, at: a.end + 0.02)
        #expect(!w1 && !w2)
        #expect(!Shf.zigzag(&d, legs: 2, amp: 120, t0: a.end + 0.03).fired)
    }

    @Test func sameSequenceWithoutTheWiggleWouldFire() {
        var d = ShakeDetector(sensitivity: .medium)
        let a = Shf.zigzag(&d, legs: 2, amp: 120)
        #expect(Shf.zigzag(&d, legs: 2, amp: 120, t0: a.end + 0.01).fired)
    }

    @Test func smallBackstepsInsideALegAreNotReversals() {
        var d = ShakeDetector(sensitivity: .medium)
        var x = 500.0
        var t = 0.0
        var fired = false
        _ = d.feed(x: x, y: 300, at: t)
        for i in 0..<60 {
            x += i % 3 == 2 ? -8 : 14
            t += 0.01
            if d.feed(x: x, y: 300, at: t) { fired = true }
        }
        #expect(!fired)
    }

    @Test func presetsGetStricterWithLowerSensitivity() {
        let l = ShakeConfig.preset(.low), m = ShakeConfig.preset(.medium), h = ShakeConfig.preset(.high)
        #expect(l.minLeg > m.minLeg && m.minLeg > h.minLeg)
        #expect(l.reversals > m.reversals && m.reversals > h.reversals)
    }
}
