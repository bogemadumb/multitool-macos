import Foundation
import CoreAudio

public struct MixParams: Equatable, Sendable {
    public var volume: Float
    public var muted: Bool
    public var ceiling: Float
    public var bandsOn: Bool

    public init(volume: Float = 1, muted: Bool = false, ceiling: Float = 1, bandsOn: Bool = false) {
        self.volume = volume
        self.muted = muted
        self.ceiling = ceiling
        self.bandsOn = bandsOn
    }

    public static let unity = MixParams()

    public func sanitized(maxBoost: Float = Float(MixGain.defaultMaxBoost)) -> MixParams {
        var p = self
        p.volume = p.volume.isFinite ? min(max(p.volume, 0), maxBoost) : 1
        p.ceiling = p.ceiling.isFinite ? min(max(p.ceiling, 0.05), 1) : 1
        return p
    }
}

public enum MixChannelMap {
    // Same count: copy. Mono: to every output. To mono: average. Otherwise channel i to i, the rest silent.
    public static func apply(_ input: UnsafePointer<UnsafeMutablePointer<Float>>, inChannels: Int, _ output: UnsafePointer<UnsafeMutablePointer<Float>>, outChannels: Int, frames: Int) {
        guard inChannels > 0, outChannels > 0, frames > 0 else { return }
        if inChannels == 1 {
            mixLoop(outChannels) { c in output[c].update(from: input[0], count: frames) }
        } else if outChannels == 1 {
            let inv = 1 / Float(inChannels)
            mixLoop(frames) { i in
                var s: Float = 0
                mixLoop(inChannels) { c in s += input[c][i] }
                output[0][i] = s * inv
            }
        } else {
            mixLoop(outChannels) { c in
                if c < inChannels { output[c].update(from: input[c], count: frames) } else { output[c].update(repeating: 0, count: frames) }
            }
        }
    }
}

// Everything the audio thread touches is allocated in init. Parameters arrive through a triple buffer.
public final class MixProcessor: @unchecked Sendable {
    public static let maxChannels = MixLimiter.maxChannels
    public static let defaultMaxFrames = 4096
    public static let volumeRampSeconds = 0.02
    public static let muteRampSeconds = 0.03

    public let sampleRate: Double
    public let maxFrames: Int
    public let renderOutput: Bool
    public let meter: MixMeter
    public let analyzer: MixBandAnalyzer
    public let reductionDb = MixAtomicFloat()
    public let callbackCount = MixAtomicU32()

    private let mailbox: MixTripleBuffer<MixParams>
    private var applied: MixParams
    private var volume: MixSmoother
    private var mute: MixSmoother
    private let limiter: MixLimiter
    private let storage: UnsafeMutablePointer<Float>
    private let inPlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outPlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(sampleRate: Double = 48_000, maxFrames: Int = MixProcessor.defaultMaxFrames, initial: MixParams = .unity, renderOutput: Bool = true) {
        self.renderOutput = renderOutput
        let sr = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
        let p = initial.sanitized()
        self.sampleRate = sr
        self.maxFrames = max(maxFrames, 1)
        mailbox = MixTripleBuffer(initial: p)
        applied = p
        volume = MixSmoother(value: p.volume, sampleRate: sr, rampSeconds: Self.volumeRampSeconds)
        mute = MixSmoother(value: p.muted ? 0 : 1, sampleRate: sr, rampSeconds: Self.muteRampSeconds)
        limiter = MixLimiter(sampleRate: sr, channels: Self.maxChannels, ceiling: p.ceiling)
        meter = MixMeter(sampleRate: sr)
        analyzer = MixBandAnalyzer(sampleRate: sr)
        let plane = self.maxFrames
        storage = .allocate(capacity: 2 * Self.maxChannels * plane)
        storage.initialize(repeating: 0, count: 2 * Self.maxChannels * plane)
        inPlanes = .allocate(capacity: Self.maxChannels)
        outPlanes = .allocate(capacity: Self.maxChannels)
        mixLoop(Self.maxChannels) { c in
            inPlanes[c] = storage + c * plane
            outPlanes[c] = storage + (Self.maxChannels + c) * plane
        }
    }

    deinit {
        storage.deallocate()
        inPlanes.deallocate()
        outPlanes.deallocate()
    }

    public var latencyFrames: Int { limiter.latencyFrames }
    public var safetyClips: Int { limiter.safetyClips }

    public func setParams(_ p: MixParams) { mailbox.publish(p.sanitized()) }

    public func levels(bands: Bool) -> MixLevels {
        MixLevels(peak: meter.peak, rms: meter.rms, reductionDb: reductionDb.load(), bands: bands ? analyzer.output.snapshot() : [])
    }

    public func reset() {
        limiter.reset()
        meter.reset()
        analyzer.reset()
        volume.jump(to: applied.volume)
        mute.jump(to: applied.muted ? 0 : 1)
    }

    private func adopt(_ p: MixParams) {
        if p.volume != applied.volume { volume.setTarget(p.volume) }
        if p.muted != applied.muted { mute.setTarget(p.muted ? 0 : 1) }
        limiter.ceiling = p.ceiling
        applied = p
    }

    private static func frames(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var n = Int.max
        mixLoop(list.count) { i in
            let b = list[i]
            let ch = max(Int(b.mNumberChannels), 1)
            n = min(n, Int(b.mDataByteSize) / (ch * MemoryLayout<Float>.size))
        }
        return n == Int.max ? 0 : n
    }

    private static func zero(_ list: UnsafeMutableAudioBufferListPointer) {
        mixLoop(list.count) { i in
            let b = list[i]
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
    }

    // Float32 only; interleaved and planar buffers both work. Safe to call from the IO thread.
    public func process(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>) {
        callbackCount.add(1)
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard let input else { Self.zero(outList); return }
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let inFrames = Self.frames(inList)
        let outFrames = Self.frames(outList)
        var outTotal = 0
        mixLoop(outList.count) { i in outTotal += max(Int(outList[i].mNumberChannels), 1) }
        var inTotal = 0
        mixLoop(inList.count) { i in inTotal += max(Int(inList[i].mNumberChannels), 1) }
        let frames = min(inFrames, outFrames)
        let outCh = min(outTotal, Self.maxChannels)
        let inCh = min(inTotal, Self.maxChannels)
        guard frames > 0, inCh > 0, outCh > 0 else { Self.zero(outList); return }

        if mailbox.hasPending { adopt(mailbox.read()) }

        var start = 0
        while start < frames {
            let n = min(maxFrames, frames - start)
            deinterleave(inList, from: start, count: n)
            MixChannelMap.apply(inPlanes, inChannels: inCh, outPlanes, outChannels: outCh, frames: n)
            applyGain(channels: outCh, frames: n)
            limiter.process(outPlanes, channels: outCh, frames: n)
            meter.process(outPlanes, channels: outCh, frames: n)
            if applied.bandsOn { analyzer.process(outPlanes, channels: outCh, frames: n) }
            interleave(outList, from: start, count: n, channels: outCh)
            start += n
        }
        if !renderOutput { Self.zero(outList) }
        reductionDb.store(Float(20 * log10(Double(max(limiter.blockMinGain, 1e-6)))))
        if outFrames > frames {
            mixLoop(outList.count) { i in
                let b = outList[i]
                let ch = max(Int(b.mNumberChannels), 1)
                if let d = b.mData { memset(d + frames * ch * MemoryLayout<Float>.size, 0, Int(b.mDataByteSize) - frames * ch * MemoryLayout<Float>.size) }
            }
        }
    }

    private func applyGain(channels: Int, frames: Int) {
        if !volume.isRamping && !mute.isRamping {
            let g = volume.value * mute.value
            if g == 1 { return }
            mixLoop(channels) { c in
                let p = outPlanes[c]
                mixLoop(frames) { i in p[i] *= g }
            }
            return
        }
        mixLoop(frames) { i in
            let g = volume.next() * mute.next()
            mixLoop(channels) { c in outPlanes[c][i] *= g }
        }
    }

    private func deinterleave(_ list: UnsafeMutableAudioBufferListPointer, from start: Int, count n: Int) {
        var plane = 0
        mixLoop(list.count) { b in
            let buf = list[b]
            let nc = max(Int(buf.mNumberChannels), 1)
            if let raw = buf.mData {
                let data = raw.assumingMemoryBound(to: Float.self)
                mixLoop(min(nc, Self.maxChannels - plane)) { k in
                    let dst = inPlanes[plane + k]
                    mixLoop(n) { i in
                        let v = data[(start + i) * nc + k]
                        dst[i] = (v.isFinite && abs(v) >= MixDenormal.threshold) ? v : 0
                    }
                }
            }
            plane += nc
        }
    }

    private func interleave(_ list: UnsafeMutableAudioBufferListPointer, from start: Int, count n: Int, channels: Int) {
        var plane = 0
        mixLoop(list.count) { b in
            let buf = list[b]
            let nc = max(Int(buf.mNumberChannels), 1)
            if let raw = buf.mData {
                let data = raw.assumingMemoryBound(to: Float.self)
                mixLoop(nc) { k in
                    if plane + k < channels {
                        let src = outPlanes[plane + k]
                        mixLoop(n) { i in data[(start + i) * nc + k] = src[i] }
                    } else {
                        mixLoop(n) { i in data[(start + i) * nc + k] = 0 }
                    }
                }
            }
            plane += nc
        }
    }
}
