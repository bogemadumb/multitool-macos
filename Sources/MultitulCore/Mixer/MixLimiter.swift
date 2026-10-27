import Foundation

// Look-ahead brickwall limiter. The gain for the sample being output is the average of the
// sliding minimum of the required gain over the look-ahead window, so it is already down when
// a peak reaches the output and the peak never exceeds the ceiling. Release is a slew on top.
// Not realtime-safe to configure; process() uses only preallocated memory.
public final class MixLimiter {
    public static let maxChannels = 8
    public static let defaultLookaheadSeconds = 0.005
    public static let defaultReleaseSeconds = 0.08

    public private(set) var sampleRate: Double
    public private(set) var channels: Int
    public private(set) var lookahead: Int
    public private(set) var currentGain: Float = 1
    public private(set) var blockMinGain: Float = 1
    public private(set) var safetyClips = 0
    public var ceiling: Float

    private var releaseCoeff: Float = 0
    private var delay: UnsafeMutablePointer<Float>
    private var dqIdx: UnsafeMutablePointer<Int>
    private var dqVal: UnsafeMutablePointer<Float>
    private var avg: UnsafeMutablePointer<Float>
    private var dqCap = 0
    private var dqHead = 0
    private var dqCount = 0
    private var avgLen = 0
    private var avgSum = 0.0
    private var delayPos = 0
    private var avgPos = 0
    private var counter = 0

    public var latencyFrames: Int { lookahead }

    public init(sampleRate: Double = 48_000, channels: Int = 2, ceiling: Float = 1,
                lookaheadSeconds: Double = MixLimiter.defaultLookaheadSeconds, releaseSeconds: Double = MixLimiter.defaultReleaseSeconds) {
        self.sampleRate = sampleRate
        self.channels = min(max(channels, 1), Self.maxChannels)
        self.ceiling = ceiling
        lookahead = 1
        delay = .allocate(capacity: 1)
        dqIdx = .allocate(capacity: 1)
        dqVal = .allocate(capacity: 1)
        avg = .allocate(capacity: 1)
        configure(sampleRate: sampleRate, channels: channels, lookaheadSeconds: lookaheadSeconds, releaseSeconds: releaseSeconds)
    }

    deinit {
        delay.deallocate()
        dqIdx.deallocate()
        dqVal.deallocate()
        avg.deallocate()
    }

    public func configure(sampleRate sr: Double, channels ch: Int, lookaheadSeconds: Double = MixLimiter.defaultLookaheadSeconds, releaseSeconds: Double = MixLimiter.defaultReleaseSeconds) {
        sampleRate = (sr.isFinite && sr > 0) ? sr : 48_000
        channels = min(max(ch, 1), Self.maxChannels)
        lookahead = max(1, Int((sampleRate * max(lookaheadSeconds, 0)).rounded()))
        let rel = max(releaseSeconds, 0.001)
        releaseCoeff = Float(1 - exp(-1 / (rel * sampleRate)))
        delay.deallocate(); dqIdx.deallocate(); dqVal.deallocate(); avg.deallocate()
        dqCap = lookahead + 2
        avgLen = lookahead + 1
        delay = .allocate(capacity: channels * lookahead)
        dqIdx = .allocate(capacity: dqCap)
        dqVal = .allocate(capacity: dqCap)
        avg = .allocate(capacity: avgLen)
        reset()
    }

    public func reset() {
        delay.initialize(repeating: 0, count: channels * lookahead)
        dqIdx.initialize(repeating: 0, count: dqCap)
        dqVal.initialize(repeating: 1, count: dqCap)
        avg.initialize(repeating: 1, count: avgLen)
        avgSum = Double(avgLen)
        dqHead = 0
        dqCount = 0
        delayPos = 0
        avgPos = 0
        counter = 0
        currentGain = 1
        blockMinGain = 1
        safetyClips = 0
    }

    public func process(_ planes: UnsafePointer<UnsafeMutablePointer<Float>>, channels ch: Int, frames: Int) {
        let nch = min(ch, channels)
        guard nch > 0, frames > 0 else { return }
        let ceil = ceiling
        let l = lookahead
        let invLen = 1 / Double(avgLen)
        var minGain: Float = 1
        mixLoop(frames) { i in
            var peak: Float = 0
            mixLoop(nch) { c in
                let a = abs(planes[c][i])
                if a > peak { peak = a }
            }
            if !peak.isFinite { peak = ceil }
            let req: Float = peak > ceil ? ceil / peak : 1

            while dqCount > 0, dqVal[(dqHead + dqCount - 1) % dqCap] >= req { dqCount -= 1 }
            let tail = (dqHead + dqCount) % dqCap
            dqIdx[tail] = counter
            dqVal[tail] = req
            dqCount += 1
            while dqIdx[dqHead] < counter - l {
                dqHead = (dqHead + 1) % dqCap
                dqCount -= 1
            }
            let h = dqVal[dqHead]

            avgSum += Double(h) - Double(avg[avgPos])
            avg[avgPos] = h
            avgPos += 1
            if avgPos == avgLen { avgPos = 0 }
            let g = Float(avgSum * invLen)

            var rel = currentGain + (1 - currentGain) * releaseCoeff
            if 1 - rel < 1e-7 { rel = 1 }
            currentGain = min(g, rel)
            if currentGain < minGain { minGain = currentGain }

            mixLoop(nch) { c in
                let slot = c * l + delayPos
                let delayed = delay[slot]
                delay[slot] = planes[c][i]
                var y = delayed * currentGain
                if abs(y) > ceil {
                    if abs(y) > ceil * 1.00001 { safetyClips += 1 }
                    y = y > 0 ? ceil : -ceil
                }
                planes[c][i] = y
            }
            delayPos += 1
            if delayPos == l { delayPos = 0 }
            counter += 1
        }
        blockMinGain = minGain
    }
}
