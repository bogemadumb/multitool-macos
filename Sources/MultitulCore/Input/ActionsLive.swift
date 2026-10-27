import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit
import IOKit.hid

public final class LiveKeyPoster: KeyPosting {
    public init() {}

    public func post(keyCode: UInt32, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .privateState) else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            e.flags = flags
            EventTapHub.markSynthetic(e)
            e.post(tap: .cghidEventTap)
        }
    }

    public func type(_ text: String) {
        guard let src = CGEventSource(stateID: .privateState) else { return }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let end = min(i + 16, units.count)
            var chunk = Array(units[i..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                EventTapHub.markSynthetic(e)
                e.post(tap: .cghidEventTap)
            }
            i = end
        }
    }
}

public final class LiveMousePoster: MousePosting {
    public init() {}

    public func post(button: Int64, down: Bool, at point: CGPoint, flags: CGEventFlags) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; cgButton = CGMouseButton(rawValue: UInt32(max(2, button))) ?? .center
        }
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.flags = flags
        EventTapHub.markSynthetic(e)
        e.post(tap: .cghidEventTap)
    }

    public func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

public final class DispatchCancelHandle: CancelHandle {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    public func cancel() { item.cancel() }
}

public final class LiveTimerScheduler: TimerScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelHandle {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchCancelHandle(item)
    }
}

public final class LiveMagnifyPoster: MagnifyPosting {
    private static let gestureType: UInt32 = 29
    private static let hidTypeField: UInt32 = 110
    private static let zoomValueField: UInt32 = 113
    private static let phaseField: UInt32 = 132
    private static let hidTypeZoom: Int64 = 8

    public init() {}

    public func post(magnification: Double) {
        guard magnification != 0 else { return }
        send(0, phase: 1)
        send(magnification, phase: 2)
        send(0, phase: 4)
    }

    private func send(_ value: Double, phase: Int64) {
        guard let e = CGEvent(source: nil), let type = CGEventType(rawValue: Self.gestureType),
              let hid = CGEventField(rawValue: Self.hidTypeField), let zoom = CGEventField(rawValue: Self.zoomValueField), let ph = CGEventField(rawValue: Self.phaseField) else { return }
        e.type = type
        e.setIntegerValueField(hid, value: Self.hidTypeZoom)
        e.setDoubleValueField(zoom, value: value)
        e.setIntegerValueField(ph, value: phase)
        EventTapHub.markSynthetic(e)
        e.post(tap: .cgSessionEventTap)
    }
}

public final class LiveSymbolicHotKeyPoster: SymbolicHotKeyPosting {
    private typealias GetValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias SetValueFn = @convention(c) (Int32, UInt16, UInt16, UInt32) -> Int32
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool
    private static let unassigned: UInt16 = 0xFFFF
    private static let fnMask: UInt32 = 0x800000
    private static let fallbackKey: UInt16 = 90
    private static let restoreDelay: TimeInterval = 0.35

    private let getValue: GetValueFn?
    private let setValue: SetValueFn?
    private let setEnabled: SetEnabledFn?
    private let isEnabled: IsEnabledFn?
    private let keys: KeyPosting

    public init(keys: KeyPosting = LiveKeyPoster()) {
        let h = UnsafeMutableRawPointer(bitPattern: -2)
        getValue = dlsym(h, "CGSGetSymbolicHotKeyValue").map { unsafeBitCast($0, to: GetValueFn.self) }
        setValue = dlsym(h, "CGSSetSymbolicHotKeyValue").map { unsafeBitCast($0, to: SetValueFn.self) }
        setEnabled = dlsym(h, "CGSSetSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: SetEnabledFn.self) }
        isEnabled = dlsym(h, "CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: IsEnabledFn.self) }
        self.keys = keys
    }

    public func post(_ id: Int32) -> Bool {
        guard let getValue, let setValue, let setEnabled, let isEnabled else { return false }
        var uni: UInt16 = 0
        var code: UInt16 = 0
        var mods: UInt32 = 0
        guard getValue(id, &uni, &code, &mods) == 0 else { return false }
        let wasEnabled = isEnabled(id)
        let wasUnassigned = code == Self.unassigned
        if wasUnassigned { guard setValue(id, uni, Self.fallbackKey, Self.fnMask) == 0 else { return false } }
        if !wasEnabled { guard setEnabled(id, true) == 0 else { return false } }
        let useCode = wasUnassigned ? UInt32(Self.fallbackKey) : UInt32(code)
        let useMods = wasUnassigned ? Self.fnMask : mods
        keys.post(keyCode: useCode, flags: CGEventFlags(rawValue: UInt64(useMods)))
        if wasUnassigned || !wasEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) { [weak self] in
                guard let self else { return }
                if wasUnassigned { _ = setValue(id, uni, code, mods) }
                if !wasEnabled { _ = setEnabled(id, false) }
            }
        }
        return true
    }
}

public final class LiveCapsLock: CapsLockToggling {
    public init() {}

    public func toggleCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(1), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(1), &on)
        IOHIDSetModifierLockState(connect, Int32(1), !on)
    }
}

public final class LiveInputSourceSwitcher: InputSourceSwitching {
    public init() {}

    private func identifier(_ s: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    public func selectNextSource() {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true, kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], list.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentID = identifier(current)
        let idx = list.firstIndex { identifier($0) == currentID } ?? -1
        TISSelectInputSource(list[(idx + 1) % list.count])
    }
}

public final class LiveSecureInput: SecureInputChecking {
    public init() {}
    public func isSecureInputActive() -> Bool { IsSecureEventInputEnabled() }
}

public final class AXSecureFocusInspector: SecureFocusInspecting {
    public init() {}

    public func focusIsSecure(pid: Int32) -> Bool {
        guard AXIsProcessTrusted(), pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let el = focused else { return false }
        let element = el as! AXUIElement
        var sub: CFTypeRef?
        let subrole = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub) == .success ? sub as? String : nil
        var role: CFTypeRef?
        let roleName = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success ? role as? String : nil
        return FocusRole.isSecure(role: roleName, subrole: subrole)
    }
}

public extension FocusRole {
    static func isSecure(role: String?, subrole: String?) -> Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
}

public final class LiveSystemGestureInfo: SystemGestureInfo {
    public init() {}

    public func threeFingerDragEnabled() -> Bool {
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            if let v = CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, domain as CFString) as? Bool, v { return true }
        }
        return false
    }
}

public final class HidutilRemapper: KeyRemapping {
    private let tool = "/usr/bin/hidutil"

    public init() {}

    private func run(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    private func current() -> [HIDMapping]? {
        let r = run(["property", "--get", "UserKeyMapping"])
        return r.ok ? HIDKeyMapping.parse(r.output) : nil
    }

    private func write(_ maps: [HIDMapping]) -> Bool { run(["property", "--set", HIDKeyMapping.argument(maps)]).ok }

    public func apply(_ m: HIDMapping) -> Bool {
        guard let cur = current() else { return false }
        return write(HIDKeyMapping.merged(cur, adding: m))
    }

    public func remove(_ m: HIDMapping) -> Bool {
        guard let cur = current() else { return false }
        return write(HIDKeyMapping.removing(cur, m))
    }
}

public final class MultitouchTouchSource: TouchSource {
    public var onFrame: ((TouchFrame) -> Void)?

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    nonisolated(unsafe) private static var current: MultitouchTouchSource?
    private static let callback: Callback = { _, touches, count, _, _ in
        var x: Float = 0
        var y: Float = 0
        if count > 0, let touches {
            x = touches.load(fromByteOffset: 32, as: Float.self)
            y = touches.load(fromByteOffset: 36, as: Float.self)
        }
        MultitouchTouchSource.current?.onFrame?(TouchFrame(fingers: Int(count), time: ProcessInfo.processInfo.systemUptime, x: x, y: y))
        return 0
    }

    private var library: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var stopFn: StopFn?
    private var unregisterFn: Register?

    public init() {}

    private func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let library, let s = dlsym(library, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    public func start() -> Bool {
        stop()
        library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
        guard library != nil, let create = symbol("MTDeviceCreateList", as: CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", as: Register.self),
              let startFn = symbol("MTDeviceStart", as: StartFn.self),
              let stopFn = symbol("MTDeviceStop", as: StopFn.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", as: Register.self),
              let list = create()?.takeRetainedValue() else { return false }
        self.stopFn = stopFn
        unregisterFn = unregister
        deviceList = list
        Self.current = self
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let d = UnsafeMutableRawPointer(mutating: raw)
            register(d, Self.callback)
            startFn(d, 0)
            devices.append(d)
        }
        return !devices.isEmpty
    }

    public func stop() {
        for d in devices {
            unregisterFn?(d, Self.callback)
            stopFn?(d)
        }
        devices.removeAll()
        deviceList = nil
        if Self.current === self { Self.current = nil }
        if let l = library { dlclose(l) }
        library = nil
    }
}
