import Foundation
import CoreGraphics

public protocol SwitcherSource: AnyObject {
    func snapshot() -> SwitcherSnapshot
    func refresh(_ completion: @escaping (SwitcherSnapshot) -> Void)
}

public protocol SwitcherActing: AnyObject {
    func activate(_ e: SwitchEntry)
    @discardableResult func close(_ e: SwitchEntry) -> Bool
    func setMinimized(_ e: SwitchEntry, _ minimized: Bool)
    func quit(pid: Int32)
    func hide(pid: Int32)
    @discardableResult func place(_ e: SwitchEntry, _ action: WindowLayoutAction) -> Bool
}

public struct SwitcherViewState: Equatable {
    public var entries: [SwitchEntry]
    public var selected: Int?
    public var query: String
    public var searching: Bool
    public var metrics: SwitcherGridMetrics
    public var display: WndDisplay
    public var layout: SwitcherLayout
    public var showHints: Bool
    public var instant: Bool
    public var minimal: Bool
    public var thumbnails: Bool
}

public protocol SwitcherPanelDriving: AnyObject {
    func present(_ state: SwitcherViewState)
    func update(_ state: SwitcherViewState)
    func thumbnailUpdated(windowID: UInt32)
    func dismiss()
    func contains(_ p: CGPoint) -> Bool
}

public final class SwitcherEngine: SwitcherControlling {
    public static let searchBarHeight: CGFloat = 44
    public static let thumbBudget = 24

    private let source: SwitcherSource
    private let actor: SwitcherActing
    private let panel: SwitcherPanelDriving
    private let thumbs: ThumbnailService?
    private let order: WindowUseOrder
    private let settings: () -> SwitcherSettings
    private let ownPID: Int32
    private let screenRecording: () -> Bool
    private let clock: () -> TimeInterval
    private let fallbackDisplay = WndDisplay(id: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 876))

    public private(set) var session: SwitcherSession?
    public private(set) var presented = false
    public private(set) var commitCount = 0
    public var onEnded: (() -> Void)?
    private var context = SwitcherContext()
    private var trigger = SwitcherTrigger.apps
    private var display: WndDisplay?
    private var lastSnapshot = SwitcherSnapshot()
    private var generation = 0

    public init(source: SwitcherSource, actor: SwitcherActing, panel: SwitcherPanelDriving, thumbs: ThumbnailService? = nil, order: WindowUseOrder = WindowUseOrder(),
                settings: @escaping () -> SwitcherSettings, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, screenRecording: @escaping () -> Bool = { true },
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.actor = actor
        self.panel = panel
        self.thumbs = thumbs
        self.order = order
        self.settings = settings
        self.ownPID = ownPID
        self.screenRecording = screenRecording
        self.clock = clock
        thumbs?.onUpdate = { [weak self] id in self?.panel.thumbnailUpdated(windowID: id) }
    }

    public var isActive: Bool { session != nil }
    public var useOrder: WindowUseOrder { order }

    private func buildEntries(_ snap: SwitcherSnapshot) -> [SwitchEntry] {
        let s = settings()
        let d = SwitcherDisplayChoice.display(for: s.screenPlacement, in: snap)
        display = d
        var ctx = SwitcherContext(scope: .allApps, focusedKey: snap.focusedKey, frontPID: snap.frontPID, activeDisplayID: d?.id)
        if trigger == .windows { ctx.scope = .sameApp(snap.frontPID ?? -1) }
        context = ctx
        return SwitcherListBuilder.build(windows: snap.windows, apps: snap.apps, filter: s.filter(ownPID: ownPID), context: ctx, order: order)
    }

    public func begin(trigger t: SwitcherTrigger, backward: Bool) -> Bool {
        trigger = t
        let snap = source.snapshot()
        lastSnapshot = snap
        order.reconcile(frontToBack: snap.windows.sorted { $0.zIndex < $1.zIndex })
        if let fk = snap.focusedKey, let w = snap.windows.first(where: { $0.key == fk }) { order.touch(window: w.key, pid: w.pid) }
        let entries = buildEntries(snap)
        if t == .windows, entries.count < 2 { return false }
        guard !entries.isEmpty else { return false }
        session = SwitcherSession(entries: entries, backward: backward)
        presented = false
        generation += 1
        let gen = generation
        thumbs?.resetFailures()
        source.refresh { [weak self] fresh in
            guard let self, self.generation == gen, self.session != nil else { return }
            self.applyRefresh(fresh)
        }
        return true
    }

    private func applyRefresh(_ snap: SwitcherSnapshot) {
        lastSnapshot = snap
        let fresh = buildEntries(snap)
        session?.merge(fresh: fresh)
        if presented { pushState(requestThumbs: true) }
    }

    private func currentMetrics() -> (SwitcherGridMetrics, WndDisplay)? {
        guard let s = session else { return nil }
        let st = settings()
        let d = display ?? lastSnapshot.displays.first ?? fallbackDisplay
        let bar = s.searching ? Self.searchBarHeight : 0
        let m = SwitcherGrid.metrics(count: s.count, available: d.visible.size, layout: st.layout, size: st.previewSize, maxColumns: st.maxColumns, searchBar: bar)
        return (m, d)
    }

    private func makeState() -> SwitcherViewState? {
        guard let s = session, let (m, d) = currentMetrics() else { return nil }
        let st = settings()
        return SwitcherViewState(entries: s.visible, selected: s.selected, query: s.query, searching: s.searching, metrics: m, display: d, layout: st.layout,
                                 showHints: st.showShortcutHints, instant: st.instantSelection, minimal: st.minimalPreviews, thumbnails: thumbnailsOn)
    }

    private var thumbnailsOn: Bool {
        let st = settings()
        return st.layout == .windows && screenRecording()
    }

    private func pushState(requestThumbs: Bool) {
        guard let state = makeState() else { return }
        panel.update(state)
        if requestThumbs { requestVisibleThumbs(state) }
    }

    private func requestVisibleThumbs(_ state: SwitcherViewState) {
        guard let thumbs, state.thumbnails else { return }
        let rows = max(state.metrics.visibleRows, 1)
        let cols = max(state.metrics.columns, 1)
        let sel = state.selected ?? 0
        let firstRow = max(0, state.metrics.row(of: sel) - rows + 1)
        let lo = firstRow * cols
        let hi = min(state.entries.count, (firstRow + rows) * cols)
        let range = lo < hi ? lo..<hi : 0..<state.entries.count
        let ids = ThumbnailPlanner.plan(entries: state.entries, selected: state.selected, cache: thumbs.cache, now: clock(), allowCapture: true, budget: Self.thumbBudget, visibleRange: range)
        thumbs.request(ids)
    }

    public func present() {
        guard session != nil, !presented else { return }
        presented = true
        guard let state = makeState() else { return }
        panel.present(state)
        requestVisibleThumbs(state)
    }

    private func refreshView() {
        guard presented else { return }
        pushState(requestThumbs: true)
    }

    public func move(_ step: Int) {
        session?.move(step)
        refreshView()
    }

    public func moveVertical(_ rows: Int) {
        guard let (m, _) = currentMetrics() else { return }
        session?.moveVertical(rows, columns: m.columns)
        refreshView()
    }

    public func select(id: SwitchEntryID) {
        guard session?.select(id: id) == true else { return }
        refreshView()
    }

    public func activateEntry(id: SwitchEntryID) {
        guard session?.select(id: id) == true else { return }
        commit()
    }

    public func commit() {
        guard let s = session else { return }
        let entry = s.selectedEntry
        endSession()
        guard let entry else { return }
        if let w = entry.window { order.touch(window: w.key, pid: w.pid) } else { order.touchApp(entry.pid) }
        actor.activate(entry)
        commitCount += 1
    }

    public func cancel() {
        guard session != nil else { return }
        endSession()
    }

    private func endSession() {
        session = nil
        generation += 1
        thumbs?.cancelQueued()
        if presented { panel.dismiss() }
        presented = false
        onEnded?()
    }

    public func closeSelected() {
        guard let s = session, let e = s.selectedEntry else { return }
        closeEntry(e)
    }

    public func closeEntry(id: SwitchEntryID) {
        guard let e = session?.visible.first(where: { $0.id == id }) else { return }
        closeEntry(e)
    }

    private func closeEntry(_ e: SwitchEntry) {
        guard e.kind != .appOnly else { actor.quit(pid: e.pid); dropApp(e.pid); return }
        guard actor.close(e) else { return }
        if let w = e.window { order.forget(window: w.key) }
        if e.kind == .group, e.windowCount > 1 {
            var copy = e
            copy.windowCount -= 1
            session?.replace(copy)
            source.refresh { [weak self] snap in self?.applyRefresh(snap) }
        } else {
            session?.remove(id: e.id)
        }
        afterMutation()
    }

    public func quitSelected() {
        guard let e = session?.selectedEntry else { return }
        quitEntry(pid: e.pid)
    }

    public func quitEntry(pid: Int32) {
        actor.quit(pid: pid)
        dropApp(pid)
    }

    private func dropApp(_ pid: Int32) {
        guard let s = session else { return }
        for e in s.all where e.pid == pid { session?.remove(id: e.id) }
        afterMutation()
    }

    public func minimizeSelected() {
        guard let e = session?.selectedEntry, e.kind != .appOnly else { return }
        let target = !e.isMinimized
        actor.setMinimized(e, target)
        var copy = e
        copy.isMinimized = target
        session?.replace(copy)
        refreshView()
    }

    public func hideSelected() {
        guard let e = session?.selectedEntry else { return }
        actor.hide(pid: e.pid)
        if let s = session {
            for x in s.all where x.pid == e.pid {
                var copy = x
                copy.isAppHidden = true
                session?.replace(copy)
            }
        }
        refreshView()
    }

    private func afterMutation() {
        guard let s = session else { return }
        if s.isEmpty { cancel(); return }
        refreshView()
    }

    public func beginSearch() {
        session?.beginSearch()
        if !presented { present() } else { pushState(requestThumbs: false) }
    }

    public func appendQuery(_ text: String) {
        session?.appendQuery(text)
        refreshView()
    }

    public func deleteQueryCharacter() {
        session?.deleteLastQueryCharacter()
        refreshView()
    }

    public func clearQuery() -> Bool {
        guard let s = session, !s.query.isEmpty else { return false }
        session?.setQuery("")
        refreshView()
        return true
    }

    public func containsPoint(_ p: CGPoint) -> Bool { panel.contains(p) }
}
