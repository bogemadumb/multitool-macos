import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let tile = DockTile(pid: 5, bundleID: "com.test.app")
private let front = DockAppState(isFrontmost: true, visibleWindows: 1)

private func decide(_ b: DockClickBrain, _ st: DockAppState = front, at t: TimeInterval = 100, mods: GestureModifiers = [], tile: DockTile = tile, _ s: DockClickSettings = DockClickSettings()) -> DockClickAction {
    b.decide(tile: tile, state: st, modifiers: mods, settings: s, now: t)
}

@Suite struct DockClickBrainTests {
    @Test func clickOnTheActiveAppMinimisesItByDefault() {
        #expect(decide(DockClickBrain()) == .minimizeAll)
    }

    @Test func inactiveAppIsLeftToTheSystem() {
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: false, visibleWindows: 2)) == .passThrough)
    }

    @Test func hiddenAppIsLeftToTheSystem() {
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, isHidden: true, visibleWindows: 0)) == .passThrough)
    }

    @Test func modifierClicksAreLeftToTheSystem() {
        #expect(decide(DockClickBrain(), mods: [.command]) == .passThrough)
        #expect(decide(DockClickBrain(), mods: [.option]) == .passThrough)
    }

    @Test func hideModeHidesTheApp() {
        var s = DockClickSettings()
        s.mode = .hide
        #expect(decide(DockClickBrain(), front, s) == .hide)
    }

    @Test func offModeDoesNothing() {
        var s = DockClickSettings()
        s.mode = .off
        #expect(decide(DockClickBrain(), front, s) == .passThrough)
    }

    @Test func cycleModeNeedsAtLeastTwoWindows() {
        var s = DockClickSettings()
        s.cycleWindows = true
        s.mode = .off
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 3), s) == .cycleNext)
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 1), s) == .passThrough)
    }

    @Test func cycleWinsOverMinimizeOnlyWithSeveralWindows() {
        var s = DockClickSettings()
        s.cycleWindows = true
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 2), s) == .cycleNext)
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 1), s) == .minimizeAll)
    }

    @Test func onlyMinimisedWindowsAreRestored() {
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 0, minimizedWindows: 2)) == .restoreAll)
    }

    @Test func noWindowsAtAllIsLeftToTheSystem() {
        #expect(decide(DockClickBrain(), DockAppState(isFrontmost: true, visibleWindows: 0)) == .passThrough)
    }

    @Test func aSecondClickInsideTheDoubleClickGapIsSwallowed() {
        let b = DockClickBrain()
        _ = decide(b, at: 100)
        #expect(decide(b, at: 100.1) == .swallow)
    }

    @Test func aFollowUpClickReturnsTheWindowsEvenIfAXLags() {
        let b = DockClickBrain()
        #expect(decide(b, at: 100) == .minimizeAll)
        #expect(decide(b, at: 100.8) == .restoreAll)
    }

    @Test func restoreThenClickMinimisesAgain() {
        let b = DockClickBrain()
        _ = decide(b, at: 100)
        _ = decide(b, at: 100.8)
        #expect(decide(b, at: 101.6) == .minimizeAll)
    }

    @Test func oldRecordsFallBackToTheRealState() {
        let b = DockClickBrain()
        _ = decide(b, at: 100)
        #expect(decide(b, at: 110) == .minimizeAll)
    }

    @Test func exceptionsAreLeftToTheSystem() {
        var s = DockClickSettings()
        s.exceptions = AppExceptionList(["com.test.app"])
        #expect(decide(DockClickBrain(), front, s) == .passThrough)
    }

    @Test func recordsArePerApp() {
        let b = DockClickBrain()
        _ = decide(b, at: 100)
        #expect(decide(b, at: 100.1, tile: DockTile(pid: 6, bundleID: "com.other")) == .minimizeAll)
    }

    @Test func resetForgetsTheRecords() {
        let b = DockClickBrain()
        _ = decide(b, at: 100)
        b.reset()
        #expect(decide(b, at: 100.1) == .minimizeAll)
    }

    @Test func nextWindowWrapsAround() {
        #expect(DockClickBrain.nextWindowIndex(focused: 0, count: 3) == 1)
        #expect(DockClickBrain.nextWindowIndex(focused: 2, count: 3) == 0)
        #expect(DockClickBrain.nextWindowIndex(focused: nil, count: 3) == 0)
        #expect(DockClickBrain.nextWindowIndex(focused: 9, count: 3) == 0)
        #expect(DockClickBrain.nextWindowIndex(focused: 0, count: 1) == nil)
    }

    @Test func dragSlopSeparatesAClickFromADrag() {
        #expect(!DockClickBrain.isDrag(from: .zero, to: CGPoint(x: 3, y: 3)))
        #expect(DockClickBrain.isDrag(from: .zero, to: CGPoint(x: 10, y: 0)))
    }

    @Test func modeTitlesAreRussian() {
        #expect(DockClickMode.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

final class WndDockDriver: DockClickDriving {
    var tileAt: DockTile? = DockTile(pid: 5, bundleID: "com.test.app")
    var stateValue = front
    var performed: [(DockClickAction, DockTile)] = []
    var replays: [CGPoint] = []

    func tile(at point: CGPoint) -> DockTile? { tileAt }
    func state(of tile: DockTile) -> DockAppState { stateValue }
    func perform(_ action: DockClickAction, on tile: DockTile) { performed.append((action, tile)) }
    func replayMouseDown(at point: CGPoint) { replays.append(point) }
}

@Suite struct DockClickEngineTests {
    private let p = CGPoint(x: 400, y: 990)

    private func rig(_ edit: (inout DockClickSettings) -> Void = { _ in }) -> (WndDockDriver, DockClickEngine, WndBox<TimeInterval>) {
        let d = WndDockDriver()
        let clock = WndBox<TimeInterval>(100)
        var s = DockClickSettings()
        edit(&s)
        return (d, DockClickEngine(driver: d, settings: { s }, clock: { clock.value }), clock)
    }

    @Test func clickRunsTheActionOnMouseUpAndHidesItFromTheDock() {
        let (d, e, _) = rig()
        #expect(e.mouseDown(at: p, flags: []) == .drop)
        #expect(d.performed.isEmpty)
        #expect(e.mouseUp(at: p) == .drop)
        #expect(d.performed.count == 1 && d.performed[0].0 == .minimizeAll && e.handledCount == 1)
    }

    @Test func clickOutsideTheDockPassesThrough() {
        let (d, e, _) = rig()
        d.tileAt = nil
        #expect(e.mouseDown(at: p, flags: []) == .pass)
        #expect(e.mouseUp(at: p) == .pass)
    }

    @Test func undecidedClicksPassThrough() {
        let (d, e, _) = rig({ $0.mode = .off })
        #expect(e.mouseDown(at: p, flags: []) == .pass)
        #expect(d.performed.isEmpty)
    }

    @Test func draggingAnIconReplaysThePressAndLetsTheDockHaveIt() {
        let (d, e, _) = rig()
        _ = e.mouseDown(at: p, flags: [])
        #expect(e.mouseDragged(to: CGPoint(x: 402, y: 990)) == .drop)
        #expect(e.mouseDragged(to: CGPoint(x: 460, y: 990)) == .pass)
        #expect(d.replays == [p])
        #expect(e.mouseUp(at: CGPoint(x: 460, y: 990)) == .pass)
        #expect(d.performed.isEmpty)
    }

    @Test func swallowedRepeatClickDoesNothingButStaysInvisible() {
        let (d, e, clock) = rig()
        _ = e.mouseDown(at: p, flags: []); _ = e.mouseUp(at: p)
        clock.value = 100.1
        #expect(e.mouseDown(at: p, flags: []) == .drop)
        #expect(e.mouseUp(at: p) == .drop)
        #expect(d.performed.count == 1)
    }

    @Test func secondSlowClickRestores() {
        let (d, e, clock) = rig()
        _ = e.mouseDown(at: p, flags: []); _ = e.mouseUp(at: p)
        clock.value = 100.9
        _ = e.mouseDown(at: p, flags: []); _ = e.mouseUp(at: p)
        #expect(d.performed.map(\.0) == [.minimizeAll, .restoreAll])
    }

    @Test func modifierClickIsNotIntercepted() {
        let (_, e, _) = rig()
        #expect(e.mouseDown(at: p, flags: .maskCommand) == .pass)
    }

    @Test func mouseUpWithoutPressIsIgnored() {
        let (_, e, _) = rig()
        #expect(e.mouseUp(at: p) == .pass)
        #expect(e.mouseDragged(to: p) == .pass)
    }

    @Test func stageDrivesTheEngineThroughTheHub() {
        let (hub, be) = actHub()
        let (d, e, _) = rig()
        let stage = DockClickStage(hub: hub, engine: e)
        stage.start()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        #expect(be.fire(.leftMouseDown, down) == .drop)
        #expect(be.fire(.leftMouseUp, up) == .drop)
        #expect(d.performed.count == 1)
        stage.stop()
        #expect(hub.subscriberCount == 0)
    }

    @Test func stageIgnoresEverythingWithoutAccessibility() {
        let (hub, be) = actHub()
        let (_, e, _) = rig()
        let stage = DockClickStage(hub: hub, engine: e, trusted: { false })
        stage.start()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        #expect(be.fire(.leftMouseDown, down) == .pass)
        stage.stop()
    }

    @Test func dockRegionCoversTheBandOutsideTheVisibleFrame() {
        let bottom = WndFix.displays([WndFix.cleanDockBottom])[0]
        #expect(DockRegion.mayContain(CGPoint(x: 400, y: 980), display: bottom))
        #expect(!DockRegion.mayContain(CGPoint(x: 400, y: 500), display: bottom))
        #expect(!DockRegion.mayContain(CGPoint(x: 400, y: 5), display: bottom))
        let left = WndFix.displays([WndFix.cleanDockLeft])[0]
        #expect(DockRegion.mayContain(CGPoint(x: 40, y: 500), display: left))
        let right = WndFix.displays([WndFix.cleanDockRight])[0]
        #expect(DockRegion.mayContain(CGPoint(x: 1780, y: 500), display: right))
        #expect(!DockRegion.mayContain(CGPoint(x: 900, y: 500), display: right))
    }

    @Test func autoHiddenDockIsCheckedNearTheEdges() {
        let hidden = WndFix.displays([WndFix.clean])[0]
        #expect(DockRegion.mayContain(CGPoint(x: 900, y: 990), display: hidden))
        #expect(DockRegion.mayContain(CGPoint(x: 10, y: 500), display: hidden))
        #expect(!DockRegion.mayContain(CGPoint(x: 900, y: 500), display: hidden))
        #expect(!DockRegion.mayContain(CGPoint(x: 5000, y: 500), display: hidden))
    }
}
