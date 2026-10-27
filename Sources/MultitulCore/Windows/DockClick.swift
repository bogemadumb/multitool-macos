import Foundation
import CoreGraphics

public enum DockClickMode: String, CaseIterable, Sendable {
    case off, minimize, hide

    public var title: String {
        switch self {
        case .off: "Ничего"
        case .minimize: "Свернуть окна (второй клик возвращает)"
        case .hide: "Спрятать приложение"
        }
    }
}

public struct DockClickSettings: Equatable, Sendable {
    public var mode = DockClickMode.minimize
    public var cycleWindows = false
    public var exceptions = AppExceptionList()
    public init() {}
}

public struct DockTile: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

public struct DockAppState: Equatable, Sendable {
    public var isFrontmost: Bool
    public var isHidden: Bool
    public var visibleWindows: Int
    public var minimizedWindows: Int

    public init(isFrontmost: Bool, isHidden: Bool = false, visibleWindows: Int, minimizedWindows: Int = 0) {
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.visibleWindows = visibleWindows
        self.minimizedWindows = minimizedWindows
    }
}

public enum DockClickAction: Equatable, Sendable {
    case passThrough
    case swallow
    case minimizeAll
    case restoreAll
    case hide
    case cycleNext
}

public final class DockClickBrain {
    public static let repeatGap: TimeInterval = 0.25
    public static let toggleIntentWindow: TimeInterval = 1.5
    public static let dragSlop: CGFloat = 6

    private var last: [Int32: (time: TimeInterval, action: DockClickAction)] = [:]

    public init() {}

    public func reset() { last.removeAll() }

    public func decide(tile: DockTile, state: DockAppState, modifiers: GestureModifiers, settings: DockClickSettings, now: TimeInterval) -> DockClickAction {
        guard modifiers.isEmpty, state.isFrontmost, !state.isHidden else { return .passThrough }
        if settings.exceptions.contains(tile.bundleID) { return .passThrough }
        if let prev = last[tile.pid], now >= prev.time {
            let dt = now - prev.time
            if dt < Self.repeatGap { return .swallow }
            if dt < Self.toggleIntentWindow {
                if prev.action == .minimizeAll { return record(tile.pid, .restoreAll, now) }
                if prev.action == .restoreAll, settings.mode == .minimize { return record(tile.pid, .minimizeAll, now) }
            }
        }
        if state.visibleWindows == 0 {
            return state.minimizedWindows > 0 ? record(tile.pid, .restoreAll, now) : .passThrough
        }
        if settings.cycleWindows, state.visibleWindows >= 2 { return record(tile.pid, .cycleNext, now) }
        switch settings.mode {
        case .off: return .passThrough
        case .minimize: return record(tile.pid, .minimizeAll, now)
        case .hide: return record(tile.pid, .hide, now)
        }
    }

    private func record(_ pid: Int32, _ action: DockClickAction, _ now: TimeInterval) -> DockClickAction {
        last[pid] = (now, action)
        return action
    }

    public static func isDrag(from origin: CGPoint, to p: CGPoint) -> Bool {
        hypot(p.x - origin.x, p.y - origin.y) > dragSlop
    }

    public static func nextWindowIndex(focused: Int?, count: Int) -> Int? {
        guard count >= 2 else { return nil }
        guard let f = focused, (0..<count).contains(f) else { return 0 }
        return (f + 1) % count
    }
}

public protocol DockClickDriving: AnyObject {
    func tile(at point: CGPoint) -> DockTile?
    func state(of tile: DockTile) -> DockAppState
    func perform(_ action: DockClickAction, on tile: DockTile)
    func replayMouseDown(at point: CGPoint)
}

public final class DockClickEngine {
    public private(set) var handledCount = 0
    private let driver: DockClickDriving
    private let brain: DockClickBrain
    private let settingsProvider: () -> DockClickSettings
    private let clock: () -> TimeInterval
    private var pendingTile: DockTile?
    private var pendingAction = DockClickAction.passThrough
    private var downPoint = CGPoint.zero
    private var replayed = false

    public init(driver: DockClickDriving, brain: DockClickBrain = DockClickBrain(), settings: @escaping () -> DockClickSettings, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver
        self.brain = brain
        self.settingsProvider = settings
        self.clock = clock
    }

    public func reset() {
        pendingTile = nil
        replayed = false
    }

    public func mouseDown(at p: CGPoint, flags: CGEventFlags) -> EventTapAction {
        reset()
        guard let tile = driver.tile(at: p) else { return .pass }
        let action = brain.decide(tile: tile, state: driver.state(of: tile), modifiers: GestureModifiers(flags: flags), settings: settingsProvider(), now: clock())
        guard action != .passThrough else { return .pass }
        pendingTile = tile
        pendingAction = action
        downPoint = p
        return .drop
    }

    public func mouseDragged(to p: CGPoint) -> EventTapAction {
        guard pendingTile != nil else { return .pass }
        if !replayed, DockClickBrain.isDrag(from: downPoint, to: p) {
            replayed = true
            driver.replayMouseDown(at: downPoint)
        }
        return replayed ? .pass : .drop
    }

    public func mouseUp(at p: CGPoint) -> EventTapAction {
        guard let tile = pendingTile else { return .pass }
        defer { reset() }
        if replayed { return .pass }
        if pendingAction != .swallow {
            driver.perform(pendingAction, on: tile)
            handledCount += 1
        }
        return .drop
    }
}
