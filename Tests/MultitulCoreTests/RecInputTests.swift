import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct RecInputTests {
    @Test func mapperNormalizesInsideTheCaptureRect() {
        let m = RecInputMapper(captureRect: CGRect(x: 100, y: 200, width: 400, height: 300))
        let n = m.normalize(CGPoint(x: 300, y: 350))!
        #expect(abs(n.x - 0.5) < 1e-9 && abs(n.y - 0.5) < 1e-9 && n.inside)
    }

    @Test func mapperFlagsAndClampsOutside() {
        let m = RecInputMapper(captureRect: CGRect(x: 100, y: 200, width: 400, height: 300))
        let n = m.normalize(CGPoint(x: 50, y: 900))!
        #expect(!n.inside && n.x == 0 && n.y == 1)
    }

    @Test func mapperRejectsDegenerateRect() {
        #expect(RecInputMapper(captureRect: .zero).normalize(CGPoint(x: 1, y: 1)) == nil)
    }

    @Test func mapperStandardizesNegativeRects() {
        let m = RecInputMapper(captureRect: CGRect(x: 500, y: 500, width: -400, height: -300))
        #expect(m.captureRect == CGRect(x: 100, y: 200, width: 400, height: 300))
    }

    @Test func movesAreThrottledByTime() {
        var log = RecInputLog()
        let r1 = log.append(RecInputEvent(t: 0, kind: .move, x: 0.1, y: 0.1))
        #expect(r1)
        let r2 = log.append(RecInputEvent(t: 0.01, kind: .move, x: 0.5, y: 0.5))
        #expect(!r2)
        let r3 = log.append(RecInputEvent(t: 0.05, kind: .move, x: 0.5, y: 0.5))
        #expect(r3)
    }

    @Test func movesAreThrottledByDistance() {
        var log = RecInputLog()
        log.append(RecInputEvent(t: 0, kind: .move, x: 0.5, y: 0.5))
        let r4 = log.append(RecInputEvent(t: 1, kind: .move, x: 0.5001, y: 0.5))
        #expect(!r4)
    }

    @Test func clicksAreNeverThrottled() {
        var log = RecInputLog()
        log.append(RecInputEvent(t: 1, kind: .move, x: 0.5, y: 0.5))
        let r5 = log.append(RecInputEvent(t: 1.001, kind: .down, x: 0.5, y: 0.5))
        #expect(r5)
        let r6 = log.append(RecInputEvent(t: 1.002, kind: .up, x: 0.5, y: 0.5))
        #expect(r6)
    }

    @Test func outOfOrderEventsAreRejected() {
        var log = RecInputLog()
        log.append(RecInputEvent(t: 5, kind: .down, x: 0.1, y: 0.1))
        let r7 = log.append(RecInputEvent(t: 4, kind: .down, x: 0.1, y: 0.1))
        #expect(!r7)
        let r8 = log.append(RecInputEvent(t: -1, kind: .down, x: 0.1, y: 0.1))
        #expect(!r8)
        let r9 = log.append(RecInputEvent(t: .nan, kind: .down, x: 0.1, y: 0.1))
        #expect(!r9)
    }

    @Test func durationFollowsLastEvent() {
        var log = RecInputLog()
        log.append(RecInputEvent(t: 2, kind: .down, x: 0, y: 0))
        log.append(RecInputEvent(t: 7.5, kind: .up, x: 0, y: 0))
        #expect(log.duration == 7.5)
    }

    @Test func clicksListSkipsOutsideAndOtherKinds() {
        let log = RecInputLog(events: [
            RecInputEvent(t: 1, kind: .down, x: 0.5, y: 0.5), RecInputEvent(t: 1.1, kind: .up, x: 0.5, y: 0.5),
            RecInputEvent(t: 2, kind: .down, x: 1, y: 1, inside: false), RecInputEvent(t: 3, kind: .move, x: 0.2, y: 0.2)
        ])
        #expect(log.clicks.count == 1 && log.clicks[0].t == 1)
    }

    @Test func cursorInterpolatesBetweenSamples() {
        let log = RecInputLog(events: [RecInputEvent(t: 0, kind: .move, x: 0, y: 0), RecInputEvent(t: 2, kind: .move, x: 1, y: 0.5)])
        let c = log.cursor(at: 1)!
        #expect(abs(c.x - 0.5) < 1e-9 && abs(c.y - 0.25) < 1e-9)
    }

    @Test func cursorClampsOutsideRange() {
        let log = RecInputLog(events: [RecInputEvent(t: 1, kind: .move, x: 0.2, y: 0.3), RecInputEvent(t: 2, kind: .move, x: 0.8, y: 0.9)])
        #expect(log.cursor(at: 0)! == (0.2, 0.3) && log.cursor(at: 9)! == (0.8, 0.9))
        #expect(RecInputLog().cursor(at: 1) == nil)
    }

    @Test func scrollDoesNotMoveTheCursor() {
        let log = RecInputLog(events: [RecInputEvent(t: 0, kind: .move, x: 0.1, y: 0.1), RecInputEvent(t: 1, kind: .scroll, x: 0.9, y: 0.9)])
        #expect(log.cursor(at: 1)! == (0.1, 0.1))
    }

    @Test func ripplesLiveForTheirLifetime() {
        let log = RecInputLog(events: [RecInputEvent(t: 10, kind: .down, x: 0.4, y: 0.6)])
        #expect(log.ripples(at: 9.9).isEmpty)
        let r = log.ripples(at: 10.3)
        #expect(r.count == 1 && abs(r[0].progress - 0.5) < 1e-9 && r[0].x == 0.4)
        #expect(log.ripples(at: 10.7).isEmpty)
    }

    @Test func ripplesIgnoreClicksOutsideTheFrame() {
        let log = RecInputLog(events: [RecInputEvent(t: 1, kind: .down, x: 1, y: 1, inside: false)])
        #expect(log.ripples(at: 1.1).isEmpty)
    }

    @Test func encodeDecodeRoundTrip() throws {
        var log = RecInputLog()
        log.append(RecInputEvent(t: 0.5, kind: .move, x: 0.1234567, y: 0.5))
        log.append(RecInputEvent(t: 1, kind: .down, x: 0.3, y: 0.4, button: .right))
        log.append(RecInputEvent(t: 1.2, kind: .up, x: 1, y: 1, button: .right, inside: false))
        let back = try RecInputLog.decode(try log.encoded())
        #expect(back.events.count == 3 && back.events[1].button == .right && !back.events[2].inside && abs(back.events[0].x - 0.1235) < 1e-9)
        #expect(back.duration == log.duration)
    }

    @Test func encodingIsCompact() throws {
        var log = RecInputLog()
        for i in 0..<1000 { log.append(RecInputEvent(t: Double(i) * 0.05, kind: .move, x: Double(i % 100) / 100, y: 0.5)) }
        #expect(try log.encoded().count < 1000 * 48)
    }

    @Test func decodeRejectsGarbage() {
        #expect((try? RecInputLog.decode(Data("nope".utf8))) == nil)
    }

    @Test func trimmedShiftsTimes() {
        let log = RecInputLog(events: [RecInputEvent(t: 1, kind: .down, x: 0, y: 0), RecInputEvent(t: 5, kind: .down, x: 0, y: 0), RecInputEvent(t: 9, kind: .down, x: 0, y: 0)])
        let t = log.trimmed(to: 4...8)
        #expect(t.events.count == 1 && t.events[0].t == 1 && t.duration == 4)
    }

    @Test func capacityIsBounded() {
        var log = RecInputLog()
        var accepted = 0
        for i in 0..<10 where log.append(RecInputEvent(t: Double(i), kind: .down, x: 0, y: 0)) { accepted += 1 }
        #expect(accepted == 10 && RecInputLog.maxEvents == 400_000)
    }
}

@Suite struct RecRippleSearchTests {
    @Test func binarySearchMatchesALinearScanOnALargeLog() {
        var events: [RecInputEvent] = []
        for i in 0..<20_000 {
            let t = Double(i) * 0.01
            events.append(RecInputEvent(t: t, kind: i % 97 == 0 ? .down : .move, x: Double(i % 100) / 100, y: 0.5))
        }
        let log = RecInputLog(events: events)
        for probe in stride(from: 0.0, to: 200.0, by: 7.31) {
            let fast = log.ripples(at: probe)
            let slow = log.events.filter { $0.kind == .down && $0.inside && $0.t <= probe && probe - $0.t < 0.6 }
            #expect(fast.count == slow.count)
        }
    }

    @Test func rippleAtExactClickTimeHasZeroProgress() {
        let log = RecInputLog(events: [RecInputEvent(t: 3, kind: .down, x: 0.5, y: 0.5)])
        #expect(log.ripples(at: 3).first?.progress == 0)
        #expect(log.ripples(at: 3, lifetime: 0).isEmpty && RecInputLog().ripples(at: 3).isEmpty)
    }
}
