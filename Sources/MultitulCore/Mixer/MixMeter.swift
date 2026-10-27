import Foundation

public struct MixLevels: Equatable, Sendable {
    public var peak: Float
    public var rms: Float
    public var reductionDb: Float
    public var bands: [Float]

    public init(peak: Float = 0, rms: Float = 0, reductionDb: Float = 0, bands: [Float] = []) {
        self.peak = peak
        self.rms = rms
        self.reductionDb = reductionDb
        self.bands = bands
    }

    public static let silent = MixLevels()

    public var peakDb: Float { Float(MixGain.linearToDb(Double(peak))) }
    public var rmsDb: Float { Float(MixGain.linearToDb(Double(rms))) }

    // 0...1 for a bar: -60 dBFS is empty, 0 dBFS is full.
    public static func barValue(_ linear: Float, floorDb: Float = -60) -> Float {
        let db = Float(MixGain.linearToDb(Double(linear)))
        return min(max((db - floorDb) / -floorDb, 0), 1)
    }
}

// Block-based peak (with falloff) and RMS (power integrator) readings; values are published atomically.
public final class MixMeter: @unchecked Sendable {
    public static let defaultPeakFallDbPerSecond: Double = 24
    public static let defaultRmsSeconds: Double = 0.15

    private let peakOut = MixAtomicFloat()
    private let rmsOut = MixAtomicFloat()
    private var peakHold: Float = 0
    private var power: Float = 0
    private var sampleRate: Double
    private let fallDb: Double
    private let rmsSeconds: Double

    public init(sampleRate: Double = 48_000, peakFallDbPerSecond: Double = MixMeter.defaultPeakFallDbPerSecond, rmsSeconds: Double = MixMeter.defaultRmsSeconds) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        fallDb = peakFallDbPerSecond
        self.rmsSeconds = rmsSeconds
    }

    public var peak: Float { peakOut.load() }
    public var rms: Float { rmsOut.load() }

    public func reset() {
        peakHold = 0
        power = 0
        peakOut.store(0)
        rmsOut.store(0)
    }

    public func process(_ planes: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) {
        guard channels > 0, frames > 0 else { return }
        var blockPeak: Float = 0
        var sumSq: Float = 0
        mixLoop(channels) { c in
            let p = planes[c]
            mixLoop(frames) { i in
                let v = p[i]
                let a = abs(v)
                if a > blockPeak { blockPeak = a }
                sumSq += v * v
            }
        }
        let seconds = Double(frames) / sampleRate
        let fall = Float(pow(10, -fallDb * seconds / 20))
        peakHold = max(blockPeak, peakHold * fall)
        if peakHold < 1e-6 { peakHold = 0 }
        let mean = sumSq / Float(frames * channels)
        let alpha = Float(1 - exp(-seconds / rmsSeconds))
        power = power + alpha * (mean - power)
        if power < 1e-14 { power = 0 }
        peakOut.store(peakHold)
        rmsOut.store(power.squareRoot())
    }
}

// Log-spaced band-pass bank for the island's live equalizer bars.
public final class MixBandAnalyzer: @unchecked Sendable {
    public static let defaultBandCount = 12
    public static let lowestHz: Double = 60
    public static let highestHz: Double = 12_000

    public let bandCount: Int
    public let centers: [Double]
    public let output: MixAtomicFloatArray
    private var filters: UnsafeMutablePointer<MixBiquad>
    private var energy: UnsafeMutablePointer<Float>
    private var level: UnsafeMutablePointer<Float>
    private var sampleRate: Double
    private let q: Double

    public static func centerFrequencies(count: Int, low: Double = lowestHz, high: Double = highestHz) -> [Double] {
        guard count > 1 else { return [sqrt(low * high)] }
        let ratio = pow(high / low, 1 / Double(count - 1))
        return (0..<count).map { low * pow(ratio, Double($0)) }
    }

    public init(sampleRate: Double = 48_000, bandCount: Int = MixBandAnalyzer.defaultBandCount) {
        self.bandCount = max(1, bandCount)
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        centers = Self.centerFrequencies(count: self.bandCount)
        let ratio = self.bandCount > 1 ? pow(Self.highestHz / Self.lowestHz, 1 / Double(self.bandCount - 1)) : 2
        q = 1 / (2 * sinh(log(ratio) / 2))
        output = MixAtomicFloatArray(count: self.bandCount)
        filters = .allocate(capacity: self.bandCount)
        energy = .allocate(capacity: self.bandCount)
        level = .allocate(capacity: self.bandCount)
        energy.initialize(repeating: 0, count: self.bandCount)
        level.initialize(repeating: 0, count: self.bandCount)
        filters.initialize(repeating: MixBiquad(), count: self.bandCount)
        design()
    }

    deinit {
        filters.deinitialize(count: bandCount)
        filters.deallocate()
        energy.deallocate()
        level.deallocate()
    }

    private func design() {
        mixLoop(bandCount) { b in
            filters[b] = MixBiquad(.make(.bandpass, frequency: centers[b], q: q, sampleRate: sampleRate))
        }
    }

    public func reset() {
        mixLoop(bandCount) { b in
            filters[b].reset()
            level[b] = 0
            output.store(0, at: b)
        }
    }

    // Mono mix of the channels goes through every band; one value per band per call.
    public func process(_ planes: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) {
        guard channels > 0, frames > 0 else { return }
        mixLoop(bandCount) { b in energy[b] = 0 }
        let inv = 1 / Float(channels)
        mixLoop(frames) { i in
            var m: Float = 0
            mixLoop(channels) { c in m += planes[c][i] }
            m *= inv
            mixLoop(bandCount) { b in
                let y = filters[b].process(m)
                energy[b] += y * y
            }
        }
        let seconds = Double(frames) / sampleRate
        let attack = Float(1 - exp(-seconds / 0.02))
        let release = Float(1 - exp(-seconds / 0.2))
        mixLoop(bandCount) { b in
            let rms = (energy[b] / Float(frames)).squareRoot()
            let target = MixLevels.barValue(rms * 1.41421356)
            let k = target > level[b] ? attack : release
            level[b] = MixDenormal.flush(level[b] + k * (target - level[b]))
            output.store(level[b], at: b)
        }
    }
}
