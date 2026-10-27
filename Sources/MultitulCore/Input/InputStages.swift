import Foundation
import CoreGraphics

public enum InputPriority {
    public static let debounce = 500
    public static let superKey = 450
    public static let middleClick = 420
    public static let buttonShortcuts = 410
    public static let zoom = 390
    public static let horizontal = 400
    public static let inverter = 300
    public static let navigation = 360
    public static let quitProtection = 350
    public static let snippets = 250
    public static let linear = 200
    public static let smooth = 100
    public static let focus = 0
}

public class ScrollStage {
    let hub: EventTapHub
    let gate: ExceptionGate
    let clock: () -> TimeInterval
    private var classifier = WheelClassifier()
    private var token: EventTapHub.Token?
    private let priority: Int

    init(hub: EventTapHub, gate: ExceptionGate, priority: Int, clock: @escaping () -> TimeInterval) {
        self.hub = hub
        self.gate = gate
        self.priority = priority
        self.clock = clock
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: [.scrollWheel], priority: priority, seesDropped: false, onReset: { [weak self] in self?.reset() }) { [weak self] _, e in
            self?.handle(e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        reset()
    }

    func reset() { classifier.reset() }

    func handle(_ e: CGEvent) -> EventTapAction {
        let s = CGScrollBridge.read(e)
        guard s.hasMovement, classifier.isMouseWheel(s, now: clock()) else { return .pass }
        guard !gate.isExcepted(at: e.location) else { return .pass }
        return process(s, e)
    }

    func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction { .pass }
}

public final class HorizontalScrollStage: ScrollStage {
    public var modifier: ScrollModifierKey

    public init(hub: EventTapHub, gate: ExceptionGate, modifier: ScrollModifierKey = .shift, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.modifier = modifier
        super.init(hub: hub, gate: gate, priority: InputPriority.horizontal, clock: clock)
    }

    override func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction {
        guard let out = ScrollMath.redirectToHorizontal(s, modifier: modifier) else { return .pass }
        CGScrollBridge.write(out, to: e)
        return .modified
    }
}

public final class ScrollInverterStage: ScrollStage {
    public var vertical: Bool
    public var horizontal: Bool

    public init(hub: EventTapHub, gate: ExceptionGate, vertical: Bool = true, horizontal: Bool = false, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.vertical = vertical
        self.horizontal = horizontal
        super.init(hub: hub, gate: gate, priority: InputPriority.inverter, clock: clock)
    }

    override func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction {
        let out = ScrollMath.inverted(s, invertVertical: vertical, invertHorizontal: horizontal)
        guard out != s else { return .pass }
        CGScrollBridge.write(out, to: e)
        return .modified
    }
}

public final class LinearScrollStage: ScrollStage {
    public private(set) var linear: LinearScroll

    public init(hub: EventTapHub, gate: ExceptionGate, linesPerNotch: Int = LinearScrollSettings.defaultLines, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        linear = LinearScroll(linesPerNotch: linesPerNotch)
        super.init(hub: hub, gate: gate, priority: InputPriority.linear, clock: clock)
    }

    public var linesPerNotch: Int {
        get { linear.linesPerNotch }
        set { linear = LinearScroll(linesPerNotch: newValue) }
    }

    override func reset() {
        super.reset()
        linear.reset()
    }

    override func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction {
        let out = linear.apply(s)
        CGScrollBridge.write(out, to: e)
        return .modified
    }
}

public final class SmoothScrollStage: ScrollStage {
    public var step: Int
    public var linearLines: () -> Int?
    public let runner: SmoothScrollRunner

    public init(hub: EventTapHub, gate: ExceptionGate, runner: SmoothScrollRunner, step: Int = SmoothScrollSettings.defaultStep,
                linearLines: @escaping () -> Int? = { nil }, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.runner = runner
        self.step = step
        self.linearLines = linearLines
        super.init(hub: hub, gate: gate, priority: InputPriority.smooth, clock: clock)
    }

    override func reset() {
        super.reset()
        runner.cancel()
    }

    override func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction {
        let px = SmoothInput.pixels(s, step: step, linearLines: linearLines(), shiftRedirect: true)
        guard px.vertical != 0 || px.horizontal != 0 else { return .pass }
        runner.enqueue(vertical: px.vertical, horizontal: px.horizontal, flags: s.flags)
        return .drop
    }
}

public final class ClickDebounceStage {
    private let hub: EventTapHub
    private var token: EventTapHub.Token?
    private var filter: ClickDebounce
    public private(set) var settings: ClickDebounceSettings

    public static let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                              .otherMouseDown, .otherMouseUp, .otherMouseDragged]

    public init(hub: EventTapHub, settings: ClickDebounceSettings = ClickDebounceSettings()) {
        self.hub = hub
        self.settings = settings.sanitized
        self.filter = ClickDebounce(windowMs: self.settings.windowMs)
    }

    public var isRunning: Bool { token != nil }
    public var suppressedCount: Int { filter.suppressedCount }

    public func update(_ s: ClickDebounceSettings) {
        settings = s.sanitized
        filter.windowSeconds = Double(settings.windowMs) / 1000
    }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.debounce, seesDropped: false, onReset: { [weak self] in self?.filter.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        filter.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        guard let r = ClickDebounce.resolve(type: type, buttonNumber: e.getIntegerValueField(.mouseEventButtonNumber)), settings.covers(button: r.button) else { return .pass }
        return filter.shouldSuppress(button: r.button, phase: r.phase, at: EventTime.seconds(of: e)) ? .drop : .pass
    }
}

public final class KeyDebounceStage {
    private let hub: EventTapHub
    private var token: EventTapHub.Token?
    private var filter: KeyDebounce
    private let frontmost: () -> String?

    public init(hub: EventTapHub, settings: KeyDebounceSettings = KeyDebounceSettings(), frontmost: @escaping () -> String? = { nil }) {
        self.hub = hub
        self.filter = KeyDebounce(settings: settings.sanitized)
        self.frontmost = frontmost
    }

    public var isRunning: Bool { token != nil }
    public var suppressedCount: Int { filter.suppressedCount }
    public var settings: KeyDebounceSettings { filter.settings }

    public func update(_ s: KeyDebounceSettings) { filter.settings = s.sanitized }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: [.keyDown, .keyUp], priority: InputPriority.debounce, seesDropped: false, onReset: { [weak self] in self?.filter.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        filter.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let repeating = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let drop = filter.shouldSuppress(keyCode: code, phase: type == .keyDown ? .down : .up, isAutoRepeat: repeating,
                                         at: EventTime.seconds(of: e), frontmostBundleID: frontmost())
        return drop ? .drop : .pass
    }
}

public final class FocusFollowsStage {
    private let hub: EventTapHub
    private var token: EventTapHub.Token?
    private let engine: FocusFollowsEngine
    private let clock: () -> TimeInterval
    public var onMove: (() -> Void)?

    public init(hub: EventTapHub, engine: FocusFollowsEngine, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hub = hub
        self.engine = engine
        self.clock = clock
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], priority: InputPriority.focus,
                              onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            guard let self else { return .pass }
            engine.pointerMoved(to: e.location, at: clock(), dragging: type != .mouseMoved)
            if engine.hasPending { onMove?() }
            return .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }
}
