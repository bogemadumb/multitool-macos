import Foundation
import CoreGraphics

public enum BrightnessStep {
    public static let coarse = 1.0 / 16.0
    public static let fine = 1.0 / 64.0
    public static let osdSegments = 16

    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    public static func size(fine isFine: Bool) -> Double { isFine ? fine : coarse }

    // Moves to the next grid point in the direction, so an off-grid value first lands on the grid instead of skipping it.
    public static func next(_ current: Double, up: Bool, fine isFine: Bool) -> Double {
        let q = size(fine: isFine)
        let c = clamp(current)
        let pos = c / q
        let eps = 1e-9
        let idx = up ? floor(pos + eps) + 1 : ceil(pos - eps) - 1
        return clamp((idx * q * 1e9).rounded() / 1e9)
    }

    public static func percent(_ v: Double) -> Int { Int((clamp(v) * 100).rounded()) }

    public static func filledSegments(_ v: Double, total: Int = osdSegments) -> Int {
        Int((clamp(v) * Double(total)).rounded())
    }
}

public enum BrightnessKey: Equatable, Sendable {
    case displayUp, displayDown, keyboardUp, keyboardDown

    public var isUp: Bool { self == .displayUp || self == .keyboardUp }
    public var isKeyboard: Bool { self == .keyboardUp || self == .keyboardDown }

    public init?(keyCode: Int) {
        switch keyCode {
        case 2: self = .displayUp
        case 3: self = .displayDown
        case 21: self = .keyboardUp
        case 22: self = .keyboardDown
        default: return nil
        }
    }
}

public struct SystemKeyEvent: Equatable, Sendable {
    public static let auxSubtype = 8
    public var keyCode: Int
    public var isDown: Bool
    public var isRepeat: Bool

    public init(keyCode: Int, isDown: Bool, isRepeat: Bool) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.isRepeat = isRepeat
    }

    public init?(subtype: Int, data1: Int) {
        guard subtype == Self.auxSubtype else { return nil }
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        self.init(keyCode: (data1 & 0xFFFF_0000) >> 16, isDown: state == 0xA, isRepeat: flags & 1 != 0)
    }

    public var brightnessKey: BrightnessKey? { BrightnessKey(keyCode: keyCode) }
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let command = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)

    public init(cgFlags f: CGEventFlags) {
        var m: KeyModifiers = []
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskControl) { m.insert(.control) }
        self = m
    }

    public var isFineStep: Bool { contains(.option) && contains(.shift) }
    // ⌥ alone opens System Settings, ⌘ toggles mirroring: those stay with the system.
    public var belongsToSystem: Bool { contains(.command) || (contains(.option) && !contains(.shift)) }
}

public enum BrightnessRouter {
    public static func displayUnderCursor(_ cursor: CGPoint, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        if let hit = displays.first(where: { $0.frame.contains(cursor) }) { return hit }
        return displays.min { distance(cursor, $0.frame) < distance(cursor, $1.frame) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func mainDisplay(in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first(where: \.isMain) ?? displays.first(where: \.isBuiltin) ?? displays.first
    }

    // nil = nothing controllable under the pointer, the key goes back to macOS.
    public static func target(cursor: CGPoint?, displays: [DisplaySnapshot], controllable: Set<UInt32>, followCursor: Bool) -> UInt32? {
        let candidate: DisplaySnapshot?
        if followCursor, let cursor { candidate = displayUnderCursor(cursor, in: displays) } else { candidate = mainDisplay(in: displays) }
        guard let c = candidate, controllable.contains(c.cgID) else { return nil }
        return c.cgID
    }
}

public enum KeyDecision: Equatable, Sendable {
    case pass
    case swallow
    case adjustDisplay(cgID: UInt32, up: Bool, fine: Bool)
    case adjustKeyboard(up: Bool, fine: Bool)
}

public struct BrightnessKeyRouter {
    public var followCursor = true
    public var fineAlways = false
    public var handleKeyboardKeys = true
    private var swallowedKeys: Set<Int> = []

    public init(followCursor: Bool = true, fineAlways: Bool = false, handleKeyboardKeys: Bool = true) {
        self.followCursor = followCursor
        self.fineAlways = fineAlways
        self.handleKeyboardKeys = handleKeyboardKeys
    }

    // A key-up follows its key-down: if the press was taken, the release is swallowed too so macOS never sees half a keystroke.
    public mutating func decide(_ event: SystemKeyEvent, modifiers: KeyModifiers, cursor: CGPoint?, displays: [DisplaySnapshot],
                                controllable: Set<UInt32>, keyboardAvailable: Bool) -> KeyDecision {
        guard let key = event.brightnessKey else { return .pass }
        if !event.isDown {
            return swallowedKeys.remove(event.keyCode) != nil ? .swallow : .pass
        }
        if modifiers.belongsToSystem { return .pass }
        let fine = fineAlways || modifiers.isFineStep
        if key.isKeyboard {
            guard handleKeyboardKeys, keyboardAvailable else { return .pass }
            swallowedKeys.insert(event.keyCode)
            return .adjustKeyboard(up: key.isUp, fine: fine)
        }
        guard let id = BrightnessRouter.target(cursor: cursor, displays: displays, controllable: controllable, followCursor: followCursor) else { return .pass }
        swallowedKeys.insert(event.keyCode)
        return .adjustDisplay(cgID: id, up: key.isUp, fine: fine)
    }
}

public enum GammaMath {
    public static let tableSize = 256
    public static let defaultFloor = 0.08

    // Software dimming never reaches black: at 0% the picture stays readable enough to bring it back.
    public static func dimFactor(for brightness: Double, floor: Double = defaultFloor) -> Float {
        let b = BrightnessStep.clamp(brightness)
        let f = min(max(floor, 0), 1)
        return Float(f + (1 - f) * b)
    }

    public static func identityTable(count: Int = tableSize) -> [Float] {
        (0..<count).map { Float($0) / Float(max(count - 1, 1)) }
    }

    public static func scaled(_ table: [Float], factor: Float) -> [Float] {
        let f = factor.isFinite ? min(max(factor, 0), 1) : 1
        return table.map { min(max($0 * f, 0), 1) }
    }

    public static func brightness(forFactor factor: Float, floor: Double = defaultFloor) -> Double {
        let f = min(max(floor, 0), 0.999)
        return BrightnessStep.clamp((Double(factor) - f) / (1 - f))
    }
}

public struct WriteCoalescer<Value: Equatable> {
    public var minInterval: TimeInterval
    private var lastSentAt: Date?
    private var lastSent: Value?
    private var pending: Value?

    public init(minInterval: TimeInterval) { self.minInterval = minInterval }

    public var hasPending: Bool { pending != nil }

    // Returns the value to write now, or nil when it was queued (or equals what is already on the wire).
    public mutating func submit(_ value: Value, now: Date) -> Value? {
        if value == lastSent && pending == nil { return nil }
        if let at = lastSentAt, now.timeIntervalSince(at) < minInterval {
            pending = value
            return nil
        }
        pending = nil
        lastSent = value
        lastSentAt = now
        return value
    }

    public mutating func flushDue(now: Date) -> Value? {
        guard let p = pending else { return nil }
        if let at = lastSentAt, now.timeIntervalSince(at) < minInterval { return nil }
        pending = nil
        if p == lastSent { return nil }
        lastSent = p
        lastSentAt = now
        return p
    }

    public func waitTime(now: Date) -> TimeInterval? {
        guard pending != nil else { return nil }
        guard let at = lastSentAt else { return 0 }
        return max(minInterval - now.timeIntervalSince(at), 0)
    }

    public mutating func reset() {
        lastSentAt = nil
        lastSent = nil
        pending = nil
    }

    public mutating func markSent(_ value: Value, now: Date) {
        lastSent = value
        lastSentAt = now
        pending = nil
    }
}
