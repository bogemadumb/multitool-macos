import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShelfDragSessionTests {
    private func make(front: String? = "com.apple.finder") -> (ShelfDragSession, ShfProbe) {
        let probe = ShfProbe()
        let s = ShelfDragSession(probe: probe, frontmost: { front })
        return (s, probe)
    }

    private func shake(_ s: ShelfDragSession, t0: TimeInterval = 0, legs: Int = 5) -> [ShelfDragEvent] {
        var events: [ShelfDragEvent] = []
        var x = 500.0, dir = 1.0, t = t0
        for _ in 0..<legs {
            for _ in 0..<12 {
                x += dir * 10
                t += 0.01
                events += s.mouseDragged(to: CGPoint(x: x, y: 300), at: t)
            }
            dir = -dir
        }
        return events
    }

    @Test func plainMouseDragIsNotAContentDrag() {
        let (s, _) = make()
        s.mouseDown(at: .zero)
        #expect(shake(s).isEmpty)
        #expect(s.mouseUp().isEmpty)
        #expect(!s.isContentDrag)
    }

    @Test func pasteboardChangeStartsAContentDrag() {
        let (s, p) = make()
        s.mouseDown(at: .zero)
        p.startDrag()
        let ev = s.mouseDragged(to: CGPoint(x: 5, y: 5), at: 0.1)
        #expect(ev == [.started])
        #expect(s.isContentDrag)
        #expect(s.mouseUp() == [.ended])
    }

    @Test func startedIsEmittedOnce() {
        let (s, p) = make()
        s.mouseDown(at: .zero)
        p.startDrag()
        #expect(s.mouseDragged(to: CGPoint(x: 5, y: 5), at: 0.1) == [.started])
        #expect(s.mouseDragged(to: CGPoint(x: 6, y: 5), at: 0.11).isEmpty)
    }

    @Test func shakeWhileDraggingContentEmitsShake() {
        let (s, p) = make()
        s.mouseDown(at: .zero)
        p.startDrag()
        let ev = shake(s)
        #expect(ev.contains(.started))
        #expect(ev.filter { $0 == .shake }.count == 1)
    }

    @Test func shakeWithoutContentDoesNothing() {
        let (s, _) = make()
        s.mouseDown(at: .zero)
        #expect(!shake(s).contains(.shake))
    }

    @Test func disabledShakeStillReportsTheDrag() {
        let (s, p) = make()
        s.config.shakeEnabled = false
        s.mouseDown(at: .zero)
        p.startDrag()
        let ev = shake(s)
        #expect(ev.contains(.started))
        #expect(!ev.contains(.shake))
    }

    @Test func excludedSourceAppSuppressesShakeOnly() {
        let (s, p) = make(front: "com.adobe.photoshop")
        s.config.excludedApps = ["com.adobe.photoshop"]
        s.mouseDown(at: .zero)
        p.startDrag()
        let ev = shake(s)
        #expect(ev.contains(.started))
        #expect(!ev.contains(.shake))
    }

    @Test func otherAppsAreNotAffectedByTheExclusionList() {
        let (s, p) = make(front: "com.apple.finder")
        s.config.excludedApps = ["com.adobe.photoshop"]
        s.mouseDown(at: .zero)
        p.startDrag()
        #expect(shake(s).contains(.shake))
    }

    @Test func dockDragsAreNeverTracked() {
        let (s, p) = make(front: "com.apple.dock")
        s.mouseDown(at: .zero)
        p.startDrag()
        #expect(shake(s).isEmpty)
        #expect(s.mouseUp().isEmpty)
    }

    @Test func visibleShelfIsNotReopenedByShake() {
        let (s, p) = make()
        s.config.shelfVisible = true
        s.mouseDown(at: .zero)
        p.startDrag()
        let ev = shake(s)
        #expect(ev.contains(.started))
        #expect(!ev.contains(.shake))
    }

    @Test func sensitivityIsReadAtMouseDown() {
        let (s, p) = make()
        s.config.sensitivity = .low
        s.mouseDown(at: .zero)
        p.startDrag()
        #expect(!shake(s, legs: 3).contains(.shake))
    }

    @Test func stalePasteboardFromAnEarlierDragDoesNotCount() {
        let (s, p) = make()
        p.startDrag()
        s.mouseDown(at: .zero)
        #expect(shake(s).isEmpty)
    }

    @Test func nextDragStartsClean() {
        let (s, p) = make()
        s.mouseDown(at: .zero)
        p.startDrag()
        _ = shake(s)
        _ = s.mouseUp()
        s.mouseDown(at: .zero)
        #expect(!s.isContentDrag)
        #expect(shake(s, t0: 20).isEmpty)
    }

    @Test func cancelEndsQuietly() {
        let (s, p) = make()
        s.mouseDown(at: .zero)
        p.startDrag()
        _ = s.mouseDragged(to: CGPoint(x: 5, y: 5), at: 0.1)
        s.cancel()
        #expect(s.mouseUp().isEmpty)
    }
}
