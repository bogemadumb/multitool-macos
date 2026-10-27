import Foundation
import AppKit
import ApplicationServices

enum AXTimeouts {
    static let configured: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.35)
    }()
}

enum AXRead {
    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func bool(_ e: AXUIElement, _ attr: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    static func point(_ e: AXUIElement, _ attr: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ e: AXUIElement, _ attr: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(e, kAXPositionAttribute), let s = size(e, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func settable(_ e: AXUIElement, _ attr: String) -> Bool {
        var v = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(e, attr as CFString, &v) == .success && v.boolValue
    }

    static func setPoint(_ e: AXUIElement, _ attr: String, _ p: CGPoint) -> Bool {
        var v = p
        guard let val = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(e, attr as CFString, val) == .success
    }

    static func setSize(_ e: AXUIElement, _ attr: String, _ s: CGSize) -> Bool {
        var v = s
        guard let val = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(e, attr as CFString, val) == .success
    }
}

public final class AXWindowDriver: WindowDriving {
    private var elements: [Int: AXUIElement] = [:]
    private var order: [Int] = []
    private let messagingTimeout: Float = 0.25
    private var lastForeignPID: pid_t?
    private var activationToken: NSObjectProtocol?

    public init() {
        _ = AXTimeouts.configured
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { lastForeignPID = f.processIdentifier }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.processIdentifier != me else { return }
            self?.lastForeignPID = a.processIdentifier
        }
    }

    deinit {
        if let t = activationToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
    }

    public func lastForeignFocusedWindow() -> WndWindow? {
        guard let pid = lastForeignPID, NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, messagingTimeout)
        guard let w = AXRead.element(ax, kAXFocusedWindowAttribute) ?? AXRead.element(ax, kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(w, messagingTimeout)
        return remember(w, pid: pid)
    }

    public static func key(pid: Int32, element: AXUIElement) -> Int {
        var h = Hasher()
        h.combine(pid)
        h.combine(CFHash(element))
        return h.finalize()
    }

    func remember(_ element: AXUIElement, pid: Int32) -> WndWindow {
        let k = Self.key(pid: pid, element: element)
        if elements[k] == nil {
            order.append(k)
            if order.count > 256 { elements.removeValue(forKey: order.removeFirst()) }
        }
        elements[k] = element
        return WndWindow(key: k, pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    func element(for w: WndWindow) -> AXUIElement? { elements[w.key] }

    public func focusedWindow() -> WndWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, messagingTimeout)
        guard let w = AXRead.element(ax, kAXFocusedWindowAttribute) ?? AXRead.element(ax, kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(w, messagingTimeout)
        return remember(w, pid: pid)
    }

    public func window(at point: CGPoint) -> WndWindow? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, messagingTimeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        var node: AXUIElement? = hit
        var depth = 0
        while let n = node, depth < 12 {
            if AXRead.string(n, kAXRoleAttribute) == (kAXWindowRole as String) { return remember(n, pid: pid) }
            if let w = AXRead.element(n, kAXWindowAttribute) { return remember(w, pid: pid) }
            node = AXRead.element(n, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    public func frame(of window: WndWindow) -> CGRect? {
        guard let e = element(for: window) else { return nil }
        return AXRead.frame(e)
    }

    public func setFrame(_ frame: CGRect, of window: WndWindow) -> Bool {
        guard let e = element(for: window) else { return false }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let enhanced = AXRead.bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        let a = AXRead.setSize(e, kAXSizeAttribute, frame.size)
        let b = AXRead.setPoint(e, kAXPositionAttribute, frame.origin)
        let c = AXRead.setSize(e, kAXSizeAttribute, frame.size)
        return a || b || c
    }

    public func isManageable(_ window: WndWindow) -> Bool {
        guard let e = element(for: window), AXRead.string(e, kAXRoleAttribute) == (kAXWindowRole as String) else { return false }
        if AXRead.bool(e, kAXMinimizedAttribute) == true || AXRead.bool(e, "AXFullScreen") == true { return false }
        let sub = AXRead.string(e, kAXSubroleAttribute)
        guard sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String) || sub == nil else { return false }
        return AXRead.settable(e, kAXPositionAttribute)
    }

    public func raise(_ window: WndWindow) {
        guard let e = element(for: window) else { return }
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
    }

    public func displays() -> [WndDisplay] { ScreenSpace.displays(from: LiveScreens.current()) }
}

public enum LiveScreens {
    public static func current() -> [WndScreen] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.map { s in
            WndScreen(id: (s.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0, frame: s.frame, visible: s.visibleFrame)
        }
    }

    public static func cocoaFrame(fromTopLeft r: CGRect) -> CGRect {
        ScreenSpace.flip(r, primaryHeight: ScreenSpace.primaryHeight(current()))
    }
}

public final class LiveZoomProbe: ZoomButtonProbing {
    private let driver: AXWindowDriver
    private var buttons: [Int: AXUIElement] = [:]

    public init(driver: AXWindowDriver) { self.driver = driver }

    public func target(at point: CGPoint) -> ZoomTarget? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.35)
        guard AXRead.string(hit, kAXSubroleAttribute) == (kAXZoomButtonSubrole as String),
              let win = AXRead.element(hit, kAXParentAttribute) ?? AXRead.element(hit, kAXWindowAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier,
              AXRead.string(win, kAXRoleAttribute) == (kAXWindowRole as String),
              let frame = AXRead.frame(win), let button = AXRead.frame(hit) else { return nil }
        let w = driver.remember(win, pid: pid)
        buttons[w.key] = hit
        return ZoomTarget(window: w, frame: frame, isFullScreen: AXRead.bool(win, "AXFullScreen") == true, button: button)
    }

    public func pressNative(_ target: ZoomTarget) {
        guard let b = buttons[target.window.key] else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }
}

public enum DockRegion {
    public static func mayContain(_ p: CGPoint, display: WndDisplay, autoHideReach: CGFloat = 120) -> Bool {
        let f = display.frame
        let v = display.visible
        guard f.contains(p) else { return false }
        let menuBar = v.minY - f.minY
        let leftBand = v.minX - f.minX
        let rightBand = f.maxX - v.maxX
        let bottomBand = f.maxY - v.maxY
        if leftBand > 1 || rightBand > 1 || bottomBand > 1 {
            if p.x < v.minX || p.x > v.maxX || p.y > v.maxY { return p.y >= f.minY + menuBar }
            return false
        }
        return p.x <= f.minX + autoHideReach || p.x >= f.maxX - autoHideReach || p.y >= f.maxY - autoHideReach
    }
}

public final class LiveDockDriver: DockClickDriving {
    private let driver: AXWindowDriver
    private let messagingTimeout: Float = 0.2

    public init(driver: AXWindowDriver) { self.driver = driver }

    private func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    public func tile(at point: CGPoint) -> DockTile? {
        let displays = driver.displays()
        guard let i = displays.firstIndex(where: { $0.frame.contains(point) }), DockRegion.mayContain(point, display: displays[i]), let dock = dockPID() else { return nil }
        let app = AXUIElementCreateApplication(dock)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
              AXRead.string(hit, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXURLAttribute as CFString, &raw) == .success, let url = raw as? URL,
              let bid = Bundle(url: url)?.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first(where: { !$0.isTerminated }) else { return nil }
        return DockTile(pid: running.processIdentifier, bundleID: bid)
    }

    private func windows(_ pid: Int32) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return AXRead.elements(app, kAXWindowsAttribute).filter {
            let sub = AXRead.string($0, kAXSubroleAttribute)
            return sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String)
        }
    }

    public func state(of tile: DockTile) -> DockAppState {
        let running = NSRunningApplication(processIdentifier: tile.pid)
        let all = windows(tile.pid)
        let minimized = all.filter { AXRead.bool($0, kAXMinimizedAttribute) == true }.count
        return DockAppState(isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == tile.pid, isHidden: running?.isHidden ?? false,
                            visibleWindows: all.count - minimized, minimizedWindows: minimized)
    }

    public func perform(_ action: DockClickAction, on tile: DockTile) {
        let all = windows(tile.pid)
        switch action {
        case .minimizeAll:
            for w in all where AXRead.bool(w, kAXMinimizedAttribute) != true { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        case .restoreAll:
            let minimized = all.filter { AXRead.bool($0, kAXMinimizedAttribute) == true }
            for w in minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            if let first = minimized.first { AXUIElementPerformAction(first, kAXRaiseAction as CFString) }
            NSRunningApplication(processIdentifier: tile.pid)?.activate(options: [])
        case .hide:
            NSRunningApplication(processIdentifier: tile.pid)?.hide()
        case .cycleNext:
            let visible = all.filter { AXRead.bool($0, kAXMinimizedAttribute) != true }
            let app = AXUIElementCreateApplication(tile.pid)
            let focused = AXRead.element(app, kAXFocusedWindowAttribute)
            let fi = focused.flatMap { f in visible.firstIndex { CFEqual($0, f) } }
            if let n = DockClickBrain.nextWindowIndex(focused: fi, count: visible.count) {
                AXUIElementPerformAction(visible[n], kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(visible[n], kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        case .passThrough, .swallow:
            break
        }
    }

    public func replayMouseDown(at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        EventTapHub.markSynthetic(e)
        e.post(tap: .cghidEventTap)
    }
}

public enum AutoQuitSurfaces {
    public static let countedLayers: ClosedRange<Int> = 1...23
    public static let minimumSide: CGFloat = 40

    public static func counts(layer: Int, size: CGSize, onScreen: Bool) -> Bool {
        onScreen && countedLayers.contains(layer) && size.width >= minimumSide && size.height >= 20
    }

    public static func isOffscreenUserWindow(layer: Int, size: CGSize, onScreen: Bool, title: String?) -> Bool {
        !onScreen && layer == 0 && size.width >= 100 && size.height >= 50 && !(title ?? "").isEmpty
    }
}

public final class LiveAutoQuitDriver: AutoQuitDriving {
    public init() {}

    public func app(pid: Int32) -> AutoQuitApp? {
        guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return nil }
        return AutoQuitApp(pid: pid, bundleID: a.bundleIdentifier, name: a.localizedName, isRegular: a.activationPolicy == .regular, isHidden: a.isHidden)
    }

    public func snapshot(of app: AutoQuitApp) -> AutoQuitSnapshot {
        guard AXIsProcessTrusted() else { return AutoQuitSnapshot(accessible: false) }
        let ax = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw) == .success, let wins = raw as? [AXUIElement] else { return AutoQuitSnapshot(accessible: false) }
        var visible = 0
        var minimized = 0
        for w in wins {
            let sub = AXRead.string(w, kAXSubroleAttribute)
            guard sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String) || sub == (kAXSystemDialogSubrole as String) || sub == (kAXFloatingWindowSubrole as String) else { continue }
            if AXRead.bool(w, kAXMinimizedAttribute) == true { minimized += 1 } else { visible += 1 }
        }
        var other = 0
        var surfaces = 0
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.pid {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let onScreen = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let rect = (w[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            if AutoQuitSurfaces.counts(layer: layer, size: rect.size, onScreen: onScreen) { surfaces += 1 }
            if visible == 0, minimized == 0, AutoQuitSurfaces.isOffscreenUserWindow(layer: layer, size: rect.size, onScreen: onScreen, title: w[kCGWindowName as String] as? String) { other += 1 }
        }
        return AutoQuitSnapshot(accessible: true, windows: visible, minimized: minimized, otherSpaces: other, surfaces: surfaces)
    }

    public func terminate(_ app: AutoQuitApp) -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.terminate() ?? false
    }
}

final class AutoQuitContext {
    weak var watcher: AutoQuitWatcher?
    let pid: Int32

    init(pid: Int32, watcher: AutoQuitWatcher) {
        self.pid = pid
        self.watcher = watcher
    }
}

public final class AutoQuitWatcher {
    private struct Entry {
        var observer: AXObserver
        var source: CFRunLoopSource
        var context: AutoQuitContext
    }

    private let service: AutoQuitService
    private var entries: [Int32: Entry] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var running = false

    public init(service: AutoQuitService, driver: AutoQuitDriving) {
        self.service = service
    }

    public var watchedCount: Int { entries.count }

    public func start() {
        guard !running else { return }
        running = true
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.attach(a) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.detach(pid: a.processIdentifier) }
        })
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { attach(a) }
    }

    public func stop() {
        guard running else { return }
        running = false
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens.removeAll()
        for pid in Array(entries.keys) { detach(pid: pid) }
        service.reset()
    }

    func attach(_ a: NSRunningApplication) {
        let pid = a.processIdentifier
        guard a.activationPolicy == .regular, entries[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let ctx = Unmanaged<AutoQuitContext>.fromOpaque(refcon).takeUnretainedValue()
            ctx.watcher?.handle(notification as String, element: element, pid: ctx.pid)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let ctx = AutoQuitContext(pid: pid, watcher: self)
        let ref = Unmanaged.passUnretained(ctx).toOpaque()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, ref) == .success else { return }
        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        entries[pid] = Entry(observer: obs, source: src, context: ctx)
        let wins = AXRead.elements(app, kAXWindowsAttribute)
        for w in wins { AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, ref) }
        service.appObserved(pid: pid, hasWindows: !wins.isEmpty)
    }

    func detach(pid: Int32) {
        if let e = entries.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), e.source, .commonModes) }
        service.appTerminated(pid: pid)
    }

    func handle(_ notification: String, element: AXUIElement, pid: Int32) {
        if notification == (kAXWindowCreatedNotification as String) {
            if let e = entries[pid] {
                AXObserverAddNotification(e.observer, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(e.context).toOpaque())
            }
            service.windowCreated(pid: pid)
        } else if notification == (kAXUIElementDestroyedNotification as String) {
            service.windowClosed(pid: pid)
        }
    }
}

public final class LiveDockPreference: DockPreferenceDriving {
    private let domain = "com.apple.dock" as CFString
    private let key = "mru-spaces" as CFString

    public init() {}

    public func readRearrange() -> DockRearrange {
        guard CFPreferencesAppSynchronize(domain) else { return .unknown }
        if CFPreferencesAppValueIsForced(key, domain) { return .managed }
        guard let v = CFPreferencesCopyAppValue(key, domain) else { return .absent }
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return .managed }
        return (v as! Bool) ? .on : .off
    }

    public func writeRearrange(_ value: Bool?) -> Bool {
        CFPreferencesSetAppValue(key, value.map { $0 as CFBoolean }, domain)
        return CFPreferencesAppSynchronize(domain)
    }

    public func restartDock() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
