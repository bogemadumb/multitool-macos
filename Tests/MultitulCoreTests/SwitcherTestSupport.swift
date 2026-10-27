import Foundation
import CoreGraphics
@testable import MultitulCore

enum SwcFix {
    static let display = WndDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1000), visible: CGRect(x: 0, y: 24, width: 1800, height: 976))
    static let second = WndDisplay(id: 2, frame: CGRect(x: 1800, y: 0, width: 2560, height: 1440), visible: CGRect(x: 1800, y: 24, width: 2560, height: 1416))

    static func win(_ key: Int, pid: Int32 = 10, app: String = "App", title: String = "", id: UInt32? = nil, z: Int? = nil, minimized: Bool = false, hidden: Bool = false,
                    fullscreen: Bool = false, space: Bool = true, display: UInt32? = 1, frame: CGRect? = nil, bundle: String? = nil) -> SwitchWindow {
        SwitchWindow(key: key, windowID: id ?? UInt32(1000 + key), pid: pid, bundleID: bundle ?? "com.test.app\(pid)", appName: app, title: title.isEmpty ? "Окно \(key)" : title,
                     frame: frame ?? CGRect(x: 100, y: 100, width: 800, height: 600), displayID: display, isMinimized: minimized, isAppHidden: hidden, isFullscreen: fullscreen,
                     isOnCurrentSpace: space, zIndex: z ?? key)
    }

    static func app(_ pid: Int32, _ name: String = "App", bundle: String? = nil, regular: Bool = true, hidden: Bool = false) -> SwitchApp {
        SwitchApp(pid: pid, bundleID: bundle ?? "com.test.app\(pid)", name: name, isRegular: regular, isHidden: hidden)
    }

    static func entries(_ n: Int, pid: Int32 = 10) -> [SwitchEntry] {
        (1...max(n, 1)).prefix(n).map { SwitchEntry(window: win($0, pid: pid, app: "App\(pid)", title: "Окно \($0)")) }
    }

    static func manyWindows(_ n: Int, apps: Int = 10) -> [SwitchWindow] {
        (0..<n).map { i in win(i + 1, pid: Int32(100 + i % apps), app: "Приложение \(i % apps)", title: "Документ номер \(i) черновик", z: i) }
    }

    static func manyApps(_ n: Int = 10) -> [SwitchApp] { (0..<n).map { app(Int32(100 + $0), "Приложение \($0)") } }
}

final class SwcSource: SwitcherSource {
    var snap = SwitcherSnapshot()
    var fresh: SwitcherSnapshot?
    var refreshCalls = 0
    var pending: [(SwitcherSnapshot) -> Void] = []
    var autoComplete = false

    init(windows: [SwitchWindow] = [], apps: [SwitchApp] = [], focused: Int? = nil, front: Int32? = nil, displays: [WndDisplay] = [SwcFix.display]) {
        snap = SwitcherSnapshot(windows: windows, apps: apps, focusedKey: focused, frontPID: front, displays: displays, primaryDisplayID: displays.first?.id, pointer: CGPoint(x: 400, y: 400))
    }

    func snapshot() -> SwitcherSnapshot { snap }

    func refresh(_ completion: @escaping (SwitcherSnapshot) -> Void) {
        refreshCalls += 1
        if autoComplete { completion(fresh ?? snap) } else { pending.append(completion) }
    }

    func completeRefresh(_ s: SwitcherSnapshot? = nil) {
        let list = pending
        pending.removeAll()
        for c in list { c(s ?? fresh ?? snap) }
    }
}

final class SwcActor: SwitcherActing {
    var activated: [SwitchEntry] = []
    var closed: [SwitchEntry] = []
    var minimized: [(SwitchEntry, Bool)] = []
    var quit: [Int32] = []
    var hidden: [Int32] = []
    var placed: [(SwitchEntry, WindowLayoutAction)] = []
    var closeResult = true
    var placeResult = true

    func activate(_ e: SwitchEntry) { activated.append(e) }
    func close(_ e: SwitchEntry) -> Bool { closed.append(e); return closeResult }
    func setMinimized(_ e: SwitchEntry, _ m: Bool) { minimized.append((e, m)) }
    func quit(pid: Int32) { quit.append(pid) }
    func hide(pid: Int32) { hidden.append(pid) }
    func place(_ e: SwitchEntry, _ a: WindowLayoutAction) -> Bool { placed.append((e, a)); return placeResult }
}

final class SwcPanel: SwitcherPanelDriving {
    var presented: [SwitcherViewState] = []
    var updates: [SwitcherViewState] = []
    var dismissed = 0
    var thumbUpdates: [UInt32] = []
    var frame = CGRect.zero
    var visible = false

    func present(_ s: SwitcherViewState) { presented.append(s); visible = true }
    func update(_ s: SwitcherViewState) { updates.append(s) }
    func thumbnailUpdated(windowID: UInt32) { thumbUpdates.append(windowID) }
    func dismiss() { dismissed += 1; visible = false }
    func contains(_ p: CGPoint) -> Bool { visible && frame.contains(p) }
    var last: SwitcherViewState? { updates.last ?? presented.last }
}

final class SwcCapturer: ThumbnailCapturing {
    var requests: [UInt32] = []
    var completions: [UInt32: (CGImage?) -> Void] = [:]

    func capture(windowID: UInt32, maxPixelWidth: Int, completion: @escaping (CGImage?) -> Void) {
        requests.append(windowID)
        completions[windowID] = completion
    }

    func finish(_ id: UInt32, ok: Bool = true) {
        let c = completions.removeValue(forKey: id)
        c?(ok ? SwcCapturer.image() : nil)
    }

    static func image(_ w: Int = 8, _ h: Int = 6) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

final class SwcController: SwitcherControlling {
    var log: [String] = []
    var beginResult = true
    var clearResult = false
    var inside = false

    func begin(trigger: SwitcherTrigger, backward: Bool) -> Bool { log.append("begin:\(trigger == .apps ? "apps" : "windows"):\(backward ? "back" : "fwd")"); return beginResult }
    func present() { log.append("present") }
    func move(_ step: Int) { log.append("move:\(step)") }
    func moveVertical(_ rows: Int) { log.append("vert:\(rows)") }
    func commit() { log.append("commit") }
    func cancel() { log.append("cancel") }
    func closeSelected() { log.append("close") }
    func quitSelected() { log.append("quit") }
    func minimizeSelected() { log.append("minimize") }
    func hideSelected() { log.append("hide") }
    func beginSearch() { log.append("search") }
    func appendQuery(_ text: String) { log.append("q+\(text)") }
    func deleteQueryCharacter() { log.append("q-") }
    func clearQuery() -> Bool { log.append("qclear"); return clearResult }
    func containsPoint(_ p: CGPoint) -> Bool { inside }
}

final class SwcHotKeys: SymbolicHotKeyDriving {
    var available = true
    var state: [Int32: Bool] = [1: true, 2: true, 27: true, 220: true]
    var failIDs = Set<Int32>()
    var writes: [(Int32, Bool)] = []

    var isAvailable: Bool { available }
    func isEnabled(_ id: Int32) -> Bool? { available ? state[id] : nil }

    func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
        writes.append((id, enabled))
        if failIDs.contains(id) { return false }
        state[id] = enabled
        return true
    }
}

final class SwcDockDriver: DockPreviewDriving {
    var tiles: [(CGRect, DockTileInfo)] = []
    var calls = 0

    func tile(at point: CGPoint) -> DockTileInfo? {
        calls += 1
        return tiles.first { $0.0.contains(point) }?.1
    }
}

final class SwcDockPanel: DockPreviewPanelDriving {
    var presented: [DockPreviewViewState] = []
    var updates: [DockPreviewViewState] = []
    var dismissed = 0
    var frame = CGRect.zero
    var visible = false

    func present(_ s: DockPreviewViewState) { presented.append(s); frame = s.frame; visible = true }
    func update(_ s: DockPreviewViewState) { updates.append(s); frame = s.frame }
    func thumbnailUpdated(windowID: UInt32) {}
    func dismiss() { dismissed += 1; visible = false }
    func contains(_ p: CGPoint) -> Bool { visible && frame.contains(p) }
}

func swcEngine(windows: [SwitchWindow], apps: [SwitchApp] = [], focused: Int? = nil, front: Int32? = 10, edit: (inout SwitcherSettings) -> Void = { _ in },
               thumbs: ThumbnailService? = nil, recording: Bool = true) -> (SwitcherEngine, SwcSource, SwcActor, SwcPanel, WindowUseOrder) {
    let src = SwcSource(windows: windows, apps: apps, focused: focused, front: front)
    let act = SwcActor()
    let panel = SwcPanel()
    let order = WindowUseOrder()
    var s = SwitcherSettings()
    edit(&s)
    let engine = SwitcherEngine(source: src, actor: act, panel: panel, thumbs: thumbs, order: order, settings: { s }, ownPID: 1, screenRecording: { recording }, clock: { 100 })
    return (engine, src, act, panel, order)
}
