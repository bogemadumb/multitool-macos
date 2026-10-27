import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let start = CGRect(x: 300, y: 200, width: 700, height: 500)

private func setup(_ screens: [WndScreen] = [WndFix.clean], settings: (inout WindowLayoutSettings) -> Void = { _ in }, configure: (inout WndFakeDriver.Win) -> Void = { _ in }) -> (WndFakeDriver, WindowLayoutEngine, WndBox<WindowLayoutSettings>) {
    let d = WndFakeDriver(screens: screens)
    d.add(1, start, configure: configure)
    let s = wndSettings(settings)
    return (d, wndLayoutEngine(d, s), s)
}

@Suite struct WindowLayoutEnginePlacementTests {
    @Test func leftHalfMovesAndResizesTheFocusedWindow() {
        let (d, e, _) = setup()
        #expect(e.perform(.leftHalf) == .applied(.leftHalf, CGRect(x: 0, y: 24, width: 900, height: 976)))
        #expect(d.frameOf(1) == CGRect(x: 0, y: 24, width: 900, height: 976))
    }

    @Test func noFocusedWindowIsReported() {
        let (d, e, _) = setup()
        d.focused = nil
        #expect(e.perform(.leftHalf) == .noWindow)
    }

    @Test func unmanageableWindowIsLeftAlone() {
        let (d, e, _) = setup(configure: { $0.manageable = false })
        #expect(e.perform(.maximize) == .notManageable)
        #expect(d.setCalls.isEmpty)
    }

    @Test func ignoredApplicationIsSkipped() {
        let (d, e, _) = setup(settings: { $0.ignoredApps = AppExceptionList(["com.test.app"]) })
        #expect(e.perform(.maximize) == .ignoredApp)
        #expect(d.setCalls.isEmpty)
    }

    @Test func wildcardIgnoreMatchesByPrefix() {
        let (_, e, _) = setup(settings: { $0.ignoredApps = AppExceptionList(["com.test.*"]) })
        #expect(e.perform(.maximize) == .ignoredApp)
    }

    @Test func failedSetIsReportedAndLeavesNoHistory() {
        let (d, e, _) = setup()
        d.failSet = true
        #expect(e.perform(.leftHalf) == .failed)
        #expect(e.history.originalCount(for: 1) == 0)
        d.failSet = false
        #expect(e.perform(.restore) == .nothingToRestore)
    }

    @Test func gapsFromSettingsAreApplied() {
        let (d, e, _) = setup(settings: { $0.gaps = WindowGaps(window: 20, screen: 10) })
        e.perform(.leftHalf)
        #expect(d.frameOf(1) == CGRect(x: 10, y: 34, width: 880, height: 956))
    }

    @Test func marginMaximizeUsesTheConfiguredPercent() {
        let (d, e, _) = setup(settings: { $0.marginPercent = 10 })
        e.perform(.marginMaximize)
        #expect(d.frameOf(1) == CGRect(x: 180, y: 122, width: 1440, height: 780))
    }

    @Test func centerKeepsTheWindowSize() {
        let (d, e, _) = setup()
        e.perform(.center)
        let f = d.frameOf(1)
        #expect(f.size == start.size)
        #expect(f.midX == 900)
    }

    @Test func customLayoutComesFromSettings() {
        let (d, e, _) = setup(settings: { $0.custom[2] = CustomLayout(name: "узкий", rect: FractionRect(x: 0.5, y: 0, w: 0.25, h: 1)) })
        e.perform(.custom2)
        #expect(d.frameOf(1) == CGRect(x: 900, y: 24, width: 450, height: 976))
    }

    @Test func undefinedCustomSlotFails() {
        let (_, e, _) = setup()
        #expect(e.perform(.custom5) == .failed)
    }

    @Test func layoutOnADisplayWithADockUsesTheVisibleFrame() {
        let (d, e, _) = setup([WndFix.cleanDockLeft])
        e.perform(.leftHalf)
        #expect(d.frameOf(1).minX == 80)
    }

    @Test func windowOnTheSecondDisplayStaysOnIt() {
        let (d, e, _) = setup([WndFix.clean, WndFix.rightExt])
        d.wins[1]!.frame = CGRect(x: 2500, y: 0, width: 600, height: 400)
        e.perform(.rightHalf)
        #expect(d.frameOf(1).maxX == 4360)
        #expect(d.frameOf(1).minX == 3080)
    }

    @Test func windowOnALeftNegativeDisplayIsPlacedThere() {
        let (d, e, _) = setup([WndFix.clean, WndFix.leftExt])
        d.wins[1]!.frame = CGRect(x: -1500, y: 0, width: 500, height: 400)
        e.perform(.maximize)
        #expect(d.frameOf(1) == WndFix.displays([WndFix.clean, WndFix.leftExt])[1].visible)
    }
}

@Suite struct WindowLayoutEngineMinSizeTests {
    @Test func aWindowWithAMinimumWidthIsGrownAndKeptOnScreen() {
        let (d, e, _) = setup(configure: { $0.minSize = CGSize(width: 800, height: 100) })
        e.perform(.rightQuarter)
        #expect(d.frameOf(1).maxX == 1800)
        #expect(d.frameOf(1).width == 800)
    }

    @Test func leftEdgeWindowGrowsToTheRight() {
        let (d, e, _) = setup(configure: { $0.minSize = CGSize(width: 800, height: 100) })
        e.perform(.leftQuarter)
        #expect(d.frameOf(1).minX == 0 && d.frameOf(1).width == 800)
    }

    @Test func fixedSizeWindowIsCentredInItsCell() {
        let (d, e, _) = setup(configure: { $0.resizable = false })
        e.perform(.leftHalf)
        #expect(d.frameOf(1) == CGRect(x: 100, y: 262, width: 700, height: 500))
    }

    @Test func windowWithAMaximumSizeIsCentredOnMaximize() {
        let (d, e, _) = setup(configure: { $0.maxSize = CGSize(width: 500, height: 400) })
        e.perform(.maximize)
        #expect(d.frameOf(1) == CGRect(x: 650, y: 312, width: 500, height: 400))
    }

    @Test func recordRemembersTheSettledFrameNotTheRequestedOne() {
        let (d, e, _) = setup(configure: { $0.minSize = CGSize(width: 800, height: 100) })
        e.perform(.leftQuarter)
        let rec = e.history.record(for: 1)!
        #expect(rec.requested.width == 450)
        #expect(rec.actual == d.frameOf(1))
    }
}

@Suite struct WindowLayoutEngineRestoreTests {
    @Test func restoreReturnsTheFrameBeforeTheFirstLayout() {
        let (d, e, _) = setup()
        e.perform(.leftHalf)
        #expect(e.perform(.restore) == .restored(start))
        #expect(d.frameOf(1) == start)
    }

    @Test func restoreAfterSeveralLayoutsReturnsTheOriginalNotTheIntermediate() {
        let (d, e, _) = setup()
        e.perform(.leftHalf)
        e.perform(.topRight)
        e.perform(.maximize)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
        #expect(e.perform(.restore) == .nothingToRestore)
    }

    @Test func restoreWithoutHistoryExplainsItself() {
        let (d, e, _) = setup()
        #expect(e.perform(.restore) == .nothingToRestore)
        #expect(d.setCalls.isEmpty)
    }

    @Test func aManualMoveInBetweenStartsANewRestorePoint() {
        let (d, e, _) = setup()
        e.perform(.leftHalf)
        let moved = CGRect(x: 600, y: 300, width: 500, height: 400)
        d.wins[1]!.frame = moved
        e.perform(.rightHalf)
        e.perform(.restore)
        #expect(d.frameOf(1) == moved)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
    }

    @Test func restoreClearsTheRepeatState() {
        let (_, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        e.perform(.leftHalf)
        e.perform(.restore)
        #expect(e.history.record(for: 1) == nil)
        #expect(e.perform(.leftHalf) == .applied(.leftHalf, CGRect(x: 0, y: 24, width: 900, height: 976)))
    }

    @Test func restoreBringsAnOffscreenOriginalBack() {
        let (d, e, _) = setup([WndFix.clean, WndFix.rightExt])
        d.wins[1]!.frame = CGRect(x: 2500, y: 0, width: 600, height: 400)
        e.perform(.leftHalf)
        d.screenList = WndFix.displays([WndFix.clean])
        e.perform(.restore)
        #expect(WndFix.displays([WndFix.clean])[0].visible.contains(d.frameOf(1)))
    }

    @Test func historyIsPerWindow() {
        let (d, e, _) = setup()
        d.add(2, CGRect(x: 50, y: 60, width: 300, height: 300))
        e.perform(.maximize)
        d.focused = 1
        e.perform(.leftHalf)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
        d.focused = 2
        e.perform(.restore)
        #expect(d.frameOf(2) == CGRect(x: 50, y: 60, width: 300, height: 300))
    }
}

@Suite struct WindowLayoutEngineRepeatTests {
    private func widths(_ e: WindowLayoutEngine, _ d: WndFakeDriver, _ a: WindowLayoutAction, times n: Int) -> [CGFloat] {
        (0..<n).map { _ in e.perform(a); return d.frameOf(1).width }
    }

    @Test func repeatedHalfCyclesThroughTwoThirdsAndThird() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        #expect(widths(e, d, .leftHalf, times: 5) == [900, 1200, 600, 900, 1200])
    }

    @Test func repeatedRightHalfKeepsTheRightEdge() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        for _ in 0..<3 { e.perform(.rightHalf) }
        #expect(d.frameOf(1).maxX == 1800 && d.frameOf(1).width == 600)
    }

    @Test func cycleDoesNothingSpecialWhenDisabled() {
        let (d, e, _) = setup()
        #expect(widths(e, d, .leftHalf, times: 3) == [900, 900, 900])
    }

    @Test func movingTheWindowByHandBreaksTheCycle() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        e.perform(.leftHalf)
        d.wins[1]!.frame = CGRect(x: 100, y: 100, width: 400, height: 400)
        e.perform(.leftHalf)
        #expect(d.frameOf(1).width == 900)
    }

    @Test func anotherActionInBetweenResetsTheCycle() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        e.perform(.leftHalf)
        e.perform(.topLeft)
        e.perform(.leftHalf)
        #expect(d.frameOf(1).width == 900)
    }

    @Test func topHalfCyclesVertically() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes })
        e.perform(.topHalf)
        e.perform(.topHalf)
        #expect(abs(d.frameOf(1).height - 651) <= 1)
    }

    @Test func cycleOnAMinSizeWindowStillAdvances() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .cycleSizes }, configure: { $0.minSize = CGSize(width: 1000, height: 100) })
        let w = widths(e, d, .leftHalf, times: 3)
        #expect(w == [1000, 1200, 1000])
    }

    @Test func crossDisplayMovesToTheNeighbourOnTheSecondPress() {
        let (d, e, _) = setup([WndFix.clean, WndFix.rightExt], settings: { $0.repeatMode = .crossDisplay })
        e.perform(.rightHalf)
        #expect(d.frameOf(1).minX == 900)
        e.perform(.rightHalf)
        let target = WndFix.displays([WndFix.clean, WndFix.rightExt])[1].visible
        #expect(d.frameOf(1) == CGRect(x: target.minX, y: target.minY, width: 1280, height: target.height))
    }

    @Test func crossDisplayWithoutANeighbourKeepsThePlacement() {
        let (d, e, _) = setup(settings: { $0.repeatMode = .crossDisplay })
        e.perform(.leftHalf)
        e.perform(.leftHalf)
        #expect(d.frameOf(1) == CGRect(x: 0, y: 24, width: 900, height: 976))
    }

    @Test func crossDisplayGoesLeftAcrossNegativeOrigins() {
        let (d, e, _) = setup([WndFix.clean, WndFix.leftExt], settings: { $0.repeatMode = .crossDisplay })
        e.perform(.leftHalf)
        e.perform(.leftHalf)
        let ext = WndFix.displays([WndFix.clean, WndFix.leftExt])[1].visible
        #expect(d.frameOf(1).maxX == ext.maxX)
        #expect(d.frameOf(1).minX == ext.midX)
    }
}

@Suite struct WindowLayoutEngineDisplayTests {
    private let two = [WndFix.clean, WndFix.rightExt]

    @Test func nextDisplayWithOneScreenSaysSo() {
        let (d, e, _) = setup()
        #expect(e.perform(.nextDisplay) == .singleDisplay)
        #expect(d.setCalls.isEmpty)
    }

    @Test func nextDisplayScalesTheWindowProportionally() {
        let (d, e, _) = setup(two)
        e.perform(.nextDisplay)
        let f = d.frameOf(1)
        let t = WndFix.displays(two)[1].visible
        #expect(t.contains(f))
        #expect(abs(f.width - 700.0 / 1800 * 2560) <= 1)
        #expect(abs(f.minX - (t.minX + 300.0 / 1800 * 2560)) <= 1)
    }

    @Test func nextThenPreviousComesBackToTheFirstDisplay() {
        let (d, e, _) = setup(two)
        e.perform(.nextDisplay)
        e.perform(.previousDisplay)
        #expect(WndFix.displays(two)[0].frame.contains(CGPoint(x: d.frameOf(1).midX, y: d.frameOf(1).midY)))
    }

    @Test func nextDisplayWrapsAroundThreeDisplays() {
        let (d, e, _) = setup([WndFix.clean, WndFix.leftExt, WndFix.rightExt])
        let disp = WndFix.displays([WndFix.clean, WndFix.leftExt, WndFix.rightExt])
        var xs: [Int] = []
        for _ in 0..<3 {
            e.perform(.nextDisplay)
            xs.append(DisplayMap.index(containing: d.frameOf(1), in: disp)!)
        }
        #expect(xs == [2, 1, 0])
    }

    @Test func aSnappedWindowKeepsItsLayoutOnTheNextDisplay() {
        let (d, e, _) = setup(two)
        e.perform(.leftHalf)
        e.perform(.nextDisplay)
        let t = WndFix.displays(two)[1].visible
        #expect(d.frameOf(1) == CGRect(x: t.minX, y: t.minY, width: 1280, height: t.height))
    }

    @Test func aMaximisedWindowFillsTheNextDisplay() {
        let (d, e, _) = setup(two)
        e.perform(.maximize)
        e.perform(.nextDisplay)
        #expect(d.frameOf(1) == WndFix.displays(two)[1].visible)
    }

    @Test func restoreAfterADisplayMoveGoesBackToTheOriginalDisplay() {
        let (d, e, _) = setup(two)
        e.perform(.nextDisplay)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
    }

    @Test func repeatedNextDisplayDoesNotStackRestorePoints() {
        let (_, e, _) = setup(two)
        e.perform(.nextDisplay)
        e.perform(.nextDisplay)
        e.perform(.nextDisplay)
        #expect(e.history.originalCount(for: 1) == 1)
    }

    @Test func nextDisplayRespectsGaps() {
        let (d, e, _) = setup(two, settings: { $0.gaps = WindowGaps(window: 0, screen: 20) })
        e.perform(.maximize)
        e.perform(.nextDisplay)
        let t = WndFix.displays(two)[1].visible
        #expect(d.frameOf(1) == t.insetBy(dx: 20, dy: 20))
    }
}

@Suite struct WindowLayoutEngineDropTests {
    @Test func placeUsesTheGivenDisplayAndRecordsTheDragStartAsOriginal() {
        let two = [WndFix.clean, WndFix.rightExt]
        let (d, e, _) = setup(two)
        d.wins[1]!.frame = CGRect(x: 2000, y: 100, width: 400, height: 300)
        let w = d.ref(1)
        #expect(e.place(.leftHalf, on: w, displayIndex: 1, reference: start).isSuccess)
        let t = WndFix.displays(two)[1].visible
        #expect(d.frameOf(1).minX == t.minX)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
    }

    @Test func droppingTwiceInARowKeepsTheFirstOriginal() {
        let (d, e, _) = setup()
        let w = d.ref(1)
        e.place(.leftHalf, on: w, displayIndex: 0, reference: start)
        let snapped = d.frameOf(1)
        d.wins[1]!.frame = snapped.offsetBy(dx: 40, dy: 30)
        e.place(.rightHalf, on: w, displayIndex: 0, reference: snapped)
        e.perform(.restore)
        #expect(d.frameOf(1) == start)
    }

    @Test func dropOnAnInvalidDisplayIsRejected() {
        let (d, e, _) = setup()
        #expect(e.place(.leftHalf, on: d.ref(1), displayIndex: 5, reference: start) == .noDisplay)
    }

    @Test func dropOnAnIgnoredAppIsRejected() {
        let (d, e, _) = setup(settings: { $0.ignoredApps = AppExceptionList(["com.test.app"]) })
        #expect(e.place(.leftHalf, on: d.ref(1), displayIndex: 0, reference: start) == .ignoredApp)
    }

    @Test func previewFrameMatchesTheFrameThatPlacementUses() {
        let (d, e, _) = setup(settings: { $0.gaps = WindowGaps(window: 10, screen: 6) })
        let pv = e.previewFrame(for: .rightHalf, at: CGPoint(x: 100, y: 100))!
        e.perform(.rightHalf)
        #expect(pv.frame == d.frameOf(1))
    }

    @Test func previewFrameFollowsThePointerDisplay() {
        let two = [WndFix.clean, WndFix.rightExt]
        let (_, e, _) = setup(two)
        let pv = e.previewFrame(for: .maximize, at: CGPoint(x: 3000, y: 100))!
        #expect(pv.frame == WndFix.displays(two)[1].visible)
    }

    @Test func forgetDropsTheWindowHistory() {
        let (d, e, _) = setup()
        e.perform(.leftHalf)
        e.forget(d.ref(1))
        #expect(e.perform(.restore) == .nothingToRestore)
    }

    @Test func outcomeMessagesAreInRussian() {
        #expect(WindowLayoutOutcome.nothingToRestore.message?.contains("возвращать") == true)
        #expect(WindowLayoutOutcome.singleDisplay.message != nil)
        #expect(WindowLayoutOutcome.applied(.leftHalf, .zero).message == nil)
    }
}
