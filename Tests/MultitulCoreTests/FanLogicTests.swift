import Testing
import Foundation
@testable import MultitulCore

private func pts(_ p: [(Double, Double)]) -> [FanCurvePoint] { p.map { FanCurvePoint(temp: $0.0, percent: $0.1) } }

@Suite struct FanCurveTests {
    private let curve = pts([(40, 0), (60, 50), (80, 100)])

    @Test func interpolatesLinearlyBetweenPoints() {
        #expect(FanCurve.percent(at: 50, in: curve) == 25)
        #expect(FanCurve.percent(at: 70, in: curve) == 75)
        #expect(FanCurve.percent(at: 45, in: curve) == 12.5)
    }

    @Test func exactPointsReturnTheirValue() {
        #expect(FanCurve.percent(at: 40, in: curve) == 0)
        #expect(FanCurve.percent(at: 60, in: curve) == 50)
        #expect(FanCurve.percent(at: 80, in: curve) == 100)
    }

    @Test func endsAreClamped() {
        #expect(FanCurve.percent(at: -10, in: curve) == 0)
        #expect(FanCurve.percent(at: 25, in: curve) == 0)
        #expect(FanCurve.percent(at: 95, in: curve) == 100)
        #expect(FanCurve.percent(at: 500, in: curve) == 100)
    }

    @Test func unsortedInputIsNormalized() {
        let shuffled = pts([(80, 100), (40, 0), (60, 50)])
        #expect(FanCurve.normalized(shuffled) == curve)
        #expect(FanCurve.percent(at: 50, in: shuffled) == 25)
    }

    @Test func duplicateTemperaturesKeepTheStrongerCooling() {
        let dup = pts([(40, 0), (60, 20), (60, 80), (80, 100)])
        let n = FanCurve.normalized(dup)
        #expect(n.count == 3 && n[1] == FanCurvePoint(temp: 60, percent: 80))
        #expect(FanCurve.percent(at: 60, in: dup) == 80)
    }

    @Test func singlePointIsAConstant() {
        let one = pts([(60, 40)])
        #expect(FanCurve.percent(at: 10, in: one) == 40)
        #expect(FanCurve.percent(at: 60, in: one) == 40)
        #expect(FanCurve.percent(at: 99, in: one) == 40)
    }

    @Test func emptyCurveHasNoAnswer() {
        #expect(FanCurve.percent(at: 50, in: []) == nil)
        #expect(FanCurve.normalized([]).isEmpty)
    }

    @Test func nonFiniteInputIsDropped() {
        #expect(FanCurve.normalized(pts([(.nan, 50), (50, .infinity), (60, 40)])) == pts([(60, 40)]))
        #expect(FanCurve.percent(at: .nan, in: curve) == nil)
    }

    @Test func valuesAreClampedIntoRange() {
        let n = FanCurve.normalized(pts([(5, -10), (200, 300)]))
        #expect(n == pts([(20, 0), (110, 100)]))
    }

    @Test func stepCurveWithTinyGapStaysMonotonic() {
        let c = pts([(50, 10), (50.5, 90)])
        #expect(FanCurve.percent(at: 50.25, in: c) == 50)
    }

    @Test func tooManyPointsKeepTheHottestOne() {
        let many = (0..<20).map { FanCurvePoint(temp: 30 + Double($0) * 3, percent: Double($0) * 5) }
        let n = FanCurve.normalized(many)
        #expect(n.count == FanCurve.maxPoints && n.last == many.last)
    }

    @Test func defaultCurveIsUsableAndMonotonic() {
        let d = FanCurve.defaultPoints
        #expect(d == FanCurve.normalized(d))
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.percent <= $1.percent })
    }
}

@Suite struct FanHysteresisTests {
    @Test func firstSampleIsTakenAsIs() {
        var h = FanHysteresis()
        #expect(h.filter(55, band: 3) == 55)
    }

    @Test func risesAreFollowedImmediately() {
        var h = FanHysteresis()
        _ = h.filter(50, band: 3)
        #expect(h.filter(50.2, band: 3) == 50.2)
        #expect(h.filter(60, band: 3) == 60)
    }

    @Test func smallFallsAreIgnored() {
        var h = FanHysteresis()
        _ = h.filter(70, band: 3)
        #expect(h.filter(68.5, band: 3) == 70)
        #expect(h.filter(67.1, band: 3) == 70)
    }

    @Test func fallBeyondTheBandIsFollowed() {
        var h = FanHysteresis()
        _ = h.filter(70, band: 3)
        #expect(h.filter(67, band: 3) == 67)
        #expect(h.filter(66, band: 3) == 67)
    }

    @Test func noisyTemperatureAroundAThresholdNeverMakesTheOutputOscillate() {
        var h = FanHysteresis()
        let curve = FanCurve.defaultPoints
        var out: [Double] = []
        for i in 0..<60 {
            let t = 70 + (i % 2 == 0 ? 0.6 : -0.6)
            out.append(FanCurve.percent(at: h.filter(t, band: 3), in: curve)!)
        }
        var reversals = 0
        for i in 2..<out.count where (out[i] - out[i - 1]) * (out[i - 1] - out[i - 2]) < 0 { reversals += 1 }
        #expect(reversals == 0)
        #expect(Set(out.dropFirst(2)).count == 1)
    }

    @Test func slowCoolingStepsDownOnlyByWholeBands() {
        var h = FanHysteresis()
        var seen: [Double] = []
        for i in 0...20 { seen.append(h.filter(80 - Double(i) * 0.5, band: 3)) }
        #expect(Set(seen).count <= 5)
        #expect(seen.last! >= 70 - 0.0001 && seen.first == 80)
    }

    @Test func zeroBandFollowsEverything() {
        var h = FanHysteresis()
        _ = h.filter(70, band: 0)
        #expect(h.filter(69.9, band: 0) == 69.9)
    }

    @Test func resetForgetsTheAnchor() {
        var h = FanHysteresis()
        _ = h.filter(90, band: 5)
        h.reset()
        #expect(h.filter(40, band: 5) == 40)
    }
}

@Suite struct FanRampTests {
    @Test func upwardStepIsLimited() {
        #expect(FanRamp.step(current: 1000, target: 5000, dt: 2, up: 800, down: 200) == 2600)
    }

    @Test func downwardStepIsLimitedSeparately() {
        #expect(FanRamp.step(current: 5000, target: 1000, dt: 2, up: 800, down: 200) == 4600)
    }

    @Test func doesNotOvershoot() {
        #expect(FanRamp.step(current: 1000, target: 1500, dt: 2, up: 800, down: 200) == 1500)
        #expect(FanRamp.step(current: 2000, target: 1900, dt: 2, up: 800, down: 200) == 1900)
    }

    @Test func zeroMeansUnlimited() {
        #expect(FanRamp.step(current: 1000, target: 6000, dt: 2, up: 0, down: 0) == 6000)
        #expect(FanRamp.step(current: 6000, target: 1000, dt: 2, up: 0, down: 0) == 1000)
    }

    @Test func noTimeNoMovement() {
        #expect(FanRamp.step(current: 1000, target: 6000, dt: 0, up: 800, down: 200) == 1000)
        #expect(FanRamp.step(current: 1000, target: 6000, dt: -3, up: 800, down: 200) == 1000)
    }

    @Test func reachesTargetInFiniteSteps() {
        var v = 1200.0
        var steps = 0
        while v != 6000 && steps < 100 { v = FanRamp.step(current: v, target: 6000, dt: 2, up: 800, down: 200); steps += 1 }
        #expect(steps == 3)
    }
}

@Suite struct FanSensorTests {
    private let t = FanThermal(cpu: [50, 60, 70], gpu: [40, 80])

    @Test func cpuGroupAveragesAndMaxes() {
        #expect(FanSensors.aggregate(t, source: .cpu, how: .average) == 60)
        #expect(FanSensors.aggregate(t, source: .cpu, how: .hottest) == 70)
    }

    @Test func gpuGroup() {
        #expect(FanSensors.aggregate(t, source: .gpu, how: .average) == 60)
        #expect(FanSensors.aggregate(t, source: .gpu, how: .hottest) == 80)
    }

    @Test func socJoinsCpuAndGpu() {
        #expect(FanSensors.aggregate(t, source: .soc, how: .average) == 60)
        #expect(FanSensors.aggregate(t, source: .soc, how: .hottest) == 80)
    }

    @Test func implausibleReadingsAreDropped() {
        let bad = FanThermal(cpu: [0, 55, 130, -5, 65], gpu: [])
        #expect(FanSensors.aggregate(bad, source: .cpu, how: .average) == 60)
        #expect(FanSensors.aggregate(bad, source: .cpu, how: .hottest) == 65)
    }

    @Test func emptyGroupMeansSensorLoss() {
        #expect(FanSensors.aggregate(FanThermal(cpu: [], gpu: [50]), source: .cpu, how: .hottest) == nil)
        #expect(FanSensors.aggregate(FanThermal(), source: .soc, how: .average) == nil)
        #expect(FanSensors.aggregate(FanThermal(cpu: [0, 200]), source: .cpu, how: .hottest) == nil)
    }

    @Test func groupMissingInOneSourceDoesNotBlockSoc() {
        #expect(FanSensors.aggregate(FanThermal(cpu: [], gpu: [50]), source: .soc, how: .hottest) == 50)
    }
}

@Suite struct FanPolicyTests {
    private let fan = FanInfo(index: 0, minRpm: 1200, maxRpm: 6000)
    private let stoppable = FanInfo(index: 0, minRpm: 0, maxRpm: 5000)

    @Test func clampKeepsTheRange() {
        #expect(FanPolicy.clamp(3000, fan: fan) == 3000)
        #expect(FanPolicy.clamp(100, fan: fan) == 1200)
        #expect(FanPolicy.clamp(99999, fan: fan) == 6000)
    }

    @Test func zeroOrNegativeBecomesMinimumForAFanThatCannotStop() {
        #expect(FanPolicy.clamp(0, fan: fan) == 1200)
        #expect(FanPolicy.clamp(-50, fan: fan) == 1200)
        #expect(FanPolicy.clamp(.nan, fan: fan) == 1200)
    }

    @Test func zeroIsAllowedOnlyWhenTheFanCanStop() {
        #expect(FanPolicy.clamp(0, fan: stoppable) == 0)
        #expect(stoppable.canStop && !fan.canStop)
    }

    @Test func percentMapsOntoTheFanOwnRange() {
        #expect(FanPolicy.rpm(percent: 0, fan: fan) == 1200)
        #expect(FanPolicy.rpm(percent: 50, fan: fan) == 3600)
        #expect(FanPolicy.rpm(percent: 100, fan: fan) == 6000)
        #expect(FanPolicy.rpm(percent: 250, fan: fan) == 6000)
        #expect(FanPolicy.rpm(percent: 0, fan: stoppable) == 0)
    }

    @Test func boundsValidation() {
        #expect(FanPolicy.validBounds(min: 1200, max: 6000))
        #expect(!FanPolicy.validBounds(min: 6000, max: 1200))
        #expect(!FanPolicy.validBounds(min: -1, max: 6000))
        #expect(!FanPolicy.validBounds(min: 1200, max: 20000))
        #expect(!FanPolicy.validBounds(min: .nan, max: 6000))
    }

    @Test func writeDecision() {
        #expect(FanPolicy.shouldWrite(last: nil, new: 3000, since: nil))
        #expect(!FanPolicy.shouldWrite(last: 3000, new: 3010, since: 2))
        #expect(FanPolicy.shouldWrite(last: 3000, new: 3030, since: 2))
        #expect(FanPolicy.shouldWrite(last: 3000, new: 3000, since: 15))
    }
}
