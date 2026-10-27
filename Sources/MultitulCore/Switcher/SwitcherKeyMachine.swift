import Foundation
import CoreGraphics

public enum SwitcherTrigger: Equatable, Sendable {
    case apps
    case windows
}

public protocol SwitcherControlling: AnyObject {
    func begin(trigger: SwitcherTrigger, backward: Bool) -> Bool
    func present()
    func move(_ step: Int)
    func moveVertical(_ rows: Int)
    func commit()
    func cancel()
    func closeSelected()
    func quitSelected()
    func minimizeSelected()
    func hideSelected()
    func beginSearch()
    func appendQuery(_ text: String)
    func deleteQueryCharacter()
    func clearQuery() -> Bool
    func containsPoint(_ p: CGPoint) -> Bool
}

public final class SwitcherKeyMachine {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]

    public private(set) var active = false
    public private(set) var presented = false
    public private(set) var searching = false
    public private(set) var pinned = false
    private var holdMask: UInt32 = 0
    private var swallowedUps = Set<UInt32>()
    private var showTimer: CancelHandle?
    private let controller: SwitcherControlling
    private let timers: TimerScheduling
    private let settings: () -> SwitcherSettings
    private let trusted: () -> Bool

    public init(controller: SwitcherControlling, timers: TimerScheduling, settings: @escaping () -> SwitcherSettings, trusted: @escaping () -> Bool = { true }) {
        self.controller = controller
        self.timers = timers
        self.settings = settings
        self.trusted = trusted
    }

    public var wantsText: Bool { active && searching }

    public func reset() {
        showTimer?.cancel()
        showTimer = nil
        swallowedUps.removeAll()
        if active { controller.cancel() }
        clearState()
    }

    private func clearState() {
        active = false
        presented = false
        searching = false
        pinned = false
        holdMask = 0
        showTimer?.cancel()
        showTimer = nil
    }

    private static let shiftBit = KeyCombo.shift

    private func matches(_ trigger: KeyCombo, code: UInt32, mods: UInt32) -> Bool? {
        guard code == trigger.keyCode else { return nil }
        if mods == trigger.modifiers { return false }
        if trigger.modifiers & Self.shiftBit == 0, mods == trigger.modifiers | Self.shiftBit { return true }
        return nil
    }

    public func keyDown(code: UInt32, mods: UInt32, isRepeat: Bool, text: () -> String?) -> EventTapAction {
        guard trusted() else { return .pass }
        let s = settings()
        let appsT = s.effectiveAppsTrigger, winT = s.effectiveWindowsTrigger
        if !active {
            if isRepeat, swallowedUps.contains(code) { return .drop }
            if let back = matches(appsT, code: code, mods: mods) { return start(.apps, backward: back, hold: appsT.modifiers, code: code) }
            if let back = matches(winT, code: code, mods: mods) { return start(.windows, backward: back, hold: winT.modifiers, code: code) }
            return .pass
        }
        if !pinned, mods & holdMask != holdMask {
            controller.cancel()
            clearState()
            swallowedUps.removeAll()
            return .pass
        }
        swallowedUps.insert(code)
        if let back = matches(appsT, code: code, mods: mods) ?? matches(winT, code: code, mods: mods) {
            controller.move(back ? -1 : 1)
            return .drop
        }
        if pinned, code == Keys.tab, mods & ~Self.shiftBit == 0 {
            controller.move(mods & Self.shiftBit != 0 ? -1 : 1)
            return .drop
        }
        let plain = mods & ~(holdMask | Self.shiftBit) == 0
        switch code {
        case Keys.escape:
            if searching, controller.clearQuery() { return .drop }
            finish(commit: false)
        case Keys.returnKey, Keys.enterKey:
            finish(commit: true)
        case Keys.left:
            controller.move(-1)
        case Keys.right:
            controller.move(1)
        case Keys.up:
            controller.moveVertical(-1)
        case Keys.down:
            controller.moveVertical(1)
        case Keys.backspace:
            if searching { controller.deleteQueryCharacter() }
        default:
            if searching {
                if plain, let t = text(), Self.isSearchText(t) { controller.appendQuery(t) }
            } else if plain, !isRepeat {
                switch code {
                case Keys.q: controller.quitSelected()
                case Keys.w: controller.closeSelected()
                case Keys.m: controller.minimizeSelected()
                case Keys.h: controller.hideSelected()
                case Keys.s: beginSearch()
                default: break
                }
            }
        }
        return .drop
    }

    private func beginSearch() {
        searching = true
        pinned = settings().searchPin
        showTimer?.cancel()
        showTimer = nil
        controller.beginSearch()
        presented = true
    }

    public func keyUp(code: UInt32) -> EventTapAction {
        swallowedUps.remove(code) != nil ? .drop : .pass
    }

    public func flagsChanged(mods: UInt32) -> EventTapAction {
        guard active, !pinned, mods & holdMask != holdMask else { return .pass }
        finish(commit: true)
        return .pass
    }

    public func mouseDown(at p: CGPoint) -> EventTapAction {
        guard active, presented else { return .pass }
        if !controller.containsPoint(p) { finish(commit: false) }
        return .pass
    }

    public func panelClosedExternally() { clearState() }

    private func start(_ trigger: SwitcherTrigger, backward: Bool, hold: UInt32, code: UInt32) -> EventTapAction {
        swallowedUps.insert(code)
        guard controller.begin(trigger: trigger, backward: backward) else { return .drop }
        active = true
        holdMask = hold & (KeyCombo.cmd | KeyCombo.opt | KeyCombo.ctrl)
        let delay = settings().appearanceDelayMs
        if delay <= 0 {
            presented = true
            controller.present()
        } else {
            showTimer = timers.schedule(after: Double(delay) / 1000) { [weak self] in
                guard let self, self.active, !self.presented else { return }
                self.presented = true
                self.controller.present()
            }
        }
        return .drop
    }

    private func finish(commit: Bool) {
        let wasActive = active
        clearState()
        guard wasActive else { return }
        if commit { controller.commit() } else { controller.cancel() }
    }

    static func isSearchText(_ t: String) -> Bool {
        guard let u = t.unicodeScalars.first else { return false }
        if u.value < 0x20 || u.value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(u.value) { return false }
        return true
    }
}

public final class SwitcherStage {
    private let hub: EventTapHub
    private let machine: SwitcherKeyMachine
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, machine: SwitcherKeyMachine) {
        self.hub = hub
        self.machine = machine
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: SwitcherKeyMachine.types, priority: InputPriority.switcher, seesDropped: false, onReset: { [weak self] in self?.machine.reset() }) { [weak self] type, e in
            self?.handle(type, e) ?? .pass
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        machine.reset()
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> EventTapAction {
        switch type {
        case .keyDown:
            let code = UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
            let rep = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return machine.keyDown(code: code, mods: KeyStroke.modifiers(from: e.flags), isRepeat: rep, text: { Self.text(of: e) })
        case .keyUp:
            return machine.keyUp(code: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            return machine.flagsChanged(mods: KeyStroke.modifiers(from: e.flags))
        case .leftMouseDown:
            return machine.mouseDown(at: e.location)
        default:
            return .pass
        }
    }

    static func text(of e: CGEvent) -> String? {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buf, count: length)
    }
}
