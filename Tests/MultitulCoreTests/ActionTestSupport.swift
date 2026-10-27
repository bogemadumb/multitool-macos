import Foundation
import CoreGraphics
@testable import MultitulCore

final class ActKeys: KeyPosting {
    var posts: [(code: UInt32, flags: CGEventFlags)] = []
    var typed: [String] = []
    var log: [String] = []

    func post(keyCode: UInt32, flags: CGEventFlags) {
        posts.append((keyCode, flags))
        log.append("key:\(keyCode)")
    }

    func type(_ text: String) {
        typed.append(text)
        log.append("type:\(text)")
    }

    func codes() -> [UInt32] { posts.map(\.code) }
}

final class ActMouse: MousePosting {
    var posts: [(button: Int64, down: Bool, point: CGPoint, flags: CGEventFlags)] = []
    var location = CGPoint(x: 40, y: 50)

    func post(button: Int64, down: Bool, at point: CGPoint, flags: CGEventFlags) { posts.append((button, down, point, flags)) }
    func pointerLocation() -> CGPoint { location }
}

final class ActFront: FrontmostAppProviding {
    var app: AppIdentity?

    init(_ bundle: String? = nil, name: String? = nil, pid: Int32 = 100) {
        app = bundle.map { AppIdentity(bundleID: $0, name: name, pid: pid) }
    }

    func frontmost() -> AppIdentity? { app }
    func set(_ bundle: String?, name: String? = nil, pid: Int32 = 100) { app = bundle.map { AppIdentity(bundleID: $0, name: name, pid: pid) } }
}

final class ActHandle: CancelHandle {
    var cancelled = false
    func cancel() { cancelled = true }
}

final class ActTimers: TimerScheduling {
    var items: [(delay: TimeInterval, block: () -> Void, handle: ActHandle)] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelHandle {
        let h = ActHandle()
        items.append((delay, block, h))
        return h
    }

    func fireAll() {
        let pending = items
        items.removeAll()
        for i in pending where !i.handle.cancelled { i.block() }
    }
}

final class ActCaps: CapsLockToggling {
    var toggles = 0
    func toggleCapsLock() { toggles += 1 }
}

final class ActSource: InputSourceSwitching {
    var switches = 0
    func selectNextSource() { switches += 1 }
}

final class ActSecure: SecureInputChecking {
    var active = false
    func isSecureInputActive() -> Bool { active }
}

final class ActFocus: SecureFocusInspecting {
    var secure = false
    var asked: [Int32] = []
    func focusIsSecure(pid: Int32) -> Bool {
        asked.append(pid)
        return secure
    }
}

final class ActRemapper: KeyRemapping {
    var applied: [HIDMapping] = []
    var removed: [HIDMapping] = []
    var failApply = false
    var failRemove = false

    func apply(_ m: HIDMapping) -> Bool {
        if failApply { return false }
        applied.append(m)
        return true
    }

    func remove(_ m: HIDMapping) -> Bool {
        if failRemove { return false }
        removed.append(m)
        return true
    }
}

final class ActTouch: TouchSource {
    var onFrame: ((TouchFrame) -> Void)?
    var starts = 0
    var stops = 0
    var startResult = true

    func start() -> Bool {
        starts += 1
        return startResult
    }

    func stop() { stops += 1 }
    func send(_ f: TouchFrame) { onFrame?(f) }
}

final class ActGesture: SystemGestureInfo {
    var drag = false
    func threeFingerDragEnabled() -> Bool { drag }
}

final class ActClock {
    var now: TimeInterval = 5000
}

private let actLock = NSLock()
nonisolated(unsafe) private var actKept: [AnyObject] = []
nonisolated(unsafe) private var actTempDirs: [String] = []
nonisolated(unsafe) private var actCleanupRegistered = false

private func actRegisterCleanup() {
    guard !actCleanupRegistered else { return }
    actCleanupRegistered = true
    atexit {
        for d in actTempDirs { try? FileManager.default.removeItem(atPath: d) }
    }
}

private func actRegisterDir(_ dir: String) {
    actLock.lock()
    defer { actLock.unlock() }
    actTempDirs.append(dir)
    actRegisterCleanup()
}

final class ActDB {
    let dir: String
    let path: String

    init() {
        dir = NSTemporaryDirectory() + "multitul-act-\(UUID().uuidString)"
        path = dir + "/multitul.db"
        actRegisterDir(dir)
    }

    func snippets(now: @escaping () -> Date = Date.init) -> SnippetStore {
        try! SnippetStore(store: SnippetSchema.openStore(path: path), now: now)
    }
}

func actDefaults() -> InMemoryKeyValueStore { InMemoryKeyValueStore() }


enum ActEvents {
    static func key(_ code: UInt16, down: Bool, flags: CGEventFlags = [], chars: String? = nil, repeating: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        e.flags = flags
        if let chars {
            var u = Array(chars.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        }
        if repeating { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return e
    }

    static func flags(_ code: UInt16, raw: UInt64) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: raw)
        return e
    }

    static func other(_ type: CGEventType, button: Int64, dx: Double = 0, dy: Double = 0) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 8, y: 9), mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        return e
    }

    static func left(_ type: CGEventType) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 5, y: 6), mouseButton: .left)!
    }

    static func tilt(_ h: Int32, continuous: Bool = false) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: h, wheel3: 0)!
        if continuous {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        }
        return e
    }

    static func vertical(_ v: Int32) -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: v, wheel2: 0, wheel3: 0)!
    }
}

func actHub() -> (EventTapHub, InpTapBackend) {
    let be = InpTapBackend()
    let hub = EventTapHub(backend: be)
    actLock.lock()
    actKept.append(hub)
    actLock.unlock()
    return (hub, be)
}

func actSnippet(_ id: Int64, _ trigger: String, _ body: String = "text", enabled: Bool = true) -> Snippet {
    Snippet(id: id, trigger: trigger, body: body, enabled: enabled)
}

@discardableResult
func actKeep<T: AnyObject>(_ o: T) -> T {
    actLock.lock()
    actKept.append(o)
    actLock.unlock()
    return o
}
