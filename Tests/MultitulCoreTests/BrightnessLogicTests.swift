import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func snap(_ id: UInt32, x: CGFloat, w: CGFloat = 1000, builtin: Bool = false, main: Bool = false) -> DisplaySnapshot {
    DisplaySnapshot(cgID: id, identity: DisplayIdentity(vendor: 1, model: id, serial: 0, isBuiltin: builtin), isMain: main,
                    frame: CGRect(x: x, y: 0, width: w, height: 800), name: "D\(id)")
}

@Suite struct BrightnessStepTests {
    @Test func coarseStepFromGrid() {
        #expect(BrightnessStep.next(0.5, up: true, fine: false) == 0.5625)
        #expect(BrightnessStep.next(0.5, up: false, fine: false) == 0.4375)
    }

    @Test func offGridValueLandsOnGridFirst() {
        #expect(BrightnessStep.next(0.51, up: true, fine: false) == 0.5625)
        #expect(BrightnessStep.next(0.51, up: false, fine: false) == 0.5)
    }

    @Test func fineStepIsQuarterOfCoarse() {
        #expect(BrightnessStep.next(0.5, up: true, fine: true) == 0.515625)
        #expect(BrightnessStep.fine * 4 == BrightnessStep.coarse)
    }

    @Test func clampsAtEnds() {
        #expect(BrightnessStep.next(1, up: true, fine: false) == 1)
        #expect(BrightnessStep.next(0, up: false, fine: false) == 0)
        #expect(BrightnessStep.next(0.99, up: true, fine: false) == 1)
        #expect(BrightnessStep.next(0.01, up: false, fine: false) == 0)
    }

    @Test func nonFiniteBecomesZero() {
        #expect(BrightnessStep.clamp(.nan) == 0)
        #expect(BrightnessStep.clamp(.infinity) == 0)
        #expect(BrightnessStep.clamp(5) == 1)
        #expect(BrightnessStep.clamp(-5) == 0)
    }

    @Test func sixteenPressesCoverRange() {
        var v = 0.0
        for _ in 0..<16 { v = BrightnessStep.next(v, up: true, fine: false) }
        #expect(v == 1)
    }

    @Test func percentAndSegments() {
        #expect(BrightnessStep.percent(0.5) == 50)
        #expect(BrightnessStep.percent(0.126) == 13)
        #expect(BrightnessStep.filledSegments(0.5) == 8)
        #expect(BrightnessStep.filledSegments(1) == 16)
        #expect(BrightnessStep.filledSegments(0) == 0)
    }
}

@Suite struct SystemKeyEventTests {
    private func data1(_ key: Int, state: Int, rep: Int = 0) -> Int { (key << 16) | (state << 8) | rep }

    @Test func parsesDownUpAndRepeat() {
        #expect(SystemKeyEvent(subtype: 8, data1: data1(2, state: 0xA)) == SystemKeyEvent(keyCode: 2, isDown: true, isRepeat: false))
        #expect(SystemKeyEvent(subtype: 8, data1: data1(3, state: 0xB)) == SystemKeyEvent(keyCode: 3, isDown: false, isRepeat: false))
        #expect(SystemKeyEvent(subtype: 8, data1: data1(2, state: 0xA, rep: 1))?.isRepeat == true)
    }

    @Test func rejectsOtherSubtypesAndStates() {
        #expect(SystemKeyEvent(subtype: 7, data1: data1(2, state: 0xA)) == nil)
        #expect(SystemKeyEvent(subtype: 8, data1: data1(2, state: 0x3)) == nil)
    }

    @Test func mapsBrightnessAndIlluminationKeys() {
        #expect(BrightnessKey(keyCode: 2) == .displayUp)
        #expect(BrightnessKey(keyCode: 3) == .displayDown)
        #expect(BrightnessKey(keyCode: 21) == .keyboardUp)
        #expect(BrightnessKey(keyCode: 22) == .keyboardDown)
        #expect(BrightnessKey(keyCode: 0) == nil)
        #expect(BrightnessKey(keyCode: 7) == nil)
        #expect(BrightnessKey.keyboardDown.isKeyboard && !BrightnessKey.keyboardDown.isUp)
    }

    @Test func modifiersFromCGFlags() {
        let m = KeyModifiers(cgFlags: [.maskAlternate, .maskShift])
        #expect(m.isFineStep)
        #expect(!m.belongsToSystem)
        #expect(KeyModifiers(cgFlags: [.maskCommand]).belongsToSystem)
        #expect(KeyModifiers(cgFlags: [.maskAlternate]).belongsToSystem)
        #expect(!KeyModifiers(cgFlags: []).belongsToSystem)
    }
}

@Suite struct BrightnessRoutingTests {
    private let a = snap(1, x: 0, builtin: true, main: true)
    private let b = snap(2, x: 1000)

    @Test func cursorInsideSecondDisplay() {
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 1500, y: 100), displays: [a, b], controllable: [1, 2], followCursor: true) == 2)
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 10, y: 10), displays: [a, b], controllable: [1, 2], followCursor: true) == 1)
    }

    @Test func edgeBelongsToRightDisplay() {
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 1000, y: 10), displays: [a, b], controllable: [1, 2], followCursor: true) == 2)
    }

    @Test func gapPicksNearest() {
        let far = snap(3, x: 5000)
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 2300, y: 100), displays: [a, b, far], controllable: [1, 2, 3], followCursor: true) == 2)
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 4500, y: 100), displays: [a, b, far], controllable: [1, 2, 3], followCursor: true) == 3)
    }

    @Test func notFollowingUsesMain() {
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 1500, y: 100), displays: [a, b], controllable: [1, 2], followCursor: false) == 1)
    }

    @Test func missingCursorUsesMain() {
        #expect(BrightnessRouter.target(cursor: nil, displays: [b, a], controllable: [1, 2], followCursor: true) == 1)
    }

    @Test func uncontrollableDisplayPassesToSystem() {
        #expect(BrightnessRouter.target(cursor: CGPoint(x: 1500, y: 100), displays: [a, b], controllable: [1], followCursor: true) == nil)
        #expect(BrightnessRouter.target(cursor: nil, displays: [], controllable: [], followCursor: true) == nil)
    }

    private func press(_ code: Int, down: Bool = true) -> SystemKeyEvent { SystemKeyEvent(keyCode: code, isDown: down, isRepeat: false) }

    @Test func keyDownAdjustsDisplayUnderCursor() {
        var r = BrightnessKeyRouter()
        let d = r.decide(press(2), modifiers: [], cursor: CGPoint(x: 1500, y: 10), displays: [a, b], controllable: [1, 2], keyboardAvailable: false)
        #expect(d == .adjustDisplay(cgID: 2, up: true, fine: false))
    }

    @Test func releaseFollowsHandledPress() {
        var r = BrightnessKeyRouter()
        _ = r.decide(press(3), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false)
        #expect(r.decide(press(3, down: false), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .swallow)
        #expect(r.decide(press(3, down: false), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .pass)
    }

    @Test func releaseWithoutPressPasses() {
        var r = BrightnessKeyRouter()
        #expect(r.decide(press(2, down: false), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .pass)
    }

    @Test func passedPressDoesNotSwallowRelease() {
        var r = BrightnessKeyRouter()
        _ = r.decide(press(2), modifiers: [], cursor: nil, displays: [a], controllable: [], keyboardAvailable: false)
        #expect(r.decide(press(2, down: false), modifiers: [], cursor: nil, displays: [a], controllable: [], keyboardAvailable: false) == .pass)
    }

    @Test func systemModifiersPass() {
        var r = BrightnessKeyRouter()
        #expect(r.decide(press(2), modifiers: [.command], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .pass)
        #expect(r.decide(press(2), modifiers: [.option], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .pass)
    }

    @Test func optionShiftIsFine() {
        var r = BrightnessKeyRouter()
        let d = r.decide(press(3), modifiers: [.option, .shift], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false)
        #expect(d == .adjustDisplay(cgID: 1, up: false, fine: true))
    }

    @Test func fineAlwaysSetting() {
        var r = BrightnessKeyRouter(fineAlways: true)
        let d = r.decide(press(2), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false)
        #expect(d == .adjustDisplay(cgID: 1, up: true, fine: true))
    }

    @Test func keyboardKeysNeedAvailabilityAndSetting() {
        var r = BrightnessKeyRouter()
        #expect(r.decide(press(21), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: false) == .pass)
        #expect(r.decide(press(21), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: true) == .adjustKeyboard(up: true, fine: false))
        var off = BrightnessKeyRouter(handleKeyboardKeys: false)
        #expect(off.decide(press(22), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: true) == .pass)
    }

    @Test func otherKeysPass() {
        var r = BrightnessKeyRouter()
        #expect(r.decide(press(0), modifiers: [], cursor: nil, displays: [a], controllable: [1], keyboardAvailable: true) == .pass)
    }
}

@Suite struct GammaMathTests {
    @Test func factorEndpoints() {
        #expect(GammaMath.dimFactor(for: 1) == 1)
        #expect(GammaMath.dimFactor(for: 0) == Float(GammaMath.defaultFloor))
        #expect(GammaMath.dimFactor(for: 0, floor: 0.2) == 0.2)
    }

    @Test func factorIsMonotonic() {
        var last: Float = -1
        for i in 0...20 {
            let f = GammaMath.dimFactor(for: Double(i) / 20)
            #expect(f > last)
            last = f
        }
    }

    @Test func identityTableEndpoints() {
        let t = GammaMath.identityTable()
        #expect(t.count == 256)
        #expect(t.first == 0)
        #expect(t.last == 1)
    }

    @Test func scalingKeepsShapeAndRange() {
        let t = GammaMath.scaled(GammaMath.identityTable(), factor: 0.5)
        #expect(t.last == 0.5)
        #expect(t[0] == 0)
        #expect(t[128] == GammaMath.identityTable()[128] * 0.5)
        #expect(GammaMath.scaled([0.4, 1.0], factor: 3) == [0.4, 1.0])
        #expect(GammaMath.scaled([0.4], factor: .nan) == [0.4])
    }

    @Test func factorRoundTripsToBrightness() {
        for b in [0.0, 0.25, 0.6, 1.0] {
            #expect(abs(GammaMath.brightness(forFactor: GammaMath.dimFactor(for: b)) - b) < 1e-5)
        }
    }
}

@Suite struct WriteCoalescerTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func firstWriteGoesImmediately() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        #expect(c.submit(0.5, now: t0) == 0.5)
        #expect(!c.hasPending)
    }

    @Test func burstKeepsOnlyLatest() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.1, now: t0)
        #expect(c.submit(0.2, now: t0.addingTimeInterval(0.01)) == nil)
        #expect(c.submit(0.3, now: t0.addingTimeInterval(0.02)) == nil)
        #expect(c.flushDue(now: t0.addingTimeInterval(0.05)) == nil)
        #expect(c.flushDue(now: t0.addingTimeInterval(0.11)) == 0.3)
        #expect(!c.hasPending)
    }

    @Test func waitTimeCountsDown() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.1, now: t0)
        _ = c.submit(0.2, now: t0.addingTimeInterval(0.04))
        let w = c.waitTime(now: t0.addingTimeInterval(0.04))
        #expect(w != nil && abs(w! - 0.06) < 1e-6)
        #expect(c.waitTime(now: t0.addingTimeInterval(0.2)) == 0)
    }

    @Test func nothingPendingMeansNoWait() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        #expect(c.waitTime(now: t0) == nil)
        _ = c.submit(0.1, now: t0)
        #expect(c.waitTime(now: t0) == nil)
    }

    @Test func sameValueIsNotResent() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.5, now: t0)
        #expect(c.submit(0.5, now: t0.addingTimeInterval(1)) == nil)
    }

    @Test func returningToSentValueDropsPendingWrite() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.5, now: t0)
        _ = c.submit(0.6, now: t0.addingTimeInterval(0.01))
        _ = c.submit(0.5, now: t0.addingTimeInterval(0.02))
        #expect(c.flushDue(now: t0.addingTimeInterval(0.5)) == nil)
    }

    @Test func afterIntervalNextWriteIsImmediate() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.1, now: t0)
        #expect(c.submit(0.2, now: t0.addingTimeInterval(0.2)) == 0.2)
    }

    @Test func resetForgetsEverything() {
        var c = WriteCoalescer<Double>(minInterval: 0.1)
        _ = c.submit(0.1, now: t0)
        _ = c.submit(0.2, now: t0.addingTimeInterval(0.01))
        c.reset()
        #expect(!c.hasPending)
        #expect(c.submit(0.1, now: t0.addingTimeInterval(0.02)) == 0.1)
    }
}
