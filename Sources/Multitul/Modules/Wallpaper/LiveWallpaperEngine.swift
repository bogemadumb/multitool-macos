import AppKit
import AVFoundation
import IOKit.ps
import MultitulCore

let wallpaperCrossfade: CFTimeInterval = 1.5

@MainActor
final class WallpaperVideoSlot {
    let url: URL
    let stamp: String
    let player = AVQueuePlayer()
    let layer: AVPlayerLayer
    var looper: AVPlayerLooper?

    init(url: URL, stamp: String, bounds: CGRect) {
        self.url = url
        self.stamp = stamp
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        layer.removeFromSuperlayer()
    }
}

@MainActor
final class ScreenWallpaper: NSObject {
    let screen: NSScreen
    let screenID: String
    let window: NSWindow
    let root: CALayer
    var current: WallpaperVideoSlot?
    var pending: WallpaperVideoSlot?
    var pendingSince = Date()
    var readyTimer: Timer?
    var playing = true
    var loggedPlaying: Bool?
    var occluded = false
    var covered = false
    var onOcclusion: (() -> Void)?

    init(screen: NSScreen) {
        self.screen = screen
        screenID = ScreenIdentity.id(for: screen)
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        root = CALayer()
        super.init()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = root
        window.contentView = view

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.orderFront(nil)
    }

    @objc func occlusionChanged() {
        occluded = !window.occlusionState.contains(.visible)
        Log.write("wallpaper occlusion: occluded=\(occluded) screen=\(screen.localizedName)")
        onOcclusion?()
    }

    func wake() {
        window.orderFrontRegardless()
        if !playing, let s = current {
            s.player.seek(to: s.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func show(_ url: URL, stamp: String) {
        if let p = pending, p.stamp == stamp, p.url == url { return }
        if pending == nil, let c = current, c.stamp == stamp, c.url == url { return }
        pending?.stop()
        pending = nil
        let slot = WallpaperVideoSlot(url: url, stamp: stamp, bounds: root.bounds)
        slot.layer.opacity = 0
        root.addSublayer(slot.layer)
        pending = slot
        pendingSince = Date()
        readyTimer?.invalidate()
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPending() }
        }
        Log.write("wallpaper show: \(url.lastPathComponent) screen=\(screen.localizedName)")
    }

    func checkPending() {
        guard let p = pending else { readyTimer?.invalidate(); readyTimer = nil; return }
        if p.layer.isReadyForDisplay {
            readyTimer?.invalidate(); readyTimer = nil
            pending = nil
            let old = current
            current = p
            if !playing { p.player.pause() }
            p.layer.opacity = 1
            if old != nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0
                a.toValue = 1
                a.duration = wallpaperCrossfade
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.layer.add(a, forKey: "fade")
                DispatchQueue.main.asyncAfter(deadline: .now() + wallpaperCrossfade + 0.15) { [weak self] in
                    MainActor.assumeIsolated {
                        if let o = old, o !== self?.current { o.stop() }
                    }
                }
            }
            Log.write("wallpaper ready: \(p.url.lastPathComponent) crossfade=\(old != nil)")
        } else if Date().timeIntervalSince(pendingSince) > 15 {
            Log.write("wallpaper failed to load: \(p.url.lastPathComponent)")
            p.stop()
            pending = nil
            readyTimer?.invalidate(); readyTimer = nil
        }
    }

    func isCoveredByWindows() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        var rects: [CGRect] = []
        for w in list {
            guard Occlusion.countsAsCover(layer: w[kCGWindowLayer as String] as? Int, ownerPID: w[kCGWindowOwnerPID as String] as? Int32,
                                          alpha: w[kCGWindowAlpha as String] as? Double, ownPID: me),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            rects.append(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
        return Occlusion.isCovered(area: Occlusion.topLeftArea(visibleFrame: screen.visibleFrame, primaryHeight: primary.frame.height), rects: rects)
    }

    func setPlaying(_ on: Bool, reason: String) {
        playing = on
        if loggedPlaying != on {
            loggedPlaying = on
            Log.write(on ? "wallpaper play screen=\(screen.localizedName)" : "wallpaper pause screen=\(screen.localizedName) reason=\(reason)")
        }
        guard let s = current else { return }
        if on { if s.player.timeControlStatus == .paused { s.player.play() } } else { s.player.pause() }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        readyTimer?.invalidate()
        readyTimer = nil
        pending?.stop()
        pending = nil
        current?.stop()
        current = nil
        window.orderOut(nil)
        window.close()
    }
}

struct LiveWallpaperStatus: Equatable {
    var running = false
    var videoName: String?
    var isStandard = false
    var isDay = false
    var screens = 0
    var playing = 0
    var pauseReason: PauseReason?
    var nextSwitch: Date?
    var videoCount = 0
    var lockBusy = false
    var lockError: String?
}

struct WallpaperScreenInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class LiveWallpaperController: ObservableObject {
    static let shared = LiveWallpaperController()

    @Published private(set) var status = LiveWallpaperStatus()
    @Published private(set) var color: WallpaperColor
    @Published private(set) var dayMode: DayMode
    @Published private(set) var pauseOnBattery: Bool
    @Published private(set) var manualPause: Bool
    @Published private(set) var lockFollows: Bool
    @Published private(set) var lockVideo: String?
    @Published private(set) var excluded: Set<String>

    private let settings: WallpaperSettings
    private let sun = SunCalc.spb
    private var wallpapers: [ScreenWallpaper] = []
    private var videoMap: [String: URL] = [:]
    private var inputs = PauseInputs()
    private var coverTimer: Timer?
    private var sunTimer: Timer?
    private var tick = 0
    private var lastEffective: String?
    private var screenSignature = ""
    private var activity: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?
    private var dirSource: DispatchSourceFileSystemObject?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lockBusy = false
    private var lockError: String?
    private let lockQueue = DispatchQueue(label: "dev.multitool.app.wallpaper.lockscreen")
    private(set) var isRunning = false

    init(settings: WallpaperSettings = WallpaperSettings()) {
        self.settings = settings
        color = settings.color
        dayMode = settings.dayMode
        pauseOnBattery = settings.pauseOnBattery
        manualPause = settings.manualPause
        lockFollows = settings.lockFollows
        lockVideo = settings.lockVideo
        excluded = settings.excludedScreens
    }

    var screens: [WallpaperScreenInfo] { NSScreen.screens.map { WallpaperScreenInfo(id: ScreenIdentity.id(for: $0), name: $0.localizedName) } }

    func liveRuns(on screenID: String) -> Bool {
        WallpaperExclusion.liveRuns(on: screenID, liveEnabled: isRunning, excluded: excluded)
    }

    private var isDayNow: Bool { WallpaperSelection.isDay(mode: dayMode, sun: sun, now: Date()) }
    private var picked: (name: String, url: URL, standard: Bool)? { WallpaperSelection.pick(color: color, day: isDayNow, videos: videoMap) }
    private var standardName: String? { picked.flatMap { $0.standard ? $0.name : nil } }

    // MARK: lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "live wallpaper must resume instantly on Space change")
        try? FileManager.default.createDirectory(atPath: WallpaperFiles.dir, withIntermediateDirectories: true)
        inputs.manual = manualPause
        inputs.pauseOnBattery = pauseOnBattery
        refreshBattery()
        startPowerWatch()
        startSystemWatch()
        startDirWatch()
        reloadVideos()
        rebuildWallpapers()
        coverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        Log.write("wallpaper start")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        coverTimer?.invalidate(); coverTimer = nil
        sunTimer?.invalidate(); sunTimer = nil
        dirSource?.cancel(); dirSource = nil
        if let s = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); powerSource = nil }
        for (c, t) in observers { c.removeObserver(t) }
        observers.removeAll()
        wallpapers.forEach { $0.teardown() }
        wallpapers = []
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        status = LiveWallpaperStatus()
        Log.write("wallpaper stop")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
        let t = center.addObserver(forName: name, object: nil, queue: .main) { n in MainActor.assumeIsolated { handler(n) } }
        observers.append((center, t))
    }

    // MARK: settings (UI entry points)

    func setColor(_ c: WallpaperColor) {
        color = c; settings.color = c
        refreshEffective("color")
    }

    func setDayMode(_ m: DayMode) {
        dayMode = m; settings.dayMode = m
        refreshEffective("day mode")
    }

    func setPauseOnBattery(_ on: Bool) {
        pauseOnBattery = on; settings.pauseOnBattery = on
        inputs.pauseOnBattery = on
        applyPause()
    }

    func togglePause() {
        manualPause.toggle()
        settings.manualPause = manualPause
        inputs.manual = manualPause
        applyPause()
    }

    func setLockFollows(_ on: Bool) {
        lockFollows = on; settings.lockFollows = on
        syncLockscreen()
    }

    func setScreen(_ id: String, enabled: Bool) {
        if enabled { excluded.remove(id) } else { excluded.insert(id) }
        settings.excludedScreens = excluded
        if isRunning { rebuildWallpapers() }
    }

    func restoreOriginalAerial() {
        lockFollows = false; settings.lockFollows = false
        runLockWork({ try AerialLockscreen.restore() }) { [weak self] in
            self?.lockVideo = nil
            self?.settings.lockVideo = nil
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(atPath: WallpaperFiles.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: WallpaperFiles.dir))
    }

    func refreshNow() { refreshEffective("manual") }

    // MARK: engine

    private func onTick() {
        checkCover()
        tick += 1
        if tick % 5 == 0 { refreshEffective("list") }
    }

    private func checkCover() {
        var changed = false
        for w in wallpapers {
            let c = w.isCoveredByWindows()
            if c != w.covered { w.covered = c; changed = true; Log.write("wallpaper covered=\(c) screen=\(w.screen.localizedName)") }
        }
        if changed { applyPause() }
    }

    private func reloadVideos() { videoMap = WallpaperFiles.scanNames(WallpaperFiles.dir) }

    private func makeSignature() -> String {
        NSScreen.screens.map { "\(ScreenIdentity.id(for: $0))@\(NSStringFromRect($0.frame))" }.joined(separator: "|")
    }

    private func rebuildWallpapers() {
        let old = wallpapers
        wallpapers = []
        screenSignature = makeSignature()
        if let p = picked, let st = FileStamp.of(p.url) {
            for screen in NSScreen.screens where !excluded.contains(ScreenIdentity.id(for: screen)) {
                let w = ScreenWallpaper(screen: screen)
                w.onOcclusion = { [weak self] in self?.checkCover(); self?.applyPause() }
                w.show(p.url, stamp: st.stamp)
                wallpapers.append(w)
            }
        }
        old.forEach { $0.teardown() }
        lastEffective = standardName
        Log.write("wallpaper rebuild: screens=\(wallpapers.count) effective=\(picked?.url.lastPathComponent ?? "none")")
        applyPause()
        syncLockscreen()
        scheduleSunTimer()
    }

    // Re-evaluates what should play now; also called on wake, unlock, clock change and sun events.
    func refreshEffective(_ reason: String) {
        guard isRunning else { return }
        reloadVideos()
        let shouldHave = picked != nil && NSScreen.screens.contains { !excluded.contains(ScreenIdentity.id(for: $0)) }
        if wallpapers.isEmpty == shouldHave { rebuildWallpapers(); return }
        if let p = picked, let st = FileStamp.of(p.url) {
            for w in wallpapers where st.isSettled || w.current == nil { w.show(p.url, stamp: st.stamp) }
        }
        if standardName != lastEffective {
            lastEffective = standardName
            Log.write("wallpaper effective: \(standardName ?? "legacy") (\(reason)) color=\(color.rawValue) day=\(isDayNow) mode=\(dayMode.rawValue)")
        }
        syncLockscreen()
        scheduleSunTimer()
        publish()
    }

    private func scheduleSunTimer() {
        sunTimer?.invalidate()
        sunTimer = nil
        guard isRunning else { return }
        let fire = sun.nextRefresh(after: Date())
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEffective("sun event") }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        sunTimer = t
    }

    private func applyPause() {
        for w in wallpapers {
            var i = inputs
            i.occluded = w.occluded
            i.covered = w.covered
            w.setPlaying(i.shouldPlay, reason: i.reason?.rawValue ?? "")
        }
        publish()
    }

    private func publish() {
        var s = LiveWallpaperStatus()
        s.running = isRunning
        s.videoName = picked?.name
        s.isStandard = picked?.standard ?? false
        s.isDay = isDayNow
        s.screens = wallpapers.count
        s.playing = wallpapers.filter(\.playing).count
        s.pauseReason = inputs.globalReason
        s.nextSwitch = dayMode == .auto ? sun.nextEvent(after: Date()) : nil
        s.videoCount = videoMap.count
        s.lockBusy = lockBusy
        s.lockError = lockError
        if s != status { status = s }
    }

    // MARK: system events

    private func refreshBattery() {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        inputs.onBattery = (type == kIOPSBatteryPowerValue)
    }

    private func startPowerWatch() {
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let c = Unmanaged<LiveWallpaperController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { c.refreshBattery(); c.applyPause() } }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource(cb, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private func startSystemWatch() {
        let dn = DistributedNotificationCenter.default()
        observe(dn, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.inputs.locked = true; self?.applyPause() }
        observe(dn, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.inputs.locked = false
            self?.applyPause()
            self?.refreshEffective("unlock")
        }
        let wn = NSWorkspace.shared.notificationCenter
        observe(wn, NSWorkspace.willSleepNotification) { [weak self] _ in self?.inputs.systemAsleep = true; self?.applyPause() }
        observe(wn, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.inputs.screensAsleep = true; self?.applyPause() }
        // DarkWake fires didWake without screensDidWake: the system is awake, the screens stay asleep, nothing plays.
        observe(wn, NSWorkspace.didWakeNotification) { [weak self] _ in self?.afterWake("didWake", screensWoke: false) }
        observe(wn, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.afterWake("screensDidWake", screensWoke: true) }
        observe(wn, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.spaceChanged() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.screensChanged() }
        for name in [Notification.Name.NSSystemClockDidChange, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observe(NotificationCenter.default, name) { [weak self] _ in self?.refreshEffective("time change") }
        }
    }

    private func afterWake(_ what: String, screensWoke: Bool) {
        inputs.systemAsleep = false
        if screensWoke { inputs.screensAsleep = false }
        Log.write("wallpaper wake: \(what) screensAsleep=\(inputs.screensAsleep)")
        applyPause()
        refreshEffective("wake")
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshEffective("wake+\(Int(delay))s") }
            }
        }
    }

    private func screensChanged() {
        let sig = makeSignature()
        Log.write("wallpaper screen parameters changed: layoutChanged=\(sig != screenSignature)")
        if sig != screenSignature { rebuildWallpapers() }
        objectWillChange.send()
    }

    private func spaceChanged() {
        for w in wallpapers { w.covered = false; w.wake() }
        applyPause()
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.checkCover() }
            }
        }
    }

    private func startDirWatch() {
        let fd = open(WallpaperFiles.dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshEffective("list") } }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    // MARK: lock screen (Aerial), only while the user toggle is on

    private func syncLockscreen() {
        guard isRunning, let name = AerialLockscreen.syncTarget(follows: lockFollows, busy: lockBusy, desired: standardName, current: lockVideo,
                                                                hasClip: { FileManager.default.fileExists(atPath: AerialPaths().clip($0)) }) else { return }
        Log.write("wallpaper lockscreen: \(lockVideo ?? "original") -> \(name)")
        runLockWork({ try AerialLockscreen.apply(name: name) }) { [weak self] in
            self?.lockVideo = name
            self?.settings.lockVideo = name
            self?.syncLockscreen()
        }
    }

    private func runLockWork(_ work: @escaping @Sendable () throws -> Void, done: @escaping @MainActor () -> Void) {
        guard !lockBusy else { return }
        lockBusy = true
        lockError = nil
        publish()
        lockQueue.async {
            let err: String?
            do { try work(); err = nil } catch { err = (error as? AerialError)?.text ?? error.localizedDescription }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.lockBusy = false
                    if let err {
                        self.lockError = err
                        Log.write("wallpaper lockscreen error: \(err)")
                    } else { done() }
                    self.publish()
                }
            }
        }
    }
}
