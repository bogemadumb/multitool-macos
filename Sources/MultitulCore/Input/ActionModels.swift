import Foundation
import CoreGraphics

public enum Keys {
    public static let q: UInt32 = 12
    public static let w: UInt32 = 13
    public static let v: UInt32 = 9
    public static let s: UInt32 = 1
    public static let m: UInt32 = 46
    public static let h: UInt32 = 4
    public static let backtick: UInt32 = 50
    public static let returnKey: UInt32 = 36
    public static let enterKey: UInt32 = 76
    public static let tab: UInt32 = 48
    public static let space: UInt32 = 49
    public static let backspace: UInt32 = 51
    public static let escape: UInt32 = 53
    public static let leftBracket: UInt32 = 33
    public static let rightBracket: UInt32 = 30
    public static let minus: UInt32 = 27
    public static let f18: UInt32 = 79
    public static let f4: UInt32 = 118
    public static let f11: UInt32 = 103
    public static let left: UInt32 = 123
    public static let right: UInt32 = 124
    public static let down: UInt32 = 125
    public static let up: UInt32 = 126
    public static let rightCommand: UInt32 = 54
    public static let rightShift: UInt32 = 60
    public static let rightOption: UInt32 = 61
    public static let rightControl: UInt32 = 62
}

public extension KeyCombo {
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & KeyCombo.cmd != 0 { f.insert(.maskCommand) }
        if modifiers & KeyCombo.shift != 0 { f.insert(.maskShift) }
        if modifiers & KeyCombo.opt != 0 { f.insert(.maskAlternate) }
        if modifiers & KeyCombo.ctrl != 0 { f.insert(.maskControl) }
        return f
    }

    static func modifierMask(from flags: CGEventFlags) -> UInt32 { KeyStroke.modifiers(from: flags) }
}

public enum ModifierFlags {
    public static let all: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
}

public protocol KeyPosting: AnyObject {
    func post(keyCode: UInt32, flags: CGEventFlags)
    func type(_ text: String)
}

public protocol MousePosting: AnyObject {
    func post(button: Int64, down: Bool, at point: CGPoint, flags: CGEventFlags)
    func pointerLocation() -> CGPoint
}

public protocol SymbolicHotKeyPosting: AnyObject {
    func post(_ id: Int32) -> Bool
}

public protocol MagnifyPosting: AnyObject {
    func post(magnification: Double)
}

public protocol CancelHandle: AnyObject {
    func cancel()
}

public protocol TimerScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelHandle
}

public enum ButtonTrigger: Hashable, Sendable {
    case button(Int64)
    case scrollLeft
    case scrollRight

    public var storage: String {
        switch self {
        case .button(let n): "b\(n)"
        case .scrollLeft: "sl"
        case .scrollRight: "sr"
        }
    }

    public init?(storage: String) {
        if storage == "sl" { self = .scrollLeft; return }
        if storage == "sr" { self = .scrollRight; return }
        guard storage.hasPrefix("b"), let n = Int64(storage.dropFirst()), n >= 2, n < 32 else { return nil }
        self = .button(n)
    }

    public var title: String {
        switch self {
        case .button(let n):
            switch n {
            case 2: "Колесо (средняя кнопка)"
            case 3: "Боковая «Назад» (кнопка 4)"
            case 4: "Боковая «Вперёд» (кнопка 5)"
            default: "Кнопка \(n + 1)"
            }
        case .scrollLeft: "Колесо влево"
        case .scrollRight: "Колесо вправо"
        }
    }
}

public enum ButtonAction: Equatable, Hashable, Sendable {
    case none
    case shortcut(KeyCombo)
    case missionControl
    case appExpose
    case spaceLeft
    case spaceRight
    case middleClick
    case showDesktop
    case launchpad

    public var storage: String {
        switch self {
        case .none: "none"
        case .shortcut(let c): "key:\(c.stored)"
        case .missionControl: "mission"
        case .appExpose: "expose"
        case .spaceLeft: "left"
        case .spaceRight: "right"
        case .middleClick: "middle"
        case .showDesktop: "desktop"
        case .launchpad: "launchpad"
        }
    }

    public init?(storage: String) {
        switch storage {
        case "none": self = .none
        case "mission": self = .missionControl
        case "expose": self = .appExpose
        case "left": self = .spaceLeft
        case "right": self = .spaceRight
        case "middle": self = .middleClick
        case "desktop": self = .showDesktop
        case "launchpad": self = .launchpad
        default:
            guard storage.hasPrefix("key:"), let c = KeyCombo(stored: String(storage.dropFirst(4))), !c.isNone else { return nil }
            self = .shortcut(c)
        }
    }

    public var keyCombo: KeyCombo? {
        switch self {
        case .shortcut(let c): c
        case .missionControl: KeyCombo(keyCode: Keys.up, modifiers: KeyCombo.ctrl)
        case .appExpose: KeyCombo(keyCode: Keys.down, modifiers: KeyCombo.ctrl)
        case .spaceLeft: KeyCombo(keyCode: Keys.left, modifiers: KeyCombo.ctrl)
        case .spaceRight: KeyCombo(keyCode: Keys.right, modifiers: KeyCombo.ctrl)
        case .showDesktop: KeyCombo(keyCode: Keys.f11, modifiers: 0)
        case .launchpad: KeyCombo(keyCode: Keys.f4, modifiers: 0)
        case .none, .middleClick: nil
        }
    }

    public var symbolicHotKeyID: Int32? {
        switch self {
        case .showDesktop: 36
        case .launchpad: 160
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .none: "Ничего"
        case .shortcut(let c): c.display
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .spaceLeft: "Рабочий стол влево"
        case .spaceRight: "Рабочий стол вправо"
        case .middleClick: "Средний клик"
        case .showDesktop: "Показать рабочий стол"
        case .launchpad: "Launchpad"
        }
    }
}

public struct ButtonBinding: Equatable, Sendable {
    public var trigger: ButtonTrigger
    public var click: ButtonAction
    public var gesture: Bool
    public var hold: ButtonAction
    public var doubleClick: ButtonAction

    public init(trigger: ButtonTrigger, click: ButtonAction, gesture: Bool = false, hold: ButtonAction = .none, doubleClick: ButtonAction = .none) {
        self.trigger = trigger
        self.click = click
        self.gesture = gesture
        self.hold = hold
        self.doubleClick = doubleClick
    }

    public var storage: String {
        let base = "\(trigger.storage)|\(click.storage)|\(gesture ? 1 : 0)"
        return hold == .none && doubleClick == .none ? base : "\(base)|\(hold.storage)|\(doubleClick.storage)"
    }

    public init?(storage: String) {
        let p = storage.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 || p.count == 5, let t = ButtonTrigger(storage: p[0]), let a = ButtonAction(storage: p[1]) else { return nil }
        let g = p[2] == "1"
        if g, case .button = t {} else if g { return nil }
        var h = ButtonAction.none
        var d = ButtonAction.none
        if p.count == 5 {
            guard let hh = ButtonAction(storage: p[3]), let dd = ButtonAction(storage: p[4]) else { return nil }
            if case .button = t { h = hh; d = dd }
        }
        self.init(trigger: t, click: a, gesture: g, hold: h, doubleClick: d)
    }
}

public struct MouseNavRule: Equatable, Sendable {
    public var pattern: String
    public var back: KeyCombo?
    public var forward: KeyCombo?

    public init(pattern: String, back: KeyCombo?, forward: KeyCombo?) {
        self.pattern = pattern
        self.back = back
        self.forward = forward
    }

    public var storage: String { "\(pattern)|\(back?.stored ?? "-")|\(forward?.stored ?? "-")" }

    public init?(storage: String) {
        let p = storage.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, !p[0].isEmpty else { return nil }
        self.init(pattern: p[0], back: KeyCombo(stored: p[1]), forward: KeyCombo(stored: p[2]))
    }
}

public enum MouseNavScope: String, CaseIterable, Sendable {
    case compatible, allApps

    public var title: String {
        switch self {
        case .compatible: "Только совместимые приложения"
        case .allApps: "Все приложения"
        }
    }
}

public struct MouseNavigationSettings: Equatable, Sendable {
    public var scope = MouseNavScope.compatible
    public var swapButtons = false
    public var rules: [MouseNavRule] = []
    public var exceptions = AppExceptionList()
    public init() {}
}

public struct ButtonShortcutsSettings: Equatable, Sendable {
    public static let thresholdRange = 20...400
    public static let defaultThreshold = 60
    public static let cooldownRange = 100...1000
    public static let defaultCooldown = 300
    public static let holdRange = 150...1000
    public static let defaultHold = 300
    public static let doubleRange = 100...600
    public static let defaultDouble = 250

    public var bindings: [ButtonBinding] = []
    public var gestureThreshold = ButtonShortcutsSettings.defaultThreshold
    public var scrollCooldownMs = ButtonShortcutsSettings.defaultCooldown
    public var holdMs = ButtonShortcutsSettings.defaultHold
    public var doubleMs = ButtonShortcutsSettings.defaultDouble
    public var exceptions = AppExceptionList()
    public init() {}

    public var sanitized: ButtonShortcutsSettings {
        var s = self
        s.gestureThreshold = min(max(gestureThreshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        s.scrollCooldownMs = min(max(scrollCooldownMs, Self.cooldownRange.lowerBound), Self.cooldownRange.upperBound)
        s.holdMs = min(max(holdMs, Self.holdRange.lowerBound), Self.holdRange.upperBound)
        s.doubleMs = min(max(doubleMs, Self.doubleRange.lowerBound), Self.doubleRange.upperBound)
        var seen = Set<ButtonTrigger>()
        s.bindings = bindings.filter { seen.insert($0.trigger).inserted }
        return s
    }

    public func binding(for trigger: ButtonTrigger) -> ButtonBinding? { bindings.first { $0.trigger == trigger } }
}

public struct MiddleClickSettings: Equatable, Sendable {
    public static let tapDurationRange = 100...600
    public static let defaultTapDuration = 300

    public var tapEnabled = false
    public var tapMaxMs = MiddleClickSettings.defaultTapDuration
    public init() {}

    public var sanitized: MiddleClickSettings {
        var s = self
        s.tapMaxMs = min(max(tapMaxMs, Self.tapDurationRange.lowerBound), Self.tapDurationRange.upperBound)
        return s
    }
}

public enum SuperKeySource: String, CaseIterable, Sendable {
    case capsLock, rightShift, rightOption, rightCommand, rightControl

    public var title: String {
        switch self {
        case .capsLock: "Caps Lock"
        case .rightShift: "Правый Shift"
        case .rightOption: "Правый Option"
        case .rightCommand: "Правый Command"
        case .rightControl: "Правый Control"
        }
    }

    public var keyCode: UInt32 {
        switch self {
        case .capsLock: Keys.f18
        case .rightShift: Keys.rightShift
        case .rightOption: Keys.rightOption
        case .rightCommand: Keys.rightCommand
        case .rightControl: Keys.rightControl
        }
    }

    public var isModifier: Bool { self != .capsLock }

    public var deviceMask: UInt64 {
        switch self {
        case .capsLock: 0
        case .rightShift: 0x04
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        }
    }

    public var leftDeviceMask: UInt64 {
        switch self {
        case .capsLock: 0
        case .rightShift: 0x02
        case .rightOption: 0x20
        case .rightCommand: 0x08
        case .rightControl: 0x01
        }
    }

    public var ownFlag: CGEventFlags? {
        switch self {
        case .capsLock: nil
        case .rightShift: .maskShift
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        }
    }
}

public enum SuperKeySolo: String, CaseIterable, Sendable {
    case none, capsLock, inputSource, escape

    public var title: String {
        switch self {
        case .none: "Ничего"
        case .capsLock: "Переключить Caps Lock"
        case .inputSource: "Переключить раскладку"
        case .escape: "Нажать Esc"
        }
    }
}

public struct SuperKeySettings: Equatable, Sendable {
    public static let defaultModifiers: UInt32 = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd
    public static let tapRange = 100...500
    public static let defaultTap = 250
    public static let longHoldRange = 300...2000
    public static let defaultLongHold = 700

    public var source = SuperKeySource.capsLock
    public var modifiers = SuperKeySettings.defaultModifiers
    public var solo = SuperKeySolo.inputSource
    public var longHoldCapsLock = true
    public var tapMaxMs = SuperKeySettings.defaultTap
    public var longHoldMs = SuperKeySettings.defaultLongHold
    public var exceptions = AppExceptionList()
    public init() {}

    public var sanitized: SuperKeySettings {
        var s = self
        s.modifiers &= (KeyCombo.cmd | KeyCombo.shift | KeyCombo.opt | KeyCombo.ctrl)
        if s.modifiers == 0 { s.modifiers = Self.defaultModifiers }
        s.tapMaxMs = min(max(tapMaxMs, Self.tapRange.lowerBound), Self.tapRange.upperBound)
        s.longHoldMs = min(max(longHoldMs, Self.longHoldRange.lowerBound), Self.longHoldRange.upperBound)
        return s
    }
}

public enum ProtectionMode: String, CaseIterable, Sendable {
    case off, hold, doublePress, extraModifier

    public var title: String {
        switch self {
        case .off: "Выключено"
        case .hold: "Удержание"
        case .doublePress: "Двойное нажатие"
        case .extraModifier: "Дополнительный модификатор"
        }
    }
}

public enum ProtectionScope: String, CaseIterable, Sendable {
    case all, except, only

    public var title: String {
        switch self {
        case .all: "Все приложения"
        case .except: "Все, кроме выбранных"
        case .only: "Только выбранные"
        }
    }
}

public struct KeyProtection: Equatable, Sendable {
    public static let holdRange = 200...3000
    public static let defaultHold = 1000
    public static let doubleRange = 300...3000
    public static let defaultDouble = 1500

    public var mode: ProtectionMode
    public var holdMs = KeyProtection.defaultHold
    public var doubleWindowMs = KeyProtection.defaultDouble
    public var extra = ScrollModifierKey.option
    public var scope = ProtectionScope.all
    public var apps = AppExceptionList()

    public init(mode: ProtectionMode) { self.mode = mode }

    public var sanitized: KeyProtection {
        var s = self
        s.holdMs = min(max(holdMs, Self.holdRange.lowerBound), Self.holdRange.upperBound)
        s.doubleWindowMs = min(max(doubleWindowMs, Self.doubleRange.lowerBound), Self.doubleRange.upperBound)
        if s.extra == .command { s.extra = .option }
        return s
    }

    public func covers(_ bundleID: String?) -> Bool {
        switch scope {
        case .all: true
        case .except: !apps.contains(bundleID)
        case .only: apps.contains(bundleID)
        }
    }
}

public struct QuitProtectionSettings: Equatable, Sendable {
    public var quit = KeyProtection(mode: .hold)
    public var close = KeyProtection(mode: .off)
    public var showHud = true
    public init() {}

    public var sanitized: QuitProtectionSettings {
        var s = self
        s.quit = quit.sanitized
        s.close = close.sanitized
        return s
    }

    public func protection(forKeyCode code: UInt32) -> KeyProtection? {
        switch code {
        case Keys.q: quit.mode == .off ? nil : quit
        case Keys.w: close.mode == .off ? nil : close
        default: nil
        }
    }

    public var reservedCombos: [KeyCombo] {
        var out: [KeyCombo] = []
        if quit.mode != .off { out.append(InterceptedKeys.quit) }
        if close.mode != .off { out.append(InterceptedKeys.close) }
        return out
    }
}

public extension InputSettingsStore {
    private func comboList(_ key: String) -> [String] { (defaults.array(forKey: key) as? [String]) ?? [] }

    private func putStrings(_ key: String, _ v: [String]) {
        if v.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
    }

    func loadNavigation() -> MouseNavigationSettings {
        var s = MouseNavigationSettings()
        if let v = defaults.string(forKey: "input.nav.scope"), let m = MouseNavScope(rawValue: v) { s.scope = m }
        s.swapButtons = bool("input.nav.swap", s.swapButtons)
        s.rules = comboList("input.nav.rules").compactMap(MouseNavRule.init(storage:))
        s.exceptions = list("input.nav.exceptions", s.exceptions)
        return s
    }

    func saveNavigation(_ s: MouseNavigationSettings) {
        let b = MouseNavigationSettings()
        put("input.nav.scope", s.scope.rawValue, b.scope.rawValue)
        put("input.nav.swap", s.swapButtons, b.swapButtons)
        putStrings("input.nav.rules", s.rules.map(\.storage))
        putList("input.nav.exceptions", s.exceptions, b.exceptions)
    }

    func loadButtons() -> ButtonShortcutsSettings {
        var s = ButtonShortcutsSettings()
        s.bindings = comboList("input.buttons.bindings").compactMap(ButtonBinding.init(storage:))
        s.gestureThreshold = int("input.buttons.threshold", s.gestureThreshold)
        s.scrollCooldownMs = int("input.buttons.cooldown", s.scrollCooldownMs)
        s.holdMs = int("input.buttons.holdMs", s.holdMs)
        s.doubleMs = int("input.buttons.doubleMs", s.doubleMs)
        s.exceptions = list("input.buttons.exceptions", s.exceptions)
        return s.sanitized
    }

    func saveButtons(_ settings: ButtonShortcutsSettings) {
        let s = settings.sanitized
        let b = ButtonShortcutsSettings()
        putStrings("input.buttons.bindings", s.bindings.map(\.storage))
        put("input.buttons.threshold", s.gestureThreshold, b.gestureThreshold)
        put("input.buttons.cooldown", s.scrollCooldownMs, b.scrollCooldownMs)
        put("input.buttons.holdMs", s.holdMs, b.holdMs)
        put("input.buttons.doubleMs", s.doubleMs, b.doubleMs)
        putList("input.buttons.exceptions", s.exceptions, b.exceptions)
    }

    func loadMiddle() -> MiddleClickSettings {
        var s = MiddleClickSettings()
        s.tapEnabled = bool("input.middle.tap", s.tapEnabled)
        s.tapMaxMs = int("input.middle.tapMs", s.tapMaxMs)
        return s.sanitized
    }

    func saveMiddle(_ settings: MiddleClickSettings) {
        let s = settings.sanitized
        let b = MiddleClickSettings()
        put("input.middle.tap", s.tapEnabled, b.tapEnabled)
        put("input.middle.tapMs", s.tapMaxMs, b.tapMaxMs)
    }

    func loadSuperKey() -> SuperKeySettings {
        var s = SuperKeySettings()
        if let v = defaults.string(forKey: "input.superKey.source"), let m = SuperKeySource(rawValue: v) { s.source = m }
        s.modifiers = UInt32(max(0, int("input.superKey.modifiers", Int(s.modifiers))))
        if let v = defaults.string(forKey: "input.superKey.solo"), let m = SuperKeySolo(rawValue: v) { s.solo = m }
        s.longHoldCapsLock = bool("input.superKey.longHold", s.longHoldCapsLock)
        s.tapMaxMs = int("input.superKey.tapMs", s.tapMaxMs)
        s.longHoldMs = int("input.superKey.longHoldMs", s.longHoldMs)
        s.exceptions = list("input.superKey.exceptions", s.exceptions)
        return s.sanitized
    }

    func saveSuperKey(_ settings: SuperKeySettings) {
        let s = settings.sanitized
        let b = SuperKeySettings()
        put("input.superKey.source", s.source.rawValue, b.source.rawValue)
        put("input.superKey.modifiers", Int(s.modifiers), Int(b.modifiers))
        put("input.superKey.solo", s.solo.rawValue, b.solo.rawValue)
        put("input.superKey.longHold", s.longHoldCapsLock, b.longHoldCapsLock)
        put("input.superKey.tapMs", s.tapMaxMs, b.tapMaxMs)
        put("input.superKey.longHoldMs", s.longHoldMs, b.longHoldMs)
        putList("input.superKey.exceptions", s.exceptions, b.exceptions)
    }

    private func loadProtection(_ prefix: String, default d: KeyProtection) -> KeyProtection {
        var p = d
        if let v = defaults.string(forKey: "\(prefix).mode"), let m = ProtectionMode(rawValue: v) { p.mode = m }
        p.holdMs = int("\(prefix).holdMs", p.holdMs)
        p.doubleWindowMs = int("\(prefix).doubleMs", p.doubleWindowMs)
        if let v = defaults.string(forKey: "\(prefix).extra"), let m = ScrollModifierKey(rawValue: v) { p.extra = m }
        if let v = defaults.string(forKey: "\(prefix).scope"), let m = ProtectionScope(rawValue: v) { p.scope = m }
        p.apps = list("\(prefix).apps", p.apps)
        return p.sanitized
    }

    private func saveProtection(_ prefix: String, _ p: KeyProtection, default d: KeyProtection) {
        put("\(prefix).mode", p.mode.rawValue, d.mode.rawValue)
        put("\(prefix).holdMs", p.holdMs, d.holdMs)
        put("\(prefix).doubleMs", p.doubleWindowMs, d.doubleWindowMs)
        put("\(prefix).extra", p.extra.rawValue, d.extra.rawValue)
        put("\(prefix).scope", p.scope.rawValue, d.scope.rawValue)
        putList("\(prefix).apps", p.apps, d.apps)
    }

    func loadQuit() -> QuitProtectionSettings {
        let d = QuitProtectionSettings()
        var s = d
        s.quit = loadProtection("input.quit.q", default: d.quit)
        s.close = loadProtection("input.quit.w", default: d.close)
        s.showHud = bool("input.quit.hud", s.showHud)
        return s
    }

    func saveQuit(_ settings: QuitProtectionSettings) {
        let s = settings.sanitized
        let d = QuitProtectionSettings()
        saveProtection("input.quit.q", s.quit.sanitized, default: d.quit)
        saveProtection("input.quit.w", s.close.sanitized, default: d.close)
        put("input.quit.hud", s.showHud, d.showHud)
    }
}
