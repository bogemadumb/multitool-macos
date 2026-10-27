import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct SmoothCurveTests {
    @Test func responseShortensTheTimeConstant() {
        #expect(SmoothCurve(response: 0).baseTau > SmoothCurve(response: 50).baseTau)
        #expect(SmoothCurve(response: 50).baseTau > SmoothCurve(response: 100).baseTau)
        #expect(abs(SmoothCurve(response: 100).baseTau - SmoothCurve.minTau) < 1e-9)
        #expect(abs(SmoothCurve(response: 0).baseTau - SmoothCurve.maxTau) < 1e-9)
    }

    @Test func inputsAreClamped() {
        #expect(SmoothCurve(response: 900, coast: -4).response == 100)
        #expect(SmoothCurve(response: 900, coast: -4).coast == 0)
    }

    @Test func zeroCoastNeverStretches() {
        let c = SmoothCurve(response: 65, coast: 0)
        #expect(c.stretch(progress: 1) == 1)
    }

    @Test func coastStretchGrowsWithProgressToTheCap() {
        let c = SmoothCurve(response: 65, coast: 100)
        #expect(c.stretch(progress: 0) == 1)
        #expect(c.stretch(progress: 0.5) < c.stretch(progress: 1))
        #expect(abs(c.stretch(progress: 1) - SmoothCurve.maxCoastStretch) < 1e-9)
        #expect(c.stretch(progress: 7) == c.stretch(progress: 1))
    }

    @Test func stepNeverOvershootsAndKeepsSign() {
        let c = SmoothCurve()
        let up = c.step(remaining: 100, glide: 100, dt: 0.016)
        let down = c.step(remaining: -100, glide: 100, dt: 0.016)
        #expect(up > 0 && up < 100 && down == -up)
        #expect(c.step(remaining: 100, glide: 100, dt: 10) <= 100)
    }

    @Test func badInputsProduceNothing() {
        let c = SmoothCurve()
        #expect(c.step(remaining: 0, glide: 0, dt: 0.016) == 0)
        #expect(c.step(remaining: 50, glide: 50, dt: 0) == 0)
        #expect(c.step(remaining: .nan, glide: 50, dt: 0.016) == 0)
        #expect(c.step(remaining: 50, glide: 50, dt: .infinity) == 0)
    }

    @Test func tinyLeftoverIsFlushedInOneStep() {
        let c = SmoothCurve()
        #expect(c.step(remaining: 0.3, glide: 40, dt: 0.001) == 0.3)
        #expect(c.step(remaining: -0.3, glide: 40, dt: 0.001) == -0.3)
    }

    @Test func longStallIsClampedToMaxFrame() {
        let c = SmoothCurve(response: 100)
        let stalled = c.step(remaining: 400, glide: 400, dt: 5)
        let capped = c.step(remaining: 400, glide: 400, dt: SmoothCurve.maxFrame)
        #expect(stalled == capped && stalled < 400)
    }

    @Test func easingIsExponentialAboveTheFloor() {
        let c = SmoothCurve(response: 50, coast: 0)
        let one = c.step(remaining: 1000, glide: 1000, dt: 0.032)
        let a = c.step(remaining: 1000, glide: 1000, dt: 0.016)
        let b = c.step(remaining: 1000 - a, glide: 1000, dt: 0.016)
        #expect(abs(one - (a + b)) < 1.0)
    }
}

@Suite struct SmoothEngineTests {
    private func drain(_ e: inout SmoothScrollEngine, dt: TimeInterval = 1.0 / 60, limit: Int = 4000) -> (v: Double, h: Double, frames: Int) {
        var v = 0.0, h = 0.0, n = 0
        while e.isActive && n < limit {
            let f = e.advance(dt: dt)
            v += f.vertical
            h += f.horizontal
            n += 1
        }
        return (v, h, n)
    }

    @Test func entireBudgetIsEventuallyEmitted() {
        var e = SmoothScrollEngine()
        e.add(vertical: 120, horizontal: -45)
        let r = drain(&e)
        #expect(abs(r.v - 120) < 1e-6 && abs(r.h + 45) < 1e-6 && !e.isActive)
    }

    @Test func glideDecaysMonotonicallyDownToTheFloor() {
        var e = SmoothScrollEngine(curve: SmoothCurve(response: 65, coast: 0))
        e.add(vertical: 300, horizontal: 0)
        var last = Double.infinity
        var slowed = false
        var frames = 0
        while e.isActive && frames < 2000 {
            let f = e.advance(dt: 1.0 / 60)
            if f.finished { break }
            if f.vertical < last - 1e-9 { slowed = true }
            #expect(f.vertical <= last + 1e-9)
            last = f.vertical
            frames += 1
        }
        #expect(slowed && frames > 5)
    }

    @Test func sameDirectionTicksAccumulate() {
        var e = SmoothScrollEngine()
        e.add(vertical: 40, horizontal: 0)
        e.add(vertical: 40, horizontal: 0)
        #expect(e.remainingVertical == 80)
    }

    @Test func directionChangeReplacesTheTail() {
        var e = SmoothScrollEngine()
        e.add(vertical: 200, horizontal: 0)
        _ = e.advance(dt: 1.0 / 60)
        e.add(vertical: -40, horizontal: 0)
        #expect(e.remainingVertical == -40)
        let r = drain(&e)
        #expect(abs(r.v + 40) < 1e-6)
    }

    @Test func axesAreIndependentOnReversal() {
        var e = SmoothScrollEngine()
        e.add(vertical: 100, horizontal: 100)
        e.add(vertical: -10, horizontal: 20)
        #expect(e.remainingVertical == -10 && e.remainingHorizontal == 120)
    }

    @Test func frameRateDoesNotChangeTotalDistanceOrBySomuchTheDuration() {
        var a = SmoothScrollEngine(), b = SmoothScrollEngine()
        a.add(vertical: 200, horizontal: 0)
        b.add(vertical: 200, horizontal: 0)
        let ra = drain(&a, dt: 1.0 / 60)
        let rb = drain(&b, dt: 1.0 / 120)
        #expect(abs(ra.v - rb.v) < 1e-6)
        let ta = Double(ra.frames) / 60, tb = Double(rb.frames) / 120
        #expect(abs(ta - tb) < 0.35)
    }

    @Test func coastLengthensTheGlide() {
        var plain = SmoothScrollEngine(curve: SmoothCurve(response: 65, coast: 0))
        var coasting = SmoothScrollEngine(curve: SmoothCurve(response: 65, coast: 100))
        plain.add(vertical: 200, horizontal: 0)
        coasting.add(vertical: 200, horizontal: 0)
        #expect(drain(&coasting).frames > drain(&plain).frames)
    }

    @Test func higherResponseFinishesSooner() {
        var slow = SmoothScrollEngine(curve: SmoothCurve(response: 0, coast: 0))
        var fast = SmoothScrollEngine(curve: SmoothCurve(response: 100, coast: 0))
        slow.add(vertical: 200, horizontal: 0)
        fast.add(vertical: 200, horizontal: 0)
        #expect(drain(&fast).frames < drain(&slow).frames)
    }

    @Test func nonFiniteInputIsIgnored() {
        var e = SmoothScrollEngine()
        e.add(vertical: .nan, horizontal: .infinity)
        #expect(!e.isActive)
    }

    @Test func resetStopsTheGlide() {
        var e = SmoothScrollEngine()
        e.add(vertical: 100, horizontal: 100)
        e.reset()
        #expect(!e.isActive && e.advance(dt: 0.016).finished)
    }

    @Test func anySingleNotchSettlesWithinAFewSeconds() {
        var e = SmoothScrollEngine(curve: SmoothCurve(response: 0, coast: 100))
        e.add(vertical: 100, horizontal: 0)
        #expect(drain(&e).frames < 60 * 3)
    }
}

@Suite struct SubPixelTests {
    @Test func fractionsAreCarriedNotLost() {
        var s = SubPixel()
        var total = 0
        for _ in 0..<10 { total += s.take(0.3, final: false) }
        #expect(total == 3 && abs(s.carry) < 1e-9)
    }

    @Test func negativeFractionsCarryToo() {
        var s = SubPixel()
        var total = 0
        for _ in 0..<10 { total += s.take(-0.3, final: false) }
        #expect(total == -3)
    }

    @Test func finalFrameRoundsTheRemainder() {
        var s = SubPixel()
        _ = s.take(0.6, final: false)
        #expect(s.take(0.5, final: true) == 1)
        #expect(s.carry == 0)
    }

    @Test func reversalDropsTheOldFraction() {
        var s = SubPixel()
        _ = s.take(0.8, final: false)
        #expect(s.take(-1.2, final: false) == -1)
        #expect(abs(s.carry + 0.2) < 1e-9)
    }

    @Test func nonFiniteGivesZero() {
        var s = SubPixel()
        #expect(s.take(.nan, final: false) == 0)
    }
}

@Suite struct SmoothInputTests {
    @Test func discreteTickIsStepPixels() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 1, point: 0, fixed: 0.1))
        #expect(SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: false).vertical == 40)
        #expect(SmoothInput.pixels(s, step: 80, linearLines: nil, shiftRedirect: false).vertical == 80)
    }

    @Test func accelerationFromTheSystemIsPreservedInTicks() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 3, point: 0, fixed: 0.3))
        #expect(SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: false).vertical == 120)
    }

    @Test func linearLinesAreConvertedBackToNotches() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: -3, point: -30, fixed: -3))
        #expect(SmoothInput.pixels(s, step: 40, linearLines: 3, shiftRedirect: false).vertical == -40)
    }

    @Test func continuousEventsScaleByStepOverDefault() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 0, point: 20, fixed: 2), isContinuous: true)
        #expect(SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: false).vertical == 20)
        #expect(SmoothInput.pixels(s, step: 80, linearLines: nil, shiftRedirect: false).vertical == 40)
    }

    @Test func continuousFallsBackToFixedPointLines() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 0, point: 0, fixed: 0.5), isContinuous: true)
        #expect(SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: false).vertical == 5)
    }

    @Test func shiftMovesVerticalToHorizontalWhenAsked() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 1, fixed: 1), flags: .maskShift)
        let on = SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: true)
        #expect(on.vertical == 0 && on.horizontal == 40)
        let off = SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: false)
        #expect(off.vertical == 40 && off.horizontal == 0)
    }

    @Test func shiftLeavesTwoAxisEventsAlone() {
        let s = ScrollSample(vertical: ScrollAxisDelta(line: 1, fixed: 1), horizontal: ScrollAxisDelta(line: 1, fixed: 1), flags: .maskShift)
        let r = SmoothInput.pixels(s, step: 40, linearLines: nil, shiftRedirect: true)
        #expect(r.vertical == 40 && r.horizontal == 40)
    }
}

@Suite struct SmoothRunnerTests {
    private func make(response: Int = 65, coast: Int = 0) -> (SmoothScrollRunner, InpTicker, InpPoster, InpClock) {
        let t = InpTicker(), p = InpPoster(), c = InpClock()
        let r = SmoothScrollRunner(ticker: t, poster: p, curve: SmoothCurve(response: response, coast: coast), clock: { c.now })
        return (r, t, p, c)
    }

    private func run(_ r: SmoothScrollRunner, _ c: InpClock, dt: TimeInterval = 1.0 / 60, limit: Int = 3000) {
        var n = 0
        while r.running && n < limit {
            c.now += dt
            r.tick()
            n += 1
        }
    }

    @Test func enqueueStartsTheTickerOnce() {
        let (r, t, _, _) = make()
        r.enqueue(vertical: 40, horizontal: 0, flags: [])
        r.enqueue(vertical: 40, horizontal: 0, flags: [])
        #expect(t.starts == 1 && r.running)
    }

    @Test func totalPostedEqualsTheWholeInputInPixels() {
        let (r, t, p, c) = make()
        r.enqueue(vertical: 40, horizontal: 0, flags: [])
        r.enqueue(vertical: 40, horizontal: 0, flags: [])
        run(r, c)
        #expect(p.totalVertical == 80 && p.totalHorizontal == 0)
        #expect(!r.running && !t.active && t.stops == 1)
    }

    @Test func fractionalDistancesStillLandOnTheRoundedTotal() {
        let (r, _, p, c) = make()
        r.enqueue(vertical: 13.4, horizontal: -7.6, flags: [])
        run(r, c)
        #expect(p.totalVertical == 13 && p.totalHorizontal == -8)
    }

    @Test func manySmallFramesNeverPostZeroEvents() {
        let (r, _, p, c) = make()
        r.enqueue(vertical: 90, horizontal: 0, flags: [])
        run(r, c, dt: 1.0 / 240)
        #expect(p.posts.allSatisfy { $0.v != 0 || $0.h != 0 })
        #expect(p.totalVertical == 90)
    }

    @Test func eachFrameMovesLessAndLessOnTheTail() {
        let (r, _, p, c) = make(response: 65)
        r.enqueue(vertical: 300, horizontal: 0, flags: [])
        run(r, c)
        #expect(p.posts.count > 5)
        #expect(abs(p.posts[1].v) >= abs(p.posts[p.posts.count - 2].v))
    }

    @Test func reversalMidGlideTurnsAroundImmediately() {
        let (r, _, p, c) = make()
        r.enqueue(vertical: 200, horizontal: 0, flags: [])
        for _ in 0..<3 { c.now += 1.0 / 60; r.tick() }
        let before = p.totalVertical
        r.enqueue(vertical: -40, horizontal: 0, flags: [])
        run(r, c)
        #expect(p.totalVertical == before - 40)
        #expect(before > 0)
    }

    @Test func flagsOfTheLastTickAreUsedForPosting() {
        let (r, _, p, c) = make()
        r.enqueue(vertical: 40, horizontal: 0, flags: .maskCommand)
        run(r, c)
        #expect(p.posts.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    @Test func cancelStopsEverythingAndForgetsTheTail() {
        let (r, t, p, c) = make()
        r.enqueue(vertical: 500, horizontal: 0, flags: [])
        c.now += 1.0 / 60
        r.tick()
        let seen = p.posts.count
        r.cancel()
        c.now += 1
        r.tick()
        #expect(!r.running && !t.active && p.posts.count == seen && !r.engine.isActive)
    }

    @Test func zeroInputDoesNotStartAnything() {
        let (r, t, _, _) = make()
        r.enqueue(vertical: 0, horizontal: 0, flags: [])
        #expect(!r.running && t.starts == 0)
    }

    @Test func curveCanBeSwappedLive() {
        let (r, _, _, _) = make(response: 0)
        r.setCurve(SmoothCurve(response: 100, coast: 50))
        #expect(r.engine.curve.response == 100 && r.engine.curve.coast == 50)
    }

    @Test func horizontalOnlyGlidePostsHorizontalOnly() {
        let (r, _, p, c) = make()
        r.enqueue(vertical: 0, horizontal: 60, flags: [])
        run(r, c)
        #expect(p.totalVertical == 0 && p.totalHorizontal == 60)
    }
}
