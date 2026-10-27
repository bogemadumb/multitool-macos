import Foundation
import CoreGraphics

public enum QuitDecision: Equatable, Sendable {
    case pass
    case drop
    case rewrite(CGEventFlags)
}

public final class QuitProtectionEngine {
    private struct Pending {
        var handle: CancelHandle
        var app: AppIdentity?
    }

    public var settings: QuitProtectionSettings {
        didSet { settings = settings.sanitized }
    }
    public private(set) var blockedCount = 0
    public private(set) var confirmedCount = 0
    private var pending: [UInt32: Pending] = [:]
    private var swallowedUp = Set<UInt32>()
    private var lastPress: [UInt32: (time: TimeInterval, bundle: String?)] = [:]
    private let frontmost: FrontmostAppProviding
    private let timers: TimerScheduling
    private let keys: KeyPosting
    private let hud: (String) -> Void
    private let clock: () -> TimeInterval

    public init(settings: QuitProtectionSettings = QuitProtectionSettings(), frontmost: FrontmostAppProviding, timers: TimerScheduling, keys: KeyPosting,
                hud: @escaping (String) -> Void = { _ in }, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings.sanitized
        self.frontmost = frontmost
        self.timers = timers
        self.keys = keys
        self.hud = hud
        self.clock = clock
    }

    public func reset() {
        for p in pending.values { p.handle.cancel() }
        pending.removeAll()
        swallowedUp.removeAll()
        lastPress.removeAll()
    }

    static func keyName(_ code: UInt32) -> String { code == Keys.q ? "⌘Q" : "⌘W" }

    private func say(_ text: String) { if settings.showHud { hud(text) } }

    public func keyDown(keyCode: UInt32, flags: CGEventFlags, isRepeat: Bool) -> QuitDecision {
        guard let p = settings.protection(forKeyCode: keyCode) else { return .pass }
        if pending[keyCode] != nil || swallowedUp.contains(keyCode) { return .drop }
        let mods = flags.intersection(ModifierFlags.all)
        if p.mode == .extraModifier {
            if mods == [.maskCommand, p.extra.flag] {
                guard p.covers(frontmost.frontmost()?.bundleID) else { return .pass }
                confirmedCount += 1
                return .rewrite(flags.subtracting(p.extra.flag))
            }
        }
        guard mods == .maskCommand else { return .pass }
        let app = frontmost.frontmost()
        guard p.covers(app?.bundleID) else { return .pass }
        let name = Self.keyName(keyCode)
        let appName = app?.name.map { " (\($0))" } ?? ""
        switch p.mode {
        case .off:
            return .pass
        case .extraModifier:
            blockedCount += 1
            swallowedUp.insert(keyCode)
            say("\(name) защищён: нажми \(p.extra.glyph)\(name)\(appName)")
            return .drop
        case .doublePress:
            let now = clock()
            if let last = lastPress[keyCode], now >= last.time, now - last.time <= Double(p.doubleWindowMs) / 1000, last.bundle == app?.bundleID {
                lastPress[keyCode] = nil
                confirmedCount += 1
                return .pass
            }
            lastPress[keyCode] = (now, app?.bundleID)
            blockedCount += 1
            swallowedUp.insert(keyCode)
            say("Нажми \(name) ещё раз\(appName)")
            return .drop
        case .hold:
            blockedCount += 1
            let handle = timers.schedule(after: Double(p.holdMs) / 1000) { [weak self] in self?.holdElapsed(keyCode) }
            pending[keyCode] = Pending(handle: handle, app: app)
            say("Держи \(name), чтобы подтвердить\(appName)")
            return .drop
        }
    }

    private func holdElapsed(_ keyCode: UInt32) {
        guard pending.removeValue(forKey: keyCode) != nil else { return }
        swallowedUp.insert(keyCode)
        confirmedCount += 1
        keys.post(keyCode: keyCode, flags: .maskCommand)
    }

    public func keyUp(keyCode: UInt32) -> QuitDecision {
        if let p = pending.removeValue(forKey: keyCode) {
            p.handle.cancel()
            return .drop
        }
        return swallowedUp.remove(keyCode) != nil ? .drop : .pass
    }

    public func flagsChanged(_ flags: CGEventFlags) {
        guard !flags.contains(.maskCommand) else { return }
        for (code, p) in pending {
            p.handle.cancel()
            swallowedUp.insert(code)
        }
        pending.removeAll()
    }
}

public final class QuitProtectionStage {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]

    private let hub: EventTapHub
    private let engine: QuitProtectionEngine
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: QuitProtectionEngine) {
        self.hub = hub
        self.engine = engine
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.quitProtection, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        let code = UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard code == Keys.q || code == Keys.w else { return .pass }
            switch engine.keyDown(keyCode: code, flags: e.flags, isRepeat: e.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            case .pass: return .pass
            case .drop: return .drop
            case .rewrite(let f):
                e.flags = f
                return .modified
            }
        case .keyUp:
            guard code == Keys.q || code == Keys.w else { return .pass }
            return engine.keyUp(keyCode: code) == .drop ? .drop : .pass
        case .flagsChanged:
            engine.flagsChanged(e.flags)
            return .pass
        default:
            return .pass
        }
    }
}
