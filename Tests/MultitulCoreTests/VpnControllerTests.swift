import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FakeClash: ClashAPI, @unchecked Sendable {
    private let lock = NSLock()
    var apiUp = true
    var mode = "Rule"
    var delay: Int? = 50
    var secret = true
    var failSetMode = false
    private var _modeSets: [String] = []
    private var _closed: [String] = []
    var conns: [ClashConn] = []
    var modeSets: [String] { lock.lock(); defer { lock.unlock() }; return _modeSets }
    var closed: [String] { lock.lock(); defer { lock.unlock() }; return _closed }

    var hasSecret: Bool { secret }
    func version() async throws -> String { if apiUp { return "sing-box 1.14.0" }; throw ClashError.http(500) }
    func configs() async throws -> (mode: String, modes: [String]) { (mode, ["Rule", "Global", "Direct"]) }
    func delay(timeoutMs: Int) async throws -> Int { if let d = delay { return d }; throw ClashError.http(504) }
    func setMode(_ m: String) async throws { record(set: m); if failSetMode { throw ClashError.http(500) } }
    func closeConnection(_ id: String) async throws { record(close: id) }
    func connections() async throws -> [ClashConn] { if apiUp { return conns }; throw ClashError.http(500) }
    func totals() async throws -> (down: Double, up: Double) { (0, 0) }
    func runTraffic(_ handler: @escaping @Sendable (VpnTrafficEvent) -> Void) async {}
    private func record(set m: String) { lock.lock(); _modeSets.append(m); lock.unlock() }
    private func record(close id: String) { lock.lock(); _closed.append(id); lock.unlock() }
}

final class FakeDaemon: VpnDaemonProbing, @unchecked Sendable {
    var status = VpnDaemonStatus(running: true, started: nil, disabled: false)
    func read() -> VpnDaemonStatus { status }
}

final class FakeControl: VpnControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var ksState: Bool? = false
    var failOn: String?
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func log(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
    func turnOn() -> String? { log("on"); return failOn }
    func turnOff() -> String? { log("off"); return nil }
    func restart() -> String? { log("restart"); return nil }
    func killSwitchStatus() -> Bool? { ksState }
    func setKillSwitch(_ on: Bool) -> Bool { log("ks:\(on ? "on" : "off")"); ksState = on; return true }
}

final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _kinds: [String] = []
    var kinds: [String] { lock.lock(); defer { lock.unlock() }; return _kinds }
    func add(_ k: String) { lock.lock(); _kinds.append(k); lock.unlock() }
}

@MainActor
private struct Rig {
    let clash = FakeClash()
    let daemon = FakeDaemon()
    let control = FakeControl()
    let notices = NoticeBox()
    let clock = ClockBox()
    let defaults = InMemoryKeyValueStore()
    let dir = NSTemporaryDirectory() + "vpnctl-\(UUID().uuidString)"
    let controller: VpnController

    init(prepare: (InMemoryKeyValueStore) -> Void = { _ in }) {
        prepare(defaults)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = VpnRuleFiles(dir: dir, writer: LocalRuleWriter(dir: dir))
        let n = notices, c = clock
        controller = VpnController(client: clash, daemon: daemon, control: control, files: files, defaults: defaults,
                                   notifier: { kind, _, _ in n.add(kind) }, clock: { c.t })
    }

    func settle() async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }
}

@MainActor
@Suite struct VpnControllerTests {
    @Test func healthyPollReachesOkAndReadsMode() async {
        let r = Rig()
        r.clash.mode = "Global"
        await r.controller.refreshDaemon()
        await r.controller.probe()
        #expect(r.controller.state == .ok && r.controller.apiOK && r.controller.daemonRunning)
        #expect(r.controller.delayMs == 50 && r.controller.mode == "Global" && r.controller.currentMode == .global)
        #expect(r.controller.singboxVersion == "sing-box 1.14.0" && r.controller.connectedSince != nil)
        #expect(r.controller.state.tone == .green)
    }

    @Test func stoppedCoreIsGrey() async {
        let r = Rig()
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: true)
        await r.controller.refreshDaemon()
        #expect(r.controller.state == .off && r.controller.state.tone == .grey)
        #expect(!r.controller.intentOn)
        #expect(r.defaults.object(forKey: VpnKeys.intentOn) as? Bool == false)
    }

    @Test func intentComesFromDaemonThenFromStorage() async {
        let r1 = Rig()
        await r1.controller.refreshDaemon()
        #expect(r1.controller.intentOn)
        let r2 = Rig { $0.set(false, forKey: VpnKeys.intentOn) }
        r2.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: false)
        await r2.controller.refreshDaemon()
        #expect(!r2.controller.intentOn)
    }

    @Test func slowAndDownTones() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        r.clash.delay = 900
        for _ in 0..<3 { r.clock.advance(15); await r.controller.probe() }
        #expect(r.controller.state == .slow && r.controller.state.tone == .yellow)
        r.clash.apiUp = false
        r.clock.advance(15); await r.controller.probe()
        r.clock.advance(61); await r.controller.probe()
        #expect(r.controller.state == .down && r.controller.state.tone == .red)
    }

    @Test func watchdogRestartsAfterSixtySecondsOfSilentApi() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        r.clash.apiUp = false
        r.clock.advance(30); await r.controller.probe()
        await r.settle()
        #expect(r.control.calls.filter { $0 == "restart" }.isEmpty)
        r.clock.advance(35); await r.controller.probe()
        await r.settle()
        #expect(r.control.calls.filter { $0 == "restart" }.count == 1)
        #expect(r.controller.attemptsUsed == 1)
        #expect(r.notices.kinds.contains("watchdog"))
        #expect(r.controller.lastAction?.contains("попытка 1 из 3") == true)
    }

    @Test func watchdogStartsStoppedCoreWhileIntentIsOn() async {
        let r = Rig { $0.set(true, forKey: VpnKeys.intentOn) }
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: false)
        await r.controller.refreshDaemon()
        r.clock.advance(11)
        await r.controller.refreshDaemon()
        await r.settle()
        #expect(r.control.calls.contains("on"))
    }

    @Test func watchdogGivesUpAfterThreeAttemptsAndOnlyNotifies() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        r.clash.apiUp = false
        r.clock.advance(1); await r.controller.probe()
        for _ in 0..<9 {
            r.clock.advance(61)
            await r.controller.probe()
            await r.settle()
        }
        #expect(r.control.calls.filter { $0 == "restart" }.count == 3)
        #expect(r.notices.kinds.filter { $0 == "giveup" }.count == 1)
        #expect(r.controller.lastAction?.contains("дальше только уведомление") == true)
    }

    @Test func watchdogSwitchOffMeansNoRestart() async {
        let r = Rig { $0.set(false, forKey: VpnKeys.watchdog) }
        await r.controller.refreshDaemon()
        r.clash.apiUp = false
        r.clock.advance(1); await r.controller.probe()
        r.clock.advance(120); await r.controller.probe()
        await r.settle()
        #expect(r.control.calls.filter { $0 == "restart" || $0 == "on" }.isEmpty)
    }

    @Test func notificationsHaveTenMinuteCooldownPerKind() {
        let r = Rig()
        r.controller.notify("down", "t", "b")
        r.clock.advance(599); r.controller.notify("down", "t", "b")
        r.controller.notify("restored", "t", "b")
        #expect(r.notices.kinds == ["down", "restored"])
        r.clock.advance(2); r.controller.notify("down", "t", "b")
        #expect(r.notices.kinds == ["down", "restored", "down"])
    }

    @Test func notificationsCanBeSwitchedOff() {
        let r = Rig { $0.set(false, forKey: VpnKeys.notifications) }
        r.controller.notify("down", "t", "b")
        #expect(r.notices.kinds.isEmpty)
        r.controller.setNotifications(true)
        r.controller.notify("down", "t", "b")
        #expect(r.notices.kinds == ["down"])
    }

    @Test func dropNotifiesOnceThenRestored() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        await r.controller.probe()
        r.clash.apiUp = false
        r.clock.advance(15); await r.controller.probe()
        r.clock.advance(61); await r.controller.probe()
        await r.settle()
        #expect(r.controller.dropOpen && r.notices.kinds.filter { $0 == "down" }.count == 1)
        r.clash.apiUp = true
        r.clock.advance(15); await r.controller.probe()
        r.clock.advance(15); await r.controller.probe()
        #expect(!r.controller.dropOpen && r.notices.kinds.contains("restored"))
    }

    @Test func togglingARunningCoreAsksForConfirmationFirst() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        r.controller.toggle()
        await r.settle()
        #expect(r.controller.confirmingOff && r.control.calls.filter { $0 == "off" }.isEmpty)
        r.controller.cancelOff()
        #expect(!r.controller.confirmingOff)
        r.controller.toggle()
        r.controller.confirmOff()
        await r.settle()
        #expect(r.control.calls.filter { $0 == "off" }.count == 1)
        #expect(r.defaults.object(forKey: VpnKeys.intentOn) as? Bool == false)
    }

    @Test func togglingAStoppedCoreTurnsItOn() async {
        let r = Rig()
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: true)
        await r.controller.refreshDaemon()
        r.controller.toggle()
        await r.settle()
        #expect(r.control.calls.contains("on") && !r.controller.confirmingOff)
        #expect(r.defaults.object(forKey: VpnKeys.intentOn) as? Bool == true)
    }

    @Test func failedTurnOnShowsErrorAndDropsIntent() async {
        let r = Rig()
        r.control.failOn = "sudo просит пароль"
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: true)
        await r.controller.refreshDaemon()
        r.controller.toggle()
        await r.settle()
        #expect(r.controller.controlError == "sudo просит пароль")
        #expect(!r.controller.intentOn && !r.controller.busy)
    }

    @Test func modeSwitchSendsPatchAndRollsBackOnError() async {
        let r = Rig()
        await r.controller.refreshDaemon()
        await r.controller.probe()
        r.controller.setMode(.direct)
        await r.settle()
        #expect(r.clash.modeSets == ["Direct"] && r.controller.mode == "Direct" && r.controller.directHint)
        r.clash.failSetMode = true
        r.controller.setMode(.global)
        await r.settle()
        #expect(r.controller.mode == "Direct")
    }

    @Test func modeSwitchIgnoredWhileApiIsDown() async {
        let r = Rig()
        r.clash.apiUp = false
        await r.controller.refreshDaemon()
        await r.controller.probe()
        r.controller.setMode(.global)
        await r.settle()
        #expect(r.clash.modeSets.isEmpty)
    }

    @Test func killSwitchFollowsSettingAndIntent() async {
        let r = Rig()
        r.control.ksState = false
        await r.controller.refreshDaemon()
        await r.settle()
        #expect(r.control.calls.contains("ks:on") && r.controller.killSwitchActive)
        r.controller.setKillSwitch(false)
        await r.settle()
        #expect(r.control.calls.last == "ks:off" && !r.controller.killSwitchActive)
        #expect(r.defaults.object(forKey: VpnKeys.killSwitch) as? Bool == false)
    }

    @Test func killSwitchNotTouchedWhenAlreadyInDesiredState() async {
        let r = Rig()
        r.control.ksState = true
        await r.controller.refreshDaemon()
        await r.settle()
        #expect(r.control.calls.filter { $0.hasPrefix("ks:") }.isEmpty && r.controller.killSwitchActive)
    }

    @Test func subtitleDescribesStates() async {
        let r = Rig()
        #expect(r.controller.subtitle == "запускаю туннель")
        await r.controller.refreshDaemon()
        await r.controller.probe()
        #expect(r.controller.subtitle.contains("умный режим"))
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: true)
        await r.controller.refreshDaemon()
        #expect(r.controller.subtitle == "туннель остановлен")
    }

    @Test func missingKeychainSecretIsExplained() async {
        let r = Rig()
        r.clash.apiUp = false
        r.clash.secret = false
        await r.controller.refreshDaemon()
        await r.controller.probe()
        #expect(r.controller.apiError == "нет ключа в Keychain")
    }
}
