import Foundation
import CoreGraphics

public struct WindowRecord: Equatable, Sendable {
    public var pressed: WindowLayoutAction
    public var effective: WindowLayoutAction
    public var requested: CGRect
    public var actual: CGRect
    public var displayID: UInt32

    public init(pressed: WindowLayoutAction, effective: WindowLayoutAction, requested: CGRect, actual: CGRect, displayID: UInt32) {
        self.pressed = pressed
        self.effective = effective
        self.requested = requested
        self.actual = actual
        self.displayID = displayID
    }
}

public struct WindowHistory: Sendable {
    public static let perWindowLimit = 20
    public static let windowLimit = 64

    private var originals: [Int: [CGRect]] = [:]
    private var records: [Int: WindowRecord] = [:]
    private var usage: [Int] = []

    public init() {}

    public var trackedWindows: Int { usage.count }

    private mutating func touch(_ key: Int) {
        usage.removeAll { $0 == key }
        usage.append(key)
        while usage.count > Self.windowLimit {
            let old = usage.removeFirst()
            originals[old] = nil
            records[old] = nil
        }
    }

    public mutating func pushOriginal(_ frame: CGRect, for key: Int) {
        var stack = originals[key] ?? []
        if let top = stack.last, WindowGeometry.approxEqual(top, frame, tolerance: 1) { touch(key); return }
        stack.append(frame)
        if stack.count > Self.perWindowLimit { stack.removeFirst(stack.count - Self.perWindowLimit) }
        originals[key] = stack
        touch(key)
    }

    public mutating func popOriginal(for key: Int) -> CGRect? {
        guard var stack = originals[key], let last = stack.popLast() else { return nil }
        originals[key] = stack.isEmpty ? nil : stack
        return last
    }

    public func peekOriginal(for key: Int) -> CGRect? { originals[key]?.last }

    public func originalCount(for key: Int) -> Int { originals[key]?.count ?? 0 }

    public mutating func setRecord(_ r: WindowRecord, for key: Int) {
        records[key] = r
        touch(key)
    }

    public mutating func clearRecord(for key: Int) { records[key] = nil }

    public mutating func forget(_ key: Int) {
        originals[key] = nil
        records[key] = nil
        usage.removeAll { $0 == key }
    }

    public func record(for key: Int) -> WindowRecord? { records[key] }

    public func continuing(_ current: CGRect, for key: Int, tolerance: CGFloat = WindowGeometry.frameTolerance) -> WindowRecord? {
        guard let r = records[key] else { return nil }
        return WindowGeometry.approxEqual(current, r.actual, tolerance: tolerance) || WindowGeometry.approxEqual(current, r.requested, tolerance: tolerance) ? r : nil
    }
}

public enum LayoutResolution: Equatable, Sendable {
    case place(WindowLayoutAction)
    case cross(WindowLayoutAction, DisplayDirection)
}

public enum WindowLayoutPlanner {
    public static let chains: [WindowLayoutAction: [WindowLayoutAction]] = [
        .leftHalf: [.leftHalf, .leftTwoThirds, .leftThird],
        .rightHalf: [.rightHalf, .rightTwoThirds, .rightThird],
        .topHalf: [.topHalf, .topTwoThirds, .topThird],
        .bottomHalf: [.bottomHalf, .bottomTwoThirds, .bottomThird]
    ]

    public static func crossing(for action: WindowLayoutAction) -> (WindowLayoutAction, DisplayDirection)? {
        switch action {
        case .leftHalf: (.rightHalf, .left)
        case .rightHalf: (.leftHalf, .right)
        case .topHalf: (.bottomHalf, .up)
        case .bottomHalf: (.topHalf, .down)
        default: nil
        }
    }

    public static func resolve(_ pressed: WindowLayoutAction, record: WindowRecord?, mode: LayoutRepeat) -> LayoutResolution {
        guard let record, record.pressed == pressed else { return .place(pressed) }
        switch mode {
        case .none:
            return .place(pressed)
        case .cycleSizes:
            guard let chain = chains[pressed] else { return .place(pressed) }
            let i = chain.firstIndex(of: record.effective) ?? -1
            return .place(chain[(i + 1) % chain.count])
        case .crossDisplay:
            if let c = crossing(for: pressed) { return .cross(c.0, c.1) }
            return .place(pressed)
        }
    }
}
