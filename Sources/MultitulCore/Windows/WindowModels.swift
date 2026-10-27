import Foundation
import CoreGraphics

public struct FractionRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public static let full = FractionRect(x: 0, y: 0, w: 1, h: 1)
    public static let minSide = 0.05

    public var sanitized: FractionRect {
        func fix(_ v: Double) -> Double { v.isFinite ? v : 0 }
        let ww = min(max(fix(w), Self.minSide), 1)
        let hh = min(max(fix(h), Self.minSide), 1)
        return FractionRect(x: min(max(fix(x), 0), 1 - ww), y: min(max(fix(y), 0), 1 - hh), w: ww, h: hh)
    }

    public var stored: String {
        [x, y, w, h].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    public init?(stored: String) {
        let p = stored.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        self = FractionRect(x: p[0], y: p[1], w: p[2], h: p[3]).sanitized
    }
}

public enum WindowLayoutGroup: String, CaseIterable, Sendable {
    case halves, thirds, twoThirds, corners, columns, rows, sixths, other, custom

    public var title: String {
        switch self {
        case .halves: "Половины"
        case .thirds: "Трети"
        case .twoThirds: "Две трети"
        case .corners: "Углы (четверти)"
        case .columns: "Колонки по четверти"
        case .rows: "Строки по четверти"
        case .sixths: "Шестые доли"
        case .other: "Прочее"
        case .custom: "Свои макеты"
        }
    }
}

public enum WindowLayoutAction: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case leftThird, centerThird, rightThird, topThird, middleThird, bottomThird
    case leftTwoThirds, centerTwoThirds, rightTwoThirds, topTwoThirds, bottomTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case leftQuarter, leftMiddleQuarter, rightMiddleQuarter, rightQuarter
    case topQuarter, upperMiddleQuarter, lowerMiddleQuarter, bottomQuarter
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, marginMaximize, center, restore, nextDisplay, previousDisplay
    case custom1, custom2, custom3, custom4, custom5, custom6, custom7, custom8

    public static let customSlots = 1...8

    public static func custom(slot: Int) -> WindowLayoutAction? { WindowLayoutAction(rawValue: "custom\(slot)") }

    public var customSlot: Int? {
        guard rawValue.hasPrefix("custom") else { return nil }
        return Int(rawValue.dropFirst(6))
    }

    public var group: WindowLayoutGroup {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf: .halves
        case .leftThird, .centerThird, .rightThird, .topThird, .middleThird, .bottomThird: .thirds
        case .leftTwoThirds, .centerTwoThirds, .rightTwoThirds, .topTwoThirds, .bottomTwoThirds: .twoThirds
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .corners
        case .leftQuarter, .leftMiddleQuarter, .rightMiddleQuarter, .rightQuarter: .columns
        case .topQuarter, .upperMiddleQuarter, .lowerMiddleQuarter, .bottomQuarter: .rows
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: .sixths
        case .maximize, .marginMaximize, .center, .restore, .nextDisplay, .previousDisplay: .other
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8: .custom
        }
    }

    public var title: String {
        switch self {
        case .leftHalf: "Левая половина"
        case .rightHalf: "Правая половина"
        case .topHalf: "Верхняя половина"
        case .bottomHalf: "Нижняя половина"
        case .centerHalf: "Центральная половина"
        case .leftThird: "Левая треть"
        case .centerThird: "Центральная треть"
        case .rightThird: "Правая треть"
        case .topThird: "Верхняя треть"
        case .middleThird: "Средняя треть"
        case .bottomThird: "Нижняя треть"
        case .leftTwoThirds: "Левые две трети"
        case .centerTwoThirds: "Центральные две трети"
        case .rightTwoThirds: "Правые две трети"
        case .topTwoThirds: "Верхние две трети"
        case .bottomTwoThirds: "Нижние две трети"
        case .topLeft: "Левый верхний угол"
        case .topRight: "Правый верхний угол"
        case .bottomLeft: "Левый нижний угол"
        case .bottomRight: "Правый нижний угол"
        case .leftQuarter: "Левая четверть"
        case .leftMiddleQuarter: "Левая средняя четверть"
        case .rightMiddleQuarter: "Правая средняя четверть"
        case .rightQuarter: "Правая четверть"
        case .topQuarter: "Верхняя четверть"
        case .upperMiddleQuarter: "Верхняя средняя четверть"
        case .lowerMiddleQuarter: "Нижняя средняя четверть"
        case .bottomQuarter: "Нижняя четверть"
        case .topLeftSixth: "Шестая: верх слева"
        case .topCenterSixth: "Шестая: верх по центру"
        case .topRightSixth: "Шестая: верх справа"
        case .bottomLeftSixth: "Шестая: низ слева"
        case .bottomCenterSixth: "Шестая: низ по центру"
        case .bottomRightSixth: "Шестая: низ справа"
        case .maximize: "Максимум"
        case .marginMaximize: "Максимум с полями"
        case .center: "По центру"
        case .restore: "Вернуть прежний размер"
        case .nextDisplay: "На следующий дисплей"
        case .previousDisplay: "На предыдущий дисплей"
        default: "Свой макет \(customSlot ?? 0)"
        }
    }

    public var hotkeyID: String { "windowLayout.\(rawValue)" }

    public var fraction: FractionRect? {
        let t = 1.0 / 3.0
        let q = 0.25
        switch self {
        case .leftHalf: return FractionRect(x: 0, y: 0, w: 0.5, h: 1)
        case .rightHalf: return FractionRect(x: 0.5, y: 0, w: 0.5, h: 1)
        case .topHalf: return FractionRect(x: 0, y: 0, w: 1, h: 0.5)
        case .bottomHalf: return FractionRect(x: 0, y: 0.5, w: 1, h: 0.5)
        case .centerHalf: return FractionRect(x: 0.25, y: 0, w: 0.5, h: 1)
        case .leftThird: return FractionRect(x: 0, y: 0, w: t, h: 1)
        case .centerThird: return FractionRect(x: t, y: 0, w: t, h: 1)
        case .rightThird: return FractionRect(x: 2 * t, y: 0, w: t, h: 1)
        case .topThird: return FractionRect(x: 0, y: 0, w: 1, h: t)
        case .middleThird: return FractionRect(x: 0, y: t, w: 1, h: t)
        case .bottomThird: return FractionRect(x: 0, y: 2 * t, w: 1, h: t)
        case .leftTwoThirds: return FractionRect(x: 0, y: 0, w: 2 * t, h: 1)
        case .centerTwoThirds: return FractionRect(x: t / 2, y: 0, w: 2 * t, h: 1)
        case .rightTwoThirds: return FractionRect(x: t, y: 0, w: 2 * t, h: 1)
        case .topTwoThirds: return FractionRect(x: 0, y: 0, w: 1, h: 2 * t)
        case .bottomTwoThirds: return FractionRect(x: 0, y: t, w: 1, h: 2 * t)
        case .topLeft: return FractionRect(x: 0, y: 0, w: 0.5, h: 0.5)
        case .topRight: return FractionRect(x: 0.5, y: 0, w: 0.5, h: 0.5)
        case .bottomLeft: return FractionRect(x: 0, y: 0.5, w: 0.5, h: 0.5)
        case .bottomRight: return FractionRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)
        case .leftQuarter: return FractionRect(x: 0, y: 0, w: q, h: 1)
        case .leftMiddleQuarter: return FractionRect(x: q, y: 0, w: q, h: 1)
        case .rightMiddleQuarter: return FractionRect(x: 2 * q, y: 0, w: q, h: 1)
        case .rightQuarter: return FractionRect(x: 3 * q, y: 0, w: q, h: 1)
        case .topQuarter: return FractionRect(x: 0, y: 0, w: 1, h: q)
        case .upperMiddleQuarter: return FractionRect(x: 0, y: q, w: 1, h: q)
        case .lowerMiddleQuarter: return FractionRect(x: 0, y: 2 * q, w: 1, h: q)
        case .bottomQuarter: return FractionRect(x: 0, y: 3 * q, w: 1, h: q)
        case .topLeftSixth: return FractionRect(x: 0, y: 0, w: t, h: 0.5)
        case .topCenterSixth: return FractionRect(x: t, y: 0, w: t, h: 0.5)
        case .topRightSixth: return FractionRect(x: 2 * t, y: 0, w: t, h: 0.5)
        case .bottomLeftSixth: return FractionRect(x: 0, y: 0.5, w: t, h: 0.5)
        case .bottomCenterSixth: return FractionRect(x: t, y: 0.5, w: t, h: 0.5)
        case .bottomRightSixth: return FractionRect(x: 2 * t, y: 0.5, w: t, h: 0.5)
        case .maximize: return .full
        case .marginMaximize, .center, .restore, .nextDisplay, .previousDisplay: return nil
        default: return nil
        }
    }

    public var needsWindow: Bool { self == .center }
    public var movesBetweenDisplays: Bool { self == .nextDisplay || self == .previousDisplay }

    public static let snapTargets: [WindowLayoutAction] = allCases.filter { $0.fraction != nil || $0 == .marginMaximize || $0.customSlot != nil }
}

public enum WindowHotkeys {
    public static func spec(for action: WindowLayoutAction) -> HotkeySpec {
        HotkeySpec(id: action.hotkeyID, title: "Окна: " + action.title, defaultCombo: .none)
    }

    public static let cursorNextDisplay = HotkeySpec(id: "windowLayout.cursorNextDisplay", title: "Окна: курсор на следующий дисплей", defaultCombo: .none)

    public static let actions: [HotkeySpec] = WindowLayoutAction.allCases.map(spec(for:))
    public static let all: [HotkeySpec] = actions + [cursorNextDisplay]
}

public struct WindowGaps: Equatable, Sendable {
    public static let range = 0...128
    public static let presets = [0, 8, 16, 32, 64, 128]
    public var window = 0
    public var screen = 0

    public init(window: Int = 0, screen: Int = 0) {
        self.window = window
        self.screen = screen
    }

    public static let none = WindowGaps()

    public var sanitized: WindowGaps {
        WindowGaps(window: min(max(window, Self.range.lowerBound), Self.range.upperBound), screen: min(max(screen, Self.range.lowerBound), Self.range.upperBound))
    }
}

public struct CustomLayout: Equatable, Sendable {
    public var name: String
    public var rect: FractionRect

    public init(name: String, rect: FractionRect) {
        self.name = name
        self.rect = rect.sanitized
    }
}

public enum LayoutRepeat: String, CaseIterable, Sendable {
    case none, cycleSizes, crossDisplay

    public var title: String {
        switch self {
        case .none: "Ничего не делать"
        case .cycleSizes: "Менять размер: половина, две трети, треть"
        case .crossDisplay: "Переносить на соседний дисплей"
        }
    }
}

public struct GestureModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = GestureModifiers(rawValue: 1)
    public static let option = GestureModifiers(rawValue: 2)
    public static let command = GestureModifiers(rawValue: 4)
    public static let shift = GestureModifiers(rawValue: 8)

    public static let order: [(GestureModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

    public var glyphs: String { Self.order.filter { contains($0.0) }.map(\.1).joined() }

    public init(flags: CGEventFlags) {
        var m: GestureModifiers = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        self = m
    }

    public static func parse(_ stored: String?) -> GestureModifiers? {
        guard let stored, let n = Int(stored), n >= 0, n < 16 else { return nil }
        return GestureModifiers(rawValue: n)
    }
}

public struct EdgeSnapSettings: Equatable, Sendable {
    public static let distanceRange = 4...40
    public var enabled = false
    public var disabledZones: Set<SnapZone> = []
    public var layout = SnapZoneLayout()
    public var distance = 12
    public var showPreview = true
    public init() {}

    public var enabledZones: Set<SnapZone> { Set(SnapZone.allCases).subtracting(disabledZones) }

    public var sanitized: EdgeSnapSettings {
        var s = self
        s.distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        return s
    }
}

public struct GestureSettings: Equatable, Sendable {
    public var enabled = false
    public var move: GestureModifiers = [.control, .option]
    public var resize: GestureModifiers = [.control, .option, .shift]
    public var raiseWindow = false
    public init() {}

    public var isValid: Bool { !move.isEmpty && !resize.isEmpty && move != resize }
}

public struct RingSettings: Equatable, Sendable {
    public static let defaultTrigger = KeyCombo(keyCode: Keys.space, modifiers: KeyCombo.ctrl | KeyCombo.opt)
    public var enabled = false
    public var trigger = RingSettings.defaultTrigger
    public init() {}
}

public struct WindowLayoutSettings: Equatable, Sendable {
    public static let marginRange = 0.0...25.0
    public var shortcutsEnabled = true
    public var gaps = WindowGaps()
    public var marginPercent = 5.0
    public var repeatMode = LayoutRepeat.none
    public var ignoredApps = AppExceptionList()
    public var custom: [Int: CustomLayout] = [:]
    public var edge = EdgeSnapSettings()
    public var gesture = GestureSettings()
    public var ring = RingSettings()
    public var cursorDisplayEnabled = true
    public init() {}

    public var sanitized: WindowLayoutSettings {
        var s = self
        s.gaps = gaps.sanitized
        s.marginPercent = min(max(marginPercent.isFinite ? marginPercent : 5, Self.marginRange.lowerBound), Self.marginRange.upperBound)
        s.edge = edge.sanitized
        s.custom = custom.filter { WindowLayoutAction.customSlots.contains($0.key) }.mapValues { CustomLayout(name: $0.name, rect: $0.rect) }
        return s
    }

    public func customRect(for action: WindowLayoutAction) -> FractionRect? {
        guard let slot = action.customSlot else { return nil }
        return custom[slot]?.rect
    }
}
