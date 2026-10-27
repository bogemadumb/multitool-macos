import Foundation
import SwiftUI

@MainActor
public final class VpnTraffic: ObservableObject {
    public private(set) var downBps: Double = 0
    public private(set) var upBps: Double = 0
    public private(set) var downHistory: [Double] = []
    public private(set) var upHistory: [Double] = []
    public private(set) var sessionDown: Double = 0
    public private(set) var sessionUp: Double = 0
    private var shown: Set<String> = []

    public init() {}

    public var active: Bool { !shown.isEmpty }

    public func setVisible(_ key: String, _ on: Bool) {
        let was = active
        if on { shown.insert(key) } else { shown.remove(key) }
        if active && !was { objectWillChange.send() }
    }

    func push(up: Double, down: Double, limit: Int) {
        upBps = up
        downBps = down
        upHistory.append(up)
        downHistory.append(down)
        let extra = downHistory.count - limit
        if extra > 0 {
            downHistory.removeFirst(extra)
            upHistory.removeFirst(extra)
        }
        notify()
    }

    func reset() {
        upBps = 0
        downBps = 0
        notify()
    }

    func setSession(down: Double, up: Double) {
        sessionDown = down
        sessionUp = up
        notify()
    }

    private func notify() { if active { objectWillChange.send() } }
}

public enum VpnKeys {
    public static let intentOn = "vpn.intentOn"
    public static let killSwitch = "vpn.killSwitchEnabled"
    public static let notifications = "vpn.notifications"
    public static let watchdog = "vpn.watchdog"
    public static let showShield = "vpn.showShield"
}

@MainActor
public final class VpnController: ObservableObject {
    nonisolated static let historyLimit = 300

    @Published public private(set) var state: VpnState = .connecting
    @Published public private(set) var daemonRunning = false
    @Published public private(set) var apiOK = false
    @Published public private(set) var mode = "Rule"
    @Published public private(set) var delayMs: Int?
    @Published public private(set) var isExpensive = false
    @Published public private(set) var outageSince: Date?
    @Published public private(set) var connectedSince: Date?
    @Published public private(set) var singboxVersion: String?
    @Published public private(set) var apiError: String?
    @Published public private(set) var controlError: String?
    @Published public private(set) var busy = false
    @Published public var confirmingOff = false
    @Published public private(set) var now = Date()
    @Published public private(set) var intentOn = true
    @Published public private(set) var killSwitchEnabled = true
    @Published public private(set) var killSwitchActive = false
    @Published public private(set) var lastAction: String?
    @Published public private(set) var attemptsUsed = 0
    @Published public private(set) var notificationsEnabled = true
    @Published public private(set) var watchdogEnabled = true

    public let traffic = VpnTraffic()
    public let rules: VpnRulesModel
    public let history: VpnHistoryStore?
    public let insights: VpnInsightsModel
    public let server: VpnServerModel
    public let speed: VpnSpeedModel
    public let checks: VpnChecksModel
    public let route: VpnRouteModel
    public let clipboard: VpnSecretClipboard
    public private(set) lazy var conns: VpnConnectionsModel = {
        let m = VpnConnectionsModel(client: client, rules: rules)
        m.isActive = { [weak self] in self?.traffic.active ?? false }
        return m
    }()

    let client: ClashAPI
    private let daemon: VpnDaemonProbing
    private let control: VpnControlling
    private let defaults: KeyValueStoring
    private let notifier: (String, String, String) -> Void
    private let clock: () -> Date

    private var machine = VpnStateMachine()
    private var watchdog = VpnWatchdog()
    private var drops = VpnDropTracker()
    private var limiter = VpnRateLimiter(interval: 600)
    private var loaded = false
    private var intentKnown = false
    private var daemonStarted: Date?
    private var daemonDisabled = false
    private var tasks: [Task<Void, Never>] = []
    private var probeNudge = false
    private var netLabel = "none"
    private var netSeen = false
    private var ksUnavailable = false
    private var lastNetChange = Date.distantPast
    private var netWatch: VpnNetworkWatch?
    private var totalsBase: (down: Double, up: Double) = (0, 0)
    private var totalsAcc: (down: Double, up: Double) = (0, 0)
    private var ksBusy = false
    private var lastKSCheck = Date.distantPast
    private var lastKSWant: Bool?
    private var actionBusy = false
    private var dropEvent: Int64 = 0
    private var checksNudge = false
    private var checksWaitStart = Date()

    init(client: ClashAPI, daemon: VpnDaemonProbing, control: VpnControlling, files: VpnRuleFiles,
         defaults: KeyValueStoring = UserDefaults.standard,
         notifier: @escaping (String, String, String) -> Void,
         clock: @escaping () -> Date = { Date() },
         history: VpnHistoryStore? = nil,
         server: VpnServerModel? = nil,
         speed: VpnSpeedModel? = nil,
         checks: VpnChecksModel? = nil,
         route: VpnRouteModel? = nil,
         clipboard: VpnSecretClipboard? = nil) {
        self.client = client
        self.daemon = daemon
        self.control = control
        self.defaults = defaults
        self.notifier = notifier
        self.clock = clock
        self.rules = VpnRulesModel(files: files)
        self.checksWaitStart = clock()
        self.history = history
        self.insights = VpnInsightsModel(history: history, clock: clock)
        self.server = server ?? VpnServerModel()
        self.speed = speed ?? VpnSpeedModel(clock: clock)
        self.checks = checks ?? VpnChecksModel(clock: clock)
        self.route = route ?? VpnRouteModel(probe: SystemRouteProbe(client: client), clock: clock)
        self.clipboard = clipboard ?? VpnSecretClipboard()
        if let v = defaults.object(forKey: VpnKeys.killSwitch) as? Bool { killSwitchEnabled = v }
        if let v = defaults.object(forKey: VpnKeys.intentOn) as? Bool { intentOn = v; intentKnown = true }
        if let v = defaults.object(forKey: VpnKeys.notifications) as? Bool { notificationsEnabled = v }
        if let v = defaults.object(forKey: VpnKeys.watchdog) as? Bool { watchdogEnabled = v }
        self.checks.onLeak = { [weak self] detail in self?.recordLeak(detail) }
        self.speed.onResult = { [weak self] mbps, bytes, seconds in
            self?.history?.insertEvent(start: clock(), end: clock(), kind: "speed",
                                       detail: VpnSpeedMath.eventDetail(mbps: mbps, bytes: bytes, seconds: seconds))
        }
    }

    public convenience init() {
        let ctl = PrivilegedCtl()
        self.init(client: ClashClient(), daemon: LaunchctlDaemonProbe(), control: PrivilegedVpnControl(ctl: ctl),
                  files: VpnRuleFiles(writer: PrivilegedRuleWriter(ctl: ctl)),
                  notifier: { kind, title, body in
                      Notifier.shared.post(title: title, body: body, id: "vpn-\(kind)-\(Int(Date().timeIntervalSince1970))")
                  },
                  history: VpnHistoryStore.open())
    }

    // MARK: lifecycle

    public func start() {
        guard tasks.isEmpty else { return }
        let watch = VpnNetworkWatch { [weak self] expensive, label in
            Task { @MainActor [weak self] in self?.networkChanged(expensive: expensive, label: label) }
        }
        watch.start()
        netWatch = watch
        history?.closeStaleDrops(at: clock())
        checksWaitStart = clock()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checksTick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDaemon()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probe()
                var waited = 0.0
                let target = self.machine.wantsFastProbe ? 5.0 : 15.0
                while waited < target && !self.probeNudge && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
                self.probeNudge = false
            }
        })
        let client = self.client
        let handler: @Sendable (VpnTrafficEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        tasks.append(Task { await client.runTraffic(handler) })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.now = Date()
            }
        })
        Log.write("vpn controller start")
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        netWatch?.stop()
        netWatch = nil
        Log.write("vpn controller stop")
    }

    private func networkChanged(expensive: Bool, label: String) {
        guard isExpensive != expensive || netLabel != label else { return }
        if netSeen && netLabel != label { lastNetChange = clock() }
        netSeen = true
        isExpensive = expensive
        netLabel = label
        Log.write("vpn net=\(label) expensive=\(expensive ? 1 : 0)")
    }

    // MARK: polling

    func refreshDaemon() async {
        let r = await Task.detached { [daemon] in daemon.read() }.value
        let was = daemonRunning
        if daemonRunning != r.running { daemonRunning = r.running }
        daemonDisabled = r.disabled
        daemonStarted = r.started
        loaded = true
        if !r.running {
            if apiOK { apiOK = false }
            if delayMs != nil { delayMs = nil }
            if connectedSince != nil { connectedSince = nil }
            feed(api: false, delay: nil)
        } else if !was {
            probeNudge = true
        }
        observe()
    }

    func probe() async {
        guard loaded else { return }
        guard daemonRunning else { feed(api: false, delay: nil); return }
        var api = false
        do {
            let v = try await client.version()
            let c = try await client.configs()
            if singboxVersion != v { singboxVersion = v }
            if mode != c.mode { mode = c.mode }
            api = true
            if apiError != nil { apiError = nil }
        } catch {
            let msg: String?
            if !client.hasSecret { msg = "нет ключа в Keychain" }
            else if case ClashError.http(401) = error { msg = "ключ не подходит" }
            else { msg = nil }
            if apiError != msg { apiError = msg }
        }
        var d: Int?
        if api { d = try? await client.delay(timeoutMs: isExpensive ? 10_000 : 5_000) }
        feed(api: api, delay: d)
        observe()
    }

    private func feed(api: Bool, delay: Int?) {
        guard loaded else { return }
        let before = machine.state
        if apiOK != api { apiOK = api }
        machine.tick(daemonRunning: daemonRunning, apiOK: api, delayMs: delay, at: clock(), isExpensive: isExpensive)
        var newDelay = delayMs
        if !api { newDelay = nil }
        else if let d = delay { newDelay = d }
        else if machine.failStreak >= 2 { newDelay = nil }
        if newDelay != delayMs { delayMs = newDelay }
        let next = machine.state
        if next != state { state = next }
        if outageSince != machine.outageSince { outageSince = machine.outageSince }
        if daemonRunning && (next == .ok || next == .slow) && connectedSince == nil {
            connectedSince = daemonStarted ?? clock()
        }
        guard next != .off || before != .off else { return }
        if before != next {
            Log.write("vpn state \(before.rawValue)->\(next.rawValue) daemon=\(daemonRunning ? 1 : 0) api=\(api ? 1 : 0) delay=\(delay.map(String.init) ?? "fail") fails=\(machine.failStreak) net=\(netLabel)")
        }
    }

    private func handle(_ e: VpnTrafficEvent) {
        switch e {
        case .connected:
            totalsAcc = (0, 0)
            Task { [weak self] in
                guard let self else { return }
                if let t = try? await self.client.totals() {
                    self.totalsBase = t
                    self.syncTotals()
                }
            }
        case .sample(let up, let down):
            traffic.push(up: up, down: down, limit: Self.historyLimit)
            totalsAcc.down += down
            totalsAcc.up += up
            syncTotals()
        case .disconnected:
            traffic.reset()
            totalsBase = (0, 0)
            totalsAcc = (0, 0)
            syncTotals()
        }
    }

    private func syncTotals() {
        traffic.setSession(down: totalsBase.down + totalsAcc.down, up: totalsBase.up + totalsAcc.up)
    }

    // MARK: guardian (intent, watchdog, drops, kill switch)

    func setIntent(_ on: Bool) {
        guard intentOn != on || !intentKnown else { return }
        intentKnown = true
        intentOn = on
        defaults.set(on, forKey: VpnKeys.intentOn)
        Log.write("vpn intent=\(on ? "on" : "off")")
    }

    public func setKillSwitch(_ on: Bool) {
        guard killSwitchEnabled != on else { return }
        killSwitchEnabled = on
        defaults.set(on, forKey: VpnKeys.killSwitch)
        Log.write("vpn killswitch setting=\(on ? "on" : "off")")
        reconcileKillSwitch(force: true)
    }

    public func setNotifications(_ on: Bool) {
        notificationsEnabled = on
        defaults.set(on, forKey: VpnKeys.notifications)
    }

    public func setWatchdog(_ on: Bool) {
        watchdogEnabled = on
        defaults.set(on, forKey: VpnKeys.watchdog)
    }

    func observe() {
        if !intentKnown { setIntent(VpnIntentSync.initial(stored: nil, daemonRunning: daemonRunning)) }
        let synced = VpnIntentSync.next(current: intentOn, daemonRunning: daemonRunning, daemonDisabled: daemonDisabled, busy: busy)
        if synced != intentOn { setIntent(synced) }
        let at = clock()
        if !busy && !actionBusy && watchdogEnabled {
            let act = watchdog.evaluate(intentOn: intentOn, daemonRunning: daemonRunning, apiOK: apiOK, at: at)
            let used = watchdog.attemptsInWindow(at: at)
            if attemptsUsed != used { attemptsUsed = used }
            if act != .none { perform(act, downFor: watchdog.lastDownFor) }
        }
        updateDrops(at: at)
        reconcileKillSwitch(force: false)
    }

    private func perform(_ act: VpnWatchdogAction, downFor: TimeInterval) {
        let n = attemptsUsed
        switch act {
        case .restart, .start:
            let what = act == .restart ? "ядро не отвечало \(Int(downFor)) с, перезапуск" : "ядро не работало, запуск"
            let detail = "\(what) (попытка \(n) из \(VpnWatchdog.maxAttempts))"
            lastAction = detail
            history?.insertEvent(start: clock(), end: clock(), kind: "watchdog", detail: detail)
            Log.write("vpn watchdog \(act == .restart ? "restart" : "start") down_for=\(Int(downFor)) attempt=\(n)")
            notify("watchdog", "Сторож перезапустил VPN", detail)
            actionBusy = true
            let restart = act == .restart
            Task { [weak self] in
                guard let self else { return }
                let err = await Task.detached { [control] in restart ? control.restart() : control.turnOn() }.value
                if let err { self.controlError = err; Log.write("vpn watchdog action failed: \(err)") }
                self.actionBusy = false
                self.reconcileKillSwitch(force: true)
            }
        case .giveUp:
            let detail = "\(VpnWatchdog.maxAttempts) попытки за 10 минут не помогли, дальше только уведомление"
            lastAction = detail
            history?.insertEvent(start: clock(), end: clock(), kind: "watchdog", detail: detail)
            Log.write("vpn watchdog giveup")
            notify("giveup", "VPN не поднимается", "\(detail). Откройте Мультитул или выключите VPN вручную.")
        case .none: break
        }
    }

    private func updateDrops(at now: Date) {
        let coreGone = intentOn && !daemonRunning && !busy
        let isDrop = state == .down || coreGone
        let recovered = (daemonRunning && (state == .ok || state == .slow)) || !intentOn
        guard let change = drops.update(isDrop: isDrop, recovered: recovered,
                                        startHint: state == .down ? outageSince : nil, at: now) else { return }
        switch change {
        case .opened(let start):
            let r = VpnDropReason.classify(daemonRunning: daemonRunning, apiOK: apiOK,
                                           netChangedRecently: now.timeIntervalSince(lastNetChange) < 180)
            Log.write("vpn drop opened kind=\(r.kind)")
            dropEvent = history?.insertEvent(start: start, end: nil, kind: r.kind, detail: r.detail) ?? 0
            notify("down", "VPN: связь с туннелем потеряна", r.detail.prefix(1).uppercased() + r.detail.dropFirst())
        case .closed(let start, let end):
            let len = end.timeIntervalSince(start)
            Log.write("vpn drop closed seconds=\(Int(len))")
            if dropEvent != 0 { history?.closeEvent(id: dropEvent, end: end) }
            dropEvent = 0
            notify("restored", "VPN: связь восстановлена", "Обрыв длился \(VpnFormat.span(len))")
        }
    }

    public var dropOpen: Bool { drops.openSince != nil }

    func notify(_ kind: String, _ title: String, _ body: String) {
        guard notificationsEnabled else { return }
        guard limiter.allow(kind, at: clock()) else {
            Log.write("vpn notify rate-limited kind=\(kind)")
            return
        }
        notifier(kind, title, body)
    }

    func reconcileKillSwitch(force: Bool) {
        guard !ksBusy else { return }
        let want = killSwitchEnabled && intentOn
        if !force && lastKSWant == want && clock().timeIntervalSince(lastKSCheck) < 15 { return }
        lastKSCheck = clock()
        lastKSWant = want
        ksBusy = true
        Task { [weak self] in
            guard let control = self?.control else { return }
            let (cur, after) = await Task.detached { () -> (Bool?, Bool?) in
                let c = control.killSwitchStatus()
                guard let c, c != want else { return (c, c) }
                return (c, control.setKillSwitch(want) ? want : c)
            }.value
            guard let self else { return }
            self.ksBusy = false
            if let cur, cur != want { Log.write("vpn killswitch \(cur ? "on" : "off") -> \(after.map { $0 ? "on" : "off" } ?? "?")") }
            if cur == nil && !self.ksUnavailable { Log.write("vpn killswitch status unavailable") }
            self.ksUnavailable = cur == nil
            if self.killSwitchActive != (after ?? false) { self.killSwitchActive = after ?? false }
        }
    }

    // MARK: checks, speed, route

    func recordLeak(_ detail: String) {
        Log.write("vpn leak detected \(detail)")
        history?.insertEvent(start: clock(), end: clock(), kind: "leak", detail: detail)
        notify("leak", "VPN: обнаружена утечка", detail)
    }

    func checksTick() async {
        guard loaded else { return }
        if !daemonRunning { checks.skip("VPN выключен"); checksNudge = true; return }
        guard apiOK, state != .connecting, !checks.running else { return }
        let first = checks.lastRun == nil && clock().timeIntervalSince(checksWaitStart) > 12
        let due = checks.lastRun.map { clock().timeIntervalSince($0) >= 300 } ?? false
        if first || due || checksNudge {
            checksNudge = false
            await checks.run(mode: mode)
        }
    }

    public func runChecksNow() {
        guard daemonRunning, !checks.running else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.checks.run(mode: self.mode)
        }
    }

    public func runSpeedTest() {
        guard apiOK, !speed.isRunning else { return }
        speed.start()
    }

    public func measureRoute() {
        let up = daemonRunning && apiOK
        let mobile = isExpensive
        Task { [weak self] in await self?.route.measure(tunnelUp: up, mobile: mobile) }
    }

    // MARK: user actions

    public func toggle() {
        if busy { return }
        if daemonRunning { confirmingOff = true } else { runControl(on: true) }
    }

    public func confirmOff() {
        confirmingOff = false
        setIntent(false)
        runControl(on: false)
    }

    public func cancelOff() { confirmingOff = false }

    public func setMode(_ m: VpnMode) {
        guard apiOK, mode != m.rawValue else { return }
        let old = mode
        mode = m.rawValue
        Task { [weak self] in
            guard let self else { return }
            do { try await self.client.setMode(m.rawValue) } catch { self.mode = old }
        }
    }

    private func runControl(on: Bool) {
        busy = true
        controlError = nil
        if on { state = .connecting; setIntent(true) }
        Task { [weak self] in
            guard let self else { return }
            let err = await Task.detached { [control] in on ? control.turnOn() : control.turnOff() }.value
            if let err {
                self.controlError = err
                Log.write("vpn control \(on ? "on" : "off") failed: \(err)")
                if on { self.setIntent(false) }
            }
            await self.refreshDaemon()
            self.busy = false
            self.reconcileKillSwitch(force: true)
        }
    }

    // MARK: derived text

    public var currentMode: VpnMode { VpnMode(rawValue: mode) ?? .rule }
    public var modeName: String { VpnMode.name(of: mode) }
    public var directHint: Bool { mode == "Direct" }
    public var isRunning: Bool { daemonRunning }

    public var stateDetail: String? {
        switch state {
        case .slow: return delayMs.map { "медленно: пинг \($0) мс" } ?? "медленно"
        case .degraded: return "связь неустойчива"
        case .down:
            let since = outageSince ?? now
            return "нет связи с сервером \(VpnFormat.duration(now.timeIntervalSince(since)))"
        default: return nil
        }
    }

    public var subtitle: String {
        var s: String
        switch state {
        case .ok:
            if let c = connectedSince { s = "подключено \(VpnFormat.duration(now.timeIntervalSince(c))) · \(modeName)" } else { s = modeName }
        case .slow, .degraded, .down: s = stateDetail ?? ""
        case .off: return "туннель остановлен"
        case .connecting: s = apiError ?? "запускаю туннель"
        }
        if isExpensive { s += " · мобильная сеть" }
        return s
    }
}
