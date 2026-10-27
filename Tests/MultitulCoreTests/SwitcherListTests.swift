import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func build(_ windows: [SwitchWindow], apps: [SwitchApp] = [], edit: (inout SwitchFilter) -> Void = { _ in }, ctx: SwitcherContext = SwitcherContext(), order: WindowUseOrder? = nil, creation: Bool = false) -> [SwitchEntry] {
    var f = SwitchFilter()
    f.ownPID = 1
    edit(&f)
    return SwitcherListBuilder.build(windows: windows, apps: apps, filter: f, context: ctx, order: order, creationOrder: creation)
}

private func keys(_ e: [SwitchEntry]) -> [SwitchEntryID] { e.map(\.id) }

@Suite struct WindowUseOrderTests {
    @Test func touchedWindowsComeFirstNewestFirst() {
        let o = WindowUseOrder()
        let w = [SwcFix.win(1), SwcFix.win(2), SwcFix.win(3)]
        o.touch(window: 2, pid: 10)
        o.touch(window: 3, pid: 10)
        #expect(o.sorted(w).map(\.key) == [3, 2, 1])
    }

    @Test func untrackedWindowsFollowZOrderWithinAnApp() {
        let o = WindowUseOrder()
        let w = [SwcFix.win(1, z: 5), SwcFix.win(2, z: 1), SwcFix.win(3, z: 3)]
        #expect(o.sorted(w).map(\.key) == [2, 3, 1])
    }

    @Test func recentAppsWinAmongUntrackedWindows() {
        let o = WindowUseOrder()
        o.touchApp(20)
        let w = [SwcFix.win(1, pid: 10, z: 0), SwcFix.win(2, pid: 20, z: 9)]
        #expect(o.sorted(w).map(\.key) == [2, 1])
    }

    @Test func reconcileFixesAStaleFrontOrder() {
        let o = WindowUseOrder()
        o.touch(window: 1, pid: 10)
        o.touch(window: 2, pid: 10)
        let front = [SwcFix.win(1, z: 0), SwcFix.win(2, z: 1)]
        o.reconcile(frontToBack: front)
        #expect(o.sorted(front).map(\.key) == [1, 2])
    }

    @Test func reconcileLeavesAConsistentOrderUntouched() {
        let o = WindowUseOrder()
        o.touch(window: 2, pid: 10)
        o.touch(window: 1, pid: 10)
        let before = o.stamp(ofWindow: 1)
        o.reconcile(frontToBack: [SwcFix.win(1, z: 0), SwcFix.win(2, z: 1)])
        #expect(o.stamp(ofWindow: 1) == before)
    }

    @Test func pruneAndForgetDropDeadWindows() {
        let o = WindowUseOrder()
        o.touch(window: 1, pid: 10)
        o.touch(window: 2, pid: 11)
        o.forget(window: 1)
        #expect(o.stamp(ofWindow: 1) == nil)
        o.prune(aliveWindows: [], alivePIDs: [10])
        #expect(o.stamp(ofWindow: 2) == nil && o.stamp(ofApp: 11) == nil && o.stamp(ofApp: 10) != nil)
    }

    @Test func capacityIsBounded() {
        let o = WindowUseOrder()
        for i in 0..<(WindowUseOrder.capacity + 50) { o.touch(window: i, pid: 1) }
        #expect(o.trackedWindows <= WindowUseOrder.capacity)
        #expect(o.stamp(ofWindow: WindowUseOrder.capacity + 49) != nil)
    }

    @Test func appsSortByRecency() {
        let o = WindowUseOrder()
        o.touchApp(2)
        o.touchApp(3)
        #expect(o.sortedApps([SwcFix.app(1), SwcFix.app(2), SwcFix.app(3)]).map(\.pid) == [3, 2, 1])
    }
}

@Suite struct SwitcherListBuilderTests {
    @Test func plainListKeepsInputOrderAndSkipsOwnWindows() {
        let e = build([SwcFix.win(1, pid: 1), SwcFix.win(2), SwcFix.win(3, pid: 11)])
        #expect(keys(e) == [.window(2), .window(3)])
    }

    @Test func tinyWindowsAreDropped() {
        let e = build([SwcFix.win(1, frame: CGRect(x: 0, y: 0, width: 30, height: 30)), SwcFix.win(2)])
        #expect(keys(e) == [.window(2)])
    }

    @Test func focusedWindowGoesFirst() {
        let e = build([SwcFix.win(1), SwcFix.win(2), SwcFix.win(3)], ctx: SwitcherContext(focusedKey: 3))
        #expect(keys(e) == [.window(3), .window(1), .window(2)])
    }

    @Test func currentSpaceFilterKeepsFullscreenWindowsOfOtherSpaces() {
        let w = [SwcFix.win(1), SwcFix.win(2, space: false), SwcFix.win(3, fullscreen: true, space: false)]
        #expect(keys(build(w) { $0.currentSpaceOnly = true }) == [.window(1), .window(3)])
        #expect(keys(build(w) { $0.currentSpaceOnly = true; $0.showFullscreen = false }) == [.window(1)])
        #expect(keys(build(w)).count == 3 - 0)
    }

    @Test func fullscreenCanBeHiddenEverywhere() {
        let w = [SwcFix.win(1), SwcFix.win(2, fullscreen: true)]
        #expect(keys(build(w) { $0.showFullscreen = false }) == [.window(1)])
    }

    @Test func displayFilterFollowsTheChosenDisplay() {
        let w = [SwcFix.win(1, display: 1), SwcFix.win(2, display: 2), SwcFix.win(3, display: nil)]
        let e = build(w, edit: { $0.currentDisplayOnly = true }, ctx: SwitcherContext(activeDisplayID: 2))
        #expect(keys(e) == [.window(2), .window(3)])
        #expect(keys(build(w, edit: { $0.currentDisplayOnly = true })).count == 3)
    }

    @Test func minimizedPlacementNormalEndHidden() {
        let w = [SwcFix.win(1), SwcFix.win(2, minimized: true), SwcFix.win(3)]
        #expect(keys(build(w)) == [.window(1), .window(2), .window(3)])
        #expect(keys(build(w) { $0.minimized = .end }) == [.window(1), .window(3), .window(2)])
        #expect(keys(build(w) { $0.minimized = .hidden }) == [.window(1), .window(3)])
    }

    @Test func hiddenAppsCanFollowTheMinimizedRule() {
        let w = [SwcFix.win(1, hidden: true), SwcFix.win(2)]
        #expect(keys(build(w) { $0.minimized = .hidden }).count == 2)
        #expect(keys(build(w) { $0.minimized = .hidden; $0.hiddenLikeMinimized = true }) == [.window(2)])
        #expect(keys(build(w) { $0.minimized = .end; $0.hiddenLikeMinimized = true }) == [.window(2), .window(1)])
    }

    @Test func mergeCollapsesAppsAndCountsWindows() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11), SwcFix.win(3, pid: 10), SwcFix.win(4, pid: 10)]
        let e = build(w) { $0.mergeWindows = true }
        #expect(keys(e) == [.window(1), .window(2)])
        #expect(e[0].kind == .group && e[0].windowCount == 3 && e[1].kind == .window && e[1].windowCount == 1)
        #expect(e[0].displayTitle == "App (3)")
    }

    @Test func mergedEntryIsNotMinimizedWhenAnyWindowIsOpen() {
        let w = [SwcFix.win(1, minimized: true), SwcFix.win(2)]
        #expect(build(w) { $0.mergeWindows = true }[0].isMinimized == false)
    }

    @Test func windowlessAppsFollowTheMode() {
        let apps = [SwcFix.app(10), SwcFix.app(20, "Finder", bundle: "com.apple.finder"), SwcFix.app(30, "Terminal"), SwcFix.app(40, "Agent", regular: false)]
        let w = [SwcFix.win(1, pid: 10)]
        #expect(keys(build(w, apps: apps) { $0.windowless = .all }) == [.window(1), .app(20), .app(30)])
        #expect(keys(build(w, apps: apps) { $0.windowless = .finder }) == [.window(1), .app(20)])
        #expect(keys(build(w, apps: apps) { $0.windowless = .off }) == [.window(1)])
    }

    @Test func anAppWhoseWindowsAreFilteredIsNotListedAsWindowless() {
        let apps = [SwcFix.app(10)]
        let w = [SwcFix.win(1, pid: 10, space: false)]
        #expect(build(w, apps: apps) { $0.currentSpaceOnly = true; $0.windowless = .all }.isEmpty)
    }

    @Test func appRulesOverrideTheGlobalMode() {
        let apps = [SwcFix.app(20, "Slack", bundle: "com.slack"), SwcFix.app(30, "Mail", bundle: "com.mail"), SwcFix.app(10)]
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 40, bundle: "com.hidden")]
        var rules = AppRules()
        rules.set("com.slack", .windowsOnly)
        rules.set("com.mail", .showWithoutWindows)
        rules.set("com.hidden", .hidden)
        let e = build(w, apps: apps) { $0.windowless = .off; $0.rules = rules }
        #expect(keys(e) == [.window(1), .app(30)])
    }

    @Test func sameAppScopeListsOnlyThatAppAndNoWindowlessEntries() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11), SwcFix.win(3, pid: 10)]
        let e = build(w, apps: [SwcFix.app(12)], ctx: SwitcherContext(scope: .sameApp(10)))
        #expect(keys(e) == [.window(1), .window(3)])
    }

    @Test func sameAppScopeIgnoresMergeSoEveryWindowShows() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 10)]
        #expect(build(w, edit: { $0.mergeWindows = true }, ctx: SwitcherContext(scope: .sameApp(10))).count == 2)
    }

    @Test func previewExclusionMarksEntriesWithoutDroppingThem() {
        let e = build([SwcFix.win(1, bundle: "com.bank"), SwcFix.win(2)]) { $0.previewExcluded = AppExceptionList(["com.bank"]) }
        #expect(e.map(\.previewAllowed) == [false, true])
    }

    @Test func useOrderDrivesTheListAndFocusedStaysOnTop() {
        let o = WindowUseOrder()
        o.touch(window: 3, pid: 10)
        o.touch(window: 2, pid: 10)
        let w = [SwcFix.win(1), SwcFix.win(2), SwcFix.win(3)]
        #expect(keys(build(w, order: o)) == [.window(2), .window(3), .window(1)])
        #expect(keys(build(w, ctx: SwitcherContext(focusedKey: 1), order: o)) == [.window(1), .window(2), .window(3)])
    }

    @Test func creationOrderSortsByWindowID() {
        let w = [SwcFix.win(1, id: 30), SwcFix.win(2, id: 10), SwcFix.win(3, id: 20)]
        #expect(keys(build(w, creation: true)) == [.window(2), .window(3), .window(1)])
    }

    @Test func initialIndexPicksThePreviousWindowOrTheLast() {
        #expect(SwitcherListBuilder.initialIndex(count: 0, backward: false) == nil)
        #expect(SwitcherListBuilder.initialIndex(count: 1, backward: false) == 0)
        #expect(SwitcherListBuilder.initialIndex(count: 5, backward: false) == 1)
        #expect(SwitcherListBuilder.initialIndex(count: 5, backward: true) == 4)
    }

    @Test func displayChoiceFollowsPlacement() {
        var snap = SwitcherSnapshot(displays: [SwcFix.display, SwcFix.second], primaryDisplayID: 1, pointer: CGPoint(x: 2000, y: 100), focusedFrame: CGRect(x: 100, y: 100, width: 500, height: 400))
        #expect(SwitcherDisplayChoice.display(for: .pointer, in: snap)?.id == 2)
        #expect(SwitcherDisplayChoice.display(for: .menuBar, in: snap)?.id == 1)
        #expect(SwitcherDisplayChoice.display(for: .activeWindow, in: snap)?.id == 1)
        snap.focusedFrame = nil
        #expect(SwitcherDisplayChoice.display(for: .activeWindow, in: snap)?.id == 2)
        #expect(SwitcherDisplayChoice.display(for: .pointer, in: SwitcherSnapshot()) == nil)
    }

    @Test func windowStraddlingTwoDisplaysBelongsToTheLargerShare() {
        let d = [SwcFix.display, SwcFix.second]
        #expect(DisplayAssignment.display(for: CGRect(x: 1700, y: 100, width: 600, height: 400), in: d)?.id == 2)
        #expect(DisplayAssignment.display(for: CGRect(x: 1000, y: 100, width: 600, height: 400), in: d)?.id == 1)
    }
}
