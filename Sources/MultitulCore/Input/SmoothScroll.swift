import Foundation
import CoreGraphics

public struct SmoothCurve: Equatable {
    public static let minTau: TimeInterval = 0.04
    public static let maxTau: TimeInterval = 0.18
    public static let maxCoastStretch = 2.5
    public static let floorSpeed: Double = 50
    public static let flushBelow: Double = 0.6
    public static let maxFrame: TimeInterval = 0.05

    public var response: Int
    public var coast: Int

    public init(response: Int = SmoothScrollSettings.defaultResponse, coast: Int = SmoothScrollSettings.defaultCoast) {
        self.response = min(max(response, 0), 100)
        self.coast = min(max(coast, 0), 100)
    }

    public var baseTau: TimeInterval {
        let r = Double(response) / 100
        return Self.maxTau - r * (Self.maxTau - Self.minTau)
    }

    public func stretch(progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return 1 + Double(coast) / 100 * (Self.maxCoastStretch - 1) * p
    }

    public func step(remaining: Double, glide: Double, dt: TimeInterval) -> Double {
        guard remaining.isFinite, remaining != 0, dt.isFinite, dt > 0 else { return 0 }
        let mag = abs(remaining)
        let progress = glide > 0 ? 1 - mag / glide : 0
        let k = stretch(progress: progress)
        if mag <= Self.flushBelow / k { return remaining }
        let t = min(dt, Self.maxFrame)
        let eased = mag * (1 - exp(-t / (baseTau * k)))
        let emitted = min(mag, max(eased, Self.floorSpeed / k * t))
        return remaining < 0 ? -emitted : emitted
    }
}

public struct SmoothScrollEngine {
    public private(set) var remainingVertical = 0.0
    public private(set) var remainingHorizontal = 0.0
    private var glideVertical = 0.0
    private var glideHorizontal = 0.0
    public var curve: SmoothCurve

    public init(curve: SmoothCurve = SmoothCurve()) { self.curve = curve }

    public var isActive: Bool { remainingVertical != 0 || remainingHorizontal != 0 }

    public mutating func reset() {
        remainingVertical = 0
        remainingHorizontal = 0
        glideVertical = 0
        glideHorizontal = 0
    }

    public mutating func add(vertical: Double, horizontal: Double) {
        Self.feed(vertical, &remainingVertical, &glideVertical)
        Self.feed(horizontal, &remainingHorizontal, &glideHorizontal)
    }

    private static func feed(_ d: Double, _ remaining: inout Double, _ glide: inout Double) {
        guard d.isFinite, d != 0 else { return }
        remaining = ScrollMath.opposes(d, remaining) ? d : remaining + d
        glide = abs(remaining)
    }

    public struct Frame: Equatable {
        public var vertical: Double
        public var horizontal: Double
        public var finished: Bool
    }

    public mutating func advance(dt: TimeInterval) -> Frame {
        let v = curve.step(remaining: remainingVertical, glide: glideVertical, dt: dt)
        let h = curve.step(remaining: remainingHorizontal, glide: glideHorizontal, dt: dt)
        remainingVertical -= v
        remainingHorizontal -= h
        if abs(remainingVertical) < 1e-9 { remainingVertical = 0 }
        if abs(remainingHorizontal) < 1e-9 { remainingHorizontal = 0 }
        return Frame(vertical: v, horizontal: h, finished: !isActive)
    }
}

public struct SubPixel {
    public private(set) var carry = 0.0

    public init() {}

    public mutating func reset() { carry = 0 }

    public mutating func take(_ distance: Double, final: Bool) -> Int {
        guard distance.isFinite else { return 0 }
        if ScrollMath.opposes(carry, distance) { carry = 0 }
        let total = distance + carry
        if final {
            carry = 0
            return Int(total.rounded(.toNearestOrAwayFromZero))
        }
        let whole = (total + (total < 0 ? -1e-9 : 1e-9)).rounded(.towardZero)
        carry = total - whole
        return Int(whole)
    }
}

public enum SmoothInput {
    public static func pixels(_ s: ScrollSample, step: Int, linearLines: Int?, shiftRedirect: Bool) -> (vertical: Double, horizontal: Double) {
        var v = axisPixels(s.vertical, continuous: s.isContinuous, step: step, linearLines: linearLines)
        var h = axisPixels(s.horizontal, continuous: s.isContinuous, step: step, linearLines: linearLines)
        if shiftRedirect, s.flags.contains(.maskShift), v != 0, h == 0 {
            h = v
            v = 0
        }
        return (v, h)
    }

    static func axisPixels(_ d: ScrollAxisDelta, continuous: Bool, step: Int, linearLines: Int?) -> Double {
        guard d.hasMovement else { return 0 }
        let perStep = Double(step)
        if continuous {
            let points = d.point != 0 ? Double(d.point) : d.fixed * ScrollMath.pointsPerLine
            guard points.isFinite else { return 0 }
            return points * perStep / Double(SmoothScrollSettings.defaultStep)
        }
        var ticks = d.line != 0 ? Double(d.line) : ScrollMath.discreteTicks(d)
        if let n = linearLines, n > 0, d.line != 0 { ticks /= Double(n) }
        return ticks * perStep
    }
}

public protocol SmoothFrameTicker: AnyObject {
    func start(_ handler: @escaping () -> Void)
    func stop()
}

public protocol SmoothScrollPoster: AnyObject {
    func post(vertical: Int, horizontal: Int, flags: CGEventFlags)
}

public final class SmoothScrollRunner {
    public let ticker: SmoothFrameTicker
    public let poster: SmoothScrollPoster
    private let clock: () -> TimeInterval
    public private(set) var engine: SmoothScrollEngine
    private var subV = SubPixel()
    private var subH = SubPixel()
    private var lastFrameAt: TimeInterval = 0
    private var flags: CGEventFlags = []
    public private(set) var running = false
    public private(set) var framesPosted = 0

    public init(ticker: SmoothFrameTicker, poster: SmoothScrollPoster, curve: SmoothCurve = SmoothCurve(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ticker = ticker
        self.poster = poster
        self.clock = clock
        self.engine = SmoothScrollEngine(curve: curve)
    }

    public func setCurve(_ c: SmoothCurve) { engine.curve = c }

    public func enqueue(vertical: Double, horizontal: Double, flags: CGEventFlags) {
        guard vertical != 0 || horizontal != 0 else { return }
        if ScrollMath.opposes(vertical, engine.remainingVertical) { subV.reset() }
        if ScrollMath.opposes(horizontal, engine.remainingHorizontal) { subH.reset() }
        self.flags = flags
        engine.add(vertical: vertical, horizontal: horizontal)
        guard !running else { return }
        running = true
        lastFrameAt = clock()
        ticker.start { [weak self] in self?.tick() }
    }

    public func tick() {
        guard running else { return }
        let now = clock()
        let dt = max(now - lastFrameAt, 0)
        lastFrameAt = now
        let frame = engine.advance(dt: dt)
        let v = subV.take(frame.vertical, final: frame.finished)
        let h = subH.take(frame.horizontal, final: frame.finished)
        if v != 0 || h != 0 {
            poster.post(vertical: v, horizontal: h, flags: flags)
            framesPosted += 1
        }
        if frame.finished { halt() }
    }

    public func cancel() {
        engine.reset()
        subV.reset()
        subH.reset()
        halt()
    }

    private func halt() {
        guard running else { return }
        running = false
        ticker.stop()
    }
}
