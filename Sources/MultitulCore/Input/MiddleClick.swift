import Foundation
import CoreGraphics

public struct TouchFrame: Equatable, Sendable {
    public var fingers: Int
    public var time: TimeInterval
    public var x: Float
    public var y: Float

    public init(fingers: Int, time: TimeInterval, x: Float = 0, y: Float = 0) {
        self.fingers = fingers
        self.time = time
        self.x = x
        self.y = y
    }
}

public protocol TouchSource: AnyObject {
    var onFrame: ((TouchFrame) -> Void)? { get set }
    func start() -> Bool
    func stop()
}

public protocol SystemGestureInfo: AnyObject {
    func threeFingerDragEnabled() -> Bool
}

public final class MiddleClickEngine {
    public static let staleFrameSeconds: TimeInterval = 0.6
    public static let maxHeldSeconds: TimeInterval = 3
    public static let tapMoveLimit: Float = 0.05
    public static let tapCooldownSeconds: TimeInterval = 0.2

    private struct Candidate {
        var start: TimeInterval
        var x: Float
        var y: Float
        var maxFingers: Int
        var moved: Float = 0
        var sawButton = false
    }

    private let lock = NSLock()
    private var settings: MiddleClickSettings
    private var systemDrag = false
    private var fingers = 0
    private var lastFrameAt: TimeInterval = -1000
    private var candidate: Candidate?
    private var lastTapAt: TimeInterval = -1000
    private var held = false
    private var heldSince: TimeInterval = 0

    public init(settings: MiddleClickSettings = MiddleClickSettings()) { self.settings = settings.sanitized }

    public func update(_ s: MiddleClickSettings) { lock.withLock { settings = s.sanitized } }

    public func setSystemDrag(_ on: Bool) { lock.withLock { systemDrag = on } }

    public var requiredFingers: Int { lock.withLock { systemDrag ? 4 : 3 } }

    public var isHeld: Bool { lock.withLock { held } }

    public var currentFingers: Int { lock.withLock { fingers } }

    public func reset() {
        lock.withLock {
            fingers = 0
            candidate = nil
            held = false
        }
    }

    public func ingest(_ f: TouchFrame) -> Bool {
        lock.withLock {
            fingers = f.fingers
            lastFrameAt = f.time
            guard settings.tapEnabled else { candidate = nil; return false }
            let need = systemDrag ? 4 : 3
            if var c = candidate {
                if f.fingers > 0 {
                    c.maxFingers = max(c.maxFingers, f.fingers)
                    c.moved = max(c.moved, abs(f.x - c.x), abs(f.y - c.y))
                    candidate = f.time - c.start > Double(settings.tapMaxMs) / 1000 ? nil : c
                    return false
                }
                candidate = nil
                let fast = f.time - c.start <= Double(settings.tapMaxMs) / 1000
                let cooled = f.time - lastTapAt >= Self.tapCooldownSeconds || f.time < lastTapAt
                guard c.maxFingers == need, !c.sawButton, c.moved <= Self.tapMoveLimit, fast, cooled else { return false }
                lastTapAt = f.time
                return true
            }
            if f.fingers == need { candidate = Candidate(start: f.time, x: f.x, y: f.y, maxFingers: f.fingers) }
            return false
        }
    }

    public func pressStarted(now: TimeInterval) -> Bool {
        lock.withLock {
            candidate?.sawButton = true
            if held, now - heldSince > Self.maxHeldSeconds { held = false }
            let need = systemDrag ? 4 : 3
            guard !held, fingers >= need, now - lastFrameAt <= Self.staleFrameSeconds else { return false }
            held = true
            heldSince = now
            return true
        }
    }

    public func pressEnded() -> Bool {
        lock.withLock {
            let was = held
            held = false
            return was
        }
    }
}

public final class MiddleClickStage {
    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]

    private let hub: EventTapHub
    private let engine: MiddleClickEngine
    private let mouse: MousePosting
    private let clock: () -> TimeInterval
    private var token: EventTapHub.Token?
    public private(set) var convertedCount = 0

    public init(hub: EventTapHub, engine: MiddleClickEngine, mouse: MousePosting, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hub = hub
        self.engine = engine
        self.mouse = mouse
        self.clock = clock
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.middleClick, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        switch type {
        case .leftMouseDown:
            guard engine.pressStarted(now: clock()) else { return .pass }
            convertedCount += 1
            mouse.post(button: 2, down: true, at: e.location, flags: e.flags)
            return .drop
        case .leftMouseDragged:
            return engine.isHeld ? .drop : .pass
        case .leftMouseUp:
            guard engine.pressEnded() else { return .pass }
            mouse.post(button: 2, down: false, at: e.location, flags: e.flags)
            return .drop
        default:
            return .pass
        }
    }
}

public final class MiddleClickService {
    private let source: TouchSource
    private let engine: MiddleClickEngine
    private let stage: MiddleClickStage
    private let mouse: MousePosting
    private let gesture: SystemGestureInfo
    private let dispatch: (@escaping () -> Void) -> Void
    public private(set) var deviceMissing = false
    public private(set) var tapCount = 0

    public init(hub: EventTapHub, source: TouchSource, mouse: MousePosting, gesture: SystemGestureInfo, settings: MiddleClickSettings = MiddleClickSettings(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                dispatch: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.source = source
        self.mouse = mouse
        self.gesture = gesture
        self.dispatch = dispatch
        engine = MiddleClickEngine(settings: settings)
        stage = MiddleClickStage(hub: hub, engine: engine, mouse: mouse, clock: clock)
    }

    public var isRunning: Bool { stage.isRunning }
    public var convertedCount: Int { stage.convertedCount }
    public var requiredFingers: Int { engine.requiredFingers }

    public func start() {
        refreshSystemGesture()
        source.onFrame = { [weak self] frame in self?.frame(frame) }
        deviceMissing = !source.start()
        stage.start()
    }

    public func stop() {
        stage.stop()
        source.stop()
        source.onFrame = nil
        engine.reset()
    }

    public func update(_ s: MiddleClickSettings) { engine.update(s) }

    public func refreshSystemGesture() { engine.setSystemDrag(gesture.threeFingerDragEnabled()) }

    private func frame(_ f: TouchFrame) {
        guard engine.ingest(f) else { return }
        dispatch { [weak self] in
            guard let self else { return }
            let p = mouse.pointerLocation()
            tapCount += 1
            mouse.post(button: 2, down: true, at: p, flags: [])
            mouse.post(button: 2, down: false, at: p, flags: [])
        }
    }
}
