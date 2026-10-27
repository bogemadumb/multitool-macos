import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func frame(_ n: Int, _ t: TimeInterval, x: Float = 0.5, y: Float = 0.5) -> TouchFrame { TouchFrame(fingers: n, time: t, x: x, y: y) }

@Suite struct MiddleClickEngineTests {
    @Test func threeFingersPressBecomesMiddle() {
        let e = MiddleClickEngine()
        _ = e.ingest(frame(3, 10))
        #expect(e.pressStarted(now: 10.05))
        #expect(e.isHeld)
        #expect(e.pressEnded())
        #expect(!e.isHeld)
    }

    @Test func twoFingerAndOneFingerPressStayLeft() {
        let e = MiddleClickEngine()
        _ = e.ingest(frame(2, 10))
        #expect(!e.pressStarted(now: 10.05))
        _ = e.ingest(frame(1, 11))
        #expect(!e.pressStarted(now: 11.05))
    }

    @Test func staleContactDataIsIgnored() {
        let e = MiddleClickEngine()
        _ = e.ingest(frame(3, 10))
        #expect(!e.pressStarted(now: 10 + MiddleClickEngine.staleFrameSeconds + 0.5))
    }

    @Test func systemThreeFingerDragNeedsFour() {
        let e = MiddleClickEngine()
        e.setSystemDrag(true)
        #expect(e.requiredFingers == 4)
        _ = e.ingest(frame(3, 10))
        #expect(!e.pressStarted(now: 10.05))
        _ = e.ingest(frame(4, 10.1))
        #expect(e.pressStarted(now: 10.15))
    }

    @Test func lostReleaseDoesNotBlockForever() {
        let e = MiddleClickEngine()
        _ = e.ingest(frame(3, 10))
        #expect(e.pressStarted(now: 10.1))
        _ = e.ingest(frame(3, 14))
        #expect(e.pressStarted(now: 14))
    }

    @Test func tapIsOffByDefault() {
        let e = MiddleClickEngine()
        _ = e.ingest(frame(3, 10))
        #expect(!e.ingest(frame(0, 10.1)))
    }

    private func tapEngine() -> MiddleClickEngine {
        var s = MiddleClickSettings()
        s.tapEnabled = true
        return MiddleClickEngine(settings: s)
    }

    @Test func quickTapFires() {
        let e = tapEngine()
        _ = e.ingest(frame(1, 10))
        _ = e.ingest(frame(3, 10.05))
        _ = e.ingest(frame(3, 10.1))
        #expect(e.ingest(frame(0, 10.15)))
    }

    @Test func slowOrMovingOrExtraFingerTapsDoNotFire() {
        let slow = tapEngine()
        _ = slow.ingest(frame(3, 10))
        _ = slow.ingest(frame(3, 10.5))
        #expect(!slow.ingest(frame(0, 10.6)))
        let swipe = tapEngine()
        _ = swipe.ingest(frame(3, 10, x: 0.2))
        _ = swipe.ingest(frame(3, 10.1, x: 0.6))
        #expect(!swipe.ingest(frame(0, 10.15)))
        let four = tapEngine()
        _ = four.ingest(frame(3, 10))
        _ = four.ingest(frame(4, 10.05))
        #expect(!four.ingest(frame(0, 10.1)))
    }

    @Test func physicalPressDuringTouchCancelsTap() {
        let e = tapEngine()
        _ = e.ingest(frame(3, 10))
        _ = e.pressStarted(now: 10.05)
        #expect(!e.ingest(frame(0, 10.1)))
    }

    @Test func tapCooldownBlocksBounce() {
        let e = tapEngine()
        _ = e.ingest(frame(3, 10))
        #expect(e.ingest(frame(0, 10.1)))
        _ = e.ingest(frame(3, 10.15))
        #expect(!e.ingest(frame(0, 10.2)))
    }
}

@Suite struct MiddleClickServiceTests {
    private func rig(drag: Bool = false, tap: Bool = false, clock: ActClock = ActClock()) -> (MiddleClickService, InpTapBackend, ActTouch, ActMouse, ActClock) {
        let (hub, be) = actHub()
        let touch = ActTouch()
        let mouse = ActMouse()
        let gesture = ActGesture()
        gesture.drag = drag
        var s = MiddleClickSettings()
        s.tapEnabled = tap
        let svc = MiddleClickService(hub: hub, source: touch, mouse: mouse, gesture: gesture, settings: s, clock: { clock.now }, dispatch: { $0() })
        actKeep(svc).start()
        return (svc, be, touch, mouse, clock)
    }

    @Test func startsTouchSourceAndSubscribes() {
        let (svc, be, touch, _, _) = rig()
        #expect(svc.isRunning && touch.starts == 1 && !be.starts.isEmpty)
        svc.stop()
        #expect(!svc.isRunning && touch.stops == 1)
    }

    @Test func missingDeviceIsReported() {
        let (hub, _) = actHub()
        let touch = ActTouch()
        touch.startResult = false
        let svc = MiddleClickService(hub: hub, source: touch, mouse: ActMouse(), gesture: ActGesture())
        svc.start()
        #expect(svc.deviceMissing)
    }

    @Test func threeFingerClickBecomesOtherMouse() {
        let (svc, be, touch, mouse, clock) = rig()
        touch.send(frame(3, clock.now))
        #expect(be.fire(.leftMouseDown, ActEvents.left(.leftMouseDown)) == .drop)
        #expect(be.fire(.leftMouseDragged, ActEvents.left(.leftMouseDragged)) == .drop)
        #expect(be.fire(.leftMouseUp, ActEvents.left(.leftMouseUp)) == .drop)
        #expect(mouse.posts.map(\.down) == [true, false] && mouse.posts.allSatisfy { $0.button == 2 })
        #expect(svc.convertedCount == 1)
    }

    @Test func ordinaryClickIsUntouched() {
        let (_, be, touch, mouse, clock) = rig()
        touch.send(frame(1, clock.now))
        #expect(be.fire(.leftMouseDown, ActEvents.left(.leftMouseDown)) == .pass)
        #expect(be.fire(.leftMouseUp, ActEvents.left(.leftMouseUp)) == .pass)
        #expect(mouse.posts.isEmpty)
    }

    @Test func systemDragRequiresFourFromTheService() {
        let (svc, be, touch, mouse, clock) = rig(drag: true)
        #expect(svc.requiredFingers == 4)
        touch.send(frame(3, clock.now))
        #expect(be.fire(.leftMouseDown, ActEvents.left(.leftMouseDown)) == .pass)
        be.fire(.leftMouseUp, ActEvents.left(.leftMouseUp))
        touch.send(frame(4, clock.now))
        #expect(be.fire(.leftMouseDown, ActEvents.left(.leftMouseDown)) == .drop)
        #expect(mouse.posts.count == 1)
    }

    @Test func tapPostsClickAtPointer() {
        let (svc, _, touch, mouse, clock) = rig(tap: true)
        mouse.location = CGPoint(x: 11, y: 12)
        touch.send(frame(3, clock.now))
        touch.send(frame(0, clock.now + 0.1))
        #expect(mouse.posts.count == 2 && mouse.posts.allSatisfy { $0.point == CGPoint(x: 11, y: 12) && $0.button == 2 })
        #expect(svc.tapCount == 1)
    }

    @Test func tapSettingCanChangeLive() {
        let (svc, _, touch, mouse, clock) = rig(tap: false)
        touch.send(frame(3, clock.now))
        touch.send(frame(0, clock.now + 0.1))
        #expect(mouse.posts.isEmpty)
        var s = MiddleClickSettings()
        s.tapEnabled = true
        svc.update(s)
        touch.send(frame(3, clock.now + 1))
        touch.send(frame(0, clock.now + 1.1))
        #expect(mouse.posts.count == 2)
    }
}
