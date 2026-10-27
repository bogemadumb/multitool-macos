import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixLimiterTests {
    private func run(_ data: [[Float]], sr: Double = 48_000, ceiling: Float = 1, lookahead: Double = 0.005, release: Double = 0.08, block: Int = 512) -> (out: [[Float]], limiter: MixLimiter) {
        let lim = MixLimiter(sampleRate: sr, channels: data.count, ceiling: ceiling, lookaheadSeconds: lookahead, releaseSeconds: release)
        var out = [[Float]](repeating: [], count: data.count)
        let frames = data[0].count
        var start = 0
        while start < frames {
            let n = min(block, frames - start)
            let p = MixPlanes(data.map { Array($0[start..<(start + n)]) })
            lim.process(p.pointers, channels: data.count, frames: n)
            let r = p.read()
            for c in 0..<data.count { out[c].append(contentsOf: r[c]) }
            start += n
        }
        return (out, lim)
    }

    @Test func loudSineNeverExceedsTheCeiling() {
        let (out, lim) = run([MixSig.sine(1000, amp: 4, frames: 48_000)])
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(lim.safetyClips == 0)
    }

    @Test func limitedSineKeepsItsLoudness() {
        let (out, _) = run([MixSig.sine(1000, amp: 4, frames: 48_000)])
        let tail = Array(out[0][24_000...])
        #expect(abs(MixSig.rms(tail) - 0.7071) < 0.02)
        #expect(MixSig.peak(tail) > 0.97)
    }

    @Test func customCeilingIsHonoured() {
        for c: Float in [0.9, 0.5, 0.25] {
            let (out, lim) = run([MixSig.sine(440, amp: 2, frames: 24_000)], ceiling: c)
            #expect(MixSig.peak(out[0]) <= c)
            #expect(lim.safetyClips == 0)
        }
    }

    @Test func quietSignalPassesUnchangedButDelayed() {
        let x = MixSig.sine(300, amp: 0.5, frames: 4800)
        let (out, lim) = run([x])
        let l = lim.latencyFrames
        for i in l..<x.count { #expect(abs(out[0][i] - x[i - l]) < 1e-7) }
        for i in 0..<l { #expect(out[0][i] == 0) }
    }

    @Test func impulseIsBroughtDownToTheCeiling() {
        let (out, lim) = run([MixSig.impulse(at: 5000, amp: 10, frames: 9000)])
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(MixSig.peak(out[0]) > 0.99)
        #expect(out[0][5000 + lim.latencyFrames] > 0.99)
        #expect(lim.safetyClips == 0)
    }

    @Test func negativeImpulseIsLimitedToo() {
        let (out, _) = run([MixSig.impulse(at: 100, amp: -8, frames: 2000)])
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(out[0].min()! < -0.99)
    }

    @Test func whiteNoiseNeverExceedsTheCeiling() {
        let (out, lim) = run([MixSig.noise(seed: 7, amp: 3, frames: 96_000)])
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(lim.safetyClips == 0)
        #expect(MixSig.rms(out[0]) > 0.2)
    }

    @Test func longNoiseRunStaysUnderTheCeilingWithoutSafetyClips() {
        let (out, lim) = run([MixSig.noise(seed: 11, amp: 5, frames: 1_500_000)], block: 4096)
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(lim.safetyClips == 0)
    }

    @Test func blockSizeDoesNotChangeTheResult() {
        let x = [MixSig.noise(seed: 5, amp: 2.5, frames: 20_000), MixSig.sine(200, amp: 3, frames: 20_000)]
        let a = run(x, block: 64).out
        let b = run(x, block: 4096).out
        let c = run(x, block: 20_000).out
        #expect(a == b && b == c)
    }

    @Test func latencyMatchesTheLookahead() {
        #expect(MixLimiter(sampleRate: 48_000).latencyFrames == 240)
        #expect(MixLimiter(sampleRate: 44_100).latencyFrames == 221)
        #expect(MixLimiter(sampleRate: 96_000).latencyFrames == 480)
        #expect(MixLimiter(sampleRate: 48_000, lookaheadSeconds: 0).latencyFrames == 1)
    }

    @Test func impulseEmergesExactlyOneLatencyLater() {
        let (out, lim) = run([MixSig.impulse(at: 1000, amp: 0.5, frames: 3000)])
        #expect(out[0][1000 + lim.latencyFrames] == 0.5)
        #expect(out[0][999 + lim.latencyFrames] == 0)
    }

    @Test func gainIsAlreadyDownWhenTheLoudPartArrives() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 1)
        let quiet = MixPlanes([MixSig.sine(500, amp: 0.1, frames: 2000)])
        lim.process(quiet.pointers, channels: 1, frames: 2000)
        #expect(lim.currentGain == 1)
        var previous: Float = 1
        for i in 0...lim.latencyFrames {
            let p = MixPlanes([[4]])
            lim.process(p.pointers, channels: 1, frames: 1)
            #expect(lim.currentGain <= previous, "frame \(i)")
            previous = lim.currentGain
        }
        #expect(abs(lim.currentGain - 0.25) < 1e-4)
    }

    @Test func attackNeverOvershootsOnAStepFromQuietToLoud() {
        var x = MixSig.sine(800, amp: 0.1, frames: 4000)
        x += MixSig.sine(800, amp: 6, frames: 4000)
        let (out, lim) = run([x])
        #expect(MixSig.peak(out[0]) <= 1)
        #expect(lim.safetyClips == 0)
    }

    @Test func releaseRecoversSmoothlyAfterTheBurst() {
        let sr = 48_000.0
        var x = MixSig.sine(500, amp: 4, frames: 4800)
        x += MixSig.sine(500, amp: 0.05, frames: 48_000)
        let lim = MixLimiter(sampleRate: sr, channels: 1, releaseSeconds: 0.08)
        let p = MixPlanes([x])
        var gains: [Float] = []
        for i in 0..<x.count {
            let one = MixPlanes([[x[i]]])
            lim.process(one.pointers, channels: 1, frames: 1)
            gains.append(lim.currentGain)
        }
        _ = p
        let burstEnd = 4800 + lim.latencyFrames
        var prev = gains[burstEnd]
        for g in gains[burstEnd...] {
            #expect(g >= prev - 1e-6)
            prev = g
        }
        let oneTau = burstEnd + Int(0.08 * sr)
        #expect(gains[oneTau] > 0.6 && gains[oneTau] < 0.85)
        #expect(gains[burstEnd + Int(0.5 * sr)] > 0.99)
        #expect(gains.last! > 0.999)
    }

    @Test func releaseTimingIsTheSameAtDifferentSampleRates() {
        var at: [Float] = []
        for sr in [44_100.0, 48_000, 96_000] {
            let lim = MixLimiter(sampleRate: sr, channels: 1, releaseSeconds: 0.08)
            let burst = Int(0.1 * sr)
            let x = MixSig.sine(500, amp: 4, sr: sr, frames: burst) + MixSig.sine(500, amp: 0.05, sr: sr, frames: Int(0.6 * sr))
            var g: Float = 1
            var probe: Float = 0
            for i in 0..<x.count {
                let one = MixPlanes([[x[i]]])
                lim.process(one.pointers, channels: 1, frames: 1)
                g = lim.currentGain
                if i == burst + lim.latencyFrames + Int(0.08 * sr) { probe = g }
            }
            #expect(g > 0.99)
            at.append(probe)
        }
        #expect(at.max()! - at.min()! < 0.03)
    }

    @Test func stereoIsLinkedSoTheImageDoesNotShift() {
        let l = MixSig.sine(300, amp: 4, frames: 24_000)
        let r = MixSig.sine(450, amp: 0.1, frames: 24_000)
        let (out, lim) = run([l, r])
        #expect(MixSig.peak(out[0]) <= 1 && MixSig.peak(out[1]) <= 1)
        let d = lim.latencyFrames
        for i in stride(from: 12_000, to: 24_000, by: 97) {
            let gl = out[0][i] / l[i - d]
            let gr = out[1][i] / r[i - d]
            if abs(l[i - d]) > 0.5 && abs(r[i - d]) > 0.02 { #expect(abs(gl - gr) < 1e-3) }
        }
    }

    @Test func worksForOneTwoSixAndEightChannels() {
        for ch in [1, 2, 6, 8] {
            let data = (0..<ch).map { MixSig.noise(seed: UInt64($0 + 1), amp: 3, frames: 12_000) }
            let (out, lim) = run(data)
            for c in 0..<ch { #expect(MixSig.peak(out[c]) <= 1) }
            #expect(lim.safetyClips == 0)
        }
    }

    @Test func processingFewerChannelsThanConfiguredIsFine() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 8)
        let p = MixPlanes([MixSig.noise(amp: 4, frames: 4000), MixSig.noise(seed: 2, amp: 4, frames: 4000)])
        lim.process(p.pointers, channels: 2, frames: 4000)
        for c in p.read() { #expect(MixSig.peak(c) <= 1) }
    }

    @Test func resetClearsDelayAndGain() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 1)
        let p = MixPlanes([MixSig.noise(amp: 5, frames: 2000)])
        lim.process(p.pointers, channels: 1, frames: 2000)
        #expect(lim.currentGain < 1)
        lim.reset()
        #expect(lim.currentGain == 1 && lim.safetyClips == 0)
        let q = MixPlanes([[Float](repeating: 0.5, count: 600)])
        lim.process(q.pointers, channels: 1, frames: 600)
        let r = q.read()[0]
        #expect(r[0..<lim.latencyFrames].allSatisfy { $0 == 0 })
        #expect(r[lim.latencyFrames] == 0.5)
    }

    @Test func reconfigureChangesLatencyAndChannels() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 2)
        lim.configure(sampleRate: 96_000, channels: 6)
        #expect(lim.latencyFrames == 480 && lim.channels == 6 && lim.sampleRate == 96_000)
        let data = (0..<6).map { MixSig.noise(seed: UInt64($0 + 9), amp: 3, frames: 5000) }
        let p = MixPlanes(data)
        lim.process(p.pointers, channels: 6, frames: 5000)
        for c in p.read() { #expect(MixSig.peak(c) <= 1) }
    }

    @Test func loweringTheCeilingMidStreamIsStillRespected() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 1)
        let a = MixPlanes([MixSig.sine(200, amp: 0.9, frames: 3000)])
        lim.process(a.pointers, channels: 1, frames: 3000)
        lim.ceiling = 0.5
        let b = MixPlanes([MixSig.sine(200, amp: 0.9, frames: 6000)])
        lim.process(b.pointers, channels: 1, frames: 6000)
        #expect(MixSig.peak(b.read()[0]) <= 0.5)
    }

    @Test func emptyAndZeroChannelCallsAreIgnored() {
        let lim = MixLimiter()
        let p = MixPlanes([[0.5]])
        lim.process(p.pointers, channels: 0, frames: 1)
        lim.process(p.pointers, channels: 1, frames: 0)
        #expect(p.read()[0][0] == 0.5)
    }

    @Test func infiniteInputIsClampedNotPropagated() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 1)
        let p = MixPlanes([[Float](repeating: 0.1, count: 400) + [.infinity] + [Float](repeating: 0.1, count: 400)])
        lim.process(p.pointers, channels: 1, frames: 801)
        #expect(p.read()[0].allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func minimumGainReportedForTheBlock() {
        let lim = MixLimiter(sampleRate: 48_000, channels: 1)
        let p = MixPlanes([MixSig.constant(4, frames: 1000)])
        lim.process(p.pointers, channels: 1, frames: 1000)
        #expect(abs(lim.blockMinGain - 0.25) < 1e-3)
        let q = MixPlanes([MixSig.constant(0.1, frames: 100)])
        lim.process(q.pointers, channels: 1, frames: 100)
        #expect(lim.blockMinGain <= 1)
    }
}

@Suite struct MixMeterTests {
    private func feed(_ m: MixMeter, _ data: [[Float]], block: Int) {
        let frames = data[0].count
        var start = 0
        while start < frames {
            let n = min(block, frames - start)
            let p = MixPlanes(data.map { Array($0[start..<(start + n)]) })
            m.process(p.pointers, channels: data.count, frames: n)
            start += n
        }
    }

    @Test func peakOfASine() {
        let m = MixMeter()
        feed(m, [MixSig.sine(1000, amp: 0.5, frames: 4800)], block: 4800)
        #expect(abs(m.peak - 0.5) < 0.001)
    }

    @Test func rmsOfASineSettlesToAmplitudeOverRootTwo() {
        let m = MixMeter()
        feed(m, [MixSig.sine(1000, amp: 0.5, frames: 96_000)], block: 512)
        #expect(abs(m.rms - 0.35355) < 0.005)
    }

    @Test func silenceReadsZero() {
        let m = MixMeter()
        feed(m, [[Float](repeating: 0, count: 4800)], block: 480)
        #expect(m.peak == 0 && m.rms == 0)
    }

    @Test func oneLoudChannelOfTwoHalvesThePower() {
        let m = MixMeter()
        feed(m, [MixSig.sine(1000, amp: 1, frames: 96_000), [Float](repeating: 0, count: 96_000)], block: 512)
        #expect(abs(m.rms - 0.5) < 0.01)
        #expect(abs(m.peak - 1) < 0.001)
    }

    @Test func peakFallsAtTheConfiguredRate() {
        let m = MixMeter(sampleRate: 48_000, peakFallDbPerSecond: 24)
        feed(m, [MixSig.constant(1, frames: 480)], block: 480)
        #expect(m.peak == 1)
        var prev = m.peak
        for _ in 0..<100 {
            feed(m, [[Float](repeating: 0, count: 480)], block: 480)
            #expect(m.peak <= prev)
            prev = m.peak
        }
        #expect(abs(m.peak - Float(pow(10, -24.0 / 20))) < 0.01)
    }

    @Test func aLouderBlockReplacesTheHeldPeak() {
        let m = MixMeter()
        feed(m, [MixSig.constant(0.3, frames: 480)], block: 480)
        feed(m, [MixSig.constant(0.9, frames: 480)], block: 480)
        #expect(m.peak == 0.9)
    }

    @Test func rmsDecaysAfterTheSignalStops() {
        let m = MixMeter()
        feed(m, [MixSig.sine(500, amp: 1, frames: 48_000)], block: 480)
        let loud = m.rms
        feed(m, [[Float](repeating: 0, count: 48_000)], block: 480)
        #expect(m.rms < loud * 0.05)
    }

    @Test func rmsEventuallyIsExactlyZero() {
        let m = MixMeter()
        feed(m, [MixSig.sine(500, amp: 1, frames: 4800)], block: 480)
        feed(m, [[Float](repeating: 0, count: 48_000 * 20)], block: 4800)
        #expect(m.rms == 0)
        #expect(m.peak == 0)
    }

    @Test func blockSizeBarelyChangesTheReading() {
        let x = MixSig.sine(700, amp: 0.8, frames: 96_000)
        let a = MixMeter(), b = MixMeter()
        feed(a, [x], block: 128)
        feed(b, [x], block: 4096)
        #expect(abs(a.rms - b.rms) < 0.01)
    }

    @Test func settleTimeIsTheSameInSecondsAtAnyRate() {
        var readings: [Float] = []
        for sr in [44_100.0, 96_000] {
            let m = MixMeter(sampleRate: sr)
            let n = Int(0.15 * sr)
            feed(m, [MixSig.sine(1000, amp: 1, sr: sr, frames: n)], block: 441)
            readings.append(m.rms)
        }
        #expect(abs(readings[0] - readings[1]) < 0.02)
        #expect(abs(readings[0] - 0.7071 * Float(sqrt(1 - exp(-1.0)))) < 0.03)
    }

    @Test func resetClearsReadings() {
        let m = MixMeter()
        feed(m, [MixSig.sine(1000, frames: 4800)], block: 480)
        m.reset()
        #expect(m.peak == 0 && m.rms == 0)
    }

    @Test func barValueMapsDecibelsToTheBar() {
        #expect(MixLevels.barValue(1) == 1)
        #expect(MixLevels.barValue(0) == 0)
        #expect(MixLevels.barValue(0.001) == 0)
        #expect(abs(MixLevels.barValue(0.0316228) - 0.5) < 0.005)
        #expect(MixLevels.barValue(4) == 1)
    }

    @Test func levelsReportDecibels() {
        let l = MixLevels(peak: 0.5, rms: 0.25)
        #expect(abs(l.peakDb + 6.0206) < 0.001)
        #expect(abs(l.rmsDb + 12.0412) < 0.001)
        #expect(MixLevels.silent == MixLevels())
    }
}

@Suite struct MixBandAnalyzerTests {
    private func run(_ a: MixBandAnalyzer, _ x: [[Float]], block: Int = 480) {
        var start = 0
        let frames = x[0].count
        while start < frames {
            let n = min(block, frames - start)
            let p = MixPlanes(x.map { Array($0[start..<(start + n)]) })
            a.process(p.pointers, channels: x.count, frames: n)
            start += n
        }
    }

    @Test func centersAreLogSpacedBetweenTheLimits() {
        let c = MixBandAnalyzer.centerFrequencies(count: 12)
        #expect(c.count == 12)
        #expect(abs(c.first! - 60) < 1e-9 && abs(c.last! - 12_000) < 1e-6)
        let r = c[1] / c[0]
        for i in 1..<c.count { #expect(abs(c[i] / c[i - 1] - r) < 1e-9) }
    }

    @Test func singleBandSitsInTheMiddleOfTheRange() {
        #expect(abs(MixBandAnalyzer.centerFrequencies(count: 1)[0] - sqrt(60 * 12_000)) < 1e-9)
        #expect(MixBandAnalyzer(bandCount: 0).bandCount == 1)
    }

    @Test func aSineLightsItsOwnBandMost() {
        let a = MixBandAnalyzer(sampleRate: 48_000)
        for target in [1, 5, 9] {
            a.reset()
            run(a, [MixSig.sine(a.centers[target], amp: 0.8, frames: 24_000)])
            let v = a.output.snapshot()
            #expect(v.firstIndex(of: v.max()!) == target)
            #expect(v[target] > 0.8)
            #expect(v[target] - v[target + 1] > 0.08)
            #expect(v[target] - v[target - 1] > 0.08)
        }
    }

    @Test func farBandsStayDark() {
        let a = MixBandAnalyzer(sampleRate: 48_000)
        run(a, [MixSig.sine(a.centers[2], amp: 0.8, frames: 24_000)])
        let v = a.output.snapshot()
        for b in 6..<12 { #expect(v[b] < v[2] - 0.3) }
    }

    @Test func silenceGivesZero() {
        let a = MixBandAnalyzer()
        run(a, [[Float](repeating: 0, count: 9600)])
        #expect(a.output.snapshot().allSatisfy { $0 == 0 })
    }

    @Test func barsFallWhenTheSoundStops() {
        let a = MixBandAnalyzer()
        run(a, [MixSig.sine(a.centers[4], amp: 0.8, frames: 24_000)])
        let loud = a.output.load(at: 4)
        run(a, [[Float](repeating: 0, count: 4800)])
        let mid = a.output.load(at: 4)
        run(a, [[Float](repeating: 0, count: 96_000)])
        #expect(mid < loud && mid > 0)
        #expect(a.output.load(at: 4) < 0.01)
    }

    @Test func valuesStayInsideZeroToOne() {
        let a = MixBandAnalyzer()
        run(a, [MixSig.noise(seed: 4, amp: 4, frames: 48_000)])
        #expect(a.output.snapshot().allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func sameBandWinsAtDifferentSampleRates() {
        for sr in [44_100.0, 48_000, 96_000] {
            let a = MixBandAnalyzer(sampleRate: sr)
            run(a, [MixSig.sine(a.centers[6], amp: 0.8, sr: sr, frames: Int(sr / 2))], block: 512)
            let v = a.output.snapshot()
            #expect(v.firstIndex(of: v.max()!) == 6)
        }
    }

    @Test func stereoIsMixedDownToOneSpectrum() {
        let a = MixBandAnalyzer()
        let s = MixSig.sine(a.centers[3], amp: 0.8, frames: 24_000)
        run(a, [s, s])
        let both = a.output.load(at: 3)
        let b = MixBandAnalyzer()
        run(b, [s])
        #expect(abs(both - b.output.load(at: 3)) < 0.01)
    }

    @Test func resetZeroesTheBars() {
        let a = MixBandAnalyzer()
        run(a, [MixSig.sine(a.centers[3], amp: 0.8, frames: 24_000)])
        a.reset()
        #expect(a.output.snapshot().allSatisfy { $0 == 0 })
    }
}
