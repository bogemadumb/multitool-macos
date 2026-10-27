import Foundation
import CoreGraphics

public struct MouseNavMapping: Equatable, Sendable {
    public var back: KeyCombo?
    public var forward: KeyCombo?

    public init(back: KeyCombo?, forward: KeyCombo?) {
        self.back = back
        self.forward = forward
    }
}

public enum MouseNavDefaults {
    private static let cmd = KeyCombo.cmd
    public static let standard = MouseNavMapping(back: KeyCombo(keyCode: Keys.leftBracket, modifiers: cmd), forward: KeyCombo(keyCode: Keys.rightBracket, modifiers: cmd))

    public static let compatible: [MouseNavRule] = [
        MouseNavRule(pattern: "com.apple.finder", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.apple.Safari", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.apple.SafariTechnologyPreview", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.google.Chrome*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "org.chromium.Chromium", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "org.mozilla.*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.microsoft.edgemac*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.brave.Browser*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "company.thebrowser.*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.operasoftware.*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.vivaldi.Vivaldi", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "ru.yandex.desktop.yandex-browser", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.kagi.kagimacOS", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.jetbrains.*", back: standard.back, forward: standard.forward),
        MouseNavRule(pattern: "com.apple.dt.Xcode", back: KeyCombo(keyCode: Keys.left, modifiers: KeyCombo.ctrl | cmd), forward: KeyCombo(keyCode: Keys.right, modifiers: KeyCombo.ctrl | cmd)),
        MouseNavRule(pattern: "com.microsoft.VSCode*", back: KeyCombo(keyCode: Keys.minus, modifiers: KeyCombo.ctrl), forward: KeyCombo(keyCode: Keys.minus, modifiers: KeyCombo.ctrl | KeyCombo.shift)),
        MouseNavRule(pattern: "com.todesktop.*", back: KeyCombo(keyCode: Keys.minus, modifiers: KeyCombo.ctrl), forward: KeyCombo(keyCode: Keys.minus, modifiers: KeyCombo.ctrl | KeyCombo.shift))
    ]

    public static func mapping(for bundleID: String?, settings: MouseNavigationSettings) -> MouseNavMapping? {
        if settings.exceptions.contains(bundleID) { return nil }
        for r in settings.rules where AppExceptionList([r.pattern]).contains(bundleID) {
            return MouseNavMapping(back: r.back, forward: r.forward)
        }
        for r in compatible where AppExceptionList([r.pattern]).contains(bundleID) {
            return MouseNavMapping(back: r.back, forward: r.forward)
        }
        return settings.scope == .allApps ? standard : nil
    }
}

public final class MouseNavigationStage {
    public static let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
    public static let backButton: Int64 = 3
    public static let forwardButton: Int64 = 4

    private let hub: EventTapHub
    private let keys: KeyPosting
    private let frontmost: FrontmostAppProviding
    private var token: EventTapHub.Token?
    private var swallowed = Set<Int64>()
    public var settings: MouseNavigationSettings
    public private(set) var handledCount = 0

    public init(hub: EventTapHub, keys: KeyPosting, frontmost: FrontmostAppProviding, settings: MouseNavigationSettings = MouseNavigationSettings()) {
        self.hub = hub
        self.keys = keys
        self.frontmost = frontmost
        self.settings = settings
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.navigation, seesDropped: false, onReset: { [weak self] in self?.swallowed.removeAll() }) { [weak self] type, e in
            self?.handle(type, button: e.getIntegerValueField(.mouseEventButtonNumber)) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        swallowed.removeAll()
    }

    func handle(_ type: CGEventType, button: Int64) -> EventTapAction {
        guard button == Self.backButton || button == Self.forwardButton else { return .pass }
        switch type {
        case .otherMouseDown:
            guard let mapping = MouseNavDefaults.mapping(for: frontmost.frontmost()?.bundleID, settings: settings) else { return .pass }
            let isBack = (button == Self.backButton) != settings.swapButtons
            guard let combo = isBack ? mapping.back : mapping.forward else { return .pass }
            swallowed.insert(button)
            handledCount += 1
            keys.post(keyCode: combo.keyCode, flags: combo.cgFlags)
            return .drop
        case .otherMouseUp:
            return swallowed.remove(button) != nil ? .drop : .pass
        case .otherMouseDragged:
            return swallowed.contains(button) ? .drop : .pass
        default:
            return .pass
        }
    }
}

public final class ButtonShortcutEngine {
    private struct Active {
        var binding: ButtonBinding?
        var origin: CGPoint
        var flags: CGEventFlags
        var dx = 0.0
        var dy = 0.0
        var fired = false
        var consumed = false
        var holdTimer: CancelHandle?
    }

    private struct PendingClick {
        var timer: CancelHandle
    }

    public var settings: ButtonShortcutsSettings
    public var onLearn: ((ButtonTrigger) -> Void)?
    public private(set) var firedCount = 0
    private var active: [Int64: Active] = [:]
    private var pending: [Int64: PendingClick] = [:]
    private var lastScroll: [ButtonTrigger: TimeInterval] = [:]
    private let keys: KeyPosting
    private let mouse: MousePosting
    private let timers: TimerScheduling
    private let symbolic: SymbolicHotKeyPosting?
    private let frontmostBundle: () -> String?

    public init(settings: ButtonShortcutsSettings = ButtonShortcutsSettings(), keys: KeyPosting, mouse: MousePosting, timers: TimerScheduling = LiveTimerScheduler(),
                symbolic: SymbolicHotKeyPosting? = nil, frontmostBundle: @escaping () -> String?) {
        self.settings = settings.sanitized
        self.keys = keys
        self.mouse = mouse
        self.timers = timers
        self.symbolic = symbolic
        self.frontmostBundle = frontmostBundle
    }

    public func reset() {
        for a in active.values { a.holdTimer?.cancel() }
        for p in pending.values { p.timer.cancel() }
        active.removeAll()
        pending.removeAll()
        lastScroll.removeAll()
    }

    public var holdsButton: Bool { !active.isEmpty }

    func perform(_ action: ButtonAction, at point: CGPoint, flags: CGEventFlags) {
        switch action {
        case .none:
            return
        case .middleClick:
            mouse.post(button: 2, down: true, at: point, flags: flags)
            mouse.post(button: 2, down: false, at: point, flags: flags)
        case .showDesktop, .launchpad:
            if let id = action.symbolicHotKeyID, symbolic?.post(id) == true {
                break
            }
            guard let c = action.keyCombo else { return }
            keys.post(keyCode: c.keyCode, flags: c.cgFlags)
        default:
            guard let c = action.keyCombo else { return }
            keys.post(keyCode: c.keyCode, flags: c.cgFlags)
        }
        firedCount += 1
    }

    private func fireClick(_ b: ButtonBinding, button: Int64, origin: CGPoint, flags: CGEventFlags, release: CGPoint) {
        if b.click == .none {
            mouse.post(button: button, down: true, at: origin, flags: flags)
            mouse.post(button: button, down: false, at: release, flags: flags)
        } else {
            perform(b.click, at: origin, flags: flags)
        }
    }

    public func buttonDown(_ button: Int64, at point: CGPoint, flags: CGEventFlags) -> EventTapAction {
        guard button >= 2 else { return .pass }
        if let learn = onLearn {
            onLearn = nil
            active[button] = Active(binding: nil, origin: point, flags: flags)
            learn(.button(button))
            return .drop
        }
        if let p = pending.removeValue(forKey: button) {
            p.timer.cancel()
            if let b = settings.binding(for: .button(button)), b.doubleClick != .none {
                perform(b.doubleClick, at: point, flags: flags)
                var a = Active(binding: b, origin: point, flags: flags)
                a.consumed = true
                active[button] = a
                return .drop
            }
        }
        guard !settings.exceptions.contains(frontmostBundle()), let b = settings.binding(for: .button(button)) else { return .pass }
        let deferred = b.hold != .none || b.doubleClick != .none
        if !b.gesture && !deferred && b.click == .none { return .pass }
        var a = Active(binding: b, origin: point, flags: flags)
        if b.hold != .none {
            a.holdTimer = timers.schedule(after: Double(settings.holdMs) / 1000) { [weak self] in self?.holdElapsed(button) }
        }
        active[button] = a
        if !b.gesture && !deferred { perform(b.click, at: point, flags: flags) }
        return .drop
    }

    private func holdElapsed(_ button: Int64) {
        guard var a = active[button], let b = a.binding, !a.fired, !a.consumed else { return }
        a.consumed = true
        a.holdTimer = nil
        active[button] = a
        perform(b.hold, at: a.origin, flags: a.flags)
    }

    public func buttonDragged(_ button: Int64, dx: Double, dy: Double) -> EventTapAction {
        guard var a = active[button] else { return .pass }
        guard let b = a.binding, b.gesture, !a.fired, !a.consumed else { return .drop }
        a.dx += dx
        a.dy += dy
        let threshold = Double(settings.gestureThreshold)
        if max(abs(a.dx), abs(a.dy)) >= threshold {
            a.fired = true
            a.holdTimer?.cancel()
            a.holdTimer = nil
            perform(Self.gestureAction(dx: a.dx, dy: a.dy), at: a.origin, flags: a.flags)
        }
        active[button] = a
        return .drop
    }

    public func buttonUp(_ button: Int64, at point: CGPoint) -> EventTapAction {
        guard let a = active.removeValue(forKey: button) else { return .pass }
        a.holdTimer?.cancel()
        guard let b = a.binding, !a.fired, !a.consumed else { return .drop }
        let deferred = b.hold != .none || b.doubleClick != .none
        guard b.gesture || deferred else { return .drop }
        if b.doubleClick != .none {
            let window = Double(settings.doubleMs) / 1000
            let origin = a.origin
            let flags = a.flags
            pending[button] = PendingClick(timer: timers.schedule(after: window) { [weak self] in
                guard let self else { return }
                pending.removeValue(forKey: button)
                fireClick(b, button: button, origin: origin, flags: flags, release: point)
            })
        } else {
            fireClick(b, button: button, origin: a.origin, flags: a.flags, release: point)
        }
        return .drop
    }

    public func horizontalScroll(delta: Int64, at time: TimeInterval, location: CGPoint, flags: CGEventFlags) -> EventTapAction {
        guard delta != 0 else { return .pass }
        let trigger: ButtonTrigger = delta > 0 ? .scrollLeft : .scrollRight
        if let learn = onLearn {
            onLearn = nil
            learn(trigger)
            return .drop
        }
        guard !settings.exceptions.contains(frontmostBundle()), let b = settings.binding(for: trigger), b.click != .none else { return .pass }
        let cooldown = Double(settings.scrollCooldownMs) / 1000
        if let last = lastScroll[trigger], time >= last, time - last < cooldown { return .drop }
        lastScroll[trigger] = time
        perform(b.click, at: location, flags: flags)
        return .drop
    }

    public static func gestureAction(dx: Double, dy: Double) -> ButtonAction {
        if abs(dx) >= abs(dy) { return dx < 0 ? .spaceLeft : .spaceRight }
        return dy < 0 ? .missionControl : .appExpose
    }
}

public final class ButtonShortcutsStage {
    public static let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]

    private let hub: EventTapHub
    private let engine: ButtonShortcutEngine
    private let clock: () -> TimeInterval
    private var token: EventTapHub.Token?
    private var classifier = WheelClassifier()

    public init(hub: EventTapHub, engine: ButtonShortcutEngine, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hub = hub
        self.engine = engine
        self.clock = clock
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.buttonShortcuts, seesDropped: false, onReset: { [weak self] in self?.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        reset()
    }

    private func reset() {
        engine.reset()
        classifier.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        let button = e.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            return engine.buttonDown(button, at: e.location, flags: e.flags)
        case .otherMouseDragged:
            return engine.buttonDragged(button, dx: e.getDoubleValueField(.mouseEventDeltaX), dy: e.getDoubleValueField(.mouseEventDeltaY))
        case .otherMouseUp:
            return engine.buttonUp(button, at: e.location)
        case .scrollWheel:
            let s = CGScrollBridge.read(e)
            guard s.horizontal.hasMovement, !s.vertical.hasMovement, classifier.isMouseWheel(s, now: clock()) else { return .pass }
            let delta = s.horizontal.line != 0 ? s.horizontal.line : (s.horizontal.point != 0 ? s.horizontal.point : (s.horizontal.fixed > 0 ? 1 : -1))
            return engine.horizontalScroll(delta: delta, at: clock(), location: e.location, flags: e.flags)
        default:
            return .pass
        }
    }
}
