import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let one = WndFix.displays([WndFix.clean])
private let twoRight = WndFix.displays([WndFix.clean, WndFix.rightExt])
private let twoLeft = WndFix.displays([WndFix.clean, WndFix.leftExt])

private func settings(_ edit: (inout WindowLayoutSettings) -> Void = { _ in }) -> WindowLayoutSettings {
    var s = WindowLayoutSettings()
    s.edge.enabled = true
    edit(&s)
    return s
}

private func target(_ x: CGFloat, _ y: CGFloat, displays: [WndDisplay] = one, velocity: CGVector = .zero, _ s: WindowLayoutSettings = settings()) -> SnapTarget? {
    SnapZoneResolver.resolve(at: CGPoint(x: x, y: y), displays: displays, velocity: velocity, settings: s)
}

@Suite struct SnapZoneHitTests {
    @Test func edgesOfTheScreen() {
        #expect(target(5, 500)?.zone == .left)
        #expect(target(1795, 500)?.zone == .right)
        #expect(target(900, 3)?.zone == .top)
        #expect(target(900, 997)?.zone == .bottom)
    }

    @Test func cornersAreResolvedFromBothDirections() {
        #expect(target(5, 5)?.zone == .topLeft)
        #expect(target(1795, 5)?.zone == .topRight)
        #expect(target(5, 995)?.zone == .bottomLeft)
        #expect(target(1795, 995)?.zone == .bottomRight)
        #expect(target(5, 100)?.zone == .topLeft)
        #expect(target(1795, 100)?.zone == .topRight)
        #expect(target(5, 900)?.zone == .bottomLeft)
        #expect(target(1795, 900)?.zone == .bottomRight)
    }

    @Test func middleOfTheScreenHasNoZone() {
        #expect(target(900, 500) == nil)
        #expect(target(30, 500) == nil)
    }

    @Test func pointerJustPastTheEdgeStillCounts() {
        #expect(target(-6, 500)?.zone == .left)
    }

    @Test func zoneDistanceIsConfigurable() {
        #expect(target(30, 500) == nil)
        #expect(target(30, 500, settings { $0.edge.distance = 40 })?.zone == .left)
        #expect(target(8, 500, settings { $0.edge.distance = 4 }) == nil)
    }

    @Test func distanceIsSanitized() {
        var s = settings { $0.edge.distance = 9999 }
        s = s.sanitized
        #expect(s.edge.distance == 40)
        #expect(settings { $0.edge.distance = -1 }.sanitized.edge.distance == 4)
    }

    @Test func cornerSizeScalesWithTheScreenWithinBounds() {
        let small = WndFix.displays([WndFix.screen(1, CGRect(x: 0, y: 0, width: 400, height: 300))])[0]
        #expect(SnapZoneResolver.horizontalCorner(for: small.frame) == 96)
        #expect(SnapZoneResolver.verticalCorner(for: small.frame) == 80)
        #expect(SnapZoneResolver.horizontalCorner(for: one[0].frame) == 180)
        #expect(SnapZoneResolver.verticalCorner(for: one[0].frame) == 160)
    }

    @Test func defaultActionsPerZone() {
        #expect(target(5, 500)?.action == .leftHalf)
        #expect(target(1795, 500)?.action == .rightHalf)
        #expect(target(900, 3)?.action == .maximize)
        #expect(target(900, 997)?.action == .bottomHalf)
        #expect(target(5, 5)?.action == .topLeft)
        #expect(target(1795, 995)?.action == .bottomRight)
    }

    @Test func targetFrameIsTheLayoutFrameOfTheVisibleArea() {
        #expect(target(5, 500)?.frame == CGRect(x: 0, y: 24, width: 900, height: 976))
        #expect(target(900, 3)?.frame == one[0].visible)
    }

    @Test func gapsShapeThePreviewFrame() {
        let t = target(5, 500, settings { $0.gaps = WindowGaps(window: 20, screen: 10) })
        #expect(t?.frame == CGRect(x: 10, y: 34, width: 880, height: 956))
    }

    @Test func disabledZoneProducesNothing() {
        let s = settings { $0.edge.disabledZones = [.left, .topLeft] }
        #expect(target(5, 500, s) == nil)
        #expect(target(5, 5, s) == nil)
        #expect(target(1795, 500, s)?.zone == .right)
    }

    @Test func secondDisplayTargetsItsOwnVisibleFrame() {
        let t = target(4355, 700, displays: twoRight)
        #expect(t?.displayIndex == 1)
        #expect(t?.zone == .right)
        #expect(t?.frame.maxX == 4360)
    }

    @Test func negativeOriginDisplayIsHitAtItsLeftEdge() {
        let t = target(-1915, 300, displays: twoLeft)
        #expect(t?.displayIndex == 1 && t?.zone == .left)
        #expect(t?.frame.minX == -1920)
    }

    @Test func wallEdgeCountsAtAnySpeed() {
        let t = target(4358, 500, displays: twoRight, velocity: CGVector(dx: 5000, dy: 0))
        #expect(t?.zone == .right)
    }

    @Test func seamBetweenDisplaysCountsOnlyWhenSlow() {
        #expect(target(1799, 500, displays: twoRight, velocity: CGVector(dx: 50, dy: 0)) != nil)
        #expect(target(1799, 500, displays: twoRight, velocity: CGVector(dx: 900, dy: 0)) == nil)
    }

    @Test func slidingAlongAnEdgeIsNotCrossingIt() {
        #expect(target(1799, 500, displays: twoRight, velocity: CGVector(dx: 0, dy: 3000)) != nil)
    }

    @Test func topEdgeAboveAnotherDisplayIsASeam() {
        let d = WndFix.displays([WndFix.clean, WndFix.aboveExt])
        #expect(target(900, 2, displays: d, velocity: CGVector(dx: 0, dy: -2000)) == nil)
        #expect(target(900, 2, displays: d, velocity: CGVector(dx: 0, dy: -10))?.zone == .top)
    }

    @Test func noDisplaysNoTarget() {
        #expect(target(0, 0, displays: []) == nil)
    }

    @Test func pointerFarFromEveryDisplayResolvesNothing() {
        #expect(target(99999, 99999) == nil)
    }
}

@Suite struct SnapZoneLayoutTests {
    @Test func defaultsHaveOnePartAndNoStorage() {
        let l = SnapZoneLayout()
        #expect(l.isDefault && l.storageValue == "")
        #expect(SnapZone.allCases.allSatisfy { l.actions(for: $0) == [$0.defaultAction] })
    }

    @Test func splitTopEdgeIntoThirdsPicksByPosition() {
        var s = settings()
        s.edge.layout.setPartCount(3, for: .top)
        #expect(target(300, 3, s)?.action == .leftThird)
        #expect(target(900, 3, s)?.action == .centerThird)
        #expect(target(1500, 3, s)?.action == .rightThird)
    }

    @Test func splitLeftEdgeIntoHalvesPicksByHeight() {
        var s = settings()
        s.edge.layout.setPartCount(2, for: .left)
        #expect(target(5, 250, s)?.action == .topHalf)
        #expect(target(5, 750, s)?.action == .bottomHalf)
    }

    @Test func cornersCannotBeSplit() {
        var l = SnapZoneLayout()
        l.setPartCount(2, for: .topLeft)
        #expect(l.actions(for: .topLeft).count == 1)
    }

    @Test func partCountIsLimited() {
        var l = SnapZoneLayout()
        l.setPartCount(9, for: .top)
        #expect(l.actions(for: .top).count == 1)
        l.setPartCount(4, for: .top)
        #expect(l.actions(for: .top) == [.leftQuarter, .leftMiddleQuarter, .rightMiddleQuarter, .rightQuarter])
    }

    @Test func goingBackToOnePartRestoresTheDefault() {
        var l = SnapZoneLayout()
        l.setPartCount(3, for: .bottom)
        l.setPartCount(1, for: .bottom)
        #expect(l.actions(for: .bottom) == [.bottomHalf] && l.isDefault)
    }

    @Test func changingAnActionKeepsTheOthers() {
        var l = SnapZoneLayout()
        l.setPartCount(2, for: .top)
        l.setAction(.centerThird, for: .top, part: 1)
        #expect(l.actions(for: .top) == [.leftHalf, .centerThird])
    }

    @Test func settingTheDefaultActionRemovesTheOverride() {
        var l = SnapZoneLayout()
        l.setAction(.maximize, for: .left, part: 0)
        #expect(!l.isDefault)
        l.setAction(.leftHalf, for: .left, part: 0)
        #expect(l.isDefault)
    }

    @Test func outOfRangePartIsIgnored() {
        var l = SnapZoneLayout()
        l.setAction(.maximize, for: .left, part: 3)
        #expect(l.isDefault)
    }

    @Test func nonPlacementActionsAreRefused() {
        var l = SnapZoneLayout()
        l.setAction(.restore, for: .left, part: 0)
        l.setAction(.nextDisplay, for: .left, part: 0)
        l.setAction(.center, for: .left, part: 0)
        #expect(l.isDefault)
    }

    @Test func storageRoundTrips() {
        var l = SnapZoneLayout()
        l.setPartCount(3, for: .top)
        l.setAction(.custom2, for: .topLeft, part: 0)
        l.setAction(.marginMaximize, for: .bottom, part: 0)
        let back = SnapZoneLayout(storageValue: l.storageValue)
        #expect(back == l)
        #expect(back.actions(for: .top) == [.leftThird, .centerThird, .rightThird])
    }

    @Test func badStorageEntriesAreDroppedIndividually() {
        let l = SnapZoneLayout(storageValue: "foo=leftHalf,top=banana,topLeft=leftHalf+rightHalf,left=restore,right=topHalf+bottomHalf,bottom=")
        #expect(l.actions(for: .right) == [.topHalf, .bottomHalf])
        #expect(l.actions(for: .top) == [.maximize])
        #expect(l.actions(for: .topLeft) == [.topLeft])
        #expect(l.actions(for: .left) == [.leftHalf])
    }

    @Test func tooManyPartsInStorageAreRejected() {
        let l = SnapZoneLayout(storageValue: "top=leftHalf+rightHalf+leftThird+rightThird+topHalf")
        #expect(l.isDefault)
    }

    @Test func nilStorageIsDefault() {
        #expect(SnapZoneLayout(storageValue: nil).isDefault)
    }

    @Test func alongFractionIsClamped() {
        var l = SnapZoneLayout()
        l.setPartCount(3, for: .top)
        #expect(l.action(for: .top, along: -4) == .leftThird)
        #expect(l.action(for: .top, along: 7) == .rightThird)
        #expect(l.action(for: .top, along: .nan) == .leftThird)
        #expect(l.action(for: .top, along: 1) == .rightThird)
    }

    @Test func resetClearsEverything() {
        var l = SnapZoneLayout()
        l.setPartCount(4, for: .left)
        l.reset()
        #expect(l.isDefault)
    }

    @Test func snapTargetsCoverPlacementsOnly() {
        let t = WindowLayoutAction.snapTargets
        #expect(t.contains(.maximize) && t.contains(.marginMaximize) && t.contains(.custom8) && t.contains(.sixthsProbe))
        #expect(!t.contains(.restore) && !t.contains(.center) && !t.contains(.nextDisplay) && !t.contains(.previousDisplay))
    }

    @Test func customLayoutOnAZoneResolvesToItsFraction() {
        var s = settings { $0.custom[1] = CustomLayout(name: "x", rect: FractionRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)) }
        s.edge.layout.setAction(.custom1, for: .left, part: 0)
        #expect(target(5, 500, s)?.frame == CGRect(x: 900, y: 512, width: 900, height: 488))
    }

    @Test func undefinedCustomLayoutOnAZoneGivesNoTarget() {
        var s = settings()
        s.edge.layout.setAction(.custom3, for: .left, part: 0)
        #expect(target(5, 500, s) == nil)
    }
}

private extension WindowLayoutAction {
    static var sixthsProbe: WindowLayoutAction { .bottomCenterSixth }
}

@Suite struct DragClassificationTests {
    private let f = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func nothingMovedYetWaits() {
        #expect(SnapZoneResolver.classify(initial: f, current: f, pointerStart: CGPoint(x: 200, y: 110), pointerNow: CGPoint(x: 230, y: 110)) == .waiting)
    }

    @Test func windowFollowingThePointerIsMoving() {
        let now = f.offsetBy(dx: 60, dy: 20)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 200, y: 110), pointerNow: CGPoint(x: 260, y: 130)) == .moving)
    }

    @Test func windowMovingWhilePointerStandsStillIsUnrelated() {
        let now = f.offsetBy(dx: 60, dy: 20)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 200, y: 110), pointerNow: CGPoint(x: 200, y: 110)) == .unrelated)
    }

    @Test func windowGoingTheOtherWayIsUnrelated() {
        let now = f.offsetBy(dx: -60, dy: 0)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 200, y: 110), pointerNow: CGPoint(x: 260, y: 110)) == .unrelated)
    }

    @Test func resizingFromTheRightEdgeIsRecognised() {
        let now = CGRect(x: 100, y: 100, width: 480, height: 300)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 500, y: 200), pointerNow: CGPoint(x: 580, y: 200)) == .resizing)
    }

    @Test func resizingFromTheTopLeftCornerIsRecognised() {
        let now = CGRect(x: 60, y: 60, width: 440, height: 340)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 100, y: 100), pointerNow: CGPoint(x: 60, y: 60)) == .resizing)
    }

    @Test func aTiledWindowThatShrinksWhileMovingIsStillAMove() {
        let now = CGRect(x: 150, y: 120, width: 300, height: 200)
        #expect(SnapZoneResolver.classify(initial: f, current: now, pointerStart: CGPoint(x: 200, y: 110), pointerNow: CGPoint(x: 250, y: 130)) == .moving)
    }

    @Test func resizeHandleDetection() {
        #expect(SnapZoneResolver.startsOnResizeHandle(CGPoint(x: 100, y: 200), frame: f))
        #expect(SnapZoneResolver.startsOnResizeHandle(CGPoint(x: 503, y: 403), frame: f))
        #expect(!SnapZoneResolver.startsOnResizeHandle(CGPoint(x: 300, y: 120), frame: f))
        #expect(!SnapZoneResolver.startsOnResizeHandle(CGPoint(x: 900, y: 900), frame: f))
    }

    @Test func trailVelocityIsMeasuredOverARecentWindow() {
        var t = PointerTrail()
        t.add(CGPoint(x: 0, y: 0), at: 1.00)
        t.add(CGPoint(x: 50, y: 0), at: 1.05)
        #expect(abs(t.velocity(at: 1.05).dx - 1000) < 1)
        #expect(t.velocity(at: 3).dx == 0)
    }

    @Test func trailNeedsTwoSamplesApart() {
        var t = PointerTrail()
        t.add(CGPoint(x: 0, y: 0), at: 1)
        #expect(t.velocity(at: 1) == .zero)
        t.add(CGPoint(x: 5, y: 5), at: 1.001)
        #expect(t.velocity(at: 1.001) == .zero)
    }

    @Test func systemTilingProbeTreatsMissingKeysAsEnabled() {
        #expect(SystemTilingProbe.isEnabled(valueFor: { _ in nil }))
        #expect(!SystemTilingProbe.isEnabled(valueFor: { _ in false }))
        #expect(SystemTilingProbe.isEnabled(valueFor: { $0 == "EnableTilingOptionAccelerator" }))
        #expect(!SystemTilingProbe.isEnabled(valueFor: { _ in nil }, displaysSpan: true))
    }
}

@Suite struct EdgeDragTrackerTests {
    private func rig(_ edit: (inout WindowLayoutSettings) -> Void = { _ in }, screens: [WndScreen] = [WndFix.clean], configure: (inout WndFakeDriver.Win) -> Void = { _ in }) -> (WndFakeDriver, EdgeDragTracker, WndPreview, WindowLayoutEngine, WndBox<WindowLayoutSettings>) {
        let d = WndFakeDriver(screens: screens)
        d.add(1, CGRect(x: 300, y: 200, width: 700, height: 500), configure: configure)
        d.windowUnderPointer = 1
        let s = wndSettings { $0.edge.enabled = true; edit(&$0) }
        let e = wndLayoutEngine(d, s)
        let p = WndPreview()
        return (d, EdgeDragTracker(driver: d, engine: e, preview: p) { s.value }, p, e, s)
    }

    private func drag(_ d: WndFakeDriver, _ t: EdgeDragTracker, from a: CGPoint, to b: CGPoint, steps: Int = 4) {
        let start = d.wins[1]!.frame
        t.mouseDown(at: a, time: 0)
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            d.wins[1]!.frame = start.offsetBy(dx: p.x - a.x, dy: p.y - a.y)
            t.mouseDragged(to: p, time: 0.1 * Double(i))
        }
    }

    @Test func droppingAtTheLeftEdgeSnapsToTheLeftHalf() {
        let (d, t, _, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 1)
        #expect(d.frameOf(1) == CGRect(x: 0, y: 24, width: 900, height: 976))
        #expect(t.snapCount == 1 && t.phase == .idle)
    }

    @Test func previewAppearsOnTheEdgeAndIsHiddenOnRelease() {
        let (d, t, p, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        #expect(p.visible && p.shown.last == CGRect(x: 0, y: 24, width: 900, height: 976))
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 1)
        #expect(!p.visible)
    }

    @Test func releasingInTheMiddleLeavesTheWindowWhereItIs() {
        let (d, t, p, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 800, y: 400))
        let dropped = d.frameOf(1)
        t.mouseUp(at: CGPoint(x: 800, y: 400), time: 1)
        #expect(d.frameOf(1) == dropped && p.shown.isEmpty && t.snapCount == 0)
    }

    @Test func pullingAwayFromTheEdgeHidesThePreviewAndCancelsTheSnap() {
        let (d, t, p, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        let start = d.wins[1]!.frame
        d.wins[1]!.frame = start.offsetBy(dx: 400, dy: 0)
        t.mouseDragged(to: CGPoint(x: 405, y: 500), time: 2)
        #expect(!p.visible)
        t.mouseUp(at: CGPoint(x: 405, y: 500), time: 2.1)
        #expect(t.snapCount == 0)
    }

    @Test func snapRemembersTheDragStartForRestore() {
        let (d, t, _, e, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 1)
        e.perform(.restore)
        #expect(d.frameOf(1) == CGRect(x: 300, y: 200, width: 700, height: 500))
    }

    @Test func topEdgeMaximises() {
        let (d, t, _, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 900, y: 2))
        t.mouseUp(at: CGPoint(x: 900, y: 2), time: 1)
        #expect(d.frameOf(1) == WndFix.displays([WndFix.clean])[0].visible)
    }

    @Test func dropOnTheSecondDisplayTilesThere() {
        let (d, t, _, _, _) = rig(screens: [WndFix.clean, WndFix.rightExt])
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 4358, y: 600))
        t.mouseUp(at: CGPoint(x: 4358, y: 600), time: 1)
        #expect(d.frameOf(1).maxX == 4360)
    }

    @Test func resizingAWindowNeverSnaps() {
        let (d, t, p, _, _) = rig()
        t.mouseDown(at: CGPoint(x: 1000, y: 400), time: 0)
        #expect(t.phase == .rejected)
        d.wins[1]!.frame = CGRect(x: 300, y: 200, width: 1500, height: 500)
        t.mouseDragged(to: CGPoint(x: 1795, y: 400), time: 0.1)
        t.mouseUp(at: CGPoint(x: 1795, y: 400), time: 0.2)
        #expect(t.snapCount == 0 && p.shown.isEmpty)
    }

    @Test func resizeDetectedByTheFrameChangeRejectsTheDrag() {
        let (d, t, p, _, _) = rig()
        t.mouseDown(at: CGPoint(x: 600, y: 300), time: 0)
        d.wins[1]!.frame = CGRect(x: 300, y: 200, width: 1500, height: 500)
        t.mouseDragged(to: CGPoint(x: 1795, y: 400), time: 0.1)
        #expect(t.phase == .rejected)
        t.mouseUp(at: CGPoint(x: 1795, y: 400), time: 0.2)
        #expect(t.snapCount == 0 && p.shown.isEmpty)
    }

    @Test func contentDragThatDoesNotMoveTheWindowNeverSnaps() {
        let (d, t, _, _, _) = rig()
        t.mouseDown(at: CGPoint(x: 600, y: 300), time: 0)
        t.mouseDragged(to: CGPoint(x: 5, y: 500), time: 0.1)
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 0.2)
        #expect(t.snapCount == 0)
        #expect(d.setCalls.isEmpty)
    }

    @Test func disabledFeatureTracksNothing() {
        let (d, t, _, _, _) = rig({ $0.edge.enabled = false })
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        #expect(t.phase == .idle)
        #expect(d.frameReads == 0)
    }

    @Test func ignoredAppsAreNotSnapped() {
        let (_, t, _, _, _) = rig({ $0.ignoredApps = AppExceptionList(["com.test.app"]) })
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        #expect(t.phase == .idle)
    }

    @Test func unmanageableWindowsAreIgnored() {
        let (_, t, _, _, _) = rig(configure: { $0.manageable = false })
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        #expect(t.phase == .idle)
    }

    @Test func mouseDownOverNoWindowStaysIdle() {
        let (d, t, _, _, _) = rig()
        d.windowUnderPointer = nil
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        #expect(t.phase == .idle)
    }

    @Test func frameReadsAreThrottled() {
        let (d, t, _, _, _) = rig()
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        let before = d.frameReads
        t.mouseDragged(to: CGPoint(x: 590, y: 210), time: 0.100)
        t.mouseDragged(to: CGPoint(x: 580, y: 210), time: 0.110)
        t.mouseDragged(to: CGPoint(x: 570, y: 210), time: 0.120)
        #expect(d.frameReads - before == 1)
    }

    @Test func previewCanBeSwitchedOffWhileSnappingStillWorks() {
        let (d, t, p, _, _) = rig({ $0.edge.showPreview = false })
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 1)
        #expect(p.shown.isEmpty && t.snapCount == 1)
    }

    @Test func resetHidesAVisiblePreview() {
        let (d, t, p, _, _) = rig()
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        t.reset()
        #expect(!p.visible && t.phase == .idle && t.target == nil)
    }

    @Test func mouseUpWithoutAMoveDoesNothing() {
        let (d, t, _, _, _) = rig()
        t.mouseDown(at: CGPoint(x: 600, y: 210), time: 0)
        t.mouseUp(at: CGPoint(x: 600, y: 210), time: 0.1)
        #expect(t.snapCount == 0 && d.setCalls.isEmpty)
    }

    @Test func customZoneLayoutIsUsedOnDrop() {
        let (d, t, _, _, _) = rig({ $0.edge.layout.setAction(.maximize, for: .left, part: 0) })
        drag(d, t, from: CGPoint(x: 600, y: 210), to: CGPoint(x: 5, y: 500))
        t.mouseUp(at: CGPoint(x: 5, y: 500), time: 1)
        #expect(d.frameOf(1) == WndFix.displays([WndFix.clean])[0].visible)
    }
}
