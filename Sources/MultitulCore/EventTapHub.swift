import Foundation
import CoreGraphics

public enum EventTapAction {
    case pass
    case modified
    case drop
}

public protocol EventTapBackend: AnyObject {
    var onEvent: ((CGEventType, CGEvent) -> EventTapAction)? { get set }
    var onDisabled: ((CGEventType) -> Void)? { get set }
    func start(mask: CGEventMask) -> Bool
    func stop()
}

public final class EventTapHub {
    public static let shared = EventTapHub(backend: CGEventTapBackend())

    public static let syntheticMarker: Int64 = 0x4D544C53

    public struct Token: Hashable { fileprivate let raw: Int }

    private struct Subscriber {
        var id: Int
        var mask: CGEventMask
        var priority: Int
        var seesDropped: Bool
        var includeSynthesized: Bool
        var onReset: (() -> Void)?
        var handler: (CGEventType, CGEvent) -> EventTapAction
    }

    private let backend: EventTapBackend
    private var subscribers: [Int: Subscriber] = [:]
    private var ordered: [Subscriber] = []
    private var counter = 0
    private var currentMask: CGEventMask = 0
    public private(set) var isRunning = false
    public private(set) var lastStartFailed = false
    public private(set) var disabledCount = 0
    public private(set) var lastDisabledType: CGEventType?

    public init(backend: EventTapBackend) {
        self.backend = backend
        backend.onEvent = { [weak self] type, event in self?.dispatch(type, event) ?? .pass }
        backend.onDisabled = { [weak self] type in self?.tapDisabled(type) }
    }

    public static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    public static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

    public func subscribe(types: [CGEventType], priority: Int = 0, seesDropped: Bool = true, includeSynthesized: Bool = false,
                          onReset: (() -> Void)? = nil, handler: @escaping (CGEventType, CGEvent) -> EventTapAction) -> Token {
        counter += 1
        subscribers[counter] = Subscriber(id: counter, mask: Self.mask(types), priority: priority, seesDropped: seesDropped,
                                          includeSynthesized: includeSynthesized, onReset: onReset, handler: handler)
        rebuildOrder()
        reconcile()
        return Token(raw: counter)
    }

    public func unsubscribe(_ token: Token) {
        guard subscribers.removeValue(forKey: token.raw) != nil else { return }
        rebuildOrder()
        reconcile()
    }

    public func retryStart() {
        guard !subscribers.isEmpty, !isRunning else { return }
        reconcile()
    }

    public var subscriberCount: Int { subscribers.count }

    public func isSubscribed(_ token: Token) -> Bool { subscribers[token.raw] != nil }

    private func rebuildOrder() {
        ordered = subscribers.values.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }

    private func reconcile() {
        let wanted = subscribers.values.reduce(CGEventMask(0)) { $0 | $1.mask }
        if wanted == 0 {
            if isRunning { backend.stop() }
            isRunning = false
            currentMask = 0
            return
        }
        if isRunning && wanted == currentMask { return }
        if isRunning { backend.stop() }
        isRunning = backend.start(mask: wanted)
        lastStartFailed = !isRunning
        currentMask = isRunning ? wanted : 0
        Log.write("eventtap start mask=\(wanted) ok=\(isRunning)")
    }

    private func tapDisabled(_ type: CGEventType) {
        disabledCount += 1
        lastDisabledType = type
        Log.write("eventtap disabled type=\(type.rawValue) count=\(disabledCount)")
        for s in ordered { s.onReset?() }
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> EventTapAction {
        let bit = CGEventMask(1) << CGEventMask(type.rawValue)
        let synthetic = Self.isSynthetic(event)
        var result = EventTapAction.pass
        for s in ordered where s.mask & bit != 0 {
            if synthetic && !s.includeSynthesized { continue }
            if result == .drop && !s.seesDropped { continue }
            guard subscribers[s.id] != nil else { continue }
            switch s.handler(type, event) {
            case .drop: result = .drop
            case .modified: if result == .pass { result = .modified }
            case .pass: break
            }
        }
        return result
    }
}

public final class CGEventTapBackend: EventTapBackend {
    public var onEvent: ((CGEventType, CGEvent) -> EventTapAction)?
    public var onDisabled: ((CGEventType) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    public func start(mask: CGEventMask) -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CGEventTapBackend>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                me.onDisabled?(type)
                return Unmanaged.passUnretained(event)
            }
            if me.onEvent?(type, event) == .drop { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    public func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
        source = nil
    }
}
