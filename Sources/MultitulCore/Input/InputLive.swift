import Foundation
import AppKit
import ApplicationServices
import IOKit
import IOKit.hid

public final class TimerFrameTicker: SmoothFrameTicker {
    public static let interval: TimeInterval = 1.0 / 120.0
    private var timer: DispatchSourceTimer?

    public init() {}

    public func start(_ handler: @escaping () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(1))
        t.setEventHandler(handler: handler)
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}

public final class CGScrollPoster: SmoothScrollPoster {
    public init() {}

    public func post(vertical: Int, horizontal: Int, flags: CGEventFlags) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(clamping: vertical), wheel2: Int32(clamping: horizontal), wheel3: 0) else { return }
        e.flags = flags
        EventTapHub.markSynthetic(e)
        e.post(tap: .cgSessionEventTap)
    }
}

public enum WindowLookup {
    public static func topWindow(at point: CGPoint) -> FocusWindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.contains(point), ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0 else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return FocusWindowInfo(pid: pid, bundleID: bid, bounds: rect, layer: layer, isOwn: pid == me)
        }
        return nil
    }
}

public final class LivePointerAppResolver: PointerAppResolver {
    private var cachedBounds: CGRect?
    private var cachedBundle: String?
    private var cachedAt: TimeInterval = 0
    private let lifetime: TimeInterval = 0.5

    public init() {}

    public func bundleID(at point: CGPoint) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if let r = cachedBounds, r.contains(point), now - cachedAt < lifetime { return cachedBundle }
        let w = WindowLookup.topWindow(at: point)
        cachedBounds = w?.bounds
        cachedBundle = w?.bundleID
        cachedAt = now
        return cachedBundle
    }
}

public final class LiveFocusDriver: FocusFollowsDriver {
    public init() {}

    public func windowUnder(_ point: CGPoint) -> FocusWindowInfo? { WindowLookup.topWindow(at: point) }

    public func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    public func focusedWindowBounds(pid: Int32) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let w = Self.element(app, kAXFocusedWindowAttribute) else { return nil }
        return Self.bounds(w)
    }

    public func buttonsPressed() -> Bool { NSEvent.pressedMouseButtons != 0 }

    public func shortcutModifiersHeld() -> Bool {
        !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    public func focus(_ window: FocusWindowInfo, at point: CGPoint, raise: Bool) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let ax = axWindow(app: app, window: window, point: point) else { return false }
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var ok = AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
        if raise { ok = (AXUIElementPerformAction(ax, kAXRaiseAction as CFString) == .success) || ok }
        if frontmostPID() != window.pid, let running = NSRunningApplication(processIdentifier: window.pid) {
            ok = running.activate(options: []) || ok
        } else {
            ok = (AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success) || ok
        }
        return ok
    }

    private func axWindow(app: AXUIElement, window: FocusWindowInfo, point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit {
            if Self.string(hit, kAXRoleAttribute) == (kAXWindowRole as String) { return hit }
            if let w = Self.element(hit, kAXWindowAttribute) { return w }
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success, let wins = raw as? [AXUIElement] else { return nil }
        return wins.first { w in Self.bounds(w).map { FocusFollowsLogic.sameWindow($0, window.bounds) } ?? false }
    }

    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func bounds(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}

public final class IOHIDPointerAccelDriver: PointerAccelDriver {
    private let client: IOHIDEventSystemClient

    public init() { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault) }

    private func services() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
    }

    private func registryID(_ s: IOHIDServiceClient) -> UInt64? {
        let v = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value
        return v == 0 ? nil : v
    }

    private func service(_ id: UInt64) -> IOHIDServiceClient? { services().first { registryID($0) == id } }

    public func mice() -> [PointerDevice] {
        services().compactMap { s in
            guard IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0, let id = registryID(s) else { return nil }
            let type = IOHIDServiceClientCopyProperty(s, AccelCurve.typeKey as CFString) as? String
            guard let key = AccelCurve.writableKey(forType: type) else { return nil }
            let name = IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString) as? String
            return PointerDevice(registryID: id, key: key, name: name ?? "Мышь")
        }
    }

    public func read(registryID: UInt64, key: String) -> Int64? {
        guard let s = service(registryID) else { return nil }
        return (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.int64Value
    }

    public func write(registryID: UInt64, key: String, value: Int64) -> Bool {
        guard let s = service(registryID) else { return false }
        guard IOHIDServiceClientSetProperty(s, key as CFString, NSNumber(value: value)) else { return false }
        return read(registryID: registryID, key: key) == value
    }
}

public final class HIDMouseWatcher {
    private var manager: IOHIDManager?
    private var onChange: (() -> Void)?

    public init() {}

    public func start(_ handler: @escaping () -> Void) {
        stop()
        onChange = handler
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let cb: IOHIDDeviceCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDMouseWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange?()
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, cb, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, cb, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        manager = m
    }

    public func stop() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        onChange = nil
    }

    deinit { stop() }
}
