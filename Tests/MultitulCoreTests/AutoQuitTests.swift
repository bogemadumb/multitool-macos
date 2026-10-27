import Testing
import Foundation
@testable import MultitulCore

final class WndAutoQuitDriver: AutoQuitDriving {
    var apps: [Int32: AutoQuitApp] = [:]
    var snapshots: [Int32: AutoQuitSnapshot] = [:]
    var terminated: [Int32] = []
    var refuse = false

    func add(_ pid: Int32, _ bundle: String, regular: Bool = true, hidden: Bool = false, snapshot: AutoQuitSnapshot = AutoQuitSnapshot()) {
        apps[pid] = AutoQuitApp(pid: pid, bundleID: bundle, isRegular: regular, isHidden: hidden)
        snapshots[pid] = snapshot
    }

    func app(pid: Int32) -> AutoQuitApp? { apps[pid] }
    func snapshot(of app: AutoQuitApp) -> AutoQuitSnapshot { snapshots[app.pid] ?? AutoQuitSnapshot() }

    func terminate(_ app: AutoQuitApp) -> Bool {
        guard !refuse else { return false }
        terminated.append(app.pid)
        apps[app.pid] = nil
        return true
    }
}

private func rig(_ edit: (inout AutoQuitSettings) -> Void = { _ in }) -> (WndAutoQuitDriver, WndTimers, AutoQuitService, WndBox<AutoQuitSettings>) {
    let d = WndAutoQuitDriver()
    let t = WndTimers()
    var s = AutoQuitSettings()
    edit(&s)
    let box = WndBox(s)
    return (d, t, AutoQuitService(driver: d, timers: t) { box.value }, box)
}

@Suite struct AutoQuitPolicyTests {
    private let app = AutoQuitApp(pid: 1, bundleID: "com.test.app")
    private let none = AutoQuitSnapshot()

    @Test func lastWindowClosedMeansQuit() {
        #expect(AutoQuitPolicy.verdict(app: app, hadWindow: true, snapshot: none, settings: AutoQuitSettings()) == .quit)
    }

    @Test func anyRemainingWindowKeepsTheApp() {
        for s in [AutoQuitSnapshot(windows: 1), AutoQuitSnapshot(minimized: 1), AutoQuitSnapshot(otherSpaces: 1), AutoQuitSnapshot(surfaces: 1)] {
            #expect(AutoQuitPolicy.verdict(app: app, hadWindow: true, snapshot: s, settings: AutoQuitSettings()) != .quit)
        }
    }

    @Test func appsThatNeverHadAWindowAreKept() {
        #expect(AutoQuitPolicy.verdict(app: app, hadWindow: false, snapshot: none, settings: AutoQuitSettings()) != .quit)
    }

    @Test func menuBarUtilitiesAreKept() {
        var a = app
        a.isRegular = false
        #expect(AutoQuitPolicy.verdict(app: a, hadWindow: true, snapshot: none, settings: AutoQuitSettings()) != .quit)
    }

    @Test func hiddenAppsAreKept() {
        var a = app
        a.isHidden = true
        #expect(AutoQuitPolicy.verdict(app: a, hadWindow: true, snapshot: none, settings: AutoQuitSettings()) != .quit)
    }

    @Test func inaccessibleWindowListIsNeverTreatedAsEmpty() {
        #expect(AutoQuitPolicy.verdict(app: app, hadWindow: true, snapshot: AutoQuitSnapshot(accessible: false), settings: AutoQuitSettings()) != .quit)
    }

    @Test func userExceptionsAreRespected() {
        var s = AutoQuitSettings()
        s.exceptions = AppExceptionList(["com.test.app"])
        #expect(AutoQuitPolicy.verdict(app: app, hadWindow: true, snapshot: none, settings: s) != .quit)
    }

    @Test func finderAndSystemUIAreAlwaysExcepted() {
        for id in ["com.apple.finder", "com.apple.dock", "dev.multitool.app"] {
            let a = AutoQuitApp(pid: 2, bundleID: id)
            #expect(AutoQuitPolicy.verdict(app: a, hadWindow: true, snapshot: none, settings: AutoQuitSettings()) != .quit)
        }
    }

    @Test func settingsSanitizeTheDelay() {
        var s = AutoQuitSettings()
        s.delayMs = 5
        #expect(s.sanitized.delayMs == 150)
        s.delayMs = 99999
        #expect(s.sanitized.delayMs == 3000)
    }

    @Test func snapshotHoldsAppReflectsAnyWindow() {
        #expect(!AutoQuitSnapshot().holdsApp && AutoQuitSnapshot(minimized: 2).holdsApp)
    }
}

@Suite struct AutoQuitServiceTests {
    @Test func closingTheLastWindowQuitsAfterTheDelay() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        #expect(t.active == 1 && d.terminated.isEmpty)
        t.fireAll()
        #expect(d.terminated == [7] && s.quitLog == ["com.test.app"])
    }

    @Test func delayComesFromSettings() {
        let (d, t, s, _) = rig({ $0.delayMs = 1000 })
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        #expect(t.items.first?.delay == 1.0)
    }

    @Test func aNewWindowBeforeTheDelayCancelsTheQuit() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        s.windowCreated(pid: 7)
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func remainingWindowsKeepTheApp() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app", snapshot: AutoQuitSnapshot(windows: 1))
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func aSaveDialogStillCountsAsASurface() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app", snapshot: AutoQuitSnapshot(surfaces: 1))
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func closeEventsWithoutAPriorWindowAreIgnored() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowClosed(pid: 7)
        #expect(t.items.isEmpty && d.terminated.isEmpty)
    }

    @Test func appsAlreadyShowingWindowsAtStartAreWatched() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.appObserved(pid: 7, hasWindows: true)
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(d.terminated == [7])
    }

    @Test func appsObservedWithoutWindowsAreNotWatched() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.appObserved(pid: 7, hasWindows: false)
        s.windowClosed(pid: 7)
        #expect(t.items.isEmpty && d.terminated.isEmpty && s.watchedCount == 0)
    }

    @Test func repeatedCloseEventsKeepOneTimer() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        for _ in 0..<4 { s.windowClosed(pid: 7) }
        #expect(t.active == 1)
        t.fireAll()
        #expect(d.terminated == [7])
    }

    @Test func exceptionsAreHonouredAtDecisionTime() {
        let (d, t, s, box) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        box.value.exceptions = AppExceptionList(["com.test.app"])
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func terminatedAppIsForgotten() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        s.appTerminated(pid: 7)
        #expect(t.active == 0 && s.watchedCount == 0)
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func appGoneBeforeTheCheckIsHandled() {
        let (d, _, s, _) = rig()
        s.windowCreated(pid: 9)
        #expect(s.check(pid: 9) == .keep("приложение закрыто"))
        _ = d
    }

    @Test func refusedTerminationIsNotLogged() {
        let (d, t, s, _) = rig()
        d.refuse = true
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(s.quitLog.isEmpty)
    }

    @Test func menuBarUtilityNeverQuits() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.bar", regular: false)
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(d.terminated.isEmpty)
    }

    @Test func resetCancelsPendingChecks() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        s.reset()
        t.fireAll()
        #expect(d.terminated.isEmpty && s.watchedCount == 0)
    }

    @Test func quittingTwiceDoesNotHappen() {
        let (d, t, s, _) = rig()
        d.add(7, "com.test.app")
        s.windowCreated(pid: 7)
        s.windowClosed(pid: 7)
        t.fireAll()
        s.windowClosed(pid: 7)
        t.fireAll()
        #expect(d.terminated == [7])
    }

    @Test func surfacesCountOnlyRealPanels() {
        #expect(AutoQuitSurfaces.counts(layer: 3, size: CGSize(width: 300, height: 80), onScreen: true))
        #expect(!AutoQuitSurfaces.counts(layer: 25, size: CGSize(width: 300, height: 80), onScreen: true))
        #expect(!AutoQuitSurfaces.counts(layer: 0, size: CGSize(width: 300, height: 80), onScreen: true))
        #expect(!AutoQuitSurfaces.counts(layer: 101, size: CGSize(width: 300, height: 80), onScreen: true))
        #expect(!AutoQuitSurfaces.counts(layer: 3, size: CGSize(width: 10, height: 10), onScreen: true))
        #expect(!AutoQuitSurfaces.counts(layer: 3, size: CGSize(width: 300, height: 80), onScreen: false))
    }

    @Test func offscreenTitledWindowsMeanAnotherSpace() {
        #expect(AutoQuitSurfaces.isOffscreenUserWindow(layer: 0, size: CGSize(width: 800, height: 600), onScreen: false, title: "Doc"))
        #expect(!AutoQuitSurfaces.isOffscreenUserWindow(layer: 0, size: CGSize(width: 800, height: 600), onScreen: false, title: ""))
        #expect(!AutoQuitSurfaces.isOffscreenUserWindow(layer: 0, size: CGSize(width: 800, height: 600), onScreen: true, title: "Doc"))
        #expect(!AutoQuitSurfaces.isOffscreenUserWindow(layer: 0, size: CGSize(width: 20, height: 20), onScreen: false, title: "x"))
    }
}
