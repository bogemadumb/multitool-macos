import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func session(windows: [ShotWindowInfo] = [], displays: [ShotDisplay] = [shotMain], _ tweak: (inout ShotSelectionConfig) -> Void = { _ in }) -> ShotSelectionSession {
    var c = ShotSelectionConfig()
    c.snapToWindows = false
    c.snapToDisplays = false
    tweak(&c)
    return ShotSelectionSession(displays: displays, windows: windows, config: c)
}

private func drag(_ s: ShotSelectionSession, from a: CGPoint, to b: CGPoint, _ m: ShotModifiers = .none, release: Bool = false) -> ShotSelectionOutcome {
    s.handle(.mouseDown(a, m))
    s.handle(.mouseDragged(b, m))
    return release ? s.handle(.mouseUp(b, m)) : .changed
}

@Suite struct ShotSelectionTests {
    @Test func plainDragMakesARect() {
        let s = session()
        _ = drag(s, from: pt(100, 100), to: pt(300, 250))
        #expect(s.state == .dragging && s.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func dragInAnyDirectionNormalisesTheRect() {
        let s = session()
        _ = drag(s, from: pt(300, 250), to: pt(100, 100))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func releaseConfirmsByDefault() {
        let s = session()
        let out = drag(s, from: pt(10, 10), to: pt(110, 60), release: true)
        #expect(out == .confirmed(ShotSelectionResult(rect: CGRect(x: 10, y: 10, width: 100, height: 50), window: nil)))
        #expect(s.state == .finished)
    }

    @Test func releaseCanLeaveTheSelectionAdjustable() {
        let s = session { $0.confirmOnRelease = false }
        let out = drag(s, from: pt(10, 10), to: pt(110, 60), release: true)
        #expect(out == .changed && s.state == .adjusting)
        #expect(s.handle(.keyDown(Keys.returnKey, .none)) == .confirmed(ShotSelectionResult(rect: CGRect(x: 10, y: 10, width: 100, height: 50), window: nil)))
    }

    @Test func dragIsClampedToTheDesktop() {
        let s = session()
        _ = drag(s, from: pt(1400, 850), to: pt(2000, 2000))
        #expect(s.rect == CGRect(x: 1400, y: 850, width: 40, height: 50))
        _ = drag(s, from: pt(50, 50), to: pt(-500, -500))
        #expect(s.rect == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    @Test func dragCanCrossIntoASecondDisplay() {
        let s = session(displays: [shotMain, shotRight])
        _ = drag(s, from: pt(1400, 100), to: pt(1600, 300))
        #expect(s.rect == CGRect(x: 1400, y: 100, width: 200, height: 200))
    }

    @Test func shiftLocksASquare() {
        let s = session()
        _ = drag(s, from: pt(100, 100), to: pt(300, 160), ShotModifiers(shift: true))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
        _ = drag(s, from: pt(100, 100), to: pt(20, 180), ShotModifiers(shift: true))
        #expect(s.rect == CGRect(x: 20, y: 100, width: 80, height: 80))
    }

    @Test func lockedRatioKeepsTheRatio() {
        let s = session { $0.lockedRatio = 16.0 / 9.0 }
        _ = drag(s, from: pt(100, 100), to: pt(420, 180))
        let r = s.rect!
        #expect(abs(r.width / r.height - 16.0 / 9.0) < 0.001 && r.minX == 100 && r.minY == 100 && r.width == 320)
    }

    @Test func lockedRatioShrinksInsteadOfLeavingTheScreen() {
        let s = session { $0.lockedRatio = 2 }
        _ = drag(s, from: pt(1000, 800), to: pt(1440, 900))
        let r = s.rect!
        #expect(r.maxX <= 1440 && r.maxY <= 900 && abs(r.width / r.height - 2) < 0.001)
    }

    @Test func optionDrawsFromTheCenter() {
        let s = session()
        _ = drag(s, from: pt(500, 400), to: pt(560, 430), ShotModifiers(option: true))
        #expect(s.rect == CGRect(x: 440, y: 370, width: 120, height: 60))
    }

    @Test func centreDragIsLimitedByTheNearestEdge() {
        let s = session()
        _ = drag(s, from: pt(30, 400), to: pt(300, 450), ShotModifiers(option: true))
        #expect(s.rect!.minX == 0 && s.rect!.width == 60)
    }

    @Test func spaceMovesTheWholeSelectionWhileDragging() {
        let s = session()
        _ = drag(s, from: pt(100, 100), to: pt(200, 200))
        s.handle(.keyDown(Keys.space, .none))
        s.handle(.mouseDragged(pt(250, 230), .none))
        #expect(s.rect == CGRect(x: 150, y: 130, width: 100, height: 100))
        s.handle(.keyUp(Keys.space))
        s.handle(.mouseDragged(pt(300, 280), .none))
        #expect(s.rect == CGRect(x: 150, y: 130, width: 150, height: 150))
    }

    @Test func movingStopsAtTheScreenEdge() {
        let s = session()
        _ = drag(s, from: pt(1300, 700), to: pt(1400, 800))
        s.handle(.keyDown(Keys.space, .none))
        s.handle(.mouseDragged(pt(1440, 900), .none))
        #expect(s.rect!.maxX == 1440 && s.rect!.maxY == 900 && s.rect!.size == CGSize(width: 100, height: 100))
    }

    @Test func tinySelectionWithoutAWindowIsDiscarded() {
        let s = session()
        let out = drag(s, from: pt(100, 100), to: pt(101, 101), release: true)
        #expect(out == .changed && s.state == .idle && s.rect == nil)
    }

    @Test func thinSelectionIsDiscarded() {
        let s = session()
        let out = drag(s, from: pt(100, 100), to: pt(300, 102), release: true)
        #expect(out == .changed && s.state == .idle)
    }

    @Test func clickOnAWindowSelectsItsFrame() {
        let w = shotWin(5, 200, 150, 400, 300, title: "Doc", owner: "Pages")
        let s = session(windows: [w])
        let out = drag(s, from: pt(300, 200), to: pt(300, 200), release: true)
        #expect(out == .confirmed(ShotSelectionResult(rect: w.frame, window: w)))
    }

    @Test func clickOnAWindowWaitsForReturnWhenNotConfirmingOnRelease() {
        let w = shotWin(5, 200, 150, 400, 300)
        let s = session(windows: [w]) { $0.confirmOnRelease = false }
        _ = drag(s, from: pt(300, 200), to: pt(300, 200), release: true)
        #expect(s.state == .adjusting && s.rect == w.frame && s.pickedWindow == w)
        #expect(s.handle(.keyDown(Keys.returnKey, .none)) == .confirmed(ShotSelectionResult(rect: w.frame, window: w)))
    }

    @Test func windowFrameIsCroppedToTheDesktop() {
        let w = shotWin(5, 1300, 800, 400, 300)
        let s = session(windows: [w])
        let out = drag(s, from: pt(1350, 850), to: pt(1350, 850), release: true)
        #expect(out == .confirmed(ShotSelectionResult(rect: CGRect(x: 1300, y: 800, width: 140, height: 100), window: w)))
    }

    @Test func hoveringTracksTheTopmostWindow() {
        let front = shotWin(1, 100, 100, 200, 200), back = shotWin(2, 0, 0, 800, 800)
        let s = session(windows: [front, back])
        s.handle(.mouseMoved(pt(150, 150), .none))
        #expect(s.hoverWindow?.id == 1)
        s.handle(.mouseMoved(pt(500, 500), .none))
        #expect(s.hoverWindow?.id == 2)
        s.handle(.mouseMoved(pt(900, 850), .none))
        #expect(s.hoverWindow == nil)
    }

    @Test func returnInIdleTakesTheHoveredWindow() {
        let w = shotWin(1, 100, 100, 200, 200)
        let s = session(windows: [w])
        s.handle(.mouseMoved(pt(150, 150), .none))
        #expect(s.handle(.keyDown(Keys.returnKey, .none)) == .confirmed(ShotSelectionResult(rect: w.frame, window: w)))
    }

    @Test func returnWithNothingToConfirmDoesNothing() {
        let s = session()
        #expect(s.handle(.keyDown(Keys.returnKey, .none)) == .none && s.state == .idle)
    }

    @Test func windowPickOnlyIgnoresDragging() {
        let w = shotWin(1, 100, 100, 200, 200)
        let s = session(windows: [w]) { $0.windowPickOnly = true }
        s.handle(.mouseDown(pt(150, 150), .none))
        s.handle(.mouseDragged(pt(400, 400), .none))
        #expect(s.rect == nil)
        #expect(s.handle(.mouseUp(pt(150, 150), .none)) == .confirmed(ShotSelectionResult(rect: w.frame, window: w)))
    }

    @Test func windowPickOnlyOnEmptySpaceKeepsWaiting() {
        let s = session(windows: [shotWin(1, 100, 100, 200, 200)]) { $0.windowPickOnly = true }
        s.handle(.mouseDown(pt(800, 800), .none))
        #expect(s.handle(.mouseUp(pt(800, 800), .none)) == .none && s.state == .idle)
    }

    @Test func escapeCancelsFromAnyState() {
        let s = session()
        _ = drag(s, from: pt(10, 10), to: pt(100, 100))
        #expect(s.handle(.keyDown(Keys.escape, .none)) == .cancelled && s.state == .finished)
        #expect(s.handle(.mouseDown(pt(0, 0), .none)) == .none)
        let t = session()
        #expect(t.handle(.keyDown(Keys.escape, .none)) == .cancelled)
    }

    @Test func arrowsMoveTheAdjustableSelection() {
        let s = session { $0.confirmOnRelease = false }
        _ = drag(s, from: pt(100, 100), to: pt(200, 200), release: true)
        s.handle(.keyDown(Keys.right, .none))
        s.handle(.keyDown(Keys.down, .none))
        #expect(s.rect == CGRect(x: 101, y: 101, width: 100, height: 100))
        s.handle(.keyDown(Keys.left, ShotModifiers(shift: true)))
        s.handle(.keyDown(Keys.up, ShotModifiers(shift: true)))
        #expect(s.rect == CGRect(x: 91, y: 91, width: 100, height: 100))
    }

    @Test func nudgeStaysInsideTheDesktop() {
        let s = session { $0.confirmOnRelease = false }
        _ = drag(s, from: pt(2, 2), to: pt(102, 102), release: true)
        for _ in 0..<5 { s.handle(.keyDown(Keys.left, ShotModifiers(shift: true))) }
        #expect(s.rect!.minX == 0)
    }

    @Test func optionArrowsResizeFromTheBottomRight() {
        let s = session { $0.confirmOnRelease = false }
        _ = drag(s, from: pt(100, 100), to: pt(200, 200), release: true)
        s.handle(.keyDown(Keys.right, ShotModifiers(option: true)))
        s.handle(.keyDown(Keys.down, ShotModifiers(shift: true, option: true)))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 101, height: 110))
        for _ in 0..<20 { s.handle(.keyDown(Keys.left, ShotModifiers(shift: true, option: true))) }
        #expect(s.rect!.width == s.config.minSide)
    }

    @Test func arrowsInIdleMoveTheCursorByOnePoint() {
        let s = session()
        s.handle(.mouseMoved(pt(100, 100), .none))
        #expect(s.handle(.keyDown(Keys.right, .none)) == .warpCursor(pt(101, 100)))
        #expect(s.handle(.keyDown(Keys.up, ShotModifiers(shift: true))) == .warpCursor(pt(101, 90)))
        #expect(s.cursor == pt(101, 90))
    }

    @Test func arrowsWhileDraggingExtendTheSelectionByOnePoint() {
        let s = session()
        _ = drag(s, from: pt(100, 100), to: pt(200, 200))
        #expect(s.handle(.keyDown(Keys.right, .none)) == .warpCursor(pt(201, 200)))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 101, height: 100))
    }

    @Test func cursorIsClampedToTheDesktop() {
        let s = session()
        s.handle(.mouseMoved(pt(-50, 5000), .none))
        #expect(s.cursor == pt(0, 900))
    }

    @Test func snapsDraggedEdgesToWindowEdges() {
        let w = shotWin(1, 400, 300, 300, 200)
        let s = session(windows: [w]) { $0.snapToWindows = true }
        _ = drag(s, from: pt(100, 100), to: pt(397, 303))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 300, height: 200))
        #expect(s.guideX == 400 && s.guideY == 300)
    }

    @Test func doesNotSnapBeyondTheThreshold() {
        let w = shotWin(1, 400, 300, 300, 200)
        let s = session(windows: [w]) { $0.snapToWindows = true }
        _ = drag(s, from: pt(100, 100), to: pt(380, 280))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 280, height: 180) && s.guideX == nil)
    }

    @Test func commandDisablesSnapping() {
        let w = shotWin(1, 400, 300, 300, 200)
        let s = session(windows: [w]) { $0.snapToWindows = true }
        _ = drag(s, from: pt(100, 100), to: pt(397, 303), ShotModifiers(command: true))
        #expect(s.rect?.maxX == 397)
    }

    @Test func snapsToDisplayEdges() {
        let s = session(displays: [shotMain, shotRight]) { $0.snapToDisplays = true }
        _ = drag(s, from: pt(1000, 100), to: pt(1436, 400))
        #expect(s.rect?.maxX == 1440)
    }

    @Test func aspectLockDisablesSnapping() {
        let w = shotWin(1, 400, 300, 300, 200)
        let s = session(windows: [w]) { $0.snapToWindows = true }
        _ = drag(s, from: pt(100, 100), to: pt(397, 303), ShotModifiers(shift: true))
        #expect(s.rect!.width == s.rect!.height)
    }

    @Test func finishedSessionIgnoresInput() {
        let s = session()
        _ = drag(s, from: pt(0, 0), to: pt(100, 100), release: true)
        #expect(s.handle(.mouseMoved(pt(5, 5), .none)) == .none && s.handle(.keyDown(Keys.escape, .none)) == .none)
    }

    @Test func newMouseDownStartsFreshAfterAdjusting() {
        let s = session { $0.confirmOnRelease = false }
        _ = drag(s, from: pt(100, 100), to: pt(200, 200), release: true)
        s.handle(.mouseDown(pt(500, 500), .none))
        #expect(s.state == .dragging && s.rect?.size == .zero && s.pickedWindow == nil)
    }
}

@Suite struct ShotMagnifierTests {
    @Test func pixelCoordinatesOnARetinaDisplay() {
        let m = ShotMagnifier.model(cursor: CGPoint(x: 100.4, y: 50.9), displays: [shotMain])!
        #expect(m.pixelX == 200 && m.pixelY == 101 && m.displayID == 1)
        #expect(m.pixelText == "200, 101 px" && m.pointText == "100, 50")
    }

    @Test func gridIsOddAndCentred() {
        let m = ShotMagnifier.model(cursor: CGPoint(x: 100, y: 100), displays: [shotMain], gridSize: 10)!
        #expect(m.gridSize == 11 && m.sourcePixelRect == CGRect(x: 195, y: 195, width: 11, height: 11))
    }

    @Test func pixelsAreLocalToTheSecondDisplay() {
        let m = ShotMagnifier.model(cursor: CGPoint(x: 1500, y: 20), displays: [shotMain, shotRight])!
        #expect(m.displayID == 2 && m.pixelX == 60 && m.pixelY == 20)
    }

    @Test func loupeFlipsAwayFromTheEdges() {
        let near = ShotMagnifier.model(cursor: CGPoint(x: 1430, y: 890), displays: [shotMain])!
        #expect(near.loupeFrame.maxX <= 1440 && near.loupeFrame.maxY <= 900)
        #expect(near.loupeFrame.maxX <= 1430 && near.loupeFrame.maxY <= 890)
        let far = ShotMagnifier.model(cursor: CGPoint(x: 100, y: 100), displays: [shotMain])!
        #expect(far.loupeFrame.minX == 120 && far.loupeFrame.minY == 120)
    }

    @Test func cursorOutsideIsClampedToTheNearestDisplay() {
        let m = ShotMagnifier.model(cursor: CGPoint(x: -40, y: 10), displays: [shotMain])!
        #expect(m.pixelX == 0 && m.pixelY == 20)
        #expect(ShotMagnifier.model(cursor: .zero, displays: []) == nil)
    }

    @Test func sizeLabelReportsPixels() {
        #expect(ShotMagnifier.sizeLabel(CGRect(x: 0, y: 0, width: 300, height: 200), scale: 2) == "600 × 400")
    }

    @Test func labelFlipsAboveWhenThereIsNoRoomBelow() {
        let b = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let low = ShotMagnifier.labelFrame(selection: CGRect(x: 100, y: 700, width: 200, height: 195), labelSize: CGSize(width: 80, height: 20), in: b)
        #expect(low.maxY <= 700)
        let normal = ShotMagnifier.labelFrame(selection: CGRect(x: 100, y: 100, width: 200, height: 100), labelSize: CGSize(width: 80, height: 20), in: b)
        #expect(normal.minY == 206)
        let edge = ShotMagnifier.labelFrame(selection: CGRect(x: 1400, y: 100, width: 40, height: 100), labelSize: CGSize(width: 80, height: 20), in: b)
        #expect(edge.maxX <= 1440)
    }
}
