import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func three() -> [SwitchWindow] {
    [SwcFix.win(1, pid: 10, app: "Safari", title: "Новости"), SwcFix.win(2, pid: 11, app: "Telegram", title: "Чат"), SwcFix.win(3, pid: 12, app: "Terminal", title: "zsh")]
}

@Suite struct SwitcherEngineTests {
    @Test func beginSelectsThePreviousWindowAndCommitActivatesIt() {
        let (e, _, act, _, _) = swcEngine(windows: three(), focused: 1)
        #expect(e.begin(trigger: .apps, backward: false))
        #expect(e.session?.selectedID == .window(2))
        e.commit()
        #expect(act.activated.map(\.id) == [.window(2)] && !e.isActive && e.commitCount == 1)
    }

    @Test func aQuickTapNeverTouchesThePanel() {
        let (e, _, _, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.commit()
        #expect(panel.presented.isEmpty && panel.dismissed == 0)
    }

    @Test func presentShowsStateAndCancelDismisses() {
        let (e, _, act, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        e.present()
        #expect(panel.presented.count == 1 && panel.presented[0].entries.count == 3 && panel.presented[0].selected == 1)
        e.cancel()
        #expect(panel.dismissed == 1 && act.activated.isEmpty && !e.isActive)
    }

    @Test func movingUpdatesThePanelAndWraps() {
        let (e, _, _, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        e.move(1)
        e.move(1)
        #expect(panel.last?.selected == 0)
        e.move(-1)
        #expect(panel.last?.selected == 2)
    }

    @Test func windowsTriggerNeedsTwoWindowsOfTheFrontApp() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11), SwcFix.win(3, pid: 10)]
        let (e, _, act, _, _) = swcEngine(windows: w, focused: 1, front: 10)
        #expect(e.begin(trigger: .windows, backward: false))
        #expect(e.session?.all.map(\.pid) == [10, 10] && e.session?.selectedID == .window(3))
        e.commit()
        #expect(act.activated.first?.id == .window(3))
        let (e2, _, _, _, _) = swcEngine(windows: [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11)], focused: 1, front: 10)
        #expect(!e2.begin(trigger: .windows, backward: false))
    }

    @Test func emptyListDoesNotStartASession() {
        let (e, _, _, _, _) = swcEngine(windows: [])
        #expect(!e.begin(trigger: .apps, backward: false) && !e.isActive)
    }

    @Test func commitFeedsTheUseOrder() {
        let (e, _, _, _, order) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.commit()
        #expect((order.stamp(ofWindow: 2) ?? 0) > (order.stamp(ofWindow: 1) ?? 0))
    }

    @Test func nextOpeningPutsThePreviouslyChosenWindowFirst() {
        let (e, src, _, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.commit()
        src.snap.focusedKey = 2
        _ = e.begin(trigger: .apps, backward: false)
        #expect(e.session?.all.first?.id == .window(2) && e.session?.selectedID == .window(1))
    }

    @Test func closeRemovesTheEntryAndKeepsTheSwitcherOpen() {
        let (e, _, act, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        e.closeSelected()
        #expect(act.closed.map(\.id) == [.window(2)] && e.session?.count == 2)
        #expect(panel.last?.entries.count == 2)
    }

    @Test func aRefusedCloseChangesNothing() {
        let (e, _, act, _, _) = swcEngine(windows: three(), focused: 1)
        act.closeResult = false
        _ = e.begin(trigger: .apps, backward: false)
        e.closeSelected()
        #expect(e.session?.count == 3)
    }

    @Test func closingTheLastEntryEndsTheSession() {
        let (e, _, _, _, _) = swcEngine(windows: [SwcFix.win(1)], focused: 1)
        var ended = 0
        e.onEnded = { ended += 1 }
        _ = e.begin(trigger: .apps, backward: false)
        e.closeSelected()
        #expect(!e.isActive && ended == 1)
    }

    @Test func closingOneWindowOfAGroupDecrementsItsCounter() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 10), SwcFix.win(3, pid: 11)]
        let (e, src, act, _, _) = swcEngine(windows: w, focused: 3, edit: { $0.mergeWindows = true })
        src.autoComplete = false
        _ = e.begin(trigger: .apps, backward: false)
        e.closeSelected()
        #expect(act.closed.count == 1 && e.session?.visible.first(where: { $0.pid == 10 })?.windowCount == 1)
    }

    @Test func quitDropsEveryEntryOfTheApp() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11), SwcFix.win(3, pid: 11), SwcFix.win(4, pid: 12)]
        let (e, _, act, _, _) = swcEngine(windows: w, focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.quitSelected()
        #expect(act.quit == [11] && e.session?.all.map(\.pid) == [10, 12])
    }

    @Test func minimizeTogglesAndMirrorsInTheList() {
        let (e, _, act, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.minimizeSelected()
        #expect(act.minimized.map(\.1) == [true] && e.session?.selectedEntry?.isMinimized == true)
        e.minimizeSelected()
        #expect(act.minimized.map(\.1) == [true, false] && e.session?.selectedEntry?.isMinimized == false)
    }

    @Test func hideMarksTheWholeApp() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 11), SwcFix.win(3, pid: 11)]
        let (e, _, act, _, _) = swcEngine(windows: w, focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.hideSelected()
        #expect(act.hidden == [11] && e.session?.all.filter { $0.pid == 11 }.allSatisfy(\.isAppHidden) == true)
    }

    @Test func windowlessAppEntryActivatesTheApp() {
        let (e, _, act, _, _) = swcEngine(windows: [SwcFix.win(1, pid: 10)], apps: [SwcFix.app(10), SwcFix.app(20, "Finder")], focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        #expect(e.session?.selectedID == .app(20))
        e.commit()
        #expect(act.activated.first?.kind == .appOnly)
    }

    @Test func closingAWindowlessEntryQuitsTheApp() {
        let (e, _, act, _, _) = swcEngine(windows: [SwcFix.win(1, pid: 10)], apps: [SwcFix.app(10), SwcFix.app(20, "Finder")], focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.closeSelected()
        #expect(act.quit == [20] && act.closed.isEmpty)
    }

    @Test func searchFiltersAndCommitsTheTopMatch() {
        let (e, _, act, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.beginSearch()
        #expect(panel.presented.count == 1 && panel.presented[0].searching)
        e.appendQuery("term")
        #expect(panel.last?.entries.map(\.appName).first == "Terminal")
        e.commit()
        #expect(act.activated.first?.id == .window(3))
    }

    @Test func clearQueryReportsWhetherItHadText() {
        let (e, _, _, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        #expect(!e.clearQuery())
        e.beginSearch(); e.appendQuery("sa")
        #expect(e.clearQuery() && e.session?.query == "" && e.session?.count == 3)
    }

    @Test func deletingFromTheQueryWidensTheList() {
        let (e, _, _, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.beginSearch(); e.appendQuery("tel")
        let narrow = e.session?.count ?? 0
        e.deleteQueryCharacter(); e.deleteQueryCharacter()
        #expect((e.session?.count ?? 0) >= narrow)
    }

    @Test func freshSnapshotMergesIntoAnOpenSessionKeepingTheSelection() {
        let (e, src, _, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        var s = src.snap
        s.windows.append(SwcFix.win(4, pid: 13, app: "Notes"))
        src.completeRefresh(s)
        #expect(e.session?.count == 4 && e.session?.selectedID == .window(2) && panel.last?.entries.count == 4)
    }

    @Test func aRefreshArrivingAfterTheSessionEndedIsIgnored() {
        let (e, src, _, panel, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.cancel()
        src.completeRefresh()
        #expect(!e.isActive && panel.updates.isEmpty)
    }

    @Test func aRefreshFromAnOlderSessionNeverLeaksIntoANewOne() {
        let (e, src, _, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.cancel()
        _ = e.begin(trigger: .apps, backward: false)
        var stale = src.snap
        stale.windows = [SwcFix.win(9, pid: 99)]
        let first = src.pending.first
        first?(stale)
        #expect(e.session?.count == 3)
    }

    @Test func mouseSelectAndActivate() {
        let (e, _, act, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        e.select(id: .window(3))
        #expect(e.session?.selectedID == .window(3))
        e.activateEntry(id: .window(1))
        #expect(act.activated.map(\.id) == [.window(1)] && !e.isActive)
    }

    @Test func mouseCloseAndQuitHelpersWork() {
        let (e, _, act, _, _) = swcEngine(windows: three(), focused: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.closeEntry(id: .window(3))
        e.quitEntry(pid: 11)
        #expect(act.closed.map(\.id) == [.window(3)] && act.quit == [11] && e.session?.count == 1)
    }

    @Test func panelHitTestIsForwarded() {
        let (e, _, _, panel, _) = swcEngine(windows: three(), focused: 1)
        panel.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        #expect(e.containsPoint(CGPoint(x: 5, y: 5)) && !e.containsPoint(CGPoint(x: 50, y: 5)))
    }

    @Test func iconsLayoutMergesAppsAndSkipsThumbnails() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 10), SwcFix.win(3, pid: 11)]
        let svc = ThumbnailService(capturer: SwcCapturer())
        let (e, _, _, panel, _) = swcEngine(windows: w, focused: 3, edit: { $0.layout = .icons }, thumbs: svc)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        #expect(panel.presented[0].entries.count == 2 && !panel.presented[0].thumbnails && svc.captureCount == 0)
    }

    @Test func withoutScreenRecordingNoCaptureIsRequested() {
        let cap = SwcCapturer()
        let svc = ThumbnailService(capturer: cap)
        let (e, _, _, panel, _) = swcEngine(windows: three(), focused: 1, thumbs: svc, recording: false)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        #expect(cap.requests.isEmpty && panel.presented[0].thumbnails == false)
    }

    @Test func presentRequestsThumbnailsSelectedFirstAndUpdatesTheViewWhenTheyArrive() {
        let cap = SwcCapturer()
        let svc = ThumbnailService(capturer: cap)
        let (e, _, _, panel, _) = swcEngine(windows: three(), focused: 1, thumbs: svc)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        #expect(cap.requests.first == 1002 && Set(cap.requests) == [1001, 1002, 1003])
        cap.finish(1002)
        #expect(panel.thumbUpdates == [1002] && svc.cache.peek(1002) != nil)
    }

    @Test func screenPlacementPicksTheDisplayOfThePanel() {
        let src = SwcSource(windows: three(), focused: 1, front: 10, displays: [SwcFix.display, SwcFix.second])
        src.snap.pointer = CGPoint(x: 2500, y: 300)
        let panel = SwcPanel()
        let e = SwitcherEngine(source: src, actor: SwcActor(), panel: panel, settings: { SwitcherSettings() }, ownPID: 1)
        _ = e.begin(trigger: .apps, backward: false)
        e.present()
        #expect(panel.presented[0].display.id == 2)
    }
}
