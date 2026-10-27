import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
private let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
private let ctrlOptShift: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]

@Suite struct GestureMathTests {
    @Test func movedShiftsByThePointerDelta() {
        let r = GestureMath.moved(frame, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 350, y: 280))
        #expect(r == CGRect(x: 150, y: 80, width: 600, height: 400))
    }

    @Test func cornersAndEdgesOfTheWindowPickResizeEdges() {
        func e(_ x: CGFloat, _ y: CGFloat) -> ResizeEdges { GestureMath.edges(at: CGPoint(x: x, y: y), in: frame) }
        #expect(e(110, 110) == [.left, .top])
        #expect(e(690, 110) == [.right, .top])
        #expect(e(110, 490) == [.left, .bottom])
        #expect(e(690, 490) == [.right, .bottom])
        #expect(e(400, 110) == [.top])
        #expect(e(400, 490) == [.bottom])
        #expect(e(110, 300) == [.left])
        #expect(e(690, 300) == [.right])
    }

    @Test func centreResizesFromTheNearestCorner() {
        #expect(GestureMath.edges(at: CGPoint(x: 380, y: 290), in: frame) == [.left, .top])
        #expect(GestureMath.edges(at: CGPoint(x: 420, y: 310), in: frame) == [.right, .bottom])
    }

    @Test func degenerateFrameResizesFromTheBottomRight() {
        #expect(GestureMath.edges(at: .zero, in: .zero) == [.right, .bottom])
    }

    @Test func resizingTheRightBottomCornerGrowsTheWindow() {
        let r = GestureMath.resized(frame, edges: [.right, .bottom], from: CGPoint(x: 700, y: 500), to: CGPoint(x: 760, y: 540))
        #expect(r == CGRect(x: 100, y: 100, width: 660, height: 440))
    }

    @Test func resizingTheLeftTopCornerMovesTheOrigin() {
        let r = GestureMath.resized(frame, edges: [.left, .top], from: CGPoint(x: 100, y: 100), to: CGPoint(x: 60, y: 70))
        #expect(r == CGRect(x: 60, y: 70, width: 640, height: 430))
    }

    @Test func minimumSizeStopsTheOppositeEdgeFromMoving() {
        let r = GestureMath.resized(frame, edges: [.left, .top], from: CGPoint(x: 100, y: 100), to: CGPoint(x: 9000, y: 9000))
        #expect(r.maxX == 700 && r.maxY == 500)
        #expect(r.width == GestureMath.minimumSide && r.height == GestureMath.minimumSide)
    }

    @Test func shrinkingFromTheRightKeepsTheLeftEdge() {
        let r = GestureMath.resized(frame, edges: [.right], from: CGPoint(x: 700, y: 300), to: CGPoint(x: -5000, y: 300))
        #expect(r.minX == 100 && r.width == GestureMath.minimumSide)
    }

    @Test func modifiersMustMatchExactly() {
        #expect(GestureMath.modifiersMatch(ctrlOpt, required: [.control, .option]))
        #expect(!GestureMath.modifiersMatch(ctrlOptShift, required: [.control, .option]))
        #expect(!GestureMath.modifiersMatch([.maskControl], required: [.control, .option]))
        #expect(!GestureMath.modifiersMatch([], required: []))
    }

    @Test func gestureModifiersFromFlags() {
        #expect(GestureModifiers(flags: [.maskCommand, .maskShift]) == [.command, .shift])
        #expect(GestureModifiers(flags: []).isEmpty)
        #expect(GestureModifiers(flags: ctrlOptShift).glyphs == "⌃⌥⇧")
    }

    @Test func gestureModifiersParsing() {
        #expect(GestureModifiers.parse("3") == [.control, .option])
        #expect(GestureModifiers.parse("99") == nil)
        #expect(GestureModifiers.parse("x") == nil)
        #expect(GestureModifiers.parse(nil) == nil)
    }
}

@Suite struct ModifierDragSessionTests {
    private func rig(_ edit: (inout GestureSettings) -> Void = { _ in }) -> (WndFakeDriver, GestureSettings) {
        let d = WndFakeDriver()
        d.add(1, frame)
        d.windowUnderPointer = 1
        var g = GestureSettings()
        g.enabled = true
        edit(&g)
        return (d, g)
    }

    @Test func moveGestureDragsTheWholeWindow() {
        let (d, g) = rig()
        let s = ModifierDragSession(driver: d, at: CGPoint(x: 300, y: 300), flags: ctrlOpt, settings: g, raise: false)!
        #expect(s.kind == .move)
        s.update(to: CGPoint(x: 340, y: 330))
        #expect(d.frameOf(1) == CGRect(x: 140, y: 130, width: 600, height: 400))
    }

    @Test func resizeGestureUsesTheExtraModifier() {
        let (d, g) = rig()
        let s = ModifierDragSession(driver: d, at: CGPoint(x: 690, y: 490), flags: ctrlOptShift, settings: g, raise: false)!
        #expect(s.kind == .resize([.right, .bottom]))
        s.update(to: CGPoint(x: 740, y: 540))
        #expect(d.frameOf(1) == CGRect(x: 100, y: 100, width: 650, height: 450))
    }

    @Test func wrongModifiersStartNothing() {
        let (d, g) = rig()
        #expect(ModifierDragSession(driver: d, at: .zero, flags: [.maskControl], settings: g, raise: false) == nil)
        #expect(ModifierDragSession(driver: d, at: .zero, flags: [], settings: g, raise: false) == nil)
    }

    @Test func disabledOrInvalidSettingsStartNothing() {
        var (d, g) = rig({ $0.enabled = false })
        #expect(ModifierDragSession(driver: d, at: .zero, flags: ctrlOpt, settings: g, raise: false) == nil)
        (d, g) = rig({ $0.move = []; })
        #expect(ModifierDragSession(driver: d, at: .zero, flags: ctrlOpt, settings: g, raise: false) == nil)
        (d, g) = rig({ $0.resize = $0.move })
        #expect(ModifierDragSession(driver: d, at: .zero, flags: ctrlOpt, settings: g, raise: false) == nil)
    }

    @Test func noWindowUnderThePointerStartsNothing() {
        let (d, g) = rig()
        d.windowUnderPointer = nil
        #expect(ModifierDragSession(driver: d, at: .zero, flags: ctrlOpt, settings: g, raise: false) == nil)
    }

    @Test func unmanageableWindowStartsNothing() {
        let (d, g) = rig()
        d.wins[1]!.manageable = false
        #expect(ModifierDragSession(driver: d, at: .zero, flags: ctrlOpt, settings: g, raise: false) == nil)
    }

    @Test func raiseOptionBringsTheWindowForward() {
        let (d, g) = rig()
        _ = ModifierDragSession(driver: d, at: CGPoint(x: 300, y: 300), flags: ctrlOpt, settings: g, raise: true)
        #expect(d.raised == [1])
        let (d2, g2) = rig()
        _ = ModifierDragSession(driver: d2, at: CGPoint(x: 300, y: 300), flags: ctrlOpt, settings: g2, raise: false)
        #expect(d2.raised.isEmpty)
    }

    @Test func unchangedPointerDoesNotRewriteTheFrame() {
        let (d, g) = rig()
        let s = ModifierDragSession(driver: d, at: CGPoint(x: 300, y: 300), flags: ctrlOpt, settings: g, raise: false)!
        s.update(to: CGPoint(x: 300, y: 300))
        #expect(d.setCalls.isEmpty)
    }

    @Test func gestureIsMeasuredFromTheOriginalFrameNotCumulatively() {
        let (d, g) = rig()
        let s = ModifierDragSession(driver: d, at: CGPoint(x: 300, y: 300), flags: ctrlOpt, settings: g, raise: false)!
        s.update(to: CGPoint(x: 400, y: 300))
        s.update(to: CGPoint(x: 310, y: 300))
        #expect(d.frameOf(1).minX == 110)
    }
}

@Suite struct RingGestureTests {
    private let o = CGPoint(x: 500, y: 500)

    @Test func eightDirections() {
        func a(_ dx: CGFloat, _ dy: CGFloat) -> WindowLayoutAction? { RingGesture.action(from: o, to: CGPoint(x: o.x + dx, y: o.y + dy)) }
        #expect(a(100, 0) == .rightHalf)
        #expect(a(-100, 0) == .leftHalf)
        #expect(a(0, -100) == .topHalf)
        #expect(a(0, 100) == .bottomHalf)
        #expect(a(80, -80) == .topRight)
        #expect(a(-80, -80) == .topLeft)
        #expect(a(80, 80) == .bottomRight)
        #expect(a(-80, 80) == .bottomLeft)
    }

    @Test func smallMovementsDoNothing() {
        #expect(RingGesture.action(from: o, to: CGPoint(x: 510, y: 505)) == nil)
        #expect(RingGesture.action(from: o, to: o) == nil)
    }

    @Test func activationDistanceIsInclusive() {
        #expect(RingGesture.action(from: o, to: CGPoint(x: o.x + RingGesture.activationDistance, y: o.y)) == .rightHalf)
        #expect(RingGesture.action(from: o, to: CGPoint(x: o.x + RingGesture.activationDistance - 1, y: o.y)) == nil)
    }

    @Test func sectorBoundariesAreStable() {
        let d: CGFloat = 100
        let just = { (deg: CGFloat) in RingGesture.action(from: self.o, to: CGPoint(x: self.o.x + d * cos(deg * .pi / 180), y: self.o.y - d * sin(deg * .pi / 180))) }
        #expect(just(20) == .rightHalf && just(25) == .topRight)
        #expect(just(65) == .topRight && just(70) == .topHalf)
        #expect(just(-20) == .rightHalf && just(-25) == .bottomRight)
    }

    @Test func sessionTracksTheLatestDirection() {
        let s = RingSession(origin: o, window: nil)
        s.update(to: CGPoint(x: 600, y: 500))
        s.update(to: CGPoint(x: 400, y: 500))
        #expect(s.finish() == .leftHalf)
    }

    @Test func movingBackToTheCentreClearsTheChoice() {
        let s = RingSession(origin: o, window: nil)
        s.update(to: CGPoint(x: 600, y: 500))
        s.update(to: CGPoint(x: 505, y: 500))
        #expect(s.finish() == nil)
    }

    @Test func cancelledSessionIgnoresEverything() {
        let s = RingSession(origin: o, window: nil)
        s.update(to: CGPoint(x: 600, y: 500))
        s.cancel()
        s.update(to: CGPoint(x: 400, y: 500))
        s.forceMaximize()
        #expect(s.finish() == nil && s.cancelled)
    }

    @Test func forceMaximizeOverridesTheDirection() {
        let s = RingSession(origin: o, window: nil)
        s.update(to: CGPoint(x: 600, y: 500))
        s.forceMaximize()
        #expect(s.finish() == .maximize)
    }
}

@Suite struct WindowStageHubTests {
    private func mouse(_ type: CGEventType, _ p: CGPoint, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = flags
        return e
    }

    @Test func gestureStageDropsAMatchingDragAndMovesTheWindow() {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, frame)
        d.windowUnderPointer = 1
        var g = GestureSettings()
        g.enabled = true
        let stage = ModifierGestureStage(hub: hub, driver: d, settings: { g })
        stage.start()
        #expect(be.fire(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 300, y: 300), flags: ctrlOpt)) == .drop)
        #expect(be.fire(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: 330, y: 320), flags: ctrlOpt)) == .drop)
        #expect(d.frameOf(1).origin == CGPoint(x: 130, y: 120))
        #expect(be.fire(.leftMouseUp, mouse(.leftMouseUp, CGPoint(x: 330, y: 320), flags: ctrlOpt)) == .drop)
        #expect(stage.session == nil)
        stage.stop()
    }

    @Test func gestureStagePassesPlainClicksThrough() {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, frame)
        d.windowUnderPointer = 1
        var g = GestureSettings()
        g.enabled = true
        let stage = ModifierGestureStage(hub: hub, driver: d, settings: { g })
        stage.start()
        #expect(be.fire(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 300, y: 300))) == .pass)
        #expect(be.fire(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: 330, y: 320))) == .pass)
        #expect(be.fire(.leftMouseUp, mouse(.leftMouseUp, CGPoint(x: 330, y: 320))) == .pass)
        #expect(d.setCalls.isEmpty)
        stage.stop()
    }

    @Test func gestureStageDoesNothingWithoutPermission() {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, frame)
        d.windowUnderPointer = 1
        var g = GestureSettings()
        g.enabled = true
        let stage = ModifierGestureStage(hub: hub, driver: d, settings: { g }, trusted: { false })
        stage.start()
        #expect(be.fire(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 300, y: 300), flags: ctrlOpt)) == .pass)
        stage.stop()
    }

    @Test func gestureStageStartsAndStopsItsSubscription() {
        let (hub, _) = actHub()
        let stage = ModifierGestureStage(hub: hub, driver: WndFakeDriver(), settings: { GestureSettings() })
        stage.start()
        stage.start()
        #expect(hub.subscriberCount == 1 && stage.isRunning)
        stage.stop()
        #expect(hub.subscriberCount == 0 && !stage.isRunning)
    }

    @Test func edgeStageNeverSwallowsEventsAndDrivesTheTracker() {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, CGRect(x: 300, y: 200, width: 700, height: 500))
        d.windowUnderPointer = 1
        let s = wndSettings { $0.edge.enabled = true }
        let e = wndLayoutEngine(d, s)
        let tracker = EdgeDragTracker(driver: d, engine: e, preview: WndPreview()) { s.value }
        let stage = EdgeSnapStage(hub: hub, tracker: tracker)
        stage.start()
        #expect(be.fire(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 600, y: 210))) == .pass)
        d.wins[1]!.frame = d.frameOf(1).offsetBy(dx: -595, dy: 290)
        #expect(be.fire(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: 5, y: 500))) == .pass)
        #expect(tracker.phase == .moving)
        stage.stop()
        #expect(tracker.phase == .idle)
    }

    @Test func edgeStageSkipsTheTrackerWithoutPermission() {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, frame)
        d.windowUnderPointer = 1
        let s = wndSettings { $0.edge.enabled = true }
        let tracker = EdgeDragTracker(driver: d, engine: wndLayoutEngine(d, s), preview: WndPreview()) { s.value }
        let stage = EdgeSnapStage(hub: hub, tracker: tracker, trusted: { false })
        stage.start()
        be.fire(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 300, y: 300)))
        #expect(tracker.phase == .idle)
        stage.stop()
    }
}

@Suite struct WindowRingStageTests {
    private func rig(enabled: Bool = true, trusted: Bool = true) -> (WndFakeDriver, WindowRingStage, WndPreview, EventTapHub, InpTapBackend) {
        let (hub, be) = actHub()
        let d = WndFakeDriver()
        d.add(1, CGRect(x: 300, y: 200, width: 700, height: 500))
        let s = wndSettings()
        var r = RingSettings()
        r.enabled = enabled
        let p = WndPreview()
        let stage = WindowRingStage(hub: hub, driver: d, engine: wndLayoutEngine(d, s), preview: p, settings: { r }, trusted: { trusted })
        return (d, stage, p, hub, be)
    }

    private let trigger = RingSettings.defaultTrigger
    private let mods = KeyCombo.ctrl | KeyCombo.opt
    private let origin = CGPoint(x: 900, y: 500)

    @Test func holdMoveReleaseSnapsTheFocusedWindow() {
        let (d, stage, p, _, _) = rig()
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin) == .drop)
        #expect(stage.session != nil)
        #expect(stage.handle(.mouseMoved, code: 0, flags: ctrlOpt, repeating: false, at: CGPoint(x: 800, y: 500)) == .pass)
        #expect(p.shown.last == CGRect(x: 0, y: 24, width: 900, height: 976))
        #expect(stage.handle(.keyUp, code: Keys.space, flags: ctrlOpt, repeating: false, at: CGPoint(x: 800, y: 500)) == .drop)
        #expect(d.frameOf(1) == CGRect(x: 0, y: 24, width: 900, height: 976))
        #expect(!p.visible && stage.session == nil && stage.appliedCount == 1)
    }

    @Test func releasingWithoutMovingDoesNothing() {
        let (d, stage, _, _, _) = rig()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        _ = stage.handle(.keyUp, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        #expect(d.setCalls.isEmpty && stage.appliedCount == 0)
    }

    @Test func escapeCancels() {
        let (d, stage, p, _, _) = rig()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        _ = stage.handle(.mouseMoved, code: 0, flags: ctrlOpt, repeating: false, at: CGPoint(x: 800, y: 500))
        #expect(stage.handle(.keyDown, code: Keys.escape, flags: ctrlOpt, repeating: false, at: origin) == .drop)
        #expect(stage.session == nil && !p.visible && d.setCalls.isEmpty)
    }

    @Test func returnMaximisesTheWindow() {
        let (d, stage, _, _, _) = rig()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        #expect(stage.handle(.keyDown, code: Keys.returnKey, flags: ctrlOpt, repeating: false, at: origin) == .drop)
        _ = stage.handle(.keyUp, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        #expect(d.frameOf(1) == WndFix.displays([WndFix.clean])[0].visible)
    }

    @Test func keyRepeatIsSwallowedWithoutRestartingTheRing() {
        let (_, stage, _, _, _) = rig()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        let first = stage.session
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: true, at: CGPoint(x: 1, y: 1)) == .drop)
        #expect(stage.session === first)
    }

    @Test func repeatBeforeAnySessionIsAlsoSwallowed() {
        let (_, stage, _, _, _) = rig()
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: true, at: origin) == .drop)
        #expect(stage.session == nil)
    }

    @Test func releasingAModifierCancelsTheRing() {
        let (d, stage, p, _, _) = rig()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        _ = stage.handle(.mouseMoved, code: 0, flags: ctrlOpt, repeating: false, at: CGPoint(x: 800, y: 500))
        #expect(stage.handle(.flagsChanged, code: 0, flags: [.maskControl], repeating: false, at: origin) == .pass)
        #expect(stage.session == nil && !p.visible && d.setCalls.isEmpty)
    }

    @Test func otherKeysAndModifiersPassThrough() {
        let (_, stage, _, _, _) = rig()
        #expect(stage.handle(.keyDown, code: Keys.space, flags: [], repeating: false, at: origin) == .pass)
        #expect(stage.handle(.keyDown, code: Keys.space, flags: [.maskControl], repeating: false, at: origin) == .pass)
        #expect(stage.handle(.keyDown, code: 0, flags: ctrlOpt, repeating: false, at: origin) == .pass)
        #expect(stage.session == nil)
    }

    @Test func disabledRingIgnoresEverything() {
        let (_, stage, _, _, _) = rig(enabled: false)
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin) == .pass)
    }

    @Test func noPermissionMeansPassThrough() {
        let (_, stage, _, _, _) = rig(trusted: false)
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin) == .pass)
    }

    @Test func stopCancelsARunningRing() {
        let (_, stage, p, hub, _) = rig()
        stage.start()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        _ = stage.handle(.mouseMoved, code: 0, flags: ctrlOpt, repeating: false, at: CGPoint(x: 800, y: 500))
        stage.stop()
        #expect(stage.session == nil && !p.visible && hub.subscriberCount == 0)
    }

    @Test func eventTapResetCancelsARunningRing() {
        let (_, stage, _, _, be) = rig()
        stage.start()
        _ = stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin)
        be.onDisabled?(.tapDisabledByTimeout)
        #expect(stage.session == nil)
        stage.stop()
    }

    @Test func customTriggerIsHonoured() {
        let (hub, _) = actHub()
        let d = WndFakeDriver()
        d.add(1, frame)
        var r = RingSettings()
        r.enabled = true
        r.trigger = KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd | KeyCombo.shift)
        let stage = WindowRingStage(hub: hub, driver: d, engine: wndLayoutEngine(d, wndSettings()), preview: WndPreview(), settings: { r })
        #expect(stage.handle(.keyDown, code: Keys.space, flags: ctrlOpt, repeating: false, at: origin) == .pass)
        #expect(stage.handle(.keyDown, code: 0, flags: [.maskCommand, .maskShift], repeating: false, at: origin) == .drop)
    }

    @Test func ringTriggerIsReservedAndIntercepted() {
        #expect(InterceptedKeys.all.contains { $0.id == InterceptedKeys.windowRingID && $0.combo == trigger })
        #expect(trigger.modifiers == mods && trigger.keyCode == Keys.space)
    }
}
