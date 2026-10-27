import Foundation
import CoreGraphics

public struct MaximizerSettings: Equatable, Sendable {
    public static let insetRange = 0...64
    public static let suggestedExcluded = [
        "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc", "com.valvesoftware.steam",
        "com.parallels.desktop.console", "com.vmware.fusion", "org.virtualbox.app.VirtualBoxVM"
    ]

    public var excluded = AppExceptionList(MaximizerSettings.suggestedExcluded)
    public var inset = 0
    public var toggleRestores = true
    public init() {}

    public var sanitized: MaximizerSettings {
        var s = self
        s.inset = min(max(inset, Self.insetRange.lowerBound), Self.insetRange.upperBound)
        return s
    }
}

public enum MaximizerDecision: Equatable, Sendable {
    case passThrough
    case maximize(CGRect)
    case restore(CGRect)
}

public final class MaximizerBrain {
    public static let minimumRestorableSide: CGFloat = 80
    public private(set) var originals: [Int: CGRect] = [:]

    public init() {}

    public func decide(key: Int, bundleID: String?, frame: CGRect, modifiers: GestureModifiers, isFullScreen: Bool, displays: [WndDisplay], settings: MaximizerSettings) -> MaximizerDecision {
        let s = settings.sanitized
        guard !isFullScreen, modifiers.isEmpty, !s.excluded.contains(bundleID), let idx = DisplayMap.index(containing: frame, in: displays) else { return .passThrough }
        let display = displays[idx]
        let area = WindowGeometry.usableArea(display.visible, gaps: WindowGaps(window: 0, screen: s.inset))
        let target = WindowGeometry.snapped(minX: area.minX, minY: area.minY, maxX: area.maxX, maxY: area.maxY)
        if WindowGeometry.approxEqual(frame, target) {
            guard s.toggleRestores, let o = originals[key], o.width > Self.minimumRestorableSide, o.height > Self.minimumRestorableSide else { return .passThrough }
            return .restore(DisplayMap.reposition(o, displays: displays))
        }
        originals[key] = frame
        return .maximize(target)
    }

    public func applied(_ decision: MaximizerDecision, key: Int, success: Bool) {
        switch decision {
        case .restore: if success { originals[key] = nil }
        case .maximize: if !success { originals[key] = nil }
        case .passThrough: break
        }
    }

    public func forget(_ key: Int) { originals[key] = nil }
}

public struct ZoomTarget: Equatable, Sendable {
    public var window: WndWindow
    public var frame: CGRect
    public var isFullScreen: Bool
    public var button: CGRect

    public init(window: WndWindow, frame: CGRect, isFullScreen: Bool, button: CGRect) {
        self.window = window
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.button = button
    }
}

public protocol ZoomButtonProbing: AnyObject {
    func target(at point: CGPoint) -> ZoomTarget?
    func pressNative(_ target: ZoomTarget)
}

public final class MaximizerClickEngine {
    public static let clickTolerance: CGFloat = 6
    public private(set) var maximizedCount = 0
    public private(set) var restoredCount = 0
    private let probe: ZoomButtonProbing
    private let driver: WindowDriving
    private let brain: MaximizerBrain
    private let settingsProvider: () -> MaximizerSettings
    private var pending: ZoomTarget?
    private var downPoint = CGPoint.zero

    public init(probe: ZoomButtonProbing, driver: WindowDriving, brain: MaximizerBrain = MaximizerBrain(), settings: @escaping () -> MaximizerSettings) {
        self.probe = probe
        self.driver = driver
        self.brain = brain
        self.settingsProvider = settings
    }

    public func reset() { pending = nil }

    public func mouseDown(at p: CGPoint, flags: CGEventFlags) -> EventTapAction {
        pending = nil
        guard GestureModifiers(flags: flags).isEmpty, let t = probe.target(at: p), !t.isFullScreen, !settingsProvider().excluded.contains(t.window.bundleID) else { return .pass }
        pending = t
        downPoint = p
        return .drop
    }

    public func mouseUp(at p: CGPoint, flags: CGEventFlags) -> EventTapAction {
        guard let t = pending else { return .pass }
        pending = nil
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) <= Self.clickTolerance, t.button.insetBy(dx: -Self.clickTolerance, dy: -Self.clickTolerance).contains(p) else {
            probe.pressNative(t)
            return .drop
        }
        guard let fresh = probe.target(at: p), fresh.window == t.window, let frame = driver.frame(of: fresh.window) else {
            probe.pressNative(t)
            return .drop
        }
        let decision = brain.decide(key: fresh.window.key, bundleID: fresh.window.bundleID, frame: frame, modifiers: GestureModifiers(flags: flags), isFullScreen: fresh.isFullScreen, displays: driver.displays(), settings: settingsProvider())
        switch decision {
        case .passThrough:
            probe.pressNative(t)
        case .maximize(let r), .restore(let r):
            let ok = driver.setFrame(r, of: fresh.window)
            brain.applied(decision, key: fresh.window.key, success: ok)
            if ok {
                if case .maximize = decision { maximizedCount += 1 } else { restoredCount += 1 }
            } else {
                probe.pressNative(t)
            }
        }
        return .drop
    }
}
