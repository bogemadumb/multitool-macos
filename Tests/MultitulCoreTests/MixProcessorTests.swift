import Testing
import Foundation
import CoreAudio
@testable import MultitulCore

@Suite struct MixProcessorTests {
    private let sr = 48_000.0

    private func stereo(_ f: Double = 440, amp: Float = 0.5, frames: Int = 9600) -> [[Float]] {
        [MixSig.sine(f, amp: amp, sr: sr, frames: frames), MixSig.sine(f * 1.5, amp: amp, sr: sr, frames: frames)]
    }

    @Test func unityIsTransparentApartFromLatency() {
        let p = MixProcessor(sampleRate: sr)
        let x = stereo()
        let y = MixRun.process(p, input: x)
        let l = p.latencyFrames
        for c in 0..<2 { for i in l..<9600 { #expect(abs(y[c][i] - x[c][i - l]) < 1e-6) } }
        #expect(p.safetyClips == 0)
    }

    @Test func halfVolumeHalvesTheAmplitude() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 0.5))
        let x = stereo()
        let y = MixRun.process(p, input: x)
        let l = p.latencyFrames
        for i in stride(from: l, to: 9600, by: 13) { #expect(abs(y[0][i] - 0.5 * x[0][i - l]) < 1e-6) }
    }

    @Test func boostRaisesQuietMaterialWithoutLimiting() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 4))
        let x = stereo(amp: 0.2)
        let y = MixRun.process(p, input: x)
        let l = p.latencyFrames
        for i in stride(from: l, to: 9600, by: 11) { #expect(abs(y[0][i] - 4 * x[0][i - l]) < 1e-5) }
        #expect(abs(MixSig.peak(Array(y[0][l...])) - 0.8) < 0.01)
    }

    @Test func boostOfLoudMaterialIsLimitedToTheCeiling() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 4))
        let y = MixRun.process(p, input: stereo(amp: 0.8, frames: 24_000))
        #expect(MixSig.peak(y[0]) <= 1 && MixSig.peak(y[1]) <= 1)
        #expect(p.safetyClips == 0)
        #expect(p.levels(bands: false).reductionDb < -6)
    }

    @Test func boostedWhiteNoiseNeverClips() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 4))
        let y = MixRun.process(p, input: [MixSig.noise(seed: 21, amp: 1, frames: 96_000), MixSig.noise(seed: 22, amp: 1, frames: 96_000)])
        #expect(MixSig.peak(y[0]) <= 1 && MixSig.peak(y[1]) <= 1)
        #expect(p.safetyClips == 0)
    }

    @Test func boostedImpulseIsLimited() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 4))
        let y = MixRun.process(p, input: [MixSig.impulse(at: 3000, amp: 1, frames: 6000), MixSig.impulse(at: 3000, amp: -1, frames: 6000)])
        #expect(MixSig.peak(y[0]) <= 1 && MixSig.peak(y[1]) <= 1)
    }

    @Test func customCeilingParameterApplies() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 2, ceiling: 0.5))
        let y = MixRun.process(p, input: stereo(amp: 0.9, frames: 12_000))
        #expect(MixSig.peak(y[0]) <= 0.5)
    }

    @Test func muteFadesToSilenceWithoutAStep() {
        let p = MixProcessor(sampleRate: sr)
        let x = [MixSig.constant(0.5, frames: 12_000), MixSig.constant(0.5, frames: 12_000)]
        _ = MixRun.process(p, input: [MixSig.constant(0.5, frames: 4800), MixSig.constant(0.5, frames: 4800)])
        p.setParams(MixParams(muted: true))
        let y = MixRun.process(p, input: x)[0]
        var maxDiff: Float = 0
        for i in 1..<y.count { maxDiff = max(maxDiff, abs(y[i] - y[i - 1])) }
        #expect(maxDiff <= 0.5 / 1440 + 1e-5)
        #expect(y[2000...].allSatisfy { $0 == 0 })
        #expect(y[0] > 0.45)
    }

    @Test func unmuteFadesBackIn() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(muted: true))
        let x = [MixSig.constant(0.5, frames: 6000), MixSig.constant(0.5, frames: 6000)]
        let first = MixRun.process(p, input: x)[0]
        #expect(first.allSatisfy { $0 == 0 })
        p.setParams(MixParams(muted: false))
        let y = MixRun.process(p, input: x)[0]
        let l = p.latencyFrames
        #expect(y[l + 1] < 0.01)
        #expect(abs(y[l + 1500] - 0.5) < 1e-5)
        var prev: Float = 0
        for i in l..<(l + 1440) { #expect(y[i] >= prev - 1e-6); prev = y[i] }
    }

    @Test func volumeChangeRampsWithoutZipper() {
        let p = MixProcessor(sampleRate: sr)
        _ = MixRun.process(p, input: [MixSig.constant(0.5, frames: 2400), MixSig.constant(0.5, frames: 2400)])
        p.setParams(MixParams(volume: 0.25))
        let y = MixRun.process(p, input: [MixSig.constant(0.5, frames: 6000), MixSig.constant(0.5, frames: 6000)])[0]
        var maxDiff: Float = 0
        for i in 1..<y.count { maxDiff = max(maxDiff, abs(y[i] - y[i - 1])) }
        #expect(maxDiff <= 0.5 * 0.75 / 960 + 1e-5)
        #expect(abs(y.last! - 0.125) < 1e-6)
    }

    @Test func fadeDurationIsTheSameInSecondsAtAnySampleRate() {
        var times: [Double] = []
        for rate in [44_100.0, 48_000, 96_000] {
            let p = MixProcessor(sampleRate: rate)
            _ = MixRun.process(p, input: [MixSig.constant(0.5, frames: 1000)])
            p.setParams(MixParams(muted: true))
            let y = MixRun.process(p, input: [MixSig.constant(0.5, frames: Int(rate * 0.2))])[0]
            let l = p.latencyFrames
            let idx = y.firstIndex { $0 == 0 && true } ?? y.count
            times.append(Double(idx - l) / rate)
        }
        #expect(times.max()! - times.min()! < 0.003)
        #expect(abs(times[1] - 0.03) < 0.003)
    }

    @Test func parameterChangesArriveThroughTheMailbox() {
        let p = MixProcessor(sampleRate: sr)
        let x = [MixSig.constant(0.4, frames: 4800)]
        let a = MixRun.process(p, input: x)[0]
        p.setParams(MixParams(volume: 0.5))
        p.setParams(MixParams(volume: 0.25))
        let b = MixRun.process(p, input: x)[0]
        #expect(abs(a.last! - 0.4) < 1e-6)
        #expect(abs(b.last! - 0.1) < 1e-6)
    }

    @Test func interleavedAndPlanarGiveTheSameResult() {
        let x = stereo(frames: 4000)
        let a = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 1.7)), input: x, inInterleaved: true, outInterleaved: true)
        let b = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 1.7)), input: x, inInterleaved: false, outInterleaved: false)
        let c = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 1.7)), input: x, inInterleaved: true, outInterleaved: false)
        let d = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 1.7)), input: x, inInterleaved: false, outInterleaved: true)
        #expect(a == b && b == c && c == d)
    }

    @Test func monoInputFeedsBothOutputChannels() {
        let p = MixProcessor(sampleRate: sr)
        let x = [MixSig.sine(300, amp: 0.5, frames: 4000)]
        let y = MixRun.process(p, input: x, outChannels: 2)
        #expect(y[0] == y[1])
        #expect(MixSig.peak(y[0]) > 0.45)
    }

    @Test func stereoInputIsAveragedForMonoOutput() {
        let p = MixProcessor(sampleRate: sr)
        let x = [MixSig.constant(0.6, frames: 3000), MixSig.constant(0.2, frames: 3000)]
        let y = MixRun.process(p, input: x, outChannels: 1)[0]
        #expect(abs(y.last! - 0.4) < 1e-6)
    }

    @Test func surroundInputKeepsTheFrontPairForStereoOutput() {
        let p = MixProcessor(sampleRate: sr)
        let x = (0..<6).map { MixSig.constant(Float($0 + 1) / 10, frames: 3000) }
        let y = MixRun.process(p, input: x, outChannels: 2)
        #expect(abs(y[0].last! - 0.1) < 1e-6 && abs(y[1].last! - 0.2) < 1e-6)
    }

    @Test func stereoInputFillsOnlyTheFrontPairOfSurroundOutput() {
        let p = MixProcessor(sampleRate: sr)
        let x = [MixSig.constant(0.3, frames: 3000), MixSig.constant(0.5, frames: 3000)]
        let y = MixRun.process(p, input: x, outChannels: 6, outInterleaved: true)
        #expect(abs(y[0].last! - 0.3) < 1e-6 && abs(y[1].last! - 0.5) < 1e-6)
        for c in 2..<6 { #expect(y[c].allSatisfy { $0 == 0 }) }
    }

    @Test func channelsBeyondEightAreSilenced() {
        let p = MixProcessor(sampleRate: sr)
        let x = (0..<10).map { _ in MixSig.constant(0.25, frames: 3000) }
        let y = MixRun.process(p, input: x, outChannels: 10, inInterleaved: true, outInterleaved: true)
        for c in 0..<8 { #expect(abs(y[c].last! - 0.25) < 1e-6) }
        for c in 8..<10 { #expect(y[c].allSatisfy { $0 == 0 }) }
    }

    @Test func bufferLargerThanTheChunkMatchesOneBigProcessor() {
        let x = stereo(frames: 10_000)
        let small = MixProcessor(sampleRate: sr, maxFrames: 256, initial: MixParams(volume: 3))
        let big = MixProcessor(sampleRate: sr, maxFrames: 16_384, initial: MixParams(volume: 3))
        let a = MixRun.process(small, input: x, block: 10_000)
        let b = MixRun.process(big, input: x, block: 10_000)
        #expect(a == b)
    }

    @Test func callSizeDoesNotChangeTheOutput() {
        let x = stereo(frames: 12_000)
        let a = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 2.5)), input: x, block: 64)
        let b = MixRun.process(MixProcessor(sampleRate: sr, initial: MixParams(volume: 2.5)), input: x, block: 3000)
        #expect(a == b)
    }

    @Test func missingInputGivesSilence() {
        let p = MixProcessor(sampleRate: sr)
        let o = MixABL(channels: 2, frames: 256, interleaved: true)
        o.setAll(0.7)
        p.process(input: nil, output: o.pointer)
        #expect(o.read().allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func emptyBuffersAreHarmless() {
        let p = MixProcessor(sampleRate: sr)
        let i = MixABL(channels: 2, frames: 0, interleaved: false)
        let o = MixABL(channels: 2, frames: 0, interleaved: false)
        p.process(input: UnsafePointer(i.pointer), output: o.pointer)
        #expect(p.callbackCount.load() == 1)
    }

    @Test func longerOutputThanInputIsZeroPadded() {
        let p = MixProcessor(sampleRate: sr)
        let i = MixABL(channels: 2, frames: 100, interleaved: true)
        let o = MixABL(channels: 2, frames: 300, interleaved: true)
        i.setAll(0.5)
        o.setAll(9)
        p.process(input: UnsafePointer(i.pointer), output: o.pointer)
        let r = o.read()
        #expect(r[0][100...].allSatisfy { $0 == 0 })
    }

    @Test func nonFiniteSamplesAreScrubbed() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 2))
        var x = stereo(frames: 4000)
        x[0][100] = .nan
        x[0][200] = .infinity
        x[1][300] = -.infinity
        let y = MixRun.process(p, input: x)
        #expect(y.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) <= 1 } })
    }

    @Test func denormalInputIsFlushed() {
        let p = MixProcessor(sampleRate: sr)
        let y = MixRun.process(p, input: [[Float](repeating: Float.leastNonzeroMagnitude * 100, count: 4000), [Float](repeating: -Float.leastNonzeroMagnitude * 100, count: 4000)])
        #expect(y.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func renderOutputOffKeepsTheOutputSilentButStillMeters() {
        let p = MixProcessor(sampleRate: sr, renderOutput: false)
        let y = MixRun.process(p, input: stereo(amp: 0.5, frames: 9600))
        #expect(y.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(p.levels(bands: false).peak > 0.4)
    }

    @Test func levelsAreReported() {
        let p = MixProcessor(sampleRate: sr)
        _ = MixRun.process(p, input: stereo(amp: 0.5, frames: 48_000))
        let l = p.levels(bands: false)
        #expect(abs(l.peak - 0.5) < 0.02)
        #expect(abs(l.rms - 0.3535) < 0.03)
        #expect(l.reductionDb == 0)
        #expect(l.bands.isEmpty)
    }

    @Test func bandsAreProducedOnDemand() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(bandsOn: true))
        let f = p.analyzer.centers[5]
        _ = MixRun.process(p, input: [MixSig.sine(f, amp: 0.8, sr: sr, frames: 24_000)])
        let b = p.levels(bands: true).bands
        #expect(b.count == MixBandAnalyzer.defaultBandCount)
        #expect(b.firstIndex(of: b.max()!) == 5)
        let off = MixProcessor(sampleRate: sr)
        _ = MixRun.process(off, input: [MixSig.sine(f, amp: 0.8, sr: sr, frames: 24_000)])
        #expect(off.analyzer.output.snapshot().allSatisfy { $0 == 0 })
    }

    @Test func parametersAreSanitised() {
        #expect(MixParams(volume: .nan).sanitized().volume == 1)
        #expect(MixParams(volume: 100).sanitized().volume == 4)
        #expect(MixParams(volume: -3).sanitized().volume == 0)
        #expect(MixParams(ceiling: 0).sanitized().ceiling == 0.05)
        #expect(MixParams(ceiling: 7).sanitized().ceiling == 1)
        #expect(MixParams(ceiling: .nan).sanitized().ceiling == 1)
    }

    @Test func latencyFollowsTheSampleRate() {
        #expect(MixProcessor(sampleRate: 48_000).latencyFrames == 240)
        #expect(MixProcessor(sampleRate: 96_000).latencyFrames == 480)
        #expect(MixProcessor(sampleRate: .nan).sampleRate == 48_000)
    }

    @Test func callbackCounterAdvances() {
        let p = MixProcessor(sampleRate: sr)
        _ = MixRun.process(p, input: stereo(frames: 2048), block: 512)
        #expect(p.callbackCount.load() == 4)
    }

    @Test func resetRestartsFromTheCurrentParameters() {
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 4))
        _ = MixRun.process(p, input: stereo(amp: 0.9, frames: 6000))
        p.reset()
        let y = MixRun.process(p, input: [MixSig.constant(0.1, frames: 1000), MixSig.constant(0.1, frames: 1000)])
        #expect(y[0][0..<p.latencyFrames].allSatisfy { $0 == 0 })
        #expect(abs(y[0].last! - 0.4) < 1e-6)
    }

    @Test func repeatedCallsOnPreallocatedBuffersAreDeterministic() {
        let a = MixProcessor(sampleRate: sr, initial: MixParams(volume: 2.2))
        let b = MixProcessor(sampleRate: sr, initial: MixParams(volume: 2.2))
        let i = MixABL(channels: 2, frames: 480, interleaved: true)
        let oa = MixABL(channels: 2, frames: 480, interleaved: true)
        let ob = MixABL(channels: 2, frames: 480, interleaved: true)
        let x = stereo(frames: 480)
        for round in 0..<3000 {
            i.fill(x)
            if round == 1000 { a.setParams(MixParams(volume: 0.7, muted: true)); b.setParams(MixParams(volume: 0.7, muted: true)) }
            if round == 2000 { a.setParams(MixParams(volume: 3)); b.setParams(MixParams(volume: 3)) }
            a.process(input: UnsafePointer(i.pointer), output: oa.pointer)
            b.process(input: UnsafePointer(i.pointer), output: ob.pointer)
        }
        #expect(oa.read() == ob.read())
        #expect(a.callbackCount.load() == 3000)
        #expect(MixSig.peak(oa.read()[0]) <= 1)
    }

    @Test func processPathMakesNoHeapAllocations() throws {
        guard MixAllocProbe.available else {
            Issue.record("malloc_logger hook is not reachable here: the realtime-allocation check did not run")
            return
        }
        let p = MixProcessor(sampleRate: sr, initial: MixParams(volume: 2, bandsOn: true))
        let i = MixABL(channels: 2, frames: 512, interleaved: true)
        let o = MixABL(channels: 2, frames: 512, interleaved: false)
        i.fill(stereo(frames: 512))
        let control = MixAllocProbe.count { _ = [Int](repeating: 1, count: 256).map { $0 + 1 } }
        #expect((control ?? 0) > 0)
        p.setParams(MixParams(volume: 0.5))
        let n = MixAllocProbe.count {
            var round = 0
            while round < 2000 {
                if round % 500 == 0 { p.setParams(MixParams(volume: Float(round % 3) + 0.5, muted: round % 1000 == 0, bandsOn: true)) }
                p.process(input: UnsafePointer(i.pointer), output: o.pointer)
                round += 1
            }
        }
        #expect(n == 0)
    }
}

@Suite struct MixChannelMapTests {
    private func map(_ input: [[Float]], to out: Int) -> [[Float]] {
        let i = MixPlanes(input)
        let o = MixPlanes([[Float]](repeating: [Float](repeating: 9, count: input[0].count), count: out))
        MixChannelMap.apply(i.pointers, inChannels: input.count, o.pointers, outChannels: out, frames: input[0].count)
        return o.read()
    }

    @Test func sameCountCopies() { #expect(map([[1, 2], [3, 4]], to: 2) == [[1, 2], [3, 4]]) }
    @Test func monoIsDuplicated() { #expect(map([[1, 2]], to: 3) == [[1, 2], [1, 2], [1, 2]]) }
    @Test func stereoToMonoAverages() { #expect(map([[1, 0], [0, 1]], to: 1) == [[0.5, 0.5]]) }
    @Test func moreToFewerKeepsTheFirst() { #expect(map([[1], [2], [3], [4]], to: 2) == [[1], [2]]) }
    @Test func fewerToMoreZeroFills() { #expect(map([[1], [2]], to: 4) == [[1], [2], [0], [0]]) }
    @Test func threeToOneAveragesAll() { #expect(map([[3], [6], [9]], to: 1) == [[6]]) }
}
