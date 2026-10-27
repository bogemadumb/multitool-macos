import Foundation
import CoreGraphics
@testable import MultitulCore

enum WndFix {
    static func screen(_ id: UInt32, _ frame: CGRect, visible: CGRect? = nil) -> WndScreen { WndScreen(id: id, frame: frame, visible: visible ?? frame) }

    static let clean = screen(1, CGRect(x: 0, y: 0, width: 1800, height: 1000), visible: CGRect(x: 0, y: 0, width: 1800, height: 976))
    static let cleanDockLeft = screen(1, CGRect(x: 0, y: 0, width: 1800, height: 1000), visible: CGRect(x: 80, y: 0, width: 1720, height: 976))
    static let cleanDockRight = screen(1, CGRect(x: 0, y: 0, width: 1800, height: 1000), visible: CGRect(x: 0, y: 0, width: 1720, height: 976))
    static let cleanDockBottom = screen(1, CGRect(x: 0, y: 0, width: 1800, height: 1000), visible: CGRect(x: 0, y: 70, width: 1800, height: 906))
    static let notch = screen(1, CGRect(x: 0, y: 0, width: 1710, height: 1107), visible: CGRect(x: 0, y: 0, width: 1710, height: 1069))
    static let leftExt = screen(2, CGRect(x: -1920, y: 0, width: 1920, height: 1080), visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
    static let rightExt = screen(3, CGRect(x: 1800, y: 0, width: 2560, height: 1440), visible: CGRect(x: 1800, y: 0, width: 2560, height: 1415))
    static let aboveExt = screen(4, CGRect(x: 0, y: 1000, width: 1920, height: 1080), visible: CGRect(x: 0, y: 1000, width: 1920, height: 1055))

    static func displays(_ s: [WndScreen]) -> [WndDisplay] { ScreenSpace.displays(from: s) }
    static var cleanDisplay: WndDisplay { displays([clean])[0] }
    static var allSingles: [WndScreen] { [clean, cleanDockLeft, cleanDockRight, cleanDockBottom, notch] }
}

final class WndBox<T> {
    var value: T
    init(_ v: T) { value = v }
}

final class WndMemoryStore: KeyValueStoring {
    var values: [String: Any] = [:]
    var writes = 0

    func object(forKey defaultName: String) -> Any? { values[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        if let value { values[defaultName] = value } else { values[defaultName] = nil }
    }

    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

final class WndFakeDriver: WindowDriving {
    struct Win {
        var frame: CGRect
        var minSize = CGSize(width: 100, height: 60)
        var maxSize: CGSize?
        var resizable = true
        var manageable = true
        var bundleID: String? = "com.test.app"
        var pid: Int32 = 10
    }

    var wins: [Int: Win] = [:]
    var focused: Int?
    var screenList: [WndDisplay]
    var setCalls: [(key: Int, frame: CGRect)] = []
    var raised: [Int] = []
    var failSet = false
    var windowUnderPointer: Int?
    var frameReads = 0

    init(screens: [WndScreen] = [WndFix.clean]) { screenList = WndFix.displays(screens) }

    @discardableResult
    func add(_ key: Int, _ frame: CGRect, focus: Bool = true, configure: (inout Win) -> Void = { _ in }) -> WndWindow {
        var w = Win(frame: frame)
        configure(&w)
        wins[key] = w
        if focus { focused = key }
        return WndWindow(key: key, pid: w.pid, bundleID: w.bundleID)
    }

    func ref(_ key: Int) -> WndWindow { WndWindow(key: key, pid: wins[key]?.pid ?? 0, bundleID: wins[key]?.bundleID) }

    func frameOf(_ key: Int) -> CGRect { wins[key]!.frame }

    func focusedWindow() -> WndWindow? { focused.map(ref) }
    func window(at point: CGPoint) -> WndWindow? { windowUnderPointer.map(ref) }

    func frame(of window: WndWindow) -> CGRect? {
        frameReads += 1
        return wins[window.key]?.frame
    }

    func setFrame(_ frame: CGRect, of window: WndWindow) -> Bool {
        guard !failSet, var w = wins[window.key] else { return false }
        var size = frame.size
        if w.resizable {
            size.width = max(size.width, w.minSize.width)
            size.height = max(size.height, w.minSize.height)
            if let m = w.maxSize { size.width = min(size.width, m.width); size.height = min(size.height, m.height) }
        } else {
            size = w.frame.size
        }
        w.frame = CGRect(origin: frame.origin, size: size)
        wins[window.key] = w
        setCalls.append((window.key, frame))
        return true
    }

    func isManageable(_ window: WndWindow) -> Bool { wins[window.key]?.manageable ?? false }
    func raise(_ window: WndWindow) { raised.append(window.key) }
    func displays() -> [WndDisplay] { screenList }
}

final class WndPreview: SnapPreviewing {
    var shown: [CGRect] = []
    var hides = 0
    var visible = false

    func show(_ frame: CGRect, display: WndDisplay) {
        shown.append(frame)
        visible = true
    }

    func hide() {
        hides += 1
        visible = false
    }
}

final class WndHandle: CancelHandle {
    var cancelled = false
    func cancel() { cancelled = true }
}

final class WndTimers: TimerScheduling {
    var items: [(delay: TimeInterval, block: () -> Void, handle: WndHandle)] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelHandle {
        let h = WndHandle()
        items.append((delay, block, h))
        return h
    }

    var active: Int { items.filter { !$0.handle.cancelled }.count }

    func fireAll() {
        let pending = items
        items.removeAll()
        for i in pending where !i.handle.cancelled { i.block() }
    }
}

func wndLayoutEngine(_ d: WndFakeDriver, _ settings: WndBox<WindowLayoutSettings>) -> WindowLayoutEngine {
    WindowLayoutEngine(driver: d) { settings.value }
}

func wndSettings(_ edit: (inout WindowLayoutSettings) -> Void = { _ in }) -> WndBox<WindowLayoutSettings> {
    var s = WindowLayoutSettings()
    edit(&s)
    return WndBox(s)
}
