import Foundation
import CoreGraphics

public protocol CapsLockToggling: AnyObject {
    func toggleCapsLock()
}

public protocol InputSourceSwitching: AnyObject {
    func selectNextSource()
}

public struct HIDMapping: Equatable, Sendable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    public static let capsToF18 = HIDMapping(source: 0x7_0000_0039, destination: 0x7_0000_006D)
}

public enum HIDKeyMapping {
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    public static func parse(_ text: String) -> [HIDMapping] {
        guard let data = text.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let arr = obj as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let s = number(d[srcKey]), let t = number(d[dstKey]) else { return nil }
            return HIDMapping(source: s, destination: t)
        }
    }

    private static func number(_ v: Any?) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) }
        return nil
    }

    public static func merged(_ existing: [HIDMapping], adding m: HIDMapping) -> [HIDMapping] {
        existing.filter { $0.source != m.source } + [m]
    }

    public static func removing(_ existing: [HIDMapping], _ m: HIDMapping) -> [HIDMapping] {
        existing.filter { $0 != m }
    }

    public static func argument(_ maps: [HIDMapping]) -> String {
        let items = maps.map { "{\"\(srcKey)\":\($0.source),\"\(dstKey)\":\($0.destination)}" }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }
}

public protocol KeyRemapping: AnyObject {
    func apply(_ m: HIDMapping) -> Bool
    func remove(_ m: HIDMapping) -> Bool
}

public final class SuperKeyRemapGuard {
    public static let journalKey = "input.superKey.remapApplied"

    private let remapper: KeyRemapping
    private let defaults: KeyValueStoring

    public init(remapper: KeyRemapping, defaults: KeyValueStoring = UserDefaults.standard) {
        self.remapper = remapper
        self.defaults = defaults
    }

    public var applied: Bool { defaults.bool(forKey: Self.journalKey) }

    @discardableResult
    public func engage() -> Bool {
        guard remapper.apply(.capsToF18) else { return false }
        defaults.set(true, forKey: Self.journalKey)
        return true
    }

    public func disengage() {
        guard applied else { return }
        if remapper.remove(.capsToF18) { defaults.removeObject(forKey: Self.journalKey) }
    }

    public func recoverStale() { disengage() }
}

public enum SuperKeyMath {
    public static func transformed(_ flags: CGEventFlags, source: SuperKeySource, modifiers: UInt32) -> CGEventFlags {
        var out = flags
        if let own = source.ownFlag, flags.rawValue & source.leftDeviceMask == 0 { out.remove(own) }
        out = CGEventFlags(rawValue: out.rawValue & ~source.deviceMask)
        out.formUnion(KeyCombo(keyCode: 0, modifiers: modifiers).cgFlags)
        return out
    }
}

public final class SuperKeyEngine {
    public var settings: SuperKeySettings {
        didSet { settings = settings.sanitized }
    }
    public private(set) var isHeld = false
    public private(set) var soloCount = 0
    private var downAt: TimeInterval = 0
    private var used = false
    private var passedThrough = false
    private let caps: CapsLockToggling
    private let input: InputSourceSwitching
    private let keys: KeyPosting
    private let frontmostBundle: () -> String?

    public init(settings: SuperKeySettings = SuperKeySettings(), caps: CapsLockToggling, input: InputSourceSwitching, keys: KeyPosting, frontmostBundle: @escaping () -> String?) {
        self.settings = settings.sanitized
        self.caps = caps
        self.input = input
        self.keys = keys
        self.frontmostBundle = frontmostBundle
    }

    public func reset() {
        isHeld = false
        used = false
        passedThrough = false
    }

    public func sourceChanged(down: Bool, isRepeat: Bool = false, at time: TimeInterval) -> EventTapAction {
        let drop: EventTapAction = settings.source.isModifier ? .pass : .drop
        if down {
            if passedThrough { return drop }
            if isHeld || isRepeat { return .drop }
            if settings.exceptions.contains(frontmostBundle()) {
                passedThrough = true
                return drop
            }
            isHeld = true
            used = false
            downAt = time
            return .drop
        }
        if passedThrough {
            passedThrough = false
            if !settings.source.isModifier { caps.toggleCapsLock() }
            return drop
        }
        guard isHeld else { return settings.source.isModifier ? .pass : .drop }
        isHeld = false
        guard !used else { return .drop }
        let held = time - downAt
        if held <= Double(settings.tapMaxMs) / 1000 {
            soloCount += 1
            switch settings.solo {
            case .none: break
            case .capsLock: caps.toggleCapsLock()
            case .inputSource: input.selectNextSource()
            case .escape: keys.post(keyCode: Keys.escape, flags: [])
            }
        } else if settings.longHoldCapsLock, held >= Double(settings.longHoldMs) / 1000 {
            caps.toggleCapsLock()
        }
        return .drop
    }

    public func modifiedFlags(_ flags: CGEventFlags) -> CGEventFlags? {
        guard isHeld else { return nil }
        used = true
        return SuperKeyMath.transformed(flags, source: settings.source, modifiers: settings.modifiers)
    }
}

public final class SuperKeyStage {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]

    private let hub: EventTapHub
    private let engine: SuperKeyEngine
    private let clock: () -> TimeInterval
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: SuperKeyEngine, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hub = hub
        self.engine = engine
        self.clock = clock
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.superKey, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        let source = engine.settings.source
        let code = UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        let now = EventTime.seconds(of: e, now: clock())
        switch type {
        case .flagsChanged:
            guard source.isModifier, code == source.keyCode else { return .pass }
            return engine.sourceChanged(down: e.flags.rawValue & source.deviceMask != 0, at: now)
        case .keyDown, .keyUp:
            if !source.isModifier, code == source.keyCode {
                return engine.sourceChanged(down: type == .keyDown, isRepeat: e.getIntegerValueField(.keyboardEventAutorepeat) != 0, at: now)
            }
            return apply(e)
        default:
            return apply(e)
        }
    }

    private func apply(_ e: CGEvent) -> EventTapAction {
        guard let f = engine.modifiedFlags(e.flags) else { return .pass }
        e.flags = f
        return .modified
    }
}

public final class SuperKeyService {
    private let hub: EventTapHub
    private let engine: SuperKeyEngine
    private let stage: SuperKeyStage
    private let remap: SuperKeyRemapGuard
    public private(set) var mappingFailed = false

    public init(hub: EventTapHub, settings: SuperKeySettings, caps: CapsLockToggling, input: InputSourceSwitching, keys: KeyPosting, remap: SuperKeyRemapGuard,
                frontmostBundle: @escaping () -> String?, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hub = hub
        self.remap = remap
        engine = SuperKeyEngine(settings: settings, caps: caps, input: input, keys: keys, frontmostBundle: frontmostBundle)
        stage = SuperKeyStage(hub: hub, engine: engine, clock: clock)
    }

    public var isRunning: Bool { stage.isRunning }
    public var settings: SuperKeySettings { engine.settings }

    public func start() {
        applyRemap()
        stage.start()
    }

    public func stop() {
        stage.stop()
        remap.disengage()
        mappingFailed = false
    }

    public func update(_ s: SuperKeySettings) {
        let was = engine.settings.source
        engine.settings = s
        if was != engine.settings.source { applyRemap() }
    }

    private func applyRemap() {
        if engine.settings.source == .capsLock {
            mappingFailed = !remap.engage()
        } else {
            remap.disengage()
            mappingFailed = false
        }
    }
}
