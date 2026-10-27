import Foundation
import Carbon.HIToolbox

public protocol HotkeyBackend: AnyObject {
    var onFire: ((UInt32) -> Void)? { get set }
    func register(_ combo: KeyCombo, token: UInt32) -> OSStatus
    func unregister(token: UInt32)
}

public enum HotkeyState: Equatable {
    case active
    case conflict(with: String)
    case failed(OSStatus)
}

public enum HotkeyChange: Equatable {
    case applied
    case conflict(with: String)
    case failed(OSStatus)
}

@MainActor
public final class HotkeyManager: ObservableObject {
    public static let shared = HotkeyManager(backend: CarbonHotkeyBackend())

    private struct Entry {
        var spec: HotkeySpec
        var owner: String
        var handler: () -> Void
        var token: UInt32
        var combo: KeyCombo
        var state: HotkeyState
    }

    private let backend: HotkeyBackend
    private let defaults: KeyValueStoring
    private var entries: [String: Entry] = [:]
    private var nextToken: UInt32 = 1
    private var suspended = false
    private var reserved: [String: (title: String, combo: KeyCombo)] = [:]

    @Published public private(set) var states: [String: HotkeyState] = [:]
    @Published public private(set) var overridesRevision = 0

    public init(backend: HotkeyBackend, defaults: KeyValueStoring = UserDefaults.standard) {
        self.backend = backend
        self.defaults = defaults
        backend.onFire = { [weak self] token in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fire(token) } }
        }
    }

    public func combo(for spec: HotkeySpec) -> KeyCombo {
        if let s = defaults.string(forKey: Self.key(spec.id)), let c = KeyCombo(stored: s) { return c }
        return spec.defaultCombo
    }

    public func state(of id: String) -> HotkeyState? { states[id] }

    public func holder(of combo: KeyCombo, excluding id: String) -> String? {
        guard !combo.isNone else { return nil }
        if let r = reserved.first(where: { $0.value.combo == combo }) { return r.key }
        return entries.values.first { $0.state == .active && $0.combo == combo && $0.spec.id != id }?.spec.id
    }

    @discardableResult
    public func register(_ spec: HotkeySpec, owner: String, handler: @escaping () -> Void) -> HotkeyState {
        unregister(spec.id)
        let token = nextToken
        nextToken += 1
        var e = Entry(spec: spec, owner: owner, handler: handler, token: token, combo: combo(for: spec), state: .active)
        entries[spec.id] = e
        e.state = activate(e)
        entries[spec.id] = e
        publish()
        Log.write("hotkey register \(spec.id) \(e.combo.display) -> \(e.state)")
        return e.state
    }

    public func unregister(_ id: String) {
        guard let e = entries.removeValue(forKey: id) else { return }
        if e.state == .active && !suspended { backend.unregister(token: e.token) }
        retryPending()
        publish()
        Log.write("hotkey unregister \(id)")
    }

    public func reserve(id: String, title: String, combo: KeyCombo) {
        if reserved[id]?.combo == combo { return }
        reserved[id] = (title, combo)
        guard !combo.isNone else { return }
        for key in entries.keys.sorted() {
            guard var e = entries[key], e.state == .active, e.combo == combo else { continue }
            if !suspended { backend.unregister(token: e.token) }
            e.state = .conflict(with: id)
            entries[key] = e
        }
        publish()
    }

    public func release(id: String) {
        guard reserved.removeValue(forKey: id) != nil else { return }
        retryPending()
        publish()
    }

    public func reservedTitle(of id: String) -> String? { reserved[id]?.title ?? InterceptedKeys.title(of: id) }

    public var reservedIDs: [String] { reserved.keys.sorted() }

    public func unregisterAll(owner: String) {
        for id in entries.values.filter({ $0.owner == owner }).map({ $0.spec.id }) { unregister(id) }
    }

    public func setCombo(_ spec: HotkeySpec, to combo: KeyCombo) -> HotkeyChange {
        if let other = holder(of: combo, excluding: spec.id) { return .conflict(with: other) }
        defaults.set(combo.stored, forKey: Self.key(spec.id))
        overridesRevision += 1
        guard var e = entries[spec.id] else { return .applied }
        if e.state == .active && !suspended { backend.unregister(token: e.token) }
        e.combo = combo
        e.state = activate(e)
        entries[spec.id] = e
        publish()
        if case .failed(let s) = e.state { return .failed(s) }
        if case .conflict(let w) = e.state { return .conflict(with: w) }
        return .applied
    }

    public func resetCombo(_ spec: HotkeySpec) -> HotkeyChange {
        let wasOverridden = defaults.string(forKey: Self.key(spec.id)) != nil
        defaults.removeObject(forKey: Self.key(spec.id))
        overridesRevision += 1
        guard var e = entries[spec.id] else { return .applied }
        if wasOverridden {
            if e.state == .active && !suspended { backend.unregister(token: e.token) }
            e.combo = spec.defaultCombo
            e.state = activate(e)
            entries[spec.id] = e
            publish()
        }
        return .applied
    }

    public func suspendAll() {
        guard !suspended else { return }
        suspended = true
        for e in entries.values where e.state == .active { backend.unregister(token: e.token) }
    }

    public func resumeAll() {
        guard suspended else { return }
        suspended = false
        for id in entries.keys.sorted() {
            guard var e = entries[id], e.state == .active, !e.combo.isNone else { continue }
            if backend.register(e.combo, token: e.token) != noErr { e.state = .failed(OSStatus(eventHotKeyExistsErr)) }
            entries[id] = e
        }
        publish()
    }

    private func activate(_ e: Entry) -> HotkeyState {
        if e.combo.isNone { return .active }
        if let r = reserved.first(where: { $0.value.combo == e.combo }) { return .conflict(with: r.key) }
        if let other = entries.values.first(where: { $0.state == .active && $0.combo == e.combo && $0.spec.id != e.spec.id }) {
            return .conflict(with: other.spec.id)
        }
        if suspended { return .active }
        let status = backend.register(e.combo, token: e.token)
        return status == noErr ? .active : .failed(status)
    }

    private func retryPending() {
        for id in entries.keys.sorted() {
            guard var e = entries[id], e.state != .active else { continue }
            e.state = activate(e)
            entries[id] = e
        }
    }

    private func publish() {
        states = entries.mapValues { $0.state }
    }

    private func fire(_ token: UInt32) {
        guard let e = entries.values.first(where: { $0.token == token && $0.state == .active }) else { return }
        e.handler()
    }

    static func key(_ id: String) -> String { "hotkey.\(id)" }
}

public final class CarbonHotkeyBackend: HotkeyBackend {
    public var onFire: ((UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static var current: CarbonHotkeyBackend?

    public init() {
        CarbonHotkeyBackend.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            CarbonHotkeyBackend.current?.onFire?(hk.id)
            return noErr
        }, 1, &spec, nil, &handler)
    }

    public func register(_ combo: KeyCombo, token: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D4C544C), id: token)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[token] = ref }
        return status
    }

    public func unregister(token: UInt32) {
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
    }
}
