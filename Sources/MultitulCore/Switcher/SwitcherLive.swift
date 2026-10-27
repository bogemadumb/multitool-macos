import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

public final class LiveSwitcherSource: SwitcherSource {
    private var axRecords: [AXWindowRecord] = []
    private var elements: [Int: AXUIElement] = [:]
    private let queue = DispatchQueue(label: "multitul.switcher.enumerate", qos: .userInitiated)
    private var waiters: [(SwitcherSnapshot) -> Void] = []
    private var refreshing = false
    private var tokens: [NSObjectProtocol] = []
    private var pendingSoon = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() { _ = AXTimeouts.configured }

    public func start() {
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                                          NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification]
        for n in names {
            tokens.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshSoon() })
        }
        refreshSoon()
    }

    public func stop() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
    }

    public func element(for key: Int) -> AXUIElement? { elements[key] }

    private func refreshSoon() {
        guard !pendingSoon else { return }
        pendingSoon = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pendingSoon = false
            self?.refresh { _ in }
        }
    }

    private func runningApps() -> [Int32: SwitchApp] {
        var out: [Int32: SwitchApp] = [:]
        for a in NSWorkspace.shared.runningApplications where !a.isTerminated && a.processIdentifier != ownPID {
            out[a.processIdentifier] = SwitchApp(pid: a.processIdentifier, bundleID: a.bundleIdentifier, name: a.localizedName ?? a.bundleIdentifier ?? "", isRegular: a.activationPolicy == .regular, isHidden: a.isHidden)
        }
        return out
    }

    private func readCG() -> [CGWindowRecord] {
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var out: [CGWindowRecord] = []
        out.reserveCapacity(list.count)
        for (i, w) in list.enumerated() {
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let b = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            out.append(CGWindowRecord(windowID: id, pid: pid, layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, title: (w[kCGWindowName as String] as? String) ?? "", frame: rect,
                                      onScreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false, alpha: (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1, zIndex: i))
        }
        return out
    }

    private func displays() -> [WndDisplay] { ScreenSpace.displays(from: LiveScreens.current()) }

    public func snapshot() -> SwitcherSnapshot {
        let apps = runningApps()
        let d = displays()
        let windows = WindowSnapshotMerger.merge(cg: readCG(), ax: axRecords, apps: apps, displays: d)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = windows.filter { $0.pid == front && !$0.isMinimized && $0.isOnCurrentSpace }.min { $0.zIndex < $1.zIndex }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        return SwitcherSnapshot(windows: windows, apps: Array(apps.values), focusedKey: focused?.key, frontPID: front, displays: d, primaryDisplayID: d.first { $0.frame.origin == .zero }?.id,
                                pointer: pointer, focusedFrame: focused?.frame)
    }

    public func refresh(_ completion: @escaping (SwitcherSnapshot) -> Void) {
        waiters.append(completion)
        guard !refreshing else { return }
        refreshing = true
        let targets = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != ownPID }.map(\.processIdentifier)
        let trusted = AXIsProcessTrusted()
        queue.async { [weak self] in
            var records: [AXWindowRecord] = []
            var map: [Int: AXUIElement] = [:]
            if trusted {
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                    let (r, m) = Self.readAX(pid: targets[i])
                    lock.lock()
                    records.append(contentsOf: r)
                    for (k, v) in m { map[k] = v }
                    lock.unlock()
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.axRecords = records
                self.elements = map
                self.refreshing = false
                let snap = self.snapshot()
                let list = self.waiters
                self.waiters.removeAll()
                for w in list { w(snap) }
            }
        }
    }

    static func readAX(pid: Int32) -> ([AXWindowRecord], [Int: AXUIElement]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var records: [AXWindowRecord] = []
        var map: [Int: AXUIElement] = [:]
        for w in AXRead.elements(app, kAXWindowsAttribute) {
            AXUIElementSetMessagingTimeout(w, 0.25)
            let sub = AXRead.string(w, kAXSubroleAttribute)
            guard sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String), let frame = AXRead.frame(w) else { continue }
            let key = AXWindowDriver.key(pid: pid, element: w)
            records.append(AXWindowRecord(key: key, pid: pid, title: AXRead.string(w, kAXTitleAttribute) ?? "", frame: frame,
                                          isMinimized: AXRead.bool(w, kAXMinimizedAttribute) == true, isFullscreen: AXRead.bool(w, "AXFullScreen") == true))
            map[key] = w
        }
        return (records, map)
    }
}

public final class LiveSwitcherActor: SwitcherActing {
    private let source: LiveSwitcherSource
    private let driver: AXWindowDriver
    private let engine: WindowLayoutEngine

    public init(source: LiveSwitcherSource, driver: AXWindowDriver, engine: WindowLayoutEngine) {
        self.source = source
        self.driver = driver
        self.engine = engine
    }

    public func activate(_ e: SwitchEntry) {
        let app = NSRunningApplication(processIdentifier: e.pid)
        if app?.isHidden == true { app?.unhide() }
        if let w = e.window, let el = source.element(for: w.key) {
            if w.isMinimized { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        let axApp = AXUIElementCreateApplication(e.pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app?.activate(options: [])
    }

    public func close(_ e: SwitchEntry) -> Bool {
        guard let w = e.window, let el = source.element(for: w.key), let button = AXRead.element(el, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    public func setMinimized(_ e: SwitchEntry, _ minimized: Bool) {
        guard let w = e.window, let el = source.element(for: w.key) else { return }
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    public func quit(pid: Int32) { NSRunningApplication(processIdentifier: pid)?.terminate() }

    public func hide(pid: Int32) { NSRunningApplication(processIdentifier: pid)?.hide() }

    public func place(_ e: SwitchEntry, _ action: WindowLayoutAction) -> Bool {
        guard let w = e.window, let el = source.element(for: w.key) else { return false }
        if w.isMinimized { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        let ref = driver.remember(el, pid: w.pid)
        if case .applied = engine.perform(action, on: ref) { return true }
        return false
    }
}

public final class SCKThumbnailCapturer: ThumbnailCapturing {
    private var known: [CGWindowID: SCWindow] = [:]
    private var lastContent: TimeInterval = 0
    private var loading = false

    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func capture(windowID: UInt32, maxPixelWidth: Int, completion: @escaping (CGImage?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(nil); return }
            guard Self.hasPermission, let win = await self.window(windowID) else { completion(nil); return }
            let cfg = SCStreamConfiguration()
            let ratio = max(win.frame.height, 1) / max(win.frame.width, 1)
            let w = max(min(maxPixelWidth, Int(win.frame.width * 2)), 32)
            cfg.width = w
            cfg.height = max(Int(CGFloat(w) * ratio), 24)
            cfg.showsCursor = false
            cfg.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            completion(image)
        }
    }

    @MainActor
    private func window(_ id: CGWindowID) async -> SCWindow? {
        if let w = known[id] { return w }
        let now = ProcessInfo.processInfo.systemUptime
        guard !loading, now - lastContent > 1.0 else {
            while loading { try? await Task.sleep(nanoseconds: 20_000_000) }
            return known[id]
        }
        loading = true
        defer { loading = false }
        lastContent = now
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        known = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        return known[id]
    }

    public func invalidate() { known.removeAll(); lastContent = 0 }
}

public final class LiveSymbolicHotKeys: SymbolicHotKeyDriving {
    private typealias SetFn = @convention(c) (Int32, Bool) -> Int32
    private typealias GetFn = @convention(c) (Int32) -> Bool
    private let setter: SetFn?
    private let getter: GetFn?

    public init() {
        let h = UnsafeMutableRawPointer(bitPattern: -2)
        setter = dlsym(h, "CGSSetSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: SetFn.self) }
        getter = dlsym(h, "CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: GetFn.self) }
    }

    public var isAvailable: Bool { setter != nil && getter != nil }

    public func isEnabled(_ id: Int32) -> Bool? { getter?(id) }

    public func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool { setter?(id, enabled) == 0 }
}

public final class LiveDockPreviewDriver: DockPreviewDriving {
    private let driver: AXWindowDriver
    private let messagingTimeout: Float = 0.2
    private var bundleByURL: [URL: String] = [:]

    public init(driver: AXWindowDriver) { self.driver = driver }

    public func tile(at point: CGPoint) -> DockTileInfo? {
        let displays = driver.displays()
        guard let i = displays.firstIndex(where: { $0.frame.contains(point) }), DockRegion.mayContain(point, display: displays[i]),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(dock)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
              AXRead.string(hit, kAXSubroleAttribute) == "AXApplicationDockItem", let frame = AXRead.frame(hit) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXURLAttribute as CFString, &raw) == .success, let url = raw as? URL else { return nil }
        let bid: String
        if let cached = bundleByURL[url] { bid = cached } else {
            guard let b = Bundle(url: url)?.bundleIdentifier else { return nil }
            if bundleByURL.count > 200 { bundleByURL.removeAll() }
            bundleByURL[url] = b
            bid = b
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first(where: { !$0.isTerminated }) else { return nil }
        return DockTileInfo(pid: running.processIdentifier, bundleID: bid, frame: frame, orientation: DockOrientation.infer(displays[i]))
    }
}
