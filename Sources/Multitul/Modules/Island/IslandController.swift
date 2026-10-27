import SwiftUI
import AppKit
import Combine
import MultitulCore
import MultitulUI

@MainActor
final class IslandController: ObservableObject {
    static let shared = IslandController()

    @Published private(set) var settings = IslSettings()
    @Published private(set) var layout = IslLayout()
    @Published private(set) var shortcuts = IslShortcutList()
    @Published private(set) var arbitration = IslArbitration.empty
    @Published private(set) var conflicts: [IslConflict] = []
    @Published private(set) var running = false
    @Published private(set) var revision = 0
    @Published private(set) var screens: [IslScreenInfo] = []

    let registry = IslSectionRegistry()
    let accessories = IslAccessoryRegistry()
    let music = IslandMusic.shared

    private let settingsStore = IslSettingsStore()
    private let layoutStore = IslLayoutStore()
    private let shortcutStore = IslShortcutStore()
    private let environment = IslandEnvironment()
    private var arbiter = IslArbiter()
    private var hosts: [UInt32: IslandDisplayHost] = [:]
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runtimeWatch: AnyCancellable?
    private var ticker: Timer?
    private var tickCount = 0
    private var fullscreenIDs = Set<UInt32>()
    private var lastSection: IslSectionID?
    private var built = false
    private var lastWingAccessories = false

    private init() {}

    var spec: HotkeySpec { IslHotkeys.toggle }

    var descriptors: [IslSectionDescriptor] { registry.descriptors }

    var visibleSectionIDs: [IslSectionID] { registry.available(layout).map { $0.descriptor.id } }

    // MARK: lifecycle

    func start() {
        guard !running else { return }
        running = true
        settings = settingsStore.load()
        shortcuts = shortcutStore.load()
        buildSections()
        layout = layoutStore.load(known: descriptors)
        lastSection = layoutStore.loadLast()
        arbiter.reset()
        for s in registry.sections {
            s.onChange = { [weak self] in self?.activitiesChanged() }
            s.start()
        }
        environment.onMenuClearance = { [weak self] in self?.relayout() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildHosts() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConflicts() }
            })
        }
        runtimeWatch = AppController.shared.runtime.$revision.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.modulesChanged() } }
        }
        installMonitors()
        HotkeyManager.shared.register(spec, owner: ModuleID.notch.rawValue) { [weak self] in self?.toggleAtCursor() }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        refreshConflicts()
        rebuildHosts()
        refreshActivities()
        Log.write("island start hosts=\(hosts.count) sections=\(registry.sections.count)")
    }

    func stop() {
        guard running else { return }
        running = false
        ticker?.invalidate()
        ticker = nil
        runtimeWatch = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.notch.rawValue)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        for h in hosts.values { h.teardown() }
        hosts = [:]
        for s in registry.sections { s.onChange = nil; s.stop() }
        arbitration = IslArbitration.empty
        AppController.shared.setStatusIconHidden(false)
        Log.write("island stop")
    }

    private func buildSections() {
        guard !built else { return }
        built = true
        registry.register(IslandMusicSection())
        registry.register(IslandLevelsSection())
        registry.register(IslandShortcutsSection())
        registry.register(IslandMixerSection())
        registry.register(IslandClipboardSection())
        registry.register(IslandShotsSection())
        registry.register(IslandShelfSection())
        registry.register(IslandStatsSection())
        registry.register(IslandToolsSection())
        registry.register(IslandCalendarSection())
        registry.register(IslandNotificationsSection())
        registry.register(IslandTimerSection())
        registry.register(IslandAccessoriesSection())
        registry.register(IslandLyricsSection())
        registry.register(IslandQueueSection())
        registry.register(IslandDownloadsSection())
        registry.register(IslandWatchSection())
    }

    // MARK: settings

    func update(_ s: IslSettings) {
        let clean = s.sanitized
        let displaysChanged = clean.displayMode != settings.displayMode || clean.selectedDisplays != settings.selectedDisplays || clean.virtualPill != settings.virtualPill
            || clean.sizePreset != settings.sizePreset
        settings = clean
        settingsStore.save(clean)
        for h in hosts.values { h.configChanged() }
        if displaysChanged { rebuildHosts() } else { relayout() }
        applyIconPolicy()
        environmentChanged()
        refreshActivities()
    }

    func updateLayout(_ l: IslLayout) {
        var n = l
        n.normalize(known: descriptors)
        layout = n
        layoutStore.save(n, known: descriptors)
        revision &+= 1
    }

    func updateShortcuts(_ list: IslShortcutList) {
        shortcuts = list.sanitized
        shortcutStore.save(shortcuts)
    }

    func resetLayout() { updateLayout(IslLayout.defaults(for: descriptors)) }

    private func applyIconPolicy() {
        AppController.shared.setStatusIconHidden(running && settings.hideMenuIcon && !hosts.isEmpty)
    }

    func openSettings() {
        AppController.shared.openSection(ModuleGroup.island.rawValue)
        hosts.values.forEach { $0.close() }
    }

    // MARK: hosts

    private func rebuildHosts() {
        guard running else { return }
        screens = IslandScreens.current()
        let wanted = IslDisplaySelector.select(screens, mode: settings.displayMode, selected: settings.selectedDisplays, virtualPill: settings.virtualPill)
        let ids = Set(wanted.map(\.id))
        for (id, h) in hosts where !ids.contains(id) {
            h.teardown()
            hosts[id] = nil
        }
        for s in wanted where hosts[s.id] == nil { hosts[s.id] = IslandDisplayHost(screen: s, ctl: self) }
        relayout()
        applyIconPolicy()
        environmentChanged()
    }

    var hasWingAccessories: Bool {
        !accessories.active(in: .wingLeading).isEmpty || !accessories.active(in: .wingTrailing).isEmpty
    }

    func accessoriesChanged() {
        lastWingAccessories = hasWingAccessories
        relayout()
        revision &+= 1
    }

    func closeAll() { hosts.values.forEach { $0.close() } }

    private func currentWings(for screen: IslScreenInfo) -> IslWings {
        guard arbitration.winner != nil || hasWingAccessories else { return .zero }
        let notch = IslNotchDetector.notch(for: screen).rect
        return environment.clearance.localized(to: screen.frame).wings(notch: notch, enabled: settings.avoidMenus)
    }

    private func relayout() {
        for (id, h) in hosts {
            guard let s = screens.first(where: { $0.id == id }) else { continue }
            h.update(screen: s, wings: currentWings(for: s))
        }
    }

    // MARK: environment and suppression

    private func environmentChanged() {
        guard running else { return }
        environment.refreshMenuClearance(enabled: settings.avoidMenus)
        fullscreenIDs = settings.hideInFullscreen ? environment.fullscreenScreens(screens) : []
        refreshSuppression()
    }

    func refreshSuppression() {
        guard running else { return }
        let menu = hosts.values.contains { $0.machine.pointerInside || $0.state != .closed } ? environment.isMenuOpen() : false
        for h in hosts.values {
            var s = Set<IslSuppression>()
            if fullscreenIDs.contains(h.screen.id) { s.insert(.fullscreen) }
            if menu && h.state == .closed { s.insert(.menuOpen) }
            h.setSuppression(s)
            h.setHidden(s.contains(.fullscreen))
        }
    }

    private func tick() {
        tickCount += 1
        refreshActivities()
        if hasWingAccessories != lastWingAccessories { accessoriesChanged() }
        if tickCount % 4 == 0 { environmentChanged() }
        for h in hosts.values where h.state == .closed { h.refreshIntake() }
    }

    func modulesChanged() {
        revision &+= 1
        for h in hosts.values { h.model.currentSection = IslNavigator.settle(current: h.model.currentSection, visible: visibleSectionIDs) }
        refreshActivities()
    }

    // MARK: activities

    private func activitiesChanged() { refreshActivities() }

    private func refreshActivities() {
        guard running else { return }
        let all = registry.activities(muted: settings.mutedActivities)
        let result = arbiter.resolve(all, now: Date(), muted: settings.mutedActivities)
        let wingsChanged = (result.winner == nil) != (arbitration.winner == nil)
        if result != arbitration { arbitration = result }
        if wingsChanged { relayout() }
        if result.shouldPeek, settings.peekOnChange {
            for h in hosts.values { h.send(.peek(duration: nil)) }
        }
    }

    // MARK: monitors

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.pointerMoved(p) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.pointerMoved(p) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.hosts.values.forEach { $0.outsideClick(p) } }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.escape() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53, e.window is IslandPanel else { return e }
            MainActor.assumeIsolated { self?.escape() }
            return nil
        }) { monitors.append(m) }
    }

    private func pointerMoved(_ p: CGPoint) {
        for h in hosts.values { h.pointerMoved(p) }
    }

    private func escape() {
        for h in hosts.values where h.state != .closed { h.send(.escape) }
    }

    func toggleAtCursor() {
        let p = NSEvent.mouseLocation
        let host = hosts.values.first { $0.screen.frame.contains(p) } ?? hosts.values.first { $0.screen.isMain } ?? hosts.values.first
        host?.send(.hotkey)
    }

    // MARK: sections

    private func draggingFiles() -> Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && !(NSPasteboard(name: .drag).types ?? []).isEmpty
    }

    func hostWillOpen(_ host: IslandDisplayHost, trigger: IslTrigger) {
        let ids = visibleSectionIDs
        let drop = (trigger == .drag || draggingFiles()) ? IslSectionIDs.shelf : nil
        let start = IslNavigator.start(choice: settings.start, last: lastSection, visible: ids, activeSection: arbitration.winner?.section, dropTarget: drop)
        host.model.currentSection = start
        host.model.pinned = host.machine.pinned
        if let s = start { registry.section(s)?.didAppear() }
        refreshIntakeAndSections()
    }

    func hostClosed(_ host: IslandDisplayHost, from: IslState) {
        guard from == .open || host.model.state == .open else { return }
        if let id = host.model.currentSection { registry.section(id)?.didDisappear() }
    }

    private func refreshIntakeAndSections() { revision &+= 1 }

    private func rememberSection(_ id: IslSectionID) {
        lastSection = id
        layoutStore.saveLast(id)
    }

    func select(_ id: IslSectionID, on host: IslandDisplayHost) {
        guard visibleSectionIDs.contains(id), id != host.model.currentSection else { return }
        if let old = host.model.currentSection { registry.section(old)?.didDisappear() }
        withAnimation(.easeInOut(duration: 0.18)) { host.model.currentSection = id }
        registry.section(id)?.didAppear()
        rememberSection(id)
    }

    func swipe(on host: IslandDisplayHost, forward: Bool) {
        guard let current = host.model.currentSection, let s = registry.section(current) else { return }
        if s.handle(forward ? .swipeNext : .swipePrevious) { return }
        let ids = visibleSectionIDs
        guard let target = forward ? IslNavigator.next(after: current, in: ids) : IslNavigator.previous(before: current, in: ids) else { return }
        select(target, on: host)
    }

    func openSection(_ id: IslSectionID) {
        guard let h = hosts.values.first(where: { $0.screen.isMain }) ?? hosts.values.first else { return }
        if h.state != .open { h.send(.hotkey) }
        if h.state == .open { select(id, on: h) }
    }

    // MARK: conflicts

    func refreshConflicts() {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (bundleID: String, name: String, pid: Int32)? in
            guard let b = app.bundleIdentifier else { return nil }
            return (b, app.localizedName ?? b, app.processIdentifier)
        }
        let found = IslConflictDetector.find(running: running)
        if found != conflicts { conflicts = found }
    }

    func terminateConflicts() {
        for c in conflicts { NSRunningApplication(processIdentifier: c.pid)?.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in MainActor.assumeIsolated { self?.refreshConflicts() } }
    }
}
