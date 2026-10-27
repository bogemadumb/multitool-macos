import Foundation
import CoreGraphics

public struct ScrollAxisDelta: Equatable {
    public var line: Int64
    public var point: Int64
    public var fixed: Double

    public init(line: Int64 = 0, point: Int64 = 0, fixed: Double = 0) {
        self.line = line
        self.point = point
        self.fixed = fixed
    }

    public var hasMovement: Bool { line != 0 || point != 0 || fixed != 0 }
    public var negated: ScrollAxisDelta { ScrollAxisDelta(line: -line, point: -point, fixed: -fixed) }
}

public struct ScrollSample: Equatable {
    public var vertical: ScrollAxisDelta
    public var horizontal: ScrollAxisDelta
    public var isContinuous: Bool
    public var scrollPhase: Int64
    public var momentumPhase: Int64
    public var scrollCount: Int64
    public var flags: CGEventFlags

    public init(vertical: ScrollAxisDelta = ScrollAxisDelta(), horizontal: ScrollAxisDelta = ScrollAxisDelta(), isContinuous: Bool = false,
                scrollPhase: Int64 = 0, momentumPhase: Int64 = 0, scrollCount: Int64 = 0, flags: CGEventFlags = []) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.isContinuous = isContinuous
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.scrollCount = scrollCount
        self.flags = flags
    }

    public var verticalOnly: Bool { vertical.hasMovement && !horizontal.hasMovement }
    public var hasMovement: Bool { vertical.hasMovement || horizontal.hasMovement }
}

public struct WheelClassifier {
    public static let touchGraceSeconds: TimeInterval = 0.6
    private var lastTouchAt: TimeInterval?

    public init() {}

    public mutating func reset() { lastTouchAt = nil }

    public mutating func isMouseWheel(_ s: ScrollSample, now: TimeInterval) -> Bool {
        if !s.isContinuous { return true }
        if s.scrollPhase != 0 || s.momentumPhase != 0 {
            lastTouchAt = now
            return false
        }
        if s.scrollCount != 0, let t = lastTouchAt, now >= t, now - t <= Self.touchGraceSeconds { return false }
        return true
    }
}

public enum ScrollMath {
    public static let pointsPerLine: Double = 10
    public static let shortcutFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]

    public static func redirectToHorizontal(_ s: ScrollSample, modifier: ScrollModifierKey) -> ScrollSample? {
        guard s.flags.intersection(shortcutFlags) == modifier.flag, s.verticalOnly else { return nil }
        var out = s
        out.horizontal = s.vertical
        out.vertical = ScrollAxisDelta()
        out.flags.remove(modifier.flag)
        return out
    }

    public struct InversionPlan: Equatable {
        public var vertical: Bool
        public var horizontal: Bool
    }

    public static func inversionPlan(_ s: ScrollSample, invertVertical: Bool, invertHorizontal: Bool) -> InversionPlan {
        let nativeShiftRedirect = !s.isContinuous && s.flags.contains(.maskShift) && s.verticalOnly
        return InversionPlan(
            vertical: s.vertical.hasMovement && (nativeShiftRedirect ? invertHorizontal : invertVertical),
            horizontal: s.horizontal.hasMovement && invertHorizontal)
    }

    public static func inverted(_ s: ScrollSample, invertVertical: Bool, invertHorizontal: Bool) -> ScrollSample {
        let plan = inversionPlan(s, invertVertical: invertVertical, invertHorizontal: invertHorizontal)
        var out = s
        if plan.vertical { out.vertical = s.vertical.negated }
        if plan.horizontal { out.horizontal = s.horizontal.negated }
        return out
    }

    public static func discreteTicks(_ d: ScrollAxisDelta) -> Double {
        if d.line != 0 { return d.line > 0 ? 1 : -1 }
        if d.fixed.isFinite, d.fixed != 0 { return d.fixed }
        return Double(d.point) / pointsPerLine
    }

    public static func continuousTicks(_ d: ScrollAxisDelta) -> Double {
        guard d.fixed.isFinite else { return 0 }
        return d.point != 0 ? Double(d.point) / pointsPerLine : d.fixed
    }

    public static func ticks(_ d: ScrollAxisDelta, continuous: Bool) -> Double {
        continuous ? continuousTicks(d) : discreteTicks(d)
    }

    public static func opposes(_ a: Double, _ b: Double) -> Bool { a != 0 && b != 0 && (a < 0) != (b < 0) }
}

public struct LinearScroll {
    public private(set) var carryVertical = 0.0
    public private(set) var carryHorizontal = 0.0
    public var linesPerNotch: Int

    public init(linesPerNotch: Int = LinearScrollSettings.defaultLines) {
        self.linesPerNotch = min(max(linesPerNotch, LinearScrollSettings.linesRange.lowerBound), LinearScrollSettings.linesRange.upperBound)
    }

    public mutating func reset() {
        carryVertical = 0
        carryHorizontal = 0
    }

    public static func lines(forTicks t: Double, linesPerNotch n: Int) -> Double {
        guard t.isFinite, t != 0 else { return 0 }
        let v = min(abs(t), 1) * Double(n)
        return t < 0 ? -v : v
    }

    public mutating func apply(_ s: ScrollSample) -> ScrollSample {
        var out = s
        if s.vertical.hasMovement { out.vertical = convert(s.vertical, continuous: s.isContinuous, carry: &carryVertical) }
        if s.horizontal.hasMovement { out.horizontal = convert(s.horizontal, continuous: s.isContinuous, carry: &carryHorizontal) }
        return out
    }

    private func convert(_ d: ScrollAxisDelta, continuous: Bool, carry: inout Double) -> ScrollAxisDelta {
        let lines = Self.lines(forTicks: ScrollMath.ticks(d, continuous: continuous), linesPerNotch: linesPerNotch)
        if ScrollMath.opposes(carry, lines) { carry = 0 }
        let total = lines + carry
        let whole = total.rounded(.towardZero)
        carry = total - whole
        let n = Int64(whole)
        return ScrollAxisDelta(line: n, point: Int64(whole * ScrollMath.pointsPerLine), fixed: whole)
    }
}
