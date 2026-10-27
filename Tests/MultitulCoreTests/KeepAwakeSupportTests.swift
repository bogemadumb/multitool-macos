import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func kaTmpDir() -> String {
    let d = "/private/tmp/claude-501/multitul-ka-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private final class KAFakeHost: KeepAwakeHost {
    var calls: [String] = []
    var lidError: String?
    var lidOffError: String?
    var sleepDisabled: Bool? = false
    var markers: KeepAwakeMarkers?
    var flagAtLidOn: Bool?
    var notices: [KeepAwakeNotice] = []

    func holdAssertion(displayToo: Bool) -> Bool { calls.append("hold:\(displayToo)"); return true }
    func releaseAssertion() { calls.append("release") }
    func setClosedLid(_ on: Bool) -> String? {
        calls.append("lid:\(on)")
        if on { flagAtLidOn = markers?.lidFlag }
        return on ? lidError : lidOffError
    }
    func dimBuiltin(_ on: Bool) { calls.append("dim:\(on)") }
    func jiggle() { calls.append("jiggle") }
    func notify(_ notice: KeepAwakeNotice) { notices.append(notice) }
    func isSleepDisabled() -> Bool? { sleepDisabled }
}

private func rig(_ settings: KeepAwakeSettings = KeepAwakeSettings()) -> (KeepAwakeRunner, KAFakeHost, KeepAwakeMarkers) {
    let m = KeepAwakeMarkers(dir: kaTmpDir())
    let h = KAFakeHost()
    h.markers = m
    return (KeepAwakeRunner(engine: KeepAwakeEngine(settings: settings), host: h, markers: m), h, m)
}

private func at(_ s: TimeInterval = 0) -> KeepAwakeInputs { KeepAwakeInputs(now: t0.addingTimeInterval(s)) }

@Suite struct KeepAwakeFormatTests {
    @Test func remainingFormats() {
        #expect(KeepAwakeFormat.remaining(0) == "00:00")
        #expect(KeepAwakeFormat.remaining(59.2) == "01:00")
        #expect(KeepAwakeFormat.remaining(754) == "12:34")
        #expect(KeepAwakeFormat.remaining(3723) == "1:02:03")
        #expect(KeepAwakeFormat.remaining(-5) == "00:00")
    }

    @Test func durationLabels() {
        #expect(KeepAwakeFormat.duration(minutes: 0) == "бессрочно")
        #expect(KeepAwakeFormat.duration(minutes: 15) == "15 мин")
        #expect(KeepAwakeFormat.duration(minutes: 120) == "2 ч")
        #expect(KeepAwakeFormat.duration(minutes: 90) == "1 ч 30 мин")
    }

    @Test func menuTitleOnlyForTimedSessions() {
        let timed = KeepAwakeSession.minutes(10, from: t0)
        #expect(KeepAwakeFormat.menuTitle(session: timed, now: t0.addingTimeInterval(60), showRemaining: true) == " 09:00")
        #expect(KeepAwakeFormat.menuTitle(session: timed, now: t0, showRemaining: false) == "")
        #expect(KeepAwakeFormat.menuTitle(session: .minutes(0, from: t0), now: t0, showRemaining: true) == "")
        #expect(KeepAwakeFormat.menuTitle(session: nil, now: t0, showRemaining: true) == "")
    }

    @Test func untilTimeRollsToTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = cal.dateComponents([.hour, .minute], from: now)
        let later = KeepAwakeUntil.next(hour: (c.hour! + 1) % 24, minute: c.minute!, after: now, calendar: cal)!
        #expect(later.timeIntervalSince(now) == 3600 || later.timeIntervalSince(now) == 3600 - 24 * 3600 + 24 * 3600)
        let same = KeepAwakeUntil.next(hour: c.hour!, minute: c.minute!, after: now, calendar: cal)!
        #expect(same.timeIntervalSince(now) > 0)
        #expect(KeepAwakeUntil.next(hour: 24, minute: 0, after: now, calendar: cal) == nil)
        #expect(KeepAwakeUntil.next(hour: 3, minute: 60, after: now, calendar: cal) == nil)
    }
}

@Suite struct KeepAwakeRecoveryTests {
    @Test func pmsetParsing() {
        #expect(KeepAwakeParsers.sleepDisabled(pmsetG: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n") == true)
        #expect(KeepAwakeParsers.sleepDisabled(pmsetG: " SleepDisabled\t\t0\n") == false)
        #expect(KeepAwakeParsers.sleepDisabled(pmsetG: " sleep 1\n displaysleep 10\n") == nil)
        #expect(KeepAwakeParsers.sleepDisabled(pmsetG: "") == nil)
    }

    @Test func planMatrix() {
        #expect(KeepAwakeRecovery.plan(flag: true, sleepDisabled: true) == .restoreAndClear)
        #expect(KeepAwakeRecovery.plan(flag: true, sleepDisabled: nil) == .restoreAndClear)
        #expect(KeepAwakeRecovery.plan(flag: true, sleepDisabled: false) == .clearFlagOnly)
        #expect(KeepAwakeRecovery.plan(flag: false, sleepDisabled: true) == .foreignSleepDisabled)
        #expect(KeepAwakeRecovery.plan(flag: false, sleepDisabled: false) == .nothing)
        #expect(KeepAwakeRecovery.plan(flag: false, sleepDisabled: nil) == .nothing)
    }

    @Test func recoverRestoresAfterCrash() {
        let (r, h, m) = rig()
        m.setLidFlag(true)
        h.sleepDisabled = true
        #expect(r.recoverOnStart() == .restoreAndClear)
        #expect(h.calls == ["lid:false"])
        #expect(!m.lidFlag)
    }

    @Test func recoverKeepsFlagWhenRestoreFails() {
        let (r, h, m) = rig()
        m.setLidFlag(true)
        h.sleepDisabled = true
        h.lidOffError = "sudo"
        _ = r.recoverOnStart()
        #expect(m.lidFlag)
        #expect(h.notices == [.lidRestoreFailed("sudo")])
    }

    @Test func recoverLeavesForeignSleepDisabledAlone() {
        let (r, h, m) = rig()
        h.sleepDisabled = true
        #expect(r.recoverOnStart() == .foreignSleepDisabled)
        #expect(h.calls.isEmpty)
        #expect(!m.lidFlag)
    }

    @Test func staleFlagWithSleepAlreadyEnabledJustClears() {
        let (r, h, m) = rig()
        m.setLidFlag(true)
        h.sleepDisabled = false
        _ = r.recoverOnStart()
        #expect(h.calls.isEmpty)
        #expect(!m.lidFlag)
    }
}

@Suite struct KeepAwakeRunnerTests {
    @Test func flagIsWrittenBeforeDisableSleepIsSwitchedOn() {
        let (r, h, m) = rig()
        r.start(.minutes(0, from: t0, closedLid: true), inputs: at())
        #expect(h.calls == ["hold:true", "lid:true"])
        #expect(h.flagAtLidOn == true)
        #expect(m.lidFlag)
    }

    @Test func stopRemovesFlagAfterRestore() {
        let (r, h, m) = rig()
        r.start(.minutes(0, from: t0, closedLid: true), inputs: at())
        r.stop(inputs: at(5))
        #expect(h.calls.suffix(2) == ["lid:false", "release"])
        #expect(!m.lidFlag)
    }

    @Test func failedLidOnClearsFlagAndFallsBack() {
        let (r, h, m) = rig()
        h.lidError = "password"
        r.start(.minutes(0, from: t0, closedLid: true), inputs: at())
        #expect(!m.lidFlag)
        #expect(r.engine.isActive)
        #expect(!r.engine.lidHeld)
        #expect(h.notices == [.lidUnavailable("password")])
    }

    @Test func failedLidOffKeepsFlagAndRetriesOnTick() {
        let (r, h, m) = rig()
        r.start(.minutes(0, from: t0, closedLid: true), inputs: at())
        h.lidOffError = "timeout"
        r.stop(inputs: at(1))
        #expect(m.lidFlag)
        #expect(h.notices == [.lidRestoreFailed("timeout")])
        h.lidOffError = nil
        h.calls = []
        r.tick(at(2))
        #expect(m.lidFlag && h.calls.isEmpty)
        r.tick(at(40))
        #expect(h.calls == ["lid:false"])
        #expect(!m.lidFlag)
    }

    @Test func shutdownRestoresEverythingAndRetriesOnce() {
        let (r, h, m) = rig()
        r.start(.minutes(0, from: t0, closedLid: true), inputs: at())
        r.tick(KeepAwakeInputs(now: t0.addingTimeInterval(1), lidClosed: true))
        r.shutdown(inputs: at(2))
        #expect(h.calls.suffix(3) == ["dim:false", "lid:false", "release"])
        #expect(!m.lidFlag)
    }

    @Test func notificationsAndJiggleReachHost() {
        var s = KeepAwakeSettings()
        s.jiggleEnabled = true
        s.jiggleMinutes = 1
        let (r, h, _) = rig(s)
        r.start(.minutes(1, from: t0), inputs: at())
        r.tick(at(60))
        #expect(h.calls.contains("jiggle") == false)
        #expect(h.notices == [.ended(.timerExpired)])
    }

    @Test func jiggleCallsHostWhileActive() {
        var s = KeepAwakeSettings()
        s.jiggleEnabled = true
        s.jiggleMinutes = 1
        let (r, h, _) = rig(s)
        r.start(.minutes(0, from: t0), inputs: at())
        r.tick(at(60))
        #expect(h.calls.contains("jiggle"))
    }
}

@Suite struct KeepAwakeStorageTests {
    @Test func markersDimRoundtrip() {
        let m = KeepAwakeMarkers(dir: kaTmpDir())
        #expect(m.dim == nil)
        m.dim = .init(displayID: 1, brightness: 0.62)
        #expect(m.dim == .init(displayID: 1, brightness: 0.62))
        m.dim = nil
        #expect(m.dim == nil)
    }

    @Test func storeRoundtripAndDefaultsAreNotPersisted() {
        let suite = "multitul-ka-\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let store = KeepAwakeStore(defaults: d)
        #expect(store.load() == KeepAwakeSettings())
        var s = KeepAwakeSettings()
        s.autoStart = true
        s.batteryLimitPercent = 35
        s.autoApps = true
        s.autoAppBundleIDs = ["com.a", "com.b"]
        s.match = .all
        s.iconKind = .moon
        s.iconTint = .pink
        store.save(s)
        #expect(store.load() == s)
        store.save(KeepAwakeSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("keepAwake.") }.isEmpty)
    }

    @Test func hostSendsDisableSleepThroughSudoNOnly() {
        let r = FakeRunner()
        let ctl = PrivilegedCtl(runner: r, stagingDir: kaTmpDir(), binaryExists: { _ in true })
        let host = KeepAwakeSystemHost(ctl: ctl, markers: KeepAwakeMarkers(dir: kaTmpDir())) { _ in }
        #expect(host.setClosedLid(true) == nil)
        #expect(host.setClosedLid(false) == nil)
        #expect(r.calls.map { $0.1 } == [["-n", "/usr/local/libexec/multitul-ctl", "power", "disablesleep", "on"],
                                         ["-n", "/usr/local/libexec/multitul-ctl", "power", "disablesleep", "off"]])
    }

    @Test func hostReportsMissingHelperAndSudoRule() {
        let none = PrivilegedCtl(runner: FakeRunner(), stagingDir: kaTmpDir(), binaryExists: { _ in false })
        let h1 = KeepAwakeSystemHost(ctl: none, markers: KeepAwakeMarkers(dir: kaTmpDir())) { _ in }
        #expect(h1.setClosedLid(true)?.contains("не установлен") == true)
        let r = FakeRunner()
        r.result = ProcessOutput(status: 1, stderr: "sudo: a password is required")
        let h2 = KeepAwakeSystemHost(ctl: PrivilegedCtl(runner: r, stagingDir: kaTmpDir(), binaryExists: { _ in true }), markers: KeepAwakeMarkers(dir: kaTmpDir())) { _ in }
        #expect(h2.setClosedLid(true)?.contains("sudoers") == true)
    }
}
