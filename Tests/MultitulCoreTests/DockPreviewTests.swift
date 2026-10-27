import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let bounds = CGRect(x: 0, y: 0, width: 1800, height: 1000)
private let tileA = CGRect(x: 800, y: 930, width: 64, height: 70)
private let tileB = CGRect(x: 880, y: 930, width: 64, height: 70)

@Suite struct DockPreviewGeometryTests {
    @Test func orientationIsInferredFromTheReservedStrip() {
        #expect(DockOrientation.infer(WndDisplay(id: 1, frame: bounds, visible: CGRect(x: 0, y: 24, width: 1800, height: 900))) == .bottom)
        #expect(DockOrientation.infer(WndDisplay(id: 1, frame: bounds, visible: CGRect(x: 80, y: 24, width: 1720, height: 976))) == .left)
        #expect(DockOrientation.infer(WndDisplay(id: 1, frame: bounds, visible: CGRect(x: 0, y: 24, width: 1720, height: 976))) == .right)
        #expect(DockOrientation.infer(WndDisplay(id: 1, frame: bounds, visible: CGRect(x: 0, y: 24, width: 1800, height: 976))) == .bottom)
    }

    @Test func bottomDockPutsThePanelCentredAboveTheTile() {
        let f = DockPreviewPlacement.frame(panel: CGSize(width: 400, height: 200), tile: tileA, orientation: .bottom, bounds: bounds)
        #expect(f.midX == tileA.midX && f.maxY == tileA.minY - DockPreviewPlacement.gap && f.size == CGSize(width: 400, height: 200))
    }

    @Test func leftAndRightDocksPutThePanelBesideTheTile() {
        let tile = CGRect(x: 0, y: 400, width: 70, height: 64)
        let l = DockPreviewPlacement.frame(panel: CGSize(width: 300, height: 200), tile: tile, orientation: .left, bounds: bounds)
        #expect(l.minX == tile.maxX + DockPreviewPlacement.gap && abs(l.midY - tile.midY) <= 1)
        let rt = CGRect(x: 1730, y: 400, width: 70, height: 64)
        let r = DockPreviewPlacement.frame(panel: CGSize(width: 300, height: 200), tile: rt, orientation: .right, bounds: bounds)
        #expect(r.maxX == rt.minX - DockPreviewPlacement.gap)
    }

    @Test func panelIsClampedInsideTheDisplayHorizontally() {
        let edge = CGRect(x: 0, y: 930, width: 64, height: 70)
        let f = DockPreviewPlacement.frame(panel: CGSize(width: 600, height: 200), tile: edge, orientation: .bottom, bounds: bounds)
        #expect(f.minX == bounds.minX + DockPreviewPlacement.margin)
        let far = CGRect(x: 1736, y: 930, width: 64, height: 70)
        let g = DockPreviewPlacement.frame(panel: CGSize(width: 600, height: 200), tile: far, orientation: .bottom, bounds: bounds)
        #expect(g.maxX == bounds.maxX - DockPreviewPlacement.margin)
    }

    @Test func oversizedPanelShrinksToTheDisplay() {
        let f = DockPreviewPlacement.frame(panel: CGSize(width: 5000, height: 5000), tile: tileA, orientation: .bottom, bounds: bounds)
        #expect(bounds.contains(f))
    }

    @Test func secondDisplayWithNegativeOriginWorks() {
        let b = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let tile = CGRect(x: -1000, y: 1010, width: 64, height: 70)
        let f = DockPreviewPlacement.frame(panel: CGSize(width: 400, height: 200), tile: tile, orientation: .bottom, bounds: b)
        #expect(b.contains(f) && abs(f.midX - tile.midX) <= 1)
    }

    @Test func corridorCoversTileGapAndPanel() {
        let panel = CGRect(x: 600, y: 720, width: 400, height: 200)
        #expect(DockPreviewPlacement.corridorContains(CGPoint(x: 830, y: 960), tile: tileA, panel: panel))
        #expect(DockPreviewPlacement.corridorContains(CGPoint(x: 700, y: 800), tile: tileA, panel: panel))
        #expect(DockPreviewPlacement.corridorContains(CGPoint(x: 830, y: 925), tile: tileA, panel: panel))
        #expect(!DockPreviewPlacement.corridorContains(CGPoint(x: 100, y: 960), tile: tileA, panel: panel))
        #expect(!DockPreviewPlacement.corridorContains(CGPoint(x: 1500, y: 400), tile: tileA, panel: panel))
    }

    @Test func closeActionFollowsTheSetting() {
        #expect(DockCloseAction.decide(quitAppOnClose: true) == .quitApp && DockCloseAction.decide(quitAppOnClose: false) == .closeWindow)
    }
}

private struct DockRig {
    let e: DockPreviewEngine
    let driver: SwcDockDriver
    let src: SwcSource
    let act: SwcActor
    let panel: SwcDockPanel
    let timers: WndTimers
    let box: WndBox<DockPreviewSettings>
    let order: WindowUseOrder
}

private func dockRig(windows: [SwitchWindow]? = nil, edit: (inout DockPreviewSettings) -> Void = { _ in }, trusted: Bool = true) -> DockRig {
    let w = windows ?? [SwcFix.win(1, pid: 10, title: "Один"), SwcFix.win(2, pid: 10, title: "Два"), SwcFix.win(3, pid: 11, title: "Чужое")]
    let src = SwcSource(windows: w, apps: [SwcFix.app(10), SwcFix.app(11)], front: 11)
    let d = SwcDockDriver()
    d.tiles = [(tileA, DockTileInfo(pid: 10, bundleID: "com.test.app10", frame: tileA)), (tileB, DockTileInfo(pid: 11, bundleID: "com.test.app11", frame: tileB))]
    var s = DockPreviewSettings()
    s.openDelayMs = 250
    s.closeDelayMs = 300
    edit(&s)
    let box = WndBox(s)
    let act = SwcActor()
    let panel = SwcDockPanel()
    let timers = WndTimers()
    let order = WindowUseOrder()
    let e = DockPreviewEngine(driver: d, source: src, actor: act, panel: panel, timers: timers, order: order, settings: { box.value }, ownPID: 1, trusted: { trusted })
    return DockRig(e: e, driver: d, src: src, act: act, panel: panel, timers: timers, box: box, order: order)
}

private let overA = CGPoint(x: 830, y: 960)
private let overB = CGPoint(x: 910, y: 960)
private let nowhere = CGPoint(x: 100, y: 500)

@Suite struct DockPreviewEngineTests {
    @Test func hoveringATileOpensThePanelAfterTheDelay() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        #expect(r.e.phase == .pending(DockTileInfo(pid: 10, bundleID: "com.test.app10", frame: tileA)) && r.panel.presented.isEmpty && r.timers.active == 1)
        r.timers.fireAll()
        #expect(r.e.isShown && r.panel.presented.count == 1 && r.panel.presented[0].entries.count == 2)
        #expect(r.panel.presented[0].entries.allSatisfy { $0.pid == 10 })
    }

    @Test func zeroDelayOpensImmediately() {
        let r = dockRig { $0.openDelayMs = 0 }
        _ = r.e.pointerMoved(overA, time: 1)
        #expect(r.e.isShown && r.timers.items.isEmpty)
    }

    @Test func leavingBeforeTheDelayCancelsTheOpening() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        _ = r.e.pointerMoved(nowhere, time: 2)
        r.timers.fireAll()
        #expect(r.e.phase == .idle && r.panel.presented.isEmpty)
    }

    @Test func untrustedAccessMeansNoPanel() {
        let r = dockRig(trusted: false)
        _ = r.e.pointerMoved(overA, time: 1)
        #expect(r.e.phase == .idle && r.driver.calls == 0)
    }

    @Test func appsWithoutWindowsShowNothing() {
        let r = dockRig(windows: [SwcFix.win(3, pid: 11)])
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        #expect(r.e.phase == .idle && r.panel.presented.isEmpty)
    }

    @Test func exceptionsAndOurOwnTileAreSkipped() {
        let r = dockRig { $0.exceptions = AppExceptionList(["com.test.app10"]) }
        _ = r.e.pointerMoved(overA, time: 1)
        #expect(r.e.phase == .idle)
        let own = dockRig()
        own.driver.tiles = [(tileA, DockTileInfo(pid: 1, bundleID: "me", frame: tileA))]
        _ = own.e.pointerMoved(overA, time: 1)
        #expect(own.e.phase == .idle)
    }

    @Test func leavingAfterTheOpenSchedulesTheCloseWithItsOwnDelay() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        _ = r.e.pointerMoved(nowhere, time: 2)
        #expect(r.e.isShown && r.timers.active == 1 && r.timers.items.last?.delay == 0.3)
        r.timers.fireAll()
        #expect(!r.e.isShown && r.panel.dismissed == 1)
    }

    @Test func movingTowardsThePanelKeepsItOpen() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        _ = r.e.pointerMoved(nowhere, time: 2)
        let inside = CGPoint(x: r.e.panelFrame.midX, y: r.e.panelFrame.midY)
        _ = r.e.pointerMoved(inside, time: 2.1)
        r.timers.fireAll()
        #expect(r.e.isShown && r.panel.dismissed == 0)
    }

    @Test func theGapBetweenTileAndPanelIsSafe() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        let gap = CGPoint(x: tileA.midX, y: r.e.panelFrame.maxY + 4)
        _ = r.e.pointerMoved(gap, time: 1.5)
        r.timers.fireAll()
        #expect(r.e.isShown)
    }

    @Test func hoveringAnotherTileSwitchesQuickly() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        _ = r.e.pointerMoved(overB, time: 2)
        #expect(r.timers.items.last?.delay == DockPreviewEngine.switchDelay && r.e.isShown)
        r.timers.fireAll()
        #expect(r.panel.presented.count == 2 && r.panel.presented[1].tile.pid == 11)
    }

    @Test func throttlingSkipsProbesOfAlmostTheSamePoint() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        _ = r.e.pointerMoved(CGPoint(x: overA.x + 1, y: overA.y), time: 1.005)
        #expect(r.driver.calls == 1)
        _ = r.e.pointerMoved(CGPoint(x: overA.x + 20, y: overA.y), time: 1.006)
        #expect(r.driver.calls == 2)
    }

    @Test func clickOnTheDockHidesAndSuppressesReopening() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        #expect(r.e.mouseDown(at: overA, time: 2) == .pass)
        #expect(!r.e.isShown)
        _ = r.e.pointerMoved(overA, time: 2.2)
        #expect(r.e.phase == .idle)
        _ = r.e.pointerMoved(CGPoint(x: overA.x + 3, y: overA.y), time: 2.6)
        #expect(r.e.phase != .idle)
    }

    @Test func clickInsideThePanelKeepsItOpen() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        _ = r.e.mouseDown(at: CGPoint(x: r.e.panelFrame.midX, y: r.e.panelFrame.midY), time: 2)
        #expect(r.e.isShown)
    }

    @Test func clickWhilePendingCancelsTheOpening() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        _ = r.e.mouseDown(at: overA, time: 1.1)
        r.timers.fireAll()
        #expect(r.e.phase == .idle && r.panel.presented.isEmpty)
    }

    @Test func focusActivatesTheWindowTouchesTheOrderAndHides() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.focus(id: .window(2))
        #expect(r.act.activated.map(\.id) == [.window(2)] && !r.e.isShown && r.order.stamp(ofWindow: 2) != nil)
    }

    @Test func closeRemovesTheCardAndKeepsThePanel() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.close(id: .window(1))
        #expect(r.act.closed.map(\.id) == [.window(1)] && r.e.cards.map(\.id) == [.window(2)] && r.e.isShown && r.panel.updates.last?.entries.count == 1)
    }

    @Test func closingTheLastCardHidesThePanel() {
        let r = dockRig(windows: [SwcFix.win(1, pid: 10)])
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.close(id: .window(1))
        #expect(!r.e.isShown && r.panel.dismissed == 1)
    }

    @Test func quitOnCloseQuitsTheWholeApp() {
        let r = dockRig { $0.quitAppOnClose = true }
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.close(id: .window(1))
        #expect(r.act.quit == [10] && r.act.closed.isEmpty && !r.e.isShown)
    }

    @Test func aRefusedCloseLeavesTheCard() {
        let r = dockRig()
        r.act.closeResult = false
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.close(id: .window(1))
        #expect(r.e.cards.count == 2)
    }

    @Test func minimizeTogglesTheCard() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.minimize(id: .window(1))
        #expect(r.act.minimized.map(\.1) == [true] && r.e.cards.first?.isMinimized == true)
    }

    @Test func placingMovesTheWindowAndHidesThePanel() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.place(id: .window(2), .nextDisplay)
        #expect(r.act.placed.map(\.1) == [.nextDisplay] && !r.e.isShown)
    }

    @Test func aFailedPlacementKeepsThePanel() {
        let r = dockRig()
        r.act.placeResult = false
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.place(id: .window(2), .leftHalf)
        #expect(r.e.isShown)
    }

    @Test func orderSettingDecidesTheCardSequence() {
        let w = [SwcFix.win(1, pid: 10, id: 50), SwcFix.win(2, pid: 10, id: 20), SwcFix.win(3, pid: 10, id: 30)]
        let created = dockRig(windows: w) { $0.order = .creation }
        _ = created.e.pointerMoved(overA, time: 1)
        created.timers.fireAll()
        #expect(created.e.cards.map(\.id) == [.window(2), .window(3), .window(1)])
        let used = dockRig(windows: w)
        used.order.touch(window: 3, pid: 10)
        _ = used.e.pointerMoved(overA, time: 1)
        used.timers.fireAll()
        #expect(used.e.cards.first?.id == .window(3))
    }

    @Test func minimizedWindowsCanBeHiddenAndSpaceFilterApplies() {
        let w = [SwcFix.win(1, pid: 10), SwcFix.win(2, pid: 10, minimized: true), SwcFix.win(3, pid: 10, space: false)]
        let r = dockRig(windows: w) { $0.showMinimized = false; $0.currentSpaceOnly = true }
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        #expect(r.e.cards.map(\.id) == [.window(1)])
    }

    @Test func panelStateCarriesTheAppearanceSettings() {
        let r = dockRig { $0.opacityPercent = 60; $0.showTitles = false; $0.quitAppOnClose = true; $0.middleClickCloses = false; $0.previewSize = .large }
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        let s = r.panel.presented[0]
        #expect(abs(s.opacity - 0.6) < 0.001 && !s.showTitles && s.closeQuitsApp && !s.middleClickCloses && s.metrics.thumb.width == PreviewSize.large.thumbWidth)
        #expect(bounds.contains(s.frame) || s.frame.minY >= 0)
    }

    @Test func freshSnapshotUpdatesAnOpenPanel() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        var s = r.src.snap
        s.windows.append(SwcFix.win(9, pid: 10, title: "Новое"))
        r.src.completeRefresh(s)
        #expect(r.e.cards.count == 3 && r.panel.updates.last?.entries.count == 3)
    }

    @Test func resetDismissesAndClearsState() {
        let r = dockRig()
        _ = r.e.pointerMoved(overA, time: 1)
        r.timers.fireAll()
        r.e.reset()
        #expect(r.e.phase == .idle && r.e.cards.isEmpty && r.panel.dismissed == 1)
    }

    @Test func stageSubscribesAndForwardsMovesAndClicks() {
        let r = dockRig()
        let (hub, be) = actHub()
        let st = DockPreviewStage(hub: hub, engine: r.e)
        st.start()
        st.start()
        #expect(st.isRunning && hub.subscriberCount == 1)
        let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: overA, mouseButton: .left)!
        #expect(be.fire(.mouseMoved, mv) == .pass)
        #expect(r.e.phase != .idle)
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: overA, mouseButton: .left)!
        #expect(be.fire(.leftMouseDown, click) == .pass && r.e.phase == .idle)
        st.stop()
        #expect(hub.subscriberCount == 0)
    }
}
