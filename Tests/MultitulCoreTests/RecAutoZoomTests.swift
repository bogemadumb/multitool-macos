import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func click(_ t: Double, _ x: Double, _ y: Double, _ b: RecButton = .left, inside: Bool = true) -> RecInputEvent {
    RecInputEvent(t: t, kind: .down, x: x, y: y, button: b, inside: inside)
}

private func plan(_ events: [RecInputEvent], duration: Double = 30, _ tweak: (inout RecZoomSettings) -> Void = { _ in }) -> RecZoomTimeline {
    var s = RecZoomSettings()
    tweak(&s)
    return RecAutoZoom.plan(log: RecInputLog(events: events, duration: duration), duration: duration, settings: s)
}

@Suite struct RecEaseTests {
    @Test func endpointsAreExact() {
        for e in RecEase.allCases { #expect(e.apply(0) == 0 && abs(e.apply(1) - 1) < 1e-12) }
    }

    @Test func inputIsClamped() {
        for e in RecEase.allCases { #expect(e.apply(-3) == 0 && abs(e.apply(7) - 1) < 1e-12) }
    }

    @Test func allCurvesAreMonotonic() {
        for e in RecEase.allCases {
            var prev = -1.0
            for i in 0...100 {
                let v = e.apply(Double(i) / 100)
                #expect(v >= prev - 1e-12)
                prev = v
            }
        }
    }

    @Test func symmetricCurvesPassThroughHalf() {
        #expect(abs(RecEase.cubic.apply(0.5) - 0.5) < 1e-12 && abs(RecEase.quint.apply(0.5) - 0.5) < 1e-12 && abs(RecEase.smoother.apply(0.5) - 0.5) < 1e-12)
    }

    @Test func outCurveStartsFast() {
        #expect(RecEase.out.apply(0.3) > 0.3 && RecEase.cubic.apply(0.3) < 0.3)
    }
}

@Suite struct RecZoomMathTests {
    @Test func viewRectSizeIsInverseOfScale() {
        let r = RecZoomMath.viewRect(scale: 2, cx: 0.5, cy: 0.5)
        #expect(r == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test func viewRectStaysInsideTheFrame() {
        let r = RecZoomMath.viewRect(scale: 2, cx: 0.02, cy: 0.99)
        #expect(r.minX == 0 && r.maxY == 1 && r.width == 0.5)
    }

    @Test func scaleBelowOneIsFullFrame() {
        #expect(RecZoomMath.viewRect(scale: 0.5, cx: 0.3, cy: 0.3) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func clampCenterKeepsViewInside() {
        let c = RecZoomMath.clampCenter((0.0, 1.0), scale: 4)
        #expect(abs(c.x - 0.125) < 1e-12 && abs(c.y - 0.875) < 1e-12)
    }

    @Test func settingsSanitizeLevel() {
        var s = RecZoomSettings()
        s.level = 12
        s.rampIn = -4
        s.followMargin = 5
        let c = s.sanitized
        #expect(c.level == 4 && c.rampIn == 0.1 && c.followMargin == 0.45)
    }
}

@Suite struct RecAutoZoomTests {
    @Test func noClicksNoSpans() {
        #expect(plan([]).spans.isEmpty)
        #expect(plan([RecInputEvent(t: 1, kind: .move, x: 0.5, y: 0.5)]).spans.isEmpty)
    }

    @Test func zeroDurationGivesNothing() {
        #expect(RecAutoZoom.plan(log: RecInputLog(events: [click(1, 0.5, 0.5)]), duration: 0).spans.isEmpty)
    }

    @Test func singleClickBuildsOneSpanWithExpectedTiming() {
        let s = plan([click(5, 0.7, 0.4)]).spans
        #expect(s.count == 1)
        let a = s[0]
        #expect(abs(a.holdStart - 4.75) < 1e-9 && abs(a.start - 4.2) < 1e-9 && abs(a.holdEnd - 6.4) < 1e-9 && abs(a.end - 7.1) < 1e-9)
        #expect(a.level == 1.8 && a.path.count == 1 && abs(a.path[0].cx - 0.7) < 1e-9)
    }

    @Test func holdIsAtLeastMinHoldAfterTheClick() {
        let s = plan([click(5, 0.5, 0.5)]) { $0.minHold = 3 }.spans[0]
        #expect(s.holdEnd - 5 >= 3 - 1e-9)
    }

    @Test func nearbyClicksMergeAndKeepEveryTarget() {
        let t = plan([click(5, 0.2, 0.3), click(6, 0.8, 0.7)])
        #expect(t.spans.count == 1 && t.spans[0].path.count == 2)
        #expect(t.spans[0].path[1].cx > 0.6)
    }

    @Test func clicksWithinMergeGapMergeEvenWhenFar() {
        #expect(plan([click(5, 0.5, 0.5), click(7.3, 0.5, 0.5)]).spans.count == 1)
    }

    @Test func spansCloserThanMinGapMerge() {
        #expect(plan([click(5, 0.5, 0.5), click(8.0, 0.5, 0.5)]).spans.count == 1)
    }

    @Test func farApartClicksStaySeparate() {
        let t = plan([click(5, 0.5, 0.5), click(15, 0.2, 0.2)])
        #expect(t.spans.count == 2 && t.spans[1].start > t.spans[0].end)
    }

    @Test func spansNeverOverlap() {
        var ev: [RecInputEvent] = []
        for i in 0..<12 { ev.append(click(Double(i) * 2.7 + 1, Double(i % 5) / 5 + 0.1, 0.5)) }
        let s = plan(ev, duration: 60).spans
        for i in 1..<s.count { #expect(s[i].start >= s[i - 1].end) }
    }

    @Test func spanOrderingInvariants() {
        let s = plan([click(0.2, 0.5, 0.5), click(10, 0.3, 0.3), click(29.5, 0.9, 0.9)]).spans
        for a in s { #expect(a.start <= a.holdStart && a.holdStart <= a.holdEnd && a.holdEnd <= a.end && a.end <= 30 && a.start >= 0) }
    }

    @Test func clickAtTheVeryStartRampsInsideTheSpan() {
        let a = plan([click(0.3, 0.5, 0.5)]).spans[0]
        #expect(a.start == 0 && abs(a.holdStart - 0.3) < 1e-9)
    }

    @Test func clickNearTheEndIsClampedToDuration() {
        let a = plan([click(19, 0.5, 0.5)], duration: 20).spans[0]
        #expect(a.end == 20 && a.holdEnd <= 20 && a.holdEnd >= a.holdStart)
    }

    @Test func clicksAfterTheEndAreIgnored() {
        #expect(plan([click(40, 0.5, 0.5)], duration: 20).spans.isEmpty)
    }

    @Test func rightClicksCanBeIgnored() {
        let off = plan([click(5, 0.5, 0.5, .right)]) { $0.rightClicks = false }
        #expect(off.spans.isEmpty)
        #expect(plan([click(5, 0.5, 0.5, .right)]).spans.count == 1)
    }

    @Test func otherButtonsNeverTrigger() {
        #expect(plan([click(5, 0.5, 0.5, .other)]).spans.isEmpty)
    }

    @Test func clicksOutsideTheFrameNeverTrigger() {
        #expect(plan([click(5, 1, 1, inside: false)]).spans.isEmpty)
    }

    @Test func skipBeforeSuppressesEarlyClicks() {
        let s = plan([click(2, 0.5, 0.5), click(12, 0.5, 0.5)]) { $0.skipBefore = 5 }.spans
        #expect(s.count == 1 && s[0].holdStart > 10)
    }

    @Test func centerIsClampedForCornerClicks() {
        let a = plan([click(5, 0.01, 0.01)]).spans[0]
        let half = 0.5 / 1.8
        #expect(abs(a.path[0].cx - half) < 1e-9 && abs(a.path[0].cy - half) < 1e-9)
        let v = RecZoomMath.viewRect(scale: 1.8, cx: a.path[0].cx, cy: a.path[0].cy)
        #expect(v.minX >= 0 && v.minY >= 0)
    }

    @Test func levelFollowsSettings() {
        let t = plan([click(5, 0.5, 0.5)]) { $0.level = 2.5 }
        #expect(t.spans[0].level == 2.5)
    }

    @Test func cursorTravelDuringHoldAddsPanKeyframes() {
        let ev = [click(5, 0.3, 0.3), RecInputEvent(t: 5.5, kind: .move, x: 0.5, y: 0.5), RecInputEvent(t: 6.0, kind: .move, x: 0.8, y: 0.8)]
        let a = plan(ev) { $0.minHold = 4 }.spans[0]
        #expect(a.path.count > 1 && a.path.last!.cx > 0.3)
    }

    @Test func followCanBeDisabled() {
        let ev = [click(5, 0.3, 0.3), RecInputEvent(t: 5.5, kind: .move, x: 0.8, y: 0.8)]
        let t = plan(ev) { $0.follow = false; $0.minHold = 4 }
        #expect(t.spans[0].path.count == 1)
    }

    @Test func smallCursorJitterDoesNotPan() {
        let ev = [click(5, 0.5, 0.5), RecInputEvent(t: 5.5, kind: .move, x: 0.52, y: 0.51), RecInputEvent(t: 6.0, kind: .move, x: 0.49, y: 0.5)]
        #expect(plan(ev).spans[0].path.count == 1)
    }

    @Test func dwellTriggerNeedsLongStillness() {
        let still = [RecInputEvent(t: 3, kind: .move, x: 0.4, y: 0.4), RecInputEvent(t: 3.5, kind: .move, x: 0.401, y: 0.4), RecInputEvent(t: 4.0, kind: .move, x: 0.402, y: 0.4),
                     RecInputEvent(t: 5.5, kind: .move, x: 0.9, y: 0.9)]
        let on = plan(still) { $0.dwell = true }
        #expect(on.spans.count == 1)
        #expect(plan(still).spans.isEmpty)
        let brief = [RecInputEvent(t: 3, kind: .move, x: 0.4, y: 0.4), RecInputEvent(t: 3.4, kind: .move, x: 0.9, y: 0.9)]
        let briefOn = plan(brief) { $0.dwell = true }
        #expect(briefOn.spans.isEmpty)
    }

    @Test func samplingOutsideSpansIsIdentity() {
        let t = plan([click(10, 0.5, 0.5)])
        #expect(t.sample(at: 0) == .identity && t.sample(at: 29).isIdentity)
    }

    @Test func samplingReachesFullLevelAtHold() {
        let t = plan([click(10, 0.5, 0.5)])
        let a = t.spans[0]
        #expect(abs(t.sample(at: a.holdStart).scale - 1.8) < 1e-9 && abs(t.sample(at: (a.holdStart + a.holdEnd) / 2).scale - 1.8) < 1e-9)
    }

    @Test func rampInIsMonotonicallyIncreasing() {
        let t = plan([click(10, 0.5, 0.5)])
        let a = t.spans[0]
        var prev = 0.99
        for i in 0...40 {
            let s = t.sample(at: a.start + (a.holdStart - a.start) * Double(i) / 40).scale
            #expect(s >= prev - 1e-9)
            prev = s
        }
    }

    @Test func rampOutIsMonotonicallyDecreasing() {
        let t = plan([click(10, 0.5, 0.5)])
        let a = t.spans[0]
        var prev = 2.0
        for i in 0...40 {
            let s = t.sample(at: a.holdEnd + (a.end - a.holdEnd) * Double(i) / 40).scale
            #expect(s <= prev + 1e-9)
            prev = s
        }
        #expect(abs(t.sample(at: a.end).scale - 1) < 1e-9)
    }

    @Test func sampledViewAlwaysStaysInsideTheFrame() {
        let t = plan([click(5, 0.99, 0.01), click(15, 0.01, 0.99), click(25, 0.5, 0.5)])
        for i in 0..<300 {
            let s = t.sample(at: Double(i) / 10)
            let r = RecZoomMath.viewRect(scale: s.scale, cx: s.cx, cy: s.cy)
            #expect(r.minX >= -1e-9 && r.minY >= -1e-9 && r.maxX <= 1 + 1e-9 && r.maxY <= 1 + 1e-9)
        }
    }

    @Test func panInterpolatesBetweenKeyframesWithEasing() {
        var s = RecZoomSettings()
        s.easing = .linear
        s.panDuration = 1
        let span = RecZoomSpan(start: 0, holdStart: 1, holdEnd: 10, end: 11, level: 2, path: [RecZoomPoint(t: 1, cx: 0.3, cy: 0.5), RecZoomPoint(t: 6, cx: 0.7, cy: 0.5)])
        let t = RecZoomTimeline(spans: [span], easing: .linear, panDuration: 1)
        #expect(abs(t.sample(at: 3).cx - 0.3) < 1e-9)
        #expect(abs(t.sample(at: 5.5).cx - 0.5) < 1e-9)
        #expect(abs(t.sample(at: 7).cx - 0.7) < 1e-9)
    }

    @Test func keyframesCoverBoundaries() {
        let t = plan([click(10, 0.5, 0.5)])
        let k = t.keyframes
        #expect(k.first?.scale == 1 && k.last?.scale == 1 && k.contains { $0.scale == 1.8 })
        #expect(k.map(\.t) == k.map(\.t).sorted())
    }

    @Test func timelineCodableRoundTrip() throws {
        let t = plan([click(5, 0.3, 0.3), click(20, 0.8, 0.2)])
        let back = try JSONDecoder().decode(RecZoomTimeline.self, from: try JSONEncoder().encode(t))
        #expect(back == t)
    }

    @Test func spanLookupHonorsBounds() {
        let t = plan([click(10, 0.5, 0.5)])
        #expect(t.span(at: t.spans[0].start) != nil && t.span(at: t.spans[0].end) != nil && t.span(at: t.spans[0].end + 0.01) == nil)
    }
}
