import Foundation
import CoreGraphics

public enum EventTime {
    public struct Timebase: Equatable {
        public var numer: UInt64
        public var denom: UInt64
        public init(numer: UInt64, denom: UInt64) { self.numer = numer; self.denom = max(denom, 1) }
    }

    public static var machTimebase: Timebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Timebase(numer: UInt64(info.numer), denom: UInt64(info.denom))
    }

    public static func seconds(raw: UInt64, nowSeconds: TimeInterval, timebase: Timebase) -> TimeInterval {
        let asNanos = Double(raw) / 1e9
        let asTicks = Double(raw) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return abs(asNanos - nowSeconds) <= abs(asTicks - nowSeconds) ? asNanos : asTicks
    }

    public static func seconds(of event: CGEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        let raw = UInt64(event.timestamp)
        guard raw != 0 else { return now }
        return seconds(raw: raw, nowSeconds: now, timebase: machTimebase)
    }
}

public enum ClickPhase: Equatable {
    case down, dragged, up
}

public struct ClickDebounce {
    public static let staleDownSeconds: TimeInterval = 1.0

    private struct Button {
        var acceptedDown = false
        var downAt: TimeInterval = 0
        var suppressedDown = false
        var lastUpAt: TimeInterval?
        var lastEventAt: TimeInterval = 0
    }

    private var buttons: [Int64: Button] = [:]
    public private(set) var suppressedCount = 0
    public var windowSeconds: TimeInterval

    public init(windowMs: Int = ClickDebounceSettings.defaultWindow) {
        windowSeconds = Double(windowMs) / 1000
    }

    public mutating func reset() { buttons.removeAll() }

    public static func resolve(type: CGEventType, buttonNumber: Int64) -> (button: Int64, phase: ClickPhase)? {
        switch type {
        case .leftMouseDown: (0, .down)
        case .leftMouseDragged: (0, .dragged)
        case .leftMouseUp: (0, .up)
        case .rightMouseDown: (1, .down)
        case .rightMouseDragged: (1, .dragged)
        case .rightMouseUp: (1, .up)
        case .otherMouseDown where buttonNumber == 2: (2, .down)
        case .otherMouseDragged where buttonNumber == 2: (2, .dragged)
        case .otherMouseUp where buttonNumber == 2: (2, .up)
        default: nil
        }
    }

    public mutating func shouldSuppress(button: Int64, phase: ClickPhase, at t: TimeInterval) -> Bool {
        var b = buttons[button] ?? Button()
        if t < b.lastEventAt { b = Button() }
        b.lastEventAt = t
        defer { buttons[button] = b }
        switch phase {
        case .down:
            if b.suppressedDown { return count() }
            if b.acceptedDown && t - b.downAt < Self.staleDownSeconds { return count() }
            if let up = b.lastUpAt, t - up < windowSeconds {
                b.suppressedDown = true
                b.acceptedDown = false
                return count()
            }
            b.acceptedDown = true
            b.downAt = t
            return false
        case .dragged:
            return b.suppressedDown
        case .up:
            if b.suppressedDown {
                b.suppressedDown = false
                return count()
            }
            if b.acceptedDown {
                b.acceptedDown = false
                b.lastUpAt = t
            }
            return false
        }
    }

    private mutating func count() -> Bool {
        suppressedCount += 1
        return true
    }
}

public enum KeyPhase: Equatable {
    case down, up
}

public struct KeyDebounce {
    public static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179]

    private enum State { case idle, down, suppressed }

    private struct Key {
        var state = State.idle
        var downAt: TimeInterval = 0
        var lastUpAt: TimeInterval?
        var lastEventAt: TimeInterval = 0
    }

    private var keys: [Int64: Key] = [:]
    public private(set) var suppressedCount = 0
    public var settings: KeyDebounceSettings

    public init(settings: KeyDebounceSettings = KeyDebounceSettings()) { self.settings = settings }

    public mutating func reset() { keys.removeAll() }

    public mutating func shouldSuppress(keyCode: Int64, phase: KeyPhase, isAutoRepeat: Bool, at t: TimeInterval, frontmostBundleID: String? = nil) -> Bool {
        if Self.modifierKeyCodes.contains(keyCode) { return false }
        var k = keys[keyCode] ?? Key()
        if t < k.lastEventAt { k = Key() }
        k.lastEventAt = t
        defer { keys[keyCode] = k }
        if settings.ignoredApps.contains(frontmostBundleID) {
            k.state = phase == .down ? .down : .idle
            return false
        }
        switch phase {
        case .down:
            if isAutoRepeat {
                if k.state == .idle { k.state = .down }
                return false
            }
            let window = Double(settings.windowMs(for: keyCode)) / 1000
            guard window > 0 else {
                k.state = .down
                k.downAt = t
                return false
            }
            if k.state == .down && t - k.downAt < window { return count() }
            if k.state == .suppressed { return count() }
            if k.state == .idle, let up = k.lastUpAt, t - up < window {
                k.state = .suppressed
                return count()
            }
            k.state = .down
            k.downAt = t
            return false
        case .up:
            if k.state == .suppressed {
                k.state = .idle
                return count()
            }
            if k.state == .down { k.lastUpAt = t }
            k.state = .idle
            return false
        }
    }

    private mutating func count() -> Bool {
        suppressedCount += 1
        return true
    }
}
