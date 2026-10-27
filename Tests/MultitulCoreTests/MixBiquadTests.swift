import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixBiquadTests {
    private let sr = 48_000.0

    private func db(_ c: MixBiquadCoeffs, _ f: Double, sr: Double = 48_000) -> Double { c.magnitudeDb(frequency: f, sampleRate: sr) }

    @Test func identityPassesEverything() {
        var f = MixBiquad(.identity)
        for x in MixSig.noise(frames: 200) { #expect(f.process(x) == x) }
        #expect(abs(db(.identity, 1000)) < 1e-9)
    }

    @Test func lowpassIsThreeDbDownAtCutoff() {
        let c = MixBiquadCoeffs.make(.lowpass, frequency: 1000, q: 0.70710678, sampleRate: sr)
        #expect(abs(db(c, 1000) + 3.0103) < 0.02)
        #expect(abs(db(c, 100)) < 0.05)
        #expect(db(c, 10_000) < -37)
    }

    @Test func highpassMirrorsLowpass() {
        let c = MixBiquadCoeffs.make(.highpass, frequency: 1000, q: 0.70710678, sampleRate: sr)
        #expect(abs(db(c, 1000) + 3.0103) < 0.02)
        #expect(abs(db(c, 10_000)) < 0.05)
        #expect(db(c, 100) < -37)
    }

    @Test func bandpassPeaksAtCenter() {
        let c = MixBiquadCoeffs.make(.bandpass, frequency: 1000, q: 2, sampleRate: sr)
        #expect(abs(db(c, 1000)) < 0.01)
        #expect(db(c, 500) < -3)
        #expect(db(c, 2000) < -3)
        #expect(db(c, 50) < -25)
    }

    @Test func notchRemovesTheCenter() {
        let c = MixBiquadCoeffs.make(.notch, frequency: 1000, q: 4, sampleRate: sr)
        #expect(db(c, 1000) < -60)
        #expect(abs(db(c, 100)) < 0.2)
        #expect(abs(db(c, 10_000)) < 0.2)
    }

    @Test func peakingBoostsAndCutsAtCenter() {
        let up = MixBiquadCoeffs.make(.peaking, frequency: 1000, q: 1, gainDb: 6, sampleRate: sr)
        let down = MixBiquadCoeffs.make(.peaking, frequency: 1000, q: 1, gainDb: -6, sampleRate: sr)
        #expect(abs(db(up, 1000) - 6) < 0.02)
        #expect(abs(db(down, 1000) + 6) < 0.02)
        #expect(abs(db(up, 50)) < 0.3)
        #expect(abs(db(up, 15_000)) < 0.5)
    }

    @Test func peakingWithZeroGainIsFlat() {
        let c = MixBiquadCoeffs.make(.peaking, frequency: 1000, q: 1, gainDb: 0, sampleRate: sr)
        for f in [30.0, 300, 1000, 5000, 18_000] { #expect(abs(db(c, f)) < 1e-6) }
    }

    @Test func lowShelfLiftsTheBottom() {
        let c = MixBiquadCoeffs.make(.lowShelf, frequency: 200, q: 0.7071, gainDb: 6, sampleRate: sr)
        #expect(abs(db(c, 20) - 6) < 0.1)
        #expect(abs(db(c, 8000)) < 0.1)
        #expect(abs(db(c, 200) - 3) < 0.2)
    }

    @Test func highShelfLiftsTheTop() {
        let c = MixBiquadCoeffs.make(.highShelf, frequency: 4000, q: 0.7071, gainDb: -6, sampleRate: sr)
        #expect(abs(db(c, 20_000) + 6) < 0.3)
        #expect(abs(db(c, 100)) < 0.1)
        #expect(abs(db(c, 4000) + 3) < 0.2)
    }

    @Test func measuredSineMatchesTheAnalyticResponse() {
        let cases: [(MixBiquadKind, Double, Double, Double)] = [(.lowpass, 2000, 0, 3000), (.highpass, 500, 0, 300), (.bandpass, 1000, 0, 1300), (.peaking, 1000, 9, 1000), (.lowShelf, 300, -6, 100)]
        for (kind, f0, gain, fTest) in cases {
            let c = MixBiquadCoeffs.make(kind, frequency: f0, q: 1.2, gainDb: gain, sampleRate: sr)
            var f = MixBiquad(c)
            let x = MixSig.sine(fTest, amp: 0.5, sr: sr, frames: 24_000)
            let y = x.map { f.process($0) }
            let measured = Double(MixSig.peak(Array(y[12_000...])))
            let expected = 0.5 * c.magnitude(frequency: fTest, sampleRate: sr)
            #expect(abs(measured - expected) < 0.005, "\(kind)")
        }
    }

    @Test func designsAreStableAcrossTheParameterGrid() {
        for kind in MixBiquadKind.allCases {
            for f in [20.0, 100, 1000, 8000, 20_000] {
                for q in [0.1, 0.7, 5, 30] {
                    for g in [-24.0, 0, 24] {
                        let c = MixBiquadCoeffs.make(kind, frequency: f, q: q, gainDb: g, sampleRate: sr)
                        #expect(c.isStable, "\(kind) f=\(f) q=\(q) g=\(g)")
                    }
                }
            }
        }
    }

    @Test func responseIsSampleRateIndependentAtTheCenter() {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let c = MixBiquadCoeffs.make(.peaking, frequency: 1000, q: 1, gainDb: 6, sampleRate: rate)
            #expect(abs(c.magnitudeDb(frequency: 1000, sampleRate: rate) - 6) < 0.02)
            #expect(abs(c.magnitudeDb(frequency: 200, sampleRate: rate) - MixBiquadCoeffs.make(.peaking, frequency: 1000, q: 1, gainDb: 6, sampleRate: 48_000).magnitudeDb(frequency: 200, sampleRate: 48_000)) < 0.3)
        }
    }

    @Test func outOfRangeParametersAreClamped() {
        let high = MixBiquadCoeffs.make(.lowpass, frequency: 90_000, q: 0, sampleRate: sr)
        #expect(high.isStable && high.b0.isFinite)
        let nan = MixBiquadCoeffs.make(.peaking, frequency: .nan, q: .nan, gainDb: .nan, sampleRate: sr)
        #expect(nan.isStable && nan.b0.isFinite)
        let low = MixBiquadCoeffs.make(.highpass, frequency: -5, sampleRate: sr)
        #expect(low.isStable)
        #expect(MixBiquadCoeffs.make(.lowpass, frequency: 100, sampleRate: 0) == .identity)
    }

    @Test func fastDecayEndsInExactZeroState() {
        var f = MixBiquad(.make(.lowpass, frequency: 5000, q: 0.7, sampleRate: sr))
        _ = f.process(1)
        var sawSubnormal = false
        var last: Float = 1
        for _ in 0..<20_000 {
            last = f.process(0)
            if last.isSubnormal { sawSubnormal = true }
        }
        #expect(!sawSubnormal)
        #expect(last == 0)
        #expect(f.state.0 == 0 && f.state.1 == 0)
    }

    @Test func slowDecayNeverEmitsSubnormalOutput() {
        var f = MixBiquad(.make(.lowpass, frequency: 50, q: 8, sampleRate: sr))
        _ = f.process(1)
        var sawSubnormal = false
        for _ in 0..<600_000 {
            let y = f.process(0)
            if y.isSubnormal { sawSubnormal = true }
            if abs(y) < 1e-30 && y != 0 { sawSubnormal = true }
        }
        #expect(!sawSubnormal)
    }

    @Test func resetClearsHistory() {
        var f = MixBiquad(.make(.lowpass, frequency: 200, sampleRate: sr))
        for _ in 0..<100 { _ = f.process(1) }
        f.reset()
        #expect(f.state.0 == 0 && f.state.1 == 0)
        var g = MixBiquad(.make(.lowpass, frequency: 200, sampleRate: sr))
        #expect(f.process(0.3) == g.process(0.3))
    }

    @Test func bufferProcessingEqualsSampleProcessing() {
        let c = MixBiquadCoeffs.make(.peaking, frequency: 800, q: 2, gainDb: 5, sampleRate: sr)
        let x = MixSig.noise(seed: 3, frames: 1000)
        var a = MixBiquad(c)
        let expected = x.map { a.process($0) }
        var b = MixBiquad(c)
        var buf = x
        buf.withUnsafeMutableBufferPointer { b.process($0.baseAddress!, count: $0.count) }
        #expect(buf == expected)
    }

    @Test func dcPassesThroughALowpassUnchanged() {
        var f = MixBiquad(.make(.lowpass, frequency: 500, sampleRate: sr))
        var y: Float = 0
        for _ in 0..<20_000 { y = f.process(0.4) }
        #expect(abs(y - 0.4) < 1e-4)
    }

    @Test func dcIsBlockedByAHighpass() {
        var f = MixBiquad(.make(.highpass, frequency: 500, sampleRate: sr))
        var y: Float = 1
        for _ in 0..<20_000 { y = f.process(0.4) }
        #expect(abs(y) < 1e-4)
    }
}
