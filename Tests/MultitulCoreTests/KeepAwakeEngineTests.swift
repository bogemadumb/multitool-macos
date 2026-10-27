import Testing
import Foundation
@testable import MultitulCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func inputs(_ offset: TimeInterval = 0, percent: Int? = nil, ac: Bool = true, apps: Set<String> = [], displays: Int = 0, lid: Bool = false) -> KeepAwakeInputs {
    var b: BatteryReading?
    if let percent {
        var r = BatteryReading()
        r.hasBattery = true
        r.percent = percent
        r.onAC = ac
        b = r
    }
    return KeepAwakeInputs(now: t0.addingTimeInterval(offset), battery: b, runningApps: apps, externalDisplays: displays, lidClosed: lid)
}

@Suite struct KeepAwakeEngineTests {
    @Test func indefiniteHoldsDisplayAndSystem() {
        var e = KeepAwakeEngine()
        let a = e.start(.minutes(0, from: t0), inputs: inputs())
        #expect(a == [.holdAssertion(displayToo: true)])
        #expect(e.isActive)
        #expect(e.session?.end == .never)
    }

    @Test func allowDisplaySleepHoldsOnlySystem() {
        var s = KeepAwakeSettings()
        s.allowDisplaySleep = true
        var e = KeepAwakeEngine(settings: s)
        #expect(e.start(.minutes(30, from: t0), inputs: inputs()) == [.holdAssertion(displayToo: false)])
    }

    @Test func togglingDisplayOptionReholdsAssertion() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0), inputs: inputs())
        var s = e.settings
        s.allowDisplaySleep = true
        #expect(e.apply(settings: s, inputs: inputs()) == [.holdAssertion(displayToo: false)])
        #expect(e.apply(settings: s, inputs: inputs()).isEmpty)
    }

    @Test func timerExpiresAndNotifies() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(10, from: t0), inputs: inputs())
        #expect(e.tick(inputs(599)).isEmpty)
        let a = e.tick(inputs(600))
        #expect(a == [.notify(.ended(.timerExpired)), .releaseAssertion])
        #expect(!e.isActive)
    }

    @Test func silentEndWhenNotificationsOff() {
        var s = KeepAwakeSettings()
        s.notifyOnEnd = false
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(1, from: t0), inputs: inputs())
        #expect(e.tick(inputs(61)) == [.releaseAssertion])
    }

    @Test func untilAppQuitsEndsWhenAppGone() {
        var e = KeepAwakeEngine()
        _ = e.start(KeepAwakeSession(start: t0, end: .appQuits(bundleID: "com.x.app")), inputs: inputs())
        #expect(e.tick(inputs(5, apps: ["com.x.app"])).isEmpty)
        #expect(e.tick(inputs(10, apps: [])) == [.notify(.ended(.appQuit)), .releaseAssertion])
    }

    @Test func manualStopReleasesWithoutNotice() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0), inputs: inputs())
        #expect(e.stop(inputs: inputs(3)) == [.releaseAssertion])
        #expect(e.stop(inputs: inputs(4)).isEmpty)
    }

    @Test func closedLidOrderOnStartAndStop() {
        var e = KeepAwakeEngine()
        let on = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        #expect(on == [.holdAssertion(displayToo: true), .setClosedLid(true)])
        #expect(e.lidHeld)
        let off = e.stop(inputs: inputs(1))
        #expect(off == [.setClosedLid(false), .releaseAssertion])
        #expect(!e.lidHeld)
    }

    @Test func lidFailureKeepsSessionWithoutLid() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        let a = e.lidFailed("sudo", inputs: inputs(1))
        #expect(a == [.notify(.lidUnavailable("sudo"))])
        #expect(!e.lidHeld)
        #expect(e.isActive)
        #expect(e.session?.closedLid == false)
    }

    @Test func dimFollowsLidState() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        #expect(e.tick(inputs(1, lid: true)) == [.dimBuiltin(true)])
        #expect(e.tick(inputs(2, lid: true)).isEmpty)
        #expect(e.tick(inputs(3, lid: false)) == [.dimBuiltin(false)])
    }

    @Test func stopWhileDimmedUndimsFirst() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        _ = e.tick(inputs(1, lid: true))
        #expect(e.stop(inputs: inputs(2, lid: true)) == [.dimBuiltin(false), .setClosedLid(false), .releaseAssertion])
    }

    @Test func noDimWhenSettingOff() {
        var s = KeepAwakeSettings()
        s.dimOnLidClosed = false
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        #expect(e.tick(inputs(1, lid: true)).isEmpty)
    }

    @Test func noDimWithoutLidMode() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0), inputs: inputs())
        #expect(e.tick(inputs(1, lid: true)).isEmpty)
    }

    @Test func lidMaxHoursEndsSession() {
        var s = KeepAwakeSettings()
        s.lidMaxHours = 2
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        #expect(e.tick(inputs(7199)).isEmpty)
        #expect(e.tick(inputs(7200)) == [.notify(.ended(.lidLimit)), .setClosedLid(false), .releaseAssertion])
    }

    @Test func lidLimitZeroMeansNone() {
        var s = KeepAwakeSettings()
        s.lidMaxHours = 0
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        #expect(e.tick(inputs(100_000)).isEmpty)
    }

    @Test func batteryBelowLimitEndsSessionEvenWithNoticesOff() {
        var s = KeepAwakeSettings()
        s.notifyOnEnd = false
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0), inputs: inputs(percent: 80, ac: false))
        let a = e.tick(inputs(10, percent: 19, ac: false))
        #expect(a == [.notify(.ended(.batteryLow)), .releaseAssertion])
        #expect(e.batterySuppressed)
    }

    @Test func batteryLimitIgnoredOnAC() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0), inputs: inputs(percent: 5, ac: true))
        #expect(e.isActive)
        #expect(e.tick(inputs(10, percent: 4, ac: true)).isEmpty)
    }

    @Test func batteryLimitZeroDisablesProtection() {
        var s = KeepAwakeSettings()
        s.batteryLimitPercent = 0
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0), inputs: inputs(percent: 3, ac: false))
        #expect(e.isActive)
    }

    @Test func startRefusedBelowLimit() {
        var e = KeepAwakeEngine()
        let a = e.start(.minutes(0, from: t0), inputs: inputs(percent: 12, ac: false))
        #expect(a == [.notify(.batteryTooLow(percent: 12, limit: 20))])
        #expect(!e.isActive)
    }

    @Test func batteryRecoveryClearsSuppression() {
        var s = KeepAwakeSettings()
        s.autoOnPower = true
        var e = KeepAwakeEngine(settings: s)
        _ = e.tick(inputs(0, percent: 90, ac: true))
        #expect(e.automationOn)
        _ = e.tick(inputs(1, percent: 10, ac: false))
        #expect(e.batterySuppressed && !e.automationOn)
        _ = e.tick(inputs(2, percent: 10, ac: true))
        #expect(!e.batterySuppressed)
        #expect(e.automationOn)
    }

    @Test func automationAnyAndAll() {
        var s = KeepAwakeSettings()
        s.autoExternalDisplay = true
        s.autoOnPower = true
        #expect(KeepAwakeEngine.automationSatisfied(s, inputs(percent: 50, ac: true, displays: 0)))
        s.match = .all
        #expect(!KeepAwakeEngine.automationSatisfied(s, inputs(percent: 50, ac: true, displays: 0)))
        #expect(KeepAwakeEngine.automationSatisfied(s, inputs(percent: 50, ac: true, displays: 1)))
        #expect(!KeepAwakeEngine.automationSatisfied(s, inputs(percent: 50, ac: false, displays: 1)))
    }

    @Test func automationWithoutConditionsIsOff() {
        #expect(!KeepAwakeEngine.automationSatisfied(KeepAwakeSettings(), inputs(percent: 50, ac: true, displays: 2)))
        var s = KeepAwakeSettings()
        s.autoApps = true
        #expect(!KeepAwakeEngine.automationSatisfied(s, inputs(apps: ["a"])))
    }

    @Test func automationPowerOnDesktopCountsAsPower() {
        var s = KeepAwakeSettings()
        s.autoOnPower = true
        var b = BatteryReading()
        b.hasBattery = false
        #expect(KeepAwakeEngine.automationSatisfied(s, KeepAwakeInputs(now: t0, battery: b)))
    }

    @Test func automationAppsHoldAndRelease() {
        var s = KeepAwakeSettings()
        s.autoApps = true
        s.autoAppBundleIDs = ["com.big.download"]
        var e = KeepAwakeEngine(settings: s)
        #expect(e.tick(inputs(1, apps: ["com.big.download"])) == [.holdAssertion(displayToo: true)])
        #expect(e.tick(inputs(2, apps: ["com.big.download"])).isEmpty)
        #expect(e.tick(inputs(3, apps: [])) == [.releaseAssertion])
    }

    @Test func jiggleRunsOnInterval() {
        var s = KeepAwakeSettings()
        s.jiggleEnabled = true
        s.jiggleMinutes = 2
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0), inputs: inputs())
        #expect(e.tick(inputs(119)).isEmpty)
        #expect(e.tick(inputs(120)) == [.jiggle])
        #expect(e.tick(inputs(180)).isEmpty)
        #expect(e.tick(inputs(240)) == [.jiggle])
    }

    @Test func noJiggleWhenIdleOrDisabled() {
        var s = KeepAwakeSettings()
        s.jiggleEnabled = true
        var e = KeepAwakeEngine(settings: s)
        #expect(e.tick(inputs(10_000)).isEmpty)
        var e2 = KeepAwakeEngine()
        _ = e2.start(.minutes(0, from: t0), inputs: inputs())
        #expect(e2.tick(inputs(10_000)).isEmpty)
    }

    @Test func shutdownReleasesEverything() {
        var s = KeepAwakeSettings()
        s.autoExternalDisplay = true
        var e = KeepAwakeEngine(settings: s)
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs(displays: 1))
        _ = e.tick(inputs(1, displays: 1, lid: true))
        let a = e.shutdown(inputs: inputs(2, displays: 1, lid: true))
        #expect(a == [.dimBuiltin(false), .setClosedLid(false), .releaseAssertion])
        #expect(!e.isActive && !e.lidHeld && !e.dimmed)
    }

    @Test func replacingSessionKeepsAssertionAndDropsLid() {
        var e = KeepAwakeEngine()
        _ = e.start(.minutes(0, from: t0, closedLid: true), inputs: inputs())
        let a = e.start(.minutes(30, from: t0), inputs: inputs(1))
        #expect(a == [.setClosedLid(false)])
        #expect(e.isActive)
    }

    @Test func settingsSanitizeClamps() {
        var s = KeepAwakeSettings()
        s.batteryLimitPercent = 500
        s.jiggleMinutes = 0
        s.lidMaxHours = -4
        s.defaultMinutes = 99_999
        s.autoAppBundleIDs = ["a", "", "a", "b"]
        let c = s.sanitized
        #expect(c.batteryLimitPercent == 90)
        #expect(c.jiggleMinutes == 1)
        #expect(c.lidMaxHours == 0)
        #expect(c.defaultMinutes == 1440)
        #expect(c.autoAppBundleIDs == ["a", "b"])
    }
}
