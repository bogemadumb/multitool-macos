import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixGainTests {
    @Test func zeroDbIsUnity() { #expect(MixGain.dbToLinear(0) == 1) }

    @Test func sixDbDoubles() { #expect(abs(MixGain.dbToLinear(6.0206) - 2) < 1e-4) }

    @Test func minusSixDbHalves() { #expect(abs(MixGain.dbToLinear(-6.0206) - 0.5) < 1e-4) }

    @Test func minusTwentyDbIsTenth() { #expect(abs(MixGain.dbToLinear(-20) - 0.1) < 1e-9) }

    @Test func floorDbIsSilence() {
        #expect(MixGain.dbToLinear(-120) == 0)
        #expect(MixGain.dbToLinear(-300) == 0)
        #expect(MixGain.dbToLinear(-.infinity) == 0)
    }

    @Test func nanDbIsSilence() { #expect(MixGain.dbToLinear(.nan) == 0) }

    @Test func linearToDbKnownValues() {
        #expect(MixGain.linearToDb(1) == 0)
        #expect(abs(MixGain.linearToDb(2) - 6.0206) < 1e-3)
        #expect(abs(MixGain.linearToDb(0.5) + 6.0206) < 1e-3)
        #expect(abs(MixGain.linearToDb(4) - 12.0412) < 1e-3)
    }

    @Test func linearToDbOfSilenceIsFloor() {
        #expect(MixGain.linearToDb(0) == MixGain.floorDb)
        #expect(MixGain.linearToDb(-1) == MixGain.floorDb)
        #expect(MixGain.linearToDb(.nan) == MixGain.floorDb)
        #expect(MixGain.linearToDb(1e-30) == MixGain.floorDb)
    }

    @Test func roundTripOverTheUsefulRange() {
        for db in stride(from: -90.0, through: 24.0, by: 1.5) {
            #expect(abs(MixGain.linearToDb(MixGain.dbToLinear(db)) - db) < 1e-9)
        }
    }

    @Test func clampVolumeBounds() {
        #expect(MixGain.clampVolume(-1) == 0)
        #expect(MixGain.clampVolume(9) == 4)
        #expect(MixGain.clampVolume(2.5) == 2.5)
        #expect(MixGain.clampVolume(3, maxBoost: 2) == 2)
    }

    @Test func clampVolumeRejectsNonFinite() {
        #expect(MixGain.clampVolume(.nan) == 1)
        #expect(MixGain.clampVolume(.infinity) == 1)
    }

    @Test func clampBoostStaysInAllowedRange() {
        #expect(MixGain.clampBoost(0.2) == 1)
        #expect(MixGain.clampBoost(9) == 4)
        #expect(MixGain.clampBoost(.nan) == 4)
        #expect(MixGain.clampBoost(2) == 2)
    }

    @Test func percentConversions() {
        #expect(MixGain.percent(1) == 100)
        #expect(MixGain.percent(0.755) == 76)
        #expect(MixGain.volume(percent: 250) == 2.5)
        #expect(MixGain.volume(percent: 900) == 4)
        #expect(MixGain.volume(percent: -5) == 0)
    }

    @Test func coarseStepMovesByFivePercent() {
        #expect(MixGain.step(1, up: true, fine: false) == 1.05)
        #expect(MixGain.step(1, up: false, fine: false) == 0.95)
    }

    @Test func fineStepMovesByOnePercent() {
        #expect(MixGain.step(1, up: true, fine: true) == 1.01)
        #expect(MixGain.step(1, up: false, fine: true) == 0.99)
    }

    @Test func stepFromOffGridLandsOnGrid() {
        #expect(MixGain.step(0.97, up: true, fine: false) == 1)
        #expect(MixGain.step(0.97, up: false, fine: false) == 0.95)
    }

    @Test func stepStopsAtTheEnds() {
        #expect(MixGain.step(0, up: false, fine: false) == 0)
        #expect(MixGain.step(4, up: true, fine: false) == 4)
        #expect(MixGain.step(2, up: true, fine: true, maxBoost: 2) == 2)
    }

    @Test func walkingUpReachesTheTopExactly() {
        var v = 0.0
        for _ in 0..<80 { v = MixGain.step(v, up: true, fine: false) }
        #expect(v == 4)
        var f = 0.0
        for _ in 0..<100 { f = MixGain.step(f, up: true, fine: true) }
        #expect(f == 1)
    }

    @Test func unityIsMagnetic() {
        #expect(MixGain.snapped(0.98) == 1)
        #expect(MixGain.snapped(1.02) == 1)
        #expect(MixGain.snapped(1.03) == 1.03)
        #expect(MixGain.snapped(0.9) == 0.9)
        #expect(MixGain.snapped(7) == 4)
    }

    @Test func labels() {
        #expect(MixGain.label(1) == "100%")
        #expect(MixGain.label(2.5) == "250%")
        #expect(MixGain.dbLabel(1) == "0 дБ")
        #expect(MixGain.dbLabel(0.5) == "−6.0 дБ")
        #expect(MixGain.dbLabel(2) == "+6.0 дБ")
        #expect(MixGain.dbLabel(0) == "−∞ дБ")
    }

    @Test func allowedBoostsAreOneToFour() { #expect(MixGain.allowedMaxBoosts == [1, 2, 3, 4]) }

    @Test func denormalFlushZeroesTinyValues() {
        #expect(MixDenormal.flush(Float(1e-38)) == 0)
        #expect(MixDenormal.flush(Float(-1e-35)) == 0)
        #expect(MixDenormal.flush(Float(0.25)) == 0.25)
        #expect(MixDenormal.flush(1e-300) == 0)
        #expect(MixDenormal.flush(0.5) == 0.5)
    }
}

@Suite struct MixSmootherTests {
    @Test func holdsWithoutTarget() {
        var s = MixSmoother(value: 0.5)
        for _ in 0..<100 { #expect(s.next() == 0.5) }
        #expect(!s.isRamping)
    }

    @Test func reachesTargetExactlyAfterTheRamp() {
        var s = MixSmoother(value: 0, sampleRate: 48_000, rampSeconds: 0.02)
        s.setTarget(1)
        #expect(s.rampSamples == 960)
        var last: Float = 0
        for _ in 0..<960 { last = s.next() }
        #expect(last == 1)
        #expect(!s.isRamping)
        #expect(s.next() == 1)
    }

    @Test func rampIsMonotonicWithConstantStep() {
        var s = MixSmoother(value: 0, sampleRate: 48_000, rampSeconds: 0.02)
        s.setTarget(1)
        var prev: Float = 0
        var maxStep: Float = 0
        var minStep: Float = 1
        for _ in 0..<960 {
            let v = s.next()
            #expect(v >= prev)
            maxStep = max(maxStep, v - prev)
            minStep = min(minStep, v - prev)
            prev = v
        }
        #expect(abs(maxStep - 1 / 960) < 1e-6)
        #expect(abs(minStep - 1 / 960) < 1e-6)
    }

    @Test func downwardRampIsMonotonic() {
        var s = MixSmoother(value: 1, sampleRate: 48_000, rampSeconds: 0.01)
        s.setTarget(0.25)
        var prev: Float = 1
        for _ in 0..<480 {
            let v = s.next()
            #expect(v <= prev)
            prev = v
        }
        #expect(prev == 0.25)
    }

    @Test func rampDurationIsInSecondsNotSamples() {
        #expect(MixSmoother(sampleRate: 44_100, rampSeconds: 0.02).rampSamples == 882)
        #expect(MixSmoother(sampleRate: 96_000, rampSeconds: 0.02).rampSamples == 1920)
        #expect(MixSmoother(sampleRate: 48_000, rampSeconds: 0.03).rampSamples == 1440)
    }

    @Test func retargetMidRampIsContinuous() {
        var s = MixSmoother(value: 0, sampleRate: 48_000, rampSeconds: 0.02)
        s.setTarget(1)
        var prev: Float = 0
        for _ in 0..<300 { prev = s.next() }
        s.setTarget(0)
        var maxJump: Float = 0
        for _ in 0..<960 {
            let v = s.next()
            maxJump = max(maxJump, abs(v - prev))
            prev = v
        }
        #expect(maxJump <= 1 / 960 + 1e-6)
        #expect(prev == 0)
    }

    @Test func settingTheSameTargetDoesNotRamp() {
        var s = MixSmoother(value: 0.7)
        s.setTarget(0.7)
        #expect(!s.isRamping)
    }

    @Test func nonFiniteTargetIsIgnored() {
        var s = MixSmoother(value: 0.7)
        s.setTarget(.nan)
        s.setTarget(.infinity)
        #expect(s.target == 0.7 && !s.isRamping)
    }

    @Test func jumpHasNoRamp() {
        var s = MixSmoother(value: 1)
        s.setTarget(0)
        s.jump(to: 0.3)
        #expect(s.next() == 0.3 && !s.isRamping)
    }

    @Test func degenerateRampIsOneSample() {
        var s = MixSmoother(value: 0, sampleRate: 48_000, rampSeconds: 0)
        s.setTarget(1)
        #expect(s.next() == 1)
    }

    @Test func configureWhileRampingKeepsTheTarget() {
        var s = MixSmoother(value: 0, sampleRate: 48_000, rampSeconds: 0.02)
        s.setTarget(1)
        _ = s.next()
        s.configure(sampleRate: 96_000, rampSeconds: 0.02)
        #expect(s.target == 1 && s.rampSamples == 1920)
        var v: Float = 0
        for _ in 0..<1920 { v = s.next() }
        #expect(v == 1)
    }

    @Test func rampedGainOnDcHasNoLargeSteps() {
        var s = MixSmoother(value: 1, sampleRate: 48_000, rampSeconds: 0.02)
        var out: [Float] = []
        for i in 0..<4800 {
            if i % 1200 == 0 { s.setTarget(i % 2400 == 0 ? 0.25 : 1) }
            out.append(0.5 * s.next())
        }
        var maxDiff: Float = 0
        for i in 1..<out.count { maxDiff = max(maxDiff, abs(out[i] - out[i - 1])) }
        #expect(maxDiff <= 0.5 * 0.75 / 960 + 1e-6)
    }

    @Test func abruptGainWouldHaveBeenAStep() {
        var maxDiff: Float = 0
        var prev: Float = 0.5
        for i in 0..<2400 {
            let v: Float = i < 1200 ? 0.5 : 0.125
            maxDiff = max(maxDiff, abs(v - prev))
            prev = v
        }
        #expect(maxDiff > 0.3)
    }
}
