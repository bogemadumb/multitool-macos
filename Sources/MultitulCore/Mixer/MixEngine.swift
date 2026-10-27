import Foundation

public protocol MixDriving: AnyObject {
    func processes() -> [MixProcessInfo]
    func runningApps() -> [MixRunningApp]
    func create(_ tap: MixDesiredTap) -> MixTapError?
    func update(key: String, params: MixParams)
    func destroy(key: String)
    func destroyAll()
    func levels(key: String, bands: Bool) -> MixLevels?
    func orphanCandidates() -> (aggregates: [MixAggregateInfo], taps: [MixTapInfo])
    func destroyAggregate(_ id: UInt32)
    func destroyTap(_ id: UInt32)
    var ownedAggregateUIDs: Set<String> { get }
    var ownedTapUIDs: Set<String> { get }
}

public protocol MixOutputVolumeControlling: AnyObject {
    func outputVolume(uid: String) -> Float?
    func setOutputVolume(uid: String, _ value: Float) -> Bool
}

public struct MixSnapshot: Equatable, Sendable {
    public var rows: [MixAppRow] = []
    public var options: [MixRouteOption] = []
    public var errors: [String: MixTapError] = [:]
    public var fallbackKeys: Set<String> = []
    public var processing: Set<String> = []
    public var defaultOutputName: String?
    public var settings = MixSettings()

    public init() {}
}

// Single-threaded: the owner calls everything from one serial queue.
public final class MixEngine {
    public private(set) var settings = MixSettings()
    public private(set) var apps: [String: MixAppSetting] = [:]
    public private(set) var list = MixAppListModel()
    public private(set) var live: [String: MixLiveTapInfo] = [:]
    public private(set) var errors: [String: MixTapError] = [:]
    public private(set) var devices: [AudioDeviceInfo] = []
    public private(set) var defaultUID: String?
    public private(set) var isRunning = false
    public var onGuard: ((MixGuardAction, String) -> Void)?

    private let driver: MixDriving
    private let hardware: AudioHardware
    private let volumes: MixOutputVolumeControlling?
    private let store: MixSettingsStore
    private let ownPID: Int32
    private let clock: () -> TimeInterval
    private var backoff = MixRetryBackoff()
    private var demands: [String: MixLevelDemand] = [:]
    private var lastDefaultInfo: AudioDeviceInfo?

    public init(driver: MixDriving, hardware: AudioHardware, volumes: MixOutputVolumeControlling? = nil, store: MixSettingsStore,
                ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver
        self.hardware = hardware
        self.volumes = volumes
        self.store = store
        self.ownPID = ownPID
        self.clock = clock
    }

    // MARK: lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        settings = store.loadSettings()
        apps = store.loadApps(maxBoost: settings.maxBoost)
        cleanupOrphans()
        readDevices()
        lastDefaultInfo = currentDefaultInfo()
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        driver.destroyAll()
        live = [:]
        errors = [:]
        backoff = MixRetryBackoff()
    }

    @discardableResult
    public func cleanupOrphans() -> MixCleanupPlan {
        let found = driver.orphanCandidates()
        let plan = MixOrphans.plan(aggregates: found.aggregates, taps: found.taps, ownedAggregateUIDs: driver.ownedAggregateUIDs, ownedTapUIDs: driver.ownedTapUIDs)
        for id in plan.aggregates { driver.destroyAggregate(id) }
        for id in plan.taps { driver.destroyTap(id) }
        return plan
    }

    // MARK: hardware

    private func readDevices() {
        devices = hardware.devices()
        defaultUID = hardware.defaultUID(.output)
    }

    private func currentDefaultInfo() -> AudioDeviceInfo? {
        defaultUID.flatMap { uid in devices.first { $0.uid == uid } }
    }

    public func handle(_ event: AudioHardwareEvent) {
        guard isRunning else { return }
        switch event {
        case .devicesChanged, .defaultChanged(.output), .systemOutputChanged:
            readDevices()
            let now = currentDefaultInfo()
            if now?.uid != lastDefaultInfo?.uid { checkGuard(previous: lastDefaultInfo, current: now) }
            lastDefaultInfo = now ?? lastDefaultInfo
            reconcileNow()
        case .defaultChanged(.input):
            break
        }
    }

    private func checkGuard(previous: AudioDeviceInfo?, current: AudioDeviceInfo?) {
        guard let current, let volumes else { return }
        let vol = volumes.outputVolume(uid: current.uid)
        guard let action = MixHeadphoneGuard.decide(previous: previous, current: current, currentVolume: vol, settings: settings) else { return }
        if volumes.setOutputVolume(uid: action.deviceUID, action.to) { onGuard?(action, current.name) }
    }

    // MARK: refresh

    @discardableResult
    public func refresh() -> MixAppDiff {
        guard isRunning else { return MixAppDiff() }
        let now = clock()
        let entries = MixAppIdentity.resolve(driver.processes(), apps: driver.runningApps(), ownPID: ownPID)
        let diff = list.update(entries, now: now)
        rememberNames()
        reconcileNow()
        return diff
    }

    private func rememberNames() {
        var changed = false
        for e in list.entries {
            guard var s = apps[e.key], s.name != e.name else { continue }
            s.name = e.name
            apps[e.key] = s
            changed = true
        }
        if changed { store.saveApps(apps) }
    }

    private var combinedDemand: MixLevelDemand {
        var d = MixLevelDemand()
        for v in demands.values {
            d.allApps = d.allApps || v.allApps
            d.keys.formUnion(v.keys)
            d.bandKeys.formUnion(v.bandKeys)
        }
        return d
    }

    public func setDemand(owner: String, _ demand: MixLevelDemand?) {
        if let demand, demand != .none { demands[owner] = demand } else { demands[owner] = nil }
        reconcileNow()
    }

    public func reconcileNow() {
        guard isRunning else { return }
        let now = clock()
        let blocked = Set(list.entries.map(\.key).filter { !backoff.canTry($0, now: now) })
        let demand = settings.showMeters ? combinedDemand : MixLevelDemand(allApps: false, keys: combinedDemand.keys, bandKeys: combinedDemand.bandKeys)
        let want = MixPlanner.desired(entries: list.entries, apps: apps, settings: settings, devices: devices, defaultUID: defaultUID, demand: demand, failedKeys: blocked)
        for action in MixPlanner.reconcile(desired: want, live: live) {
            switch action {
            case .destroy(let key):
                driver.destroy(key: key)
                live[key] = nil
            case .create(let d):
                build(d, now: now)
            case .replace(let d):
                driver.destroy(key: d.key)
                live[d.key] = nil
                build(d, now: now)
            case .update(let key, let params):
                driver.update(key: key, params: params)
                if var l = live[key] {
                    l.appliedParams = params
                    l.desired.params = params
                    live[key] = l
                }
            }
        }
        let present = Set(list.entries.map(\.key))
        for key in errors.keys where !present.contains(key) || !(apps[key]?.needsProcessing ?? false) { errors[key] = nil }
    }

    private func build(_ d: MixDesiredTap, now: TimeInterval) {
        if let err = driver.create(d) {
            errors[d.key] = err
            backoff.fail(d.key, now: now)
        } else {
            live[d.key] = MixLiveTapInfo(desired: d)
            errors[d.key] = nil
            backoff.succeed(d.key)
        }
    }

    // MARK: intents

    private func touch(_ key: String, name: String? = nil, _ change: (inout MixAppSetting) -> Void, persist: Bool = true) {
        var s = apps[key] ?? MixAppSetting()
        if s.name.isEmpty { s.name = name ?? list.entries.first { $0.key == key }?.name ?? "" }
        change(&s)
        s.lastUsed = Date().timeIntervalSince1970
        apps[key] = s.isNeutral ? nil : s
        if persist { store.saveApps(apps) }
        reconcileNow()
    }

    public func setVolume(_ key: String, _ volume: Double, persist: Bool = true) {
        let v = MixGain.clampVolume(volume, maxBoost: settings.maxBoost)
        touch(key, { $0.volume = v }, persist: persist)
    }

    public func setMuted(_ key: String, _ muted: Bool) { touch(key) { $0.muted = muted } }

    public func toggleMute(_ key: String) { setMuted(key, !(apps[key]?.muted ?? false)) }

    public func setOutput(_ key: String, _ uid: String?) { touch(key) { $0.outputUID = uid } }

    public func setPinned(_ key: String, _ pinned: Bool) { touch(key) { $0.pinned = pinned } }

    public func reset(_ key: String) {
        guard apps[key] != nil else { return }
        touch(key) { $0.volume = 1; $0.muted = false; $0.outputUID = nil }
    }

    public func resetAll() {
        for key in apps.keys {
            guard var s = apps[key] else { continue }
            s.volume = 1; s.muted = false; s.outputUID = nil
            apps[key] = s.isNeutral ? nil : s
        }
        store.saveApps(apps)
        reconcileNow()
    }

    public func step(_ key: String, up: Bool) {
        let cur = apps[key]?.volume ?? 1
        setVolume(key, MixGain.step(cur, up: up, fine: settings.fineSteps, maxBoost: settings.maxBoost))
    }

    public func update(settings new: MixSettings) {
        var s = new
        s.maxBoost = MixGain.clampBoost(s.maxBoost)
        s.guardCapPercent = min(max(s.guardCapPercent, MixSettings.guardRange.lowerBound), MixSettings.guardRange.upperBound)
        s.order = MixSettingsStore.cleanOrder(s.order)
        settings = s
        var changed = false
        for (k, a) in apps where a.volume > s.maxBoost {
            var b = a
            b.volume = s.maxBoost
            apps[k] = b
            changed = true
        }
        if changed { store.saveApps(apps) }
        store.saveSettings(s)
        reconcileNow()
    }

    public func moveRow(_ key: String, before target: String) {
        let visible = snapshot().rows.map(\.key)
        var s = settings
        s.order = MixOrdering.move(s.order, visible: visible, key: key, before: target)
        update(settings: s)
    }

    public func nudgeRow(_ key: String, by delta: Int) {
        let visible = snapshot().rows.map(\.key)
        var s = settings
        s.order = MixOrdering.move(s.order, visible: visible, key: key, by: delta)
        update(settings: s)
    }

    public func key(forPID pid: Int32, bundleID: String?) -> String? {
        if let e = list.entries.first(where: { $0.pids.contains(pid) }) { return e.key }
        if let b = bundleID, list.entries.contains(where: { $0.key == b }) { return b }
        return nil
    }

    // MARK: reading

    public func levels() -> [String: MixLevels] {
        var out: [String: MixLevels] = [:]
        let bands = combinedDemand.bandKeys
        for key in live.keys { if let l = driver.levels(key: key, bands: bands.contains(key)) { out[key] = l } }
        return out
    }

    public func snapshot() -> MixSnapshot {
        var s = MixSnapshot()
        s.settings = settings
        s.rows = list.rows(settings: settings, apps: apps, now: clock())
        s.options = MixRouting.options(devices: devices, defaultUID: defaultUID)
        s.errors = errors
        s.processing = Set(live.filter { $0.value.desired.mode == .process }.keys)
        s.fallbackKeys = Set(apps.filter { MixRouting.isOffline(preferred: $0.value.outputUID, devices: devices) }.keys)
        s.defaultOutputName = currentDefaultInfo()?.name
        return s
    }
}
