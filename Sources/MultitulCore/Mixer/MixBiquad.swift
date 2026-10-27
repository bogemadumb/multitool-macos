import Foundation

public enum MixBiquadKind: String, CaseIterable, Sendable {
    case lowpass, highpass, bandpass, notch, peaking, lowShelf, highShelf
}

public struct MixBiquadCoeffs: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public static let identity = MixBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public static func make(_ kind: MixBiquadKind, frequency: Double, q: Double = 0.7071, gainDb: Double = 0, sampleRate: Double) -> MixBiquadCoeffs {
        guard sampleRate.isFinite, sampleRate > 0 else { return .identity }
        let f = min(max(frequency.isFinite ? frequency : 1000, 10), sampleRate * 0.45)
        let qq = min(max(q.isFinite ? q : 0.7071, 0.1), 30)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * qq)
        let a = pow(10, (gainDb.isFinite ? gainDb : 0) / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .lowpass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highpass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .bandpass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .lowShelf:
            let r = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + r)
            b1 = 2 * a * ((a - 1) - (a + 1) * cw)
            b2 = a * ((a + 1) - (a - 1) * cw - r)
            a0 = (a + 1) + (a - 1) * cw + r
            a1 = -2 * ((a - 1) + (a + 1) * cw)
            a2 = (a + 1) + (a - 1) * cw - r
        case .highShelf:
            let r = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + r)
            b1 = -2 * a * ((a - 1) + (a + 1) * cw)
            b2 = a * ((a + 1) + (a - 1) * cw - r)
            a0 = (a + 1) - (a - 1) * cw + r
            a1 = 2 * ((a - 1) - (a + 1) * cw)
            a2 = (a + 1) - (a - 1) * cw - r
        }
        return MixBiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public func magnitude(frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let den = dr * dr + di * di
        guard den > 0 else { return 0 }
        return ((nr * nr + ni * ni) / den).squareRoot()
    }

    public func magnitudeDb(frequency: Double, sampleRate: Double) -> Double {
        MixGain.linearToDb(magnitude(frequency: frequency, sampleRate: sampleRate))
    }

    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }
}

// Transposed direct form II.
public struct MixBiquad: Sendable {
    public var coeffs: MixBiquadCoeffs
    private var z1 = 0.0
    private var z2 = 0.0

    public init(_ coeffs: MixBiquadCoeffs = .identity) { self.coeffs = coeffs }

    public var state: (Double, Double) { (z1, z2) }

    public mutating func reset() { z1 = 0; z2 = 0 }

    @inline(__always) public mutating func process(_ x: Float) -> Float {
        let xd = Double(x)
        let y = coeffs.b0 * xd + z1
        z1 = MixDenormal.flush(coeffs.b1 * xd - coeffs.a1 * y + z2)
        z2 = MixDenormal.flush(coeffs.b2 * xd - coeffs.a2 * y)
        return MixDenormal.flush(Float(y))
    }

    public mutating func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        mixLoop(count) { i in buffer[i] = process(buffer[i]) }
    }
}
