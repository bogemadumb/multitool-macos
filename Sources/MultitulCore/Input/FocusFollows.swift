import Foundation
import CoreGraphics

public struct FocusWindowInfo: Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var bounds: CGRect
    public var layer: Int
    public var isOwn: Bool

    public init(pid: Int32, bundleID: String?, bounds: CGRect, layer: Int = 0, isOwn: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.bounds = bounds
        self.layer = layer
        self.isOwn = isOwn
    }
}

public protocol FocusFollowsDriver: AnyObject {
    func windowUnder(_ point: CGPoint) -> FocusWindowInfo?
    func frontmostPID() -> Int32?
    func focusedWindowBounds(pid: Int32) -> CGRect?
    func buttonsPressed() -> Bool
    func shortcutModifiersHeld() -> Bool
    func focus(_ window: FocusWindowInfo, at point: CGPoint, raise: Bool) -> Bool
}

public enum FocusSkip: Equatable {
    case noWindow, wrongLayer, excepted, own, buttonsPressed, modifiersHeld, alreadyFocused, focusUnknown
}

public enum FocusDecision: Equatable {
    case skip(FocusSkip)
    case activate(raise: Bool)
}

public enum FocusTick: Equatable {
    case idle
    case waiting
    case skipped(FocusSkip)
    case focused(raise: Bool)
    case failed
}

public enum FocusFollowsLogic {
    public static let appLayers = 0...3
    public static let boundsTolerance: CGFloat = 2

    public static func sameWindow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance && abs(a.minY - b.minY) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }

    public static func waitsForStop(_ s: FocusFollowsSettings) -> Bool { s.raise || s.waitForStop }

    public static func decide(settings: FocusFollowsSettings, target: FocusWindowInfo?, frontmostPID: Int32?, focusedBounds: CGRect?,
                              buttonsPressed: Bool, modifiersHeld: Bool) -> FocusDecision {
        guard let target else { return .skip(.noWindow) }
        guard appLayers.contains(target.layer) else { return .skip(.wrongLayer) }
        if target.isOwn { return .skip(.own) }
        if settings.exceptions.contains(target.bundleID) { return .skip(.excepted) }
        if buttonsPressed { return .skip(.buttonsPressed) }
        if modifiersHeld { return .skip(.modifiersHeld) }
        if target.pid == frontmostPID {
            guard let focusedBounds else { return .skip(.focusUnknown) }
            if sameWindow(focusedBounds, target.bounds) { return .skip(.alreadyFocused) }
        }
        return .activate(raise: settings.raise)
    }
}

public final class FocusFollowsEngine {
    public var settings: FocusFollowsSettings
    private let driver: FocusFollowsDriver
    private var pending = false
    private var point = CGPoint.zero
    private var lastMoveAt: TimeInterval = 0
    private var observed: FocusWindowInfo?
    private var observedSince: TimeInterval = 0
    public private(set) var focusCount = 0

    public init(settings: FocusFollowsSettings, driver: FocusFollowsDriver) {
        self.settings = settings.sanitized
        self.driver = driver
    }

    public var hasPending: Bool { pending }

    public func reset() {
        pending = false
        observed = nil
    }

    public func pointerMoved(to p: CGPoint, at t: TimeInterval, dragging: Bool) {
        if dragging {
            reset()
            return
        }
        point = p
        lastMoveAt = t
        pending = true
    }

    public func tick(now: TimeInterval) -> FocusTick {
        guard pending else { return .idle }
        let delay = Double(settings.delayMs) / 1000
        let target = driver.windowUnder(point)
        let since: TimeInterval
        if FocusFollowsLogic.waitsForStop(settings) {
            since = lastMoveAt
        } else {
            if observed != target {
                observed = target
                observedSince = now
                return .waiting
            }
            since = observedSince
        }
        guard now - since >= delay else { return .waiting }
        pending = false
        observed = nil
        let decision = FocusFollowsLogic.decide(
            settings: settings, target: target, frontmostPID: driver.frontmostPID(),
            focusedBounds: target.flatMap { driver.focusedWindowBounds(pid: $0.pid) },
            buttonsPressed: driver.buttonsPressed(), modifiersHeld: driver.shortcutModifiersHeld())
        switch decision {
        case .skip(let reason):
            return .skipped(reason)
        case .activate(let raise):
            guard let target, driver.focus(target, at: point, raise: raise) else { return .failed }
            focusCount += 1
            return .focused(raise: raise)
        }
    }
}
