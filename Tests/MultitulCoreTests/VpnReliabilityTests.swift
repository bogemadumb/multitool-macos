import Testing
import Foundation
@testable import MultitulCore

private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

@Suite struct VpnReliabilityTests {
    @Test func r00WatchdogHealthyDoesNothing() {
    var w = VpnWatchdog()
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: true, at: at(0)) == .none, "watchdog: healthy does nothing")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(1)) == .none, "watchdog: api down just started waits")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(59)) == .none, "watchdog: api down 58 s waits")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(61)) == .restart, "watchdog: api down 60 s restarts")
    check(w.attemptsInWindow(at: at(61)) == 1, "watchdog: attempt counted")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(70)) == .none, "watchdog: after restart waits again")
    }

    @Test func r01WatchdogApiRecoveryResetsThe60SClock() {
    var w = VpnWatchdog()
    _ = w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(0))
    _ = w.evaluate(intentOn: true, daemonRunning: true, apiOK: true, at: at(30))
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(61)) == .none, "watchdog: api recovery resets the 60 s clock")
    }

    @Test func r02WatchdogCoreNotRunningGraceFirst() {
    var w = VpnWatchdog()
    check(w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(0)) == .none, "watchdog: core not running, grace first")
    check(w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(11)) == .start, "watchdog: core not running with intent on starts")
    }

    @Test func r03WatchdogIntentOffNeverActsCoreStopped() {
    var w = VpnWatchdog()
    check(w.evaluate(intentOn: false, daemonRunning: false, apiOK: false, at: at(0)) == .none
          && w.evaluate(intentOn: false, daemonRunning: false, apiOK: false, at: at(500)) == .none, "watchdog: intent off never acts (core stopped)")
    check(w.evaluate(intentOn: false, daemonRunning: true, apiOK: false, at: at(1000)) == .none
          && w.evaluate(intentOn: false, daemonRunning: true, apiOK: false, at: at(2000)) == .none, "watchdog: intent off never acts (api down)")
    }

    @Test func r04WatchdogAtMost3RestartsIn10Minutes() {
    var w = VpnWatchdog()
    var acts: [VpnWatchdogAction] = []
    for i in 0..<14 {
        acts.append(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(Double(i) * 40)))
    }
    check(acts.filter { $0 == .restart }.count == 3, "watchdog: at most 3 restarts in 10 minutes")
    check(acts.filter { $0 == .giveUp }.count == 1, "watchdog: gives up exactly once, then only notifies")
    let later = w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(14 * 40 + 700))
    check(later == .none || later == .restart, "watchdog: window expires")
    check(w.attemptsInWindow(at: at(14 * 40 + 700)) <= 1, "watchdog: old attempts leave the window")
    }

    @Test func r05WatchdogFailedStartsAreSpacedBy30S() {
    var w = VpnWatchdog()
    var spaced = 0
    for i in 0..<20 where w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(Double(i) * 3)) == .start { spaced += 1 }
    check(spaced <= 2, "watchdog: failed starts are spaced by 30 s")
    }

    @Test func r06IntentDefaultOnWhenCoreRunsAtFirstLaunch() {
    check(VpnIntentSync.initial(stored: nil, daemonRunning: true), "intent: default on when core runs at first launch")
    check(!VpnIntentSync.initial(stored: nil, daemonRunning: false), "intent: default off when core is stopped at first launch")
    check(!VpnIntentSync.initial(stored: false, daemonRunning: true), "intent: stored value wins")
    check(VpnIntentSync.next(current: false, daemonRunning: true, daemonDisabled: false, busy: false), "intent: external vpn on turns intent on")
    check(!VpnIntentSync.next(current: false, daemonRunning: true, daemonDisabled: false, busy: true), "intent: busy keeps value")
    check(!VpnIntentSync.next(current: true, daemonRunning: false, daemonDisabled: true, busy: false), "intent: disabled daemon means deliberate off")
    check(VpnIntentSync.next(current: true, daemonRunning: false, daemonDisabled: false, busy: false), "intent: crashed core keeps intent on")
    check(VpnIntentSync.isDisabled("disabled services = {\n\t\"dev.multitool.singbox\" => disabled\n\t\"x\" => enabled\n}"), "print-disabled: disabled parsed")
    check(!VpnIntentSync.isDisabled("\t\"dev.multitool.singbox\" => enabled\n"), "print-disabled: enabled parsed")
    check(!VpnIntentSync.isDisabled("\t\"other\" => disabled\n"), "print-disabled: other label ignored")
    }

    @Test func r07RateLimitFirstAllowed() {
    var rl = VpnRateLimiter()
    check(rl.allow("down", at: at(0)), "rate limit: first allowed")
    check(!rl.allow("down", at: at(599)), "rate limit: same kind within 10 min blocked")
    check(rl.allow("leak", at: at(10)), "rate limit: other kind independent")
    check(rl.allow("down", at: at(601)), "rate limit: allowed after 10 min")
    }

    @Test func r08DropsNothingWhenHealthy() {
    var dt = VpnDropTracker()
    check(dt.update(isDrop: false, recovered: true, startHint: nil, at: at(0)) == nil, "drops: nothing when healthy")
    check(dt.update(isDrop: true, recovered: false, startHint: at(-30), at: at(0)) == .opened(start: at(-30)), "drops: opens with start hint")
    check(dt.update(isDrop: true, recovered: false, startHint: at(-30), at: at(5)) == nil, "drops: no double open")
    check(dt.update(isDrop: false, recovered: false, startHint: nil, at: at(10)) == nil, "drops: stays open until recovered")
    check(dt.update(isDrop: false, recovered: true, startHint: nil, at: at(90)) == .closed(start: at(-30), end: at(90)), "drops: closes with duration")
    check(VpnDropReason.classify(daemonRunning: false, apiOK: false, netChangedRecently: true).kind == "core", "drop reason: core stopped")
    check(VpnDropReason.classify(daemonRunning: true, apiOK: false, netChangedRecently: false).kind == "core", "drop reason: api silent")
    check(VpnDropReason.classify(daemonRunning: true, apiOK: true, netChangedRecently: true).kind == "net", "drop reason: network change")
    check(VpnDropReason.classify(daemonRunning: true, apiOK: true, netChangedRecently: false).kind == "server", "drop reason: server")
    }

}
