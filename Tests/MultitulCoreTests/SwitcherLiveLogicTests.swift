import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let apps: [Int32: SwitchApp] = [
    10: SwitchApp(pid: 10, bundleID: "com.a", name: "A"),
    11: SwitchApp(pid: 11, bundleID: "com.b", name: "B"),
    12: SwitchApp(pid: 12, bundleID: "com.hidden", name: "H", isHidden: true),
    13: SwitchApp(pid: 13, bundleID: "com.agent", name: "Agent", isRegular: false)
]
private let displays = [SwcFix.display, SwcFix.second]

private func cg(_ id: UInt32, _ pid: Int32, _ title: String, _ x: CGFloat, z: Int = 0, onScreen: Bool = true, layer: Int = 0, w: CGFloat = 800, alpha: Double = 1) -> CGWindowRecord {
    CGWindowRecord(windowID: id, pid: pid, layer: layer, title: title, frame: CGRect(x: x, y: 100, width: w, height: 600), onScreen: onScreen, alpha: alpha, zIndex: z)
}

private func ax(_ key: Int, _ pid: Int32, _ title: String, _ x: CGFloat, minimized: Bool = false, fullscreen: Bool = false) -> AXWindowRecord {
    AXWindowRecord(key: key, pid: pid, title: title, frame: CGRect(x: x, y: 100, width: 800, height: 600), isMinimized: minimized, isFullscreen: fullscreen)
}

@Suite struct WindowSnapshotMergerTests {
    @Test func axWindowsGetTheirCGWindowIDAndZIndexByTitleAndFrame() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "Doc", 0, z: 3), cg(101, 10, "Other", 50, z: 1)], ax: [ax(1, 10, "Doc", 0), ax(2, 10, "Other", 50)], apps: apps, displays: displays)
        #expect(r.map(\.key) == [2, 1] && r.map(\.windowID) == [101, 100] && r.map(\.zIndex) == [1, 3])
        #expect(r.allSatisfy { $0.isOnCurrentSpace && $0.bundleID == "com.a" && $0.appName == "A" && $0.displayID == 1 })
    }

    @Test func twoWindowsWithTheSameTitleMatchByFrame() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "Doc", 0, z: 0), cg(101, 10, "Doc", 300, z: 1)], ax: [ax(1, 10, "Doc", 300), ax(2, 10, "Doc", 0)], apps: apps, displays: displays)
        #expect(r.first { $0.key == 1 }?.windowID == 101 && r.first { $0.key == 2 }?.windowID == 100)
    }

    @Test func emptyCGTitlesFallBackToTheFrame() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "", 0)], ax: [ax(1, 10, "Секретно", 2)], apps: apps, displays: displays)
        #expect(r.first?.windowID == 100 && r.first?.title == "Секретно")
    }

    @Test func aMovedWindowStillMatchesByTitle() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "Doc", 400)], ax: [ax(1, 10, "Doc", 0)], apps: apps, displays: displays)
        #expect(r.first?.windowID == 100)
    }

    @Test func minimizedWindowsStayEvenWithoutACGMatch() {
        let r = WindowSnapshotMerger.merge(cg: [], ax: [ax(1, 10, "Doc", 0, minimized: true)], apps: apps, displays: displays)
        #expect(r.count == 1 && r[0].isMinimized && r[0].windowID == 0 && r[0].zIndex == Int.max)
    }

    @Test func aClosedWindowDisappearsEvenIfTheAXCacheIsStale() {
        let r = WindowSnapshotMerger.merge(cg: [], ax: [ax(1, 10, "Gone", 0)], apps: apps, displays: displays)
        #expect(r.isEmpty)
    }

    @Test func hiddenAppWindowsAreKeptAndMarked() {
        let r = WindowSnapshotMerger.merge(cg: [], ax: [ax(1, 12, "Doc", 0)], apps: apps, displays: displays)
        #expect(r.count == 1 && r[0].isAppHidden)
    }

    @Test func windowsOfOtherSpacesComeFromCGOnlyWithATitle() {
        let r = WindowSnapshotMerger.merge(cg: [cg(200, 11, "На другом столе", 0, onScreen: false, w: 700), cg(201, 11, "", 0, onScreen: false), cg(202, 11, "Мелочь", 0, onScreen: false, w: 50)],
                                           ax: [], apps: apps, displays: displays)
        #expect(r.count == 1 && !r[0].isOnCurrentSpace && r[0].windowID == 200 && r[0].key == WindowSnapshotMerger.syntheticKey(windowID: 200))
    }

    @Test func withoutAccessibilityOnScreenWindowsStillShow() {
        let r = WindowSnapshotMerger.merge(cg: [cg(300, 10, "", 0, z: 2), cg(301, 10, "", 0, z: 1, w: 60)], ax: [], apps: apps, displays: displays)
        #expect(r.map(\.windowID) == [300] && r[0].isOnCurrentSpace)
    }

    @Test func overlaysAndMenuBarLayersAreIgnored() {
        let r = WindowSnapshotMerger.merge(cg: [cg(1, 10, "Bar", 0, layer: 25), cg(2, 10, "Ghost", 0, alpha: 0), cg(3, 99, "Unknown", 0)], ax: [], apps: apps, displays: displays)
        #expect(r.isEmpty)
    }

    @Test func agentAppsNeverGetCGOnlyWindows() {
        let r = WindowSnapshotMerger.merge(cg: [cg(400, 13, "Popup", 0)], ax: [], apps: apps, displays: displays)
        #expect(r.isEmpty)
    }

    @Test func fullscreenWindowOfAnotherSpaceSurvivesWithoutCGMatch() {
        let r = WindowSnapshotMerger.merge(cg: [], ax: [ax(1, 10, "Video", 0, fullscreen: true)], apps: apps, displays: displays)
        #expect(r.count == 1 && r[0].isFullscreen)
    }

    @Test func unmatchedOnScreenCGWindowOfAnAXAppIsLeftForTheNextRefresh() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "Doc", 0), cg(101, 10, "Palette", 900, z: 1)], ax: [ax(1, 10, "Doc", 0)], apps: apps, displays: displays)
        #expect(r.map(\.key) == [1])
    }

    @Test func displayIsAssignedByTheLargestShare() {
        let r = WindowSnapshotMerger.merge(cg: [cg(100, 10, "Doc", 2000)], ax: [ax(1, 10, "Doc", 2000)], apps: apps, displays: displays)
        #expect(r.first?.displayID == 2)
    }

    @Test func resultIsFrontToBack() {
        let r = WindowSnapshotMerger.merge(cg: [cg(1, 10, "A", 0, z: 5), cg(2, 11, "B", 10, z: 0), cg(3, 10, "C", 20, z: 2)], ax: [ax(1, 10, "A", 0), ax(2, 11, "B", 10), ax(3, 10, "C", 20)], apps: apps, displays: displays)
        #expect(r.map(\.key) == [2, 3, 1])
    }
}

@Suite struct SystemShortcutTakeoverTests {
    private func rig() -> (SystemShortcutTakeover, SwcHotKeys, WndMemoryStore) {
        let d = SwcHotKeys()
        let kv = WndMemoryStore()
        return (SystemShortcutTakeover(driver: d, store: kv), d, kv)
    }

    @Test func holdDisablesTheFourNativeShortcutsAndJournalsThemFirst() {
        let (t, d, kv) = rig()
        #expect(t.hold() == .held([1, 2, 27, 220]))
        #expect(d.state.values.allSatisfy { !$0 } && t.isHolding && t.journal == [1, 2, 27, 220])
        #expect(kv.values[SystemShortcutTakeover.journalKey] != nil)
    }

    @Test func releaseRestoresExactlyWhatWeDisabled() {
        let (t, d, _) = rig()
        d.state[27] = false
        #expect(t.hold() == .held([1, 2, 220]))
        #expect(t.release() == .released([1, 2, 220]))
        #expect(d.state == [1: true, 2: true, 27: false, 220: true] && !t.isHolding)
    }

    @Test func holdingTwiceDoesNotTouchTheSystemAgain() {
        let (t, d, _) = rig()
        _ = t.hold()
        let n = d.writes.count
        #expect(t.hold() == .alreadyHeld && d.writes.count == n)
    }

    @Test func unavailablePrivateCallsAreReportedAndNothingIsJournalled() {
        let (t, d, kv) = rig()
        d.available = false
        #expect(t.hold() == .unavailable && kv.values.isEmpty)
    }

    @Test func aFailedDisableKeepsTheJournalHonest() {
        let (t, d, _) = rig()
        d.failIDs = [2]
        if case .failed = t.hold() {} else { Issue.record("expected failure") }
        #expect(t.journal == [1, 27, 220])
        d.failIDs = []
        #expect(t.release() == .released([1, 27, 220]))
    }

    @Test func aFailedRestoreIsRetriedNextTime() {
        let (t, d, _) = rig()
        _ = t.hold()
        d.failIDs = [27]
        if case .failed = t.release() {} else { Issue.record("expected failure") }
        #expect(t.journal == [27])
        d.failIDs = []
        #expect(t.release() == .released([27]) && !t.isHolding)
    }

    @Test func releaseWithNothingHeldDoesNothing() {
        let (t, d, _) = rig()
        #expect(t.release() == .nothingToRelease && d.writes.isEmpty)
    }

    @Test func staleJournalIsRecoveredOnlyWhileTheModuleIsOff() {
        let (t, d, _) = rig()
        _ = t.hold()
        #expect(t.recoverStale(moduleEnabled: true) == nil && t.isHolding)
        #expect(t.recoverStale(moduleEnabled: false) == .released([1, 2, 27, 220]))
        #expect(d.state.values.allSatisfy { $0 })
        #expect(t.recoverStale(moduleEnabled: false) == nil)
    }

    @Test func policyHoldsNativeOnlyWhenOurTapIsAlive() {
        #expect(TakeoverPolicy.shouldHoldNative(takeOver: true, trusted: true, tapRunning: true))
        #expect(!TakeoverPolicy.shouldHoldNative(takeOver: true, trusted: false, tapRunning: true))
        #expect(!TakeoverPolicy.shouldHoldNative(takeOver: true, trusted: true, tapRunning: false))
        #expect(!TakeoverPolicy.shouldHoldNative(takeOver: false, trusted: true, tapRunning: true))
    }

    @Test func nativeHotKeyIdsAreTheKnownSystemOnes() {
        #expect(NativeSwitcherHotKey.allCases.map(\.rawValue) == [1, 2, 27, 220])
    }
}
