import Foundation
import CoreGraphics

public enum IslScrollPhase: String, Sendable {
    case none, began, changed, ended, momentum
}

public struct IslScrollSample: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var precise: Bool
    public var phase: IslScrollPhase
    public var time: TimeInterval
    public var invertedFromDevice: Bool

    public init(dx: Double, dy: Double, precise: Bool = true, phase: IslScrollPhase = .changed, time: TimeInterval, invertedFromDevice: Bool = true) {
        self.dx = dx
        self.dy = dy
        self.precise = precise
        self.phase = phase
        self.time = time
        self.invertedFromDevice = invertedFromDevice
    }

    // Finger space: +x right, +y down; wheel ticks are scaled to points.
    public var finger: CGVector {
        let scale = precise ? 1.0 : IslGestureConfig.wheelScale
        let fx = (invertedFromDevice ? dx : -dx) * scale
        let fy = (invertedFromDevice ? dy : -dy) * scale
        return CGVector(dx: fx, dy: fy)
    }
}

public struct IslGestureConfig: Equatable, Sendable {
    public static let wheelScale = 12.0

    public var lockDistance = 6.0
    public var axisRatio = 1.25
    public var verticalFire = 36.0
    public var horizontalFire = 60.0
    public var idleGap = 0.35

    public init() {}
}

public enum IslGestureZone: String, Sendable {
    case notch, topRow, body

    public static func zone(for point: CGPoint, state: IslState, frames: IslFrames) -> IslGestureZone {
        switch state {
        case .closed, .peek: .notch
        case .open: point.y >= frames.open.maxY - frames.notch.height ? .topRow : .body
        }
    }
}

public struct IslGestureContext: Equatable, Sendable {
    public var state: IslState
    public var zone: IslGestureZone
    public var musicActive: Bool
    public var musicIsCurrent: Bool
    public var swipe: IslSwipeAction
    public var openOnScroll: Bool
    public var closeOnScrollUp: Bool

    public init(state: IslState, zone: IslGestureZone, musicActive: Bool = false, musicIsCurrent: Bool = false, swipe: IslSwipeAction = .track,
                openOnScroll: Bool = true, closeOnScrollUp: Bool = true) {
        self.state = state
        self.zone = zone
        self.musicActive = musicActive
        self.musicIsCurrent = musicIsCurrent
        self.swipe = swipe
        self.openOnScroll = openOnScroll
        self.closeOnScrollUp = closeOnScrollUp
    }
}

public enum IslGestureIntent: Equatable, Sendable {
    case open, close, nextTrack, previousTrack, nextSection, previousSection
}

public struct IslGestureOutput: Equatable, Sendable {
    public var intent: IslGestureIntent?
    public var consumed: Bool

    public static let passThrough = IslGestureOutput(intent: nil, consumed: false)
}

public struct IslGestureClassifier: Sendable {
    public var config: IslGestureConfig
    private var ax = 0.0
    private var ay = 0.0
    private var axis: Axis?
    private var fired = false
    private var lastTime: TimeInterval = -.infinity
    private var inGesture = false

    private enum Axis { case horizontal, vertical }

    public init(config: IslGestureConfig = IslGestureConfig()) { self.config = config }

    public mutating func reset() {
        ax = 0
        ay = 0
        axis = nil
        fired = false
        inGesture = false
    }

    public mutating func feed(_ s: IslScrollSample, context: IslGestureContext) -> IslGestureOutput {
        let startsNew = s.phase == .began || (s.phase == .none && s.time - lastTime > config.idleGap) || (!inGesture && s.phase != .momentum && s.phase != .ended)
        if startsNew { reset(); inGesture = true }
        let idle = s.time - lastTime > config.idleGap
        lastTime = s.time
        if s.phase == .ended {
            let out = IslGestureOutput(intent: nil, consumed: fired && axis == .horizontal)
            reset()
            return out
        }
        if s.phase == .momentum { return IslGestureOutput(intent: nil, consumed: fired && axis == .horizontal) }
        if idle && !startsNew { reset(); inGesture = true }

        let v = s.finger
        ax += Double(v.dx)
        ay += Double(v.dy)

        if axis == nil, max(abs(ax), abs(ay)) >= config.lockDistance {
            if abs(ax) > abs(ay) * config.axisRatio { axis = .horizontal } else if abs(ay) > abs(ax) * config.axisRatio { axis = .vertical }
        }
        guard let axis else { return .passThrough }

        switch axis {
        case .vertical:
            guard !fired else { return .passThrough }
            if ay >= config.verticalFire {
                guard context.state != .open, context.openOnScroll else { return .passThrough }
                fired = true
                return IslGestureOutput(intent: .open, consumed: true)
            }
            if ay <= -config.verticalFire {
                guard context.state == .open, context.zone == .topRow, context.closeOnScrollUp else { return .passThrough }
                fired = true
                return IslGestureOutput(intent: .close, consumed: true)
            }
            return IslGestureOutput(intent: nil, consumed: context.state != .open)
        case .horizontal:
            guard let handler = horizontalHandler(context) else { return .passThrough }
            if fired { return IslGestureOutput(intent: nil, consumed: true) }
            if abs(ax) >= config.horizontalFire {
                fired = true
                return IslGestureOutput(intent: ax < 0 ? handler.next : handler.previous, consumed: true)
            }
            return IslGestureOutput(intent: nil, consumed: true)
        }
    }

    private func horizontalHandler(_ c: IslGestureContext) -> (next: IslGestureIntent, previous: IslGestureIntent)? {
        switch c.state {
        case .closed, .peek:
            return c.musicActive && c.swipe == .track ? (.nextTrack, .previousTrack) : nil
        case .open:
            if c.musicIsCurrent && c.swipe == .track { return (.nextTrack, .previousTrack) }
            return (.nextSection, .previousSection)
        }
    }
}
