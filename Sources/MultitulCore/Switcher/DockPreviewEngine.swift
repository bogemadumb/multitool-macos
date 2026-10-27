import Foundation
import CoreGraphics

public enum DockOrientation: String, Sendable {
    case bottom, left, right

    public static func infer(_ d: WndDisplay) -> DockOrientation {
        let left = d.visible.minX - d.frame.minX
        let right = d.frame.maxX - d.visible.maxX
        let bottom = d.frame.maxY - d.visible.maxY
        if left > 1, left >= right, left >= bottom { return .left }
        if right > 1, right >= bottom { return .right }
        return .bottom
    }
}

public struct DockTileInfo: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var frame: CGRect
    public var orientation: DockOrientation

    public init(pid: Int32, bundleID: String?, frame: CGRect, orientation: DockOrientation = .bottom) {
        self.pid = pid
        self.bundleID = bundleID
        self.frame = frame
        self.orientation = orientation
    }
}

public enum DockPreviewPlacement {
    public static let gap: CGFloat = 10
    public static let margin: CGFloat = 8

    public static func frame(panel: CGSize, tile: CGRect, orientation: DockOrientation, bounds: CGRect) -> CGRect {
        let w = min(panel.width, bounds.width - margin * 2)
        let h = min(panel.height, bounds.height - margin * 2)
        var x: CGFloat, y: CGFloat
        switch orientation {
        case .bottom:
            x = tile.midX - w / 2
            y = tile.minY - gap - h
        case .left:
            x = tile.maxX + gap
            y = tile.midY - h / 2
        case .right:
            x = tile.minX - gap - w
            y = tile.midY - h / 2
        }
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - w)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    public static func corridorContains(_ p: CGPoint, tile: CGRect, panel: CGRect) -> Bool {
        if tile.insetBy(dx: -2, dy: -2).contains(p) || panel.insetBy(dx: -4, dy: -4).contains(p) { return true }
        let bar = CGRect(x: min(tile.minX, panel.minX), y: min(tile.maxY, panel.maxY), width: max(tile.maxX, panel.maxX) - min(tile.minX, panel.minX), height: max(0, max(tile.minY, panel.minY) - min(tile.maxY, panel.maxY)))
        let bar2 = CGRect(x: min(tile.maxX, panel.maxX), y: min(tile.minY, panel.minY), width: max(0, max(tile.minX, panel.minX) - min(tile.maxX, panel.maxX)), height: max(tile.maxY, panel.maxY) - min(tile.minY, panel.minY))
        return bar.contains(p) || bar2.contains(p)
    }
}

public enum DockCloseAction: Equatable, Sendable {
    case closeWindow
    case quitApp

    public static func decide(quitAppOnClose: Bool) -> DockCloseAction { quitAppOnClose ? .quitApp : .closeWindow }
}

public protocol DockPreviewDriving: AnyObject {
    func tile(at point: CGPoint) -> DockTileInfo?
}

public struct DockPreviewViewState: Equatable {
    public var entries: [SwitchEntry]
    public var tile: DockTileInfo
    public var frame: CGRect
    public var display: WndDisplay
    public var metrics: SwitcherGridMetrics
    public var opacity: Double
    public var showTitles: Bool
    public var minimal: Bool
    public var thumbnails: Bool
    public var closeQuitsApp: Bool
    public var middleClickCloses: Bool
}

public protocol DockPreviewPanelDriving: AnyObject {
    func present(_ state: DockPreviewViewState)
    func update(_ state: DockPreviewViewState)
    func thumbnailUpdated(windowID: UInt32)
    func dismiss()
    func contains(_ p: CGPoint) -> Bool
}

public final class DockPreviewEngine {
    public static let minProbeInterval: TimeInterval = 0.03
    public static let switchDelay: TimeInterval = 0.12
    public static let clickSuppress: TimeInterval = 0.5

    public enum Phase: Equatable {
        case idle
        case pending(DockTileInfo)
        case shown(DockTileInfo)
    }

    public private(set) var phase = Phase.idle
    public private(set) var shownCount = 0
    private var entries: [SwitchEntry] = []
    private var frame = CGRect.zero
    private var display: WndDisplay?
    private var openTimer: CancelHandle?
    private var closeTimer: CancelHandle?
    private var lastProbe: (time: TimeInterval, point: CGPoint)?
    private var suppressUntil: TimeInterval = 0
    private var generation = 0

    private let driver: DockPreviewDriving
    private let source: SwitcherSource
    private let actor: SwitcherActing
    private let panel: DockPreviewPanelDriving
    private let thumbs: ThumbnailService?
    private let timers: TimerScheduling
    private let order: WindowUseOrder
    private let settings: () -> DockPreviewSettings
    private let screenRecording: () -> Bool
    private let ownPID: Int32
    private let trusted: () -> Bool

    public init(driver: DockPreviewDriving, source: SwitcherSource, actor: SwitcherActing, panel: DockPreviewPanelDriving, thumbs: ThumbnailService? = nil, timers: TimerScheduling,
                order: WindowUseOrder, settings: @escaping () -> DockPreviewSettings, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                screenRecording: @escaping () -> Bool = { true }, trusted: @escaping () -> Bool = { true }) {
        self.driver = driver
        self.source = source
        self.actor = actor
        self.panel = panel
        self.thumbs = thumbs
        self.timers = timers
        self.order = order
        self.settings = settings
        self.ownPID = ownPID
        self.screenRecording = screenRecording
        self.trusted = trusted
        thumbs?.onUpdate = { [weak self] id in self?.panel.thumbnailUpdated(windowID: id) }
    }

    public var isShown: Bool { if case .shown = phase { return true } else { return false } }
    public var cards: [SwitchEntry] { entries }
    public var panelFrame: CGRect { frame }

    public func reset() {
        openTimer?.cancel()
        closeTimer?.cancel()
        openTimer = nil
        closeTimer = nil
        lastProbe = nil
        if isShown { panel.dismiss() }
        phase = .idle
        entries = []
        generation += 1
        thumbs?.cancelQueued()
    }

    public func hide() { reset() }

    public func pointerMoved(_ p: CGPoint, time: TimeInterval) -> EventTapAction {
        guard trusted() else { return .pass }
        if time < suppressUntil { return .pass }
        if case .shown(let t) = phase, DockPreviewPlacement.corridorContains(p, tile: t.frame, panel: frame) {
            closeTimer?.cancel()
            closeTimer = nil
            if t.frame.insetBy(dx: -2, dy: -2).contains(p) || panel.contains(p) { return .pass }
        }
        if let l = lastProbe, time - l.time < Self.minProbeInterval, hypot(p.x - l.point.x, p.y - l.point.y) < 3 { return .pass }
        lastProbe = (time, p)
        let s = settings()
        let tile = driver.tile(at: p).flatMap { s.exceptions.contains($0.bundleID) || $0.pid == ownPID ? nil : $0 }
        switch phase {
        case .idle:
            if let tile { startPending(tile, delay: Double(s.openDelayMs) / 1000) }
        case .pending(let cur):
            guard let tile else { cancelPending(); break }
            if tile.pid != cur.pid { startPending(tile, delay: Double(s.openDelayMs) / 1000) }
        case .shown(let cur):
            if let tile {
                closeTimer?.cancel()
                closeTimer = nil
                if tile.pid != cur.pid { startPending(tile, delay: min(Double(s.openDelayMs) / 1000, Self.switchDelay), keepShown: true) }
                else if openTimer != nil { openTimer?.cancel(); openTimer = nil }
            } else if !DockPreviewPlacement.corridorContains(p, tile: cur.frame, panel: frame) {
                openTimer?.cancel()
                openTimer = nil
                scheduleClose(Double(s.closeDelayMs) / 1000)
            }
        }
        return .pass
    }

    public func mouseDown(at p: CGPoint, time: TimeInterval) -> EventTapAction {
        switch phase {
        case .idle: break
        case .pending:
            cancelPending()
            suppressUntil = time + Self.clickSuppress
        case .shown:
            if panel.contains(p) { break }
            reset()
            suppressUntil = time + Self.clickSuppress
        }
        return .pass
    }

    private func startPending(_ tile: DockTileInfo, delay: TimeInterval, keepShown: Bool = false) {
        openTimer?.cancel()
        if !keepShown { phase = .pending(tile) }
        generation += 1
        let gen = generation
        let fire = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.openTimer = nil
            self.open(tile)
        }
        if delay <= 0 { openTimer = nil; fire() } else { openTimer = timers.schedule(after: delay, fire) }
    }

    private func cancelPending() {
        openTimer?.cancel()
        openTimer = nil
        if case .pending = phase { phase = .idle }
    }

    private func scheduleClose(_ delay: TimeInterval) {
        guard closeTimer == nil else { return }
        closeTimer = timers.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.closeTimer = nil
            self.reset()
        }
    }

    func buildEntries(_ snap: SwitcherSnapshot, pid: Int32) -> [SwitchEntry] {
        let s = settings()
        var ctx = SwitcherContext(scope: .sameApp(pid), focusedKey: nil, frontPID: snap.frontPID, activeDisplayID: nil)
        ctx.focusedKey = nil
        return SwitcherListBuilder.build(windows: snap.windows, apps: snap.apps, filter: s.filter(ownPID: ownPID), context: ctx, order: s.order == .lastUse ? order : nil, creationOrder: s.order == .creation)
    }

    private func open(_ tile: DockTileInfo) {
        let snap = source.snapshot()
        let list = buildEntries(snap, pid: tile.pid)
        guard !list.isEmpty else {
            if isShown { panel.dismiss() }
            phase = .idle
            entries = []
            return
        }
        let d = display(for: tile, snap)
        entries = list
        display = d
        phase = .shown(tile)
        shownCount += 1
        pushState(tile: tile, snap: snap, present: true)
        let gen = generation
        source.refresh { [weak self] fresh in
            guard let self, self.generation == gen, case .shown(let t) = self.phase, t.pid == tile.pid else { return }
            self.entries = self.buildEntries(fresh, pid: tile.pid)
            if self.entries.isEmpty { self.reset(); return }
            self.pushState(tile: t, snap: fresh, present: false)
        }
    }

    private func display(for tile: DockTileInfo, _ snap: SwitcherSnapshot) -> WndDisplay {
        if let d = DisplayAssignment.display(for: tile.frame, in: snap.displays) { return d }
        return display ?? WndDisplay(id: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 876))
    }

    private func state(tile: DockTileInfo, snap: SwitcherSnapshot) -> DockPreviewViewState {
        let s = settings()
        let d = display(for: tile, snap)
        display = d
        let thumbsOn = screenRecording()
        let m = SwitcherGrid.metrics(count: entries.count, available: d.frame.size, layout: .windows, size: s.previewSize, maxColumns: 0)
        let f = DockPreviewPlacement.frame(panel: m.panel, tile: tile.frame, orientation: tile.orientation, bounds: d.frame)
        frame = f
        return DockPreviewViewState(entries: entries, tile: tile, frame: f, display: d, metrics: m, opacity: s.opacity, showTitles: s.showTitles, minimal: s.minimalPreviews, thumbnails: thumbsOn,
                                    closeQuitsApp: s.quitAppOnClose, middleClickCloses: s.middleClickCloses)
    }

    private func pushState(tile: DockTileInfo, snap: SwitcherSnapshot, present: Bool) {
        let st = state(tile: tile, snap: snap)
        if present { panel.present(st) } else { panel.update(st) }
        if let thumbs, st.thumbnails {
            let ids = ThumbnailPlanner.plan(entries: entries, selected: nil, cache: thumbs.cache, now: ProcessInfo.processInfo.systemUptime, allowCapture: true, budget: SwitcherEngine.thumbBudget)
            thumbs.request(ids)
        }
    }

    public func focus(id: SwitchEntryID) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        reset()
        if let w = e.window { order.touch(window: w.key, pid: w.pid) }
        actor.activate(e)
    }

    public func close(id: SwitchEntryID) {
        guard let e = entries.first(where: { $0.id == id }), case .shown(let tile) = phase else { return }
        switch DockCloseAction.decide(quitAppOnClose: settings().quitAppOnClose) {
        case .quitApp:
            actor.quit(pid: e.pid)
            reset()
            return
        case .closeWindow:
            guard actor.close(e) else { return }
            if let w = e.window { order.forget(window: w.key) }
            entries.removeAll { $0.id == id }
        }
        if entries.isEmpty { reset(); return }
        pushState(tile: tile, snap: source.snapshot(), present: false)
    }

    public func minimize(id: SwitchEntryID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), case .shown(let tile) = phase else { return }
        let target = !entries[idx].isMinimized
        actor.setMinimized(entries[idx], target)
        entries[idx].isMinimized = target
        pushState(tile: tile, snap: source.snapshot(), present: false)
    }

    public func place(id: SwitchEntryID, _ action: WindowLayoutAction) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        if actor.place(e, action) { reset() }
    }
}

public final class DockPreviewStage {
    public static let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown]
    private let hub: EventTapHub
    private let engine: DockPreviewEngine
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, engine: DockPreviewEngine) {
        self.hub = hub
        self.engine = engine
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.dockPreview, seesDropped: false, onReset: { [weak self] in self?.engine.reset() }) { [weak self] type, e in
            guard let self else { return .pass }
            let t = TimeInterval(e.timestamp) / 1_000_000_000
            switch type {
            case .mouseMoved: return self.engine.pointerMoved(e.location, time: t)
            case .leftMouseDown, .rightMouseDown: return self.engine.mouseDown(at: e.location, time: t)
            default: return .pass
            }
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        engine.reset()
    }
}
