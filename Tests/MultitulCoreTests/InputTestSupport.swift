import Foundation
import CoreGraphics
@testable import MultitulCore

final class InpTapBackend: EventTapBackend {
    var onEvent: ((CGEventType, CGEvent) -> EventTapAction)?
    var onDisabled: ((CGEventType) -> Void)?
    var starts: [CGEventMask] = []
    var stops = 0
    var startResult = true

    func start(mask: CGEventMask) -> Bool {
        starts.append(mask)
        return startResult
    }

    func stop() { stops += 1 }

    @discardableResult
    func fire(_ type: CGEventType, _ event: CGEvent) -> EventTapAction { onEvent?(type, event) ?? .pass }
}

final class InpResolver: PointerAppResolver {
    var bundle: String?
    var lookups = 0

    init(_ bundle: String? = nil) { self.bundle = bundle }

    func bundleID(at point: CGPoint) -> String? {
        lookups += 1
        return bundle
    }
}

final class InpTicker: SmoothFrameTicker {
    var handler: (() -> Void)?
    var starts = 0
    var stops = 0
    var active: Bool { handler != nil }

    func start(_ handler: @escaping () -> Void) {
        starts += 1
        self.handler = handler
    }

    func stop() {
        stops += 1
        handler = nil
    }
}

final class InpPoster: SmoothScrollPoster {
    var posts: [(v: Int, h: Int, flags: CGEventFlags)] = []
    var totalVertical: Int { posts.reduce(0) { $0 + $1.v } }
    var totalHorizontal: Int { posts.reduce(0) { $0 + $1.h } }

    func post(vertical: Int, horizontal: Int, flags: CGEventFlags) {
        posts.append((vertical, horizontal, flags))
    }
}

final class InpClock {
    var now: TimeInterval = 1000
}

enum InpEvents {
    static func wheel(line: Int32 = 0, lineH: Int32 = 0, flags: CGEventFlags = [], location: CGPoint = CGPoint(x: 10, y: 10)) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: line, wheel2: lineH, wheel3: 0)!
        e.flags = flags
        e.location = location
        return e
    }

    static func pixelWheel(v: Int32 = 0, h: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0, count: Int64 = 0) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0)!
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.setIntegerValueField(.scrollWheelEventScrollCount, value: count)
        return e
    }

    static func key(_ code: UInt16, down: Bool, repeating: Bool = false, at t: TimeInterval? = nil) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        if repeating { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if let t { e.timestamp = CGEventTimestamp(t * 1e9) }
        return e
    }

    static func mouse(_ type: CGEventType, button: CGMouseButton = .left, at t: TimeInterval? = nil) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: button)!
        if let t { e.timestamp = CGEventTimestamp(t * 1e9) }
        return e
    }

    static func moved(_ p: CGPoint) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
    }
}

final class InpFocusDriver: FocusFollowsDriver {
    var window: FocusWindowInfo?
    var front: Int32?
    var focusedBounds: CGRect?
    var buttons = false
    var modifiers = false
    var focusOK = true
    var focusCalls: [(FocusWindowInfo, Bool)] = []
    var lookups = 0

    func windowUnder(_ point: CGPoint) -> FocusWindowInfo? {
        lookups += 1
        return window
    }

    func frontmostPID() -> Int32? { front }
    func focusedWindowBounds(pid: Int32) -> CGRect? { focusedBounds }
    func buttonsPressed() -> Bool { buttons }
    func shortcutModifiersHeld() -> Bool { modifiers }

    func focus(_ window: FocusWindowInfo, at point: CGPoint, raise: Bool) -> Bool {
        focusCalls.append((window, raise))
        return focusOK
    }
}

final class InpAccelDriver: PointerAccelDriver {
    var devices: [PointerDevice] = []
    var values: [UInt64: Int64] = [:]
    var failWrites: Set<UInt64> = []
    var writes: [(UInt64, Int64)] = []

    func mice() -> [PointerDevice] { devices }
    func read(registryID: UInt64, key: String) -> Int64? { values[registryID] }

    func write(registryID: UInt64, key: String, value: Int64) -> Bool {
        writes.append((registryID, value))
        if failWrites.contains(registryID) { return false }
        values[registryID] = value
        return true
    }
}

final class InpJournal: AccelJournalStore {
    var entries: [AccelJournalEntry] = []
    var saves = 0

    func load() -> [AccelJournalEntry] { entries }

    func save(_ entries: [AccelJournalEntry]) {
        self.entries = entries
        saves += 1
    }
}
