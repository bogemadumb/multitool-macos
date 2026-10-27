import Foundation
import CoreGraphics

enum WindowEventTime {
    static func seconds(_ e: CGEvent) -> TimeInterval { TimeInterval(e.timestamp) / 1_000_000_000 }
}

public final class EdgeSnapStage {
    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    private let hub: EventTapHub
    private let tracker: EdgeDragTracker
    private let trusted: () -> Bool
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, tracker: EdgeDragTracker, trusted: @escaping () -> Bool = { true }) {
        self.hub = hub
        self.tracker = tracker
        self.trusted = trusted
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.edgeSnap, seesDropped: false, onReset: { [weak self] in self?.tracker.reset() }) { [weak self] type, e in
            self?.handle(type, e.location, WindowEventTime.seconds(e)) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        tracker.reset()
    }

    func handle(_ type: CGEventType, _ p: CGPoint, _ time: TimeInterval) -> EventTapAction {
        switch type {
        case .leftMouseDown:
            guard trusted() else { tracker.reset(); return .pass }
            tracker.mouseDown(at: p, time: time)
        case .leftMouseDragged: tracker.mouseDragged(to: p, time: time)
        case .leftMouseUp: tracker.mouseUp(at: p, time: time)
        default: break
        }
        return .pass
    }
}

public final class ModifierGestureStage {
    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    private let hub: EventTapHub
    private let driver: WindowDriving
    private let settings: () -> GestureSettings
    private let trusted: () -> Bool
    private var token: EventTapHub.Token?
    public private(set) var session: ModifierDragSession?

    public init(hub: EventTapHub, driver: WindowDriving, settings: @escaping () -> GestureSettings, trusted: @escaping () -> Bool = { true }) {
        self.hub = hub
        self.driver = driver
        self.settings = settings
        self.trusted = trusted
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.windowGesture, seesDropped: false, onReset: { [weak self] in self?.session = nil }) { [weak self] type, e in
            self?.handle(type, e.location, e.flags) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        session = nil
    }

    func handle(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags) -> EventTapAction {
        switch type {
        case .leftMouseDown:
            guard trusted() else { session = nil; return .pass }
            let s = settings()
            session = ModifierDragSession(driver: driver, at: p, flags: flags, settings: s, raise: s.raiseWindow)
            return session == nil ? .pass : .drop
        case .leftMouseDragged:
            guard let ses = session else { return .pass }
            ses.update(to: p)
            return .drop
        case .leftMouseUp:
            guard session != nil else { return .pass }
            session = nil
            return .drop
        default:
            return .pass
        }
    }
}

public final class WindowRingStage {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged]
    private let hub: EventTapHub
    private let driver: WindowDriving
    private let engine: WindowLayoutEngine
    private let preview: SnapPreviewing
    private let settings: () -> RingSettings
    private let trusted: () -> Bool
    private var token: EventTapHub.Token?
    public private(set) var session: RingSession?
    public private(set) var appliedCount = 0

    public init(hub: EventTapHub, driver: WindowDriving, engine: WindowLayoutEngine, preview: SnapPreviewing, settings: @escaping () -> RingSettings, trusted: @escaping () -> Bool = { true }) {
        self.hub = hub
        self.driver = driver
        self.engine = engine
        self.preview = preview
        self.settings = settings
        self.trusted = trusted
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.windowRing, seesDropped: false, onReset: { [weak self] in self?.cancel() }) { [weak self] type, e in
            self?.handle(type, code: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)), flags: e.flags, repeating: e.getIntegerValueField(.keyboardEventAutorepeat) != 0, at: e.location) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        cancel()
    }

    public func cancel() {
        guard session != nil else { return }
        session = nil
        preview.hide()
    }

    func handle(_ type: CGEventType, code: UInt32, flags: CGEventFlags, repeating: Bool, at p: CGPoint) -> EventTapAction {
        if session == nil, type != .keyDown { return .pass }
        let ring = settings()
        guard ring.enabled else { return .pass }
        let trigger = ring.trigger
        let mods = KeyStroke.modifiers(from: flags)
        switch type {
        case .keyDown:
            if session == nil, (code != trigger.keyCode || mods != trigger.modifiers || !trusted()) { return .pass }
            if let s = session {
                if code == Keys.escape { s.cancel(); finish(); return .drop }
                if code == Keys.returnKey || code == Keys.enterKey { s.forceMaximize(); showPreview(s.action, at: p); return .drop }
                return code == trigger.keyCode ? .drop : .pass
            }
            guard code == trigger.keyCode, mods == trigger.modifiers else { return .pass }
            if repeating { return .drop }
            session = RingSession(origin: p, window: driver.focusedWindow())
            return .drop
        case .keyUp:
            guard session != nil, code == trigger.keyCode else { return .pass }
            finish()
            return .drop
        case .flagsChanged:
            guard session != nil, mods & trigger.modifiers != trigger.modifiers else { return .pass }
            session?.cancel()
            finish()
            return .pass
        case .mouseMoved, .leftMouseDragged:
            guard let s = session else { return .pass }
            showPreview(s.update(to: p), at: p)
            return .pass
        default:
            return .pass
        }
    }

    private func showPreview(_ action: WindowLayoutAction?, at p: CGPoint) {
        guard let action, let r = engine.previewFrame(for: action, at: p) else { preview.hide(); return }
        preview.show(r.frame, display: r.display)
    }

    private func finish() {
        guard let s = session else { return }
        session = nil
        preview.hide()
        guard let action = s.finish(), let w = s.window else { return }
        engine.perform(action, on: w)
        appliedCount += 1
    }
}

public final class MaximizerStage {
    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
    private let hub: EventTapHub
    private let engine: MaximizerClickEngine
    private let trusted: () -> Bool
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: MaximizerClickEngine, trusted: @escaping () -> Bool = { true }) {
        self.hub = hub
        self.engine = engine
        self.trusted = trusted
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.zoomButton, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e.location, e.flags) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags) -> EventTapAction {
        switch type {
        case .leftMouseDown:
            guard trusted() else { engine.reset(); return .pass }
            return engine.mouseDown(at: p, flags: flags)
        case .leftMouseUp: return engine.mouseUp(at: p, flags: flags)
        default: return .pass
        }
    }
}

public final class DockClickStage {
    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    private let hub: EventTapHub
    private let engine: DockClickEngine
    private let trusted: () -> Bool
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: DockClickEngine, trusted: @escaping () -> Bool = { true }) {
        self.hub = hub
        self.engine = engine
        self.trusted = trusted
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.dockClick, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e.location, e.flags) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags) -> EventTapAction {
        switch type {
        case .leftMouseDown:
            guard trusted() else { engine.reset(); return .pass }
            return engine.mouseDown(at: p, flags: flags)
        case .leftMouseDragged: return engine.mouseDragged(to: p)
        case .leftMouseUp: return engine.mouseUp(at: p)
        default: return .pass
        }
    }
}
