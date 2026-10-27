import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ClickDebounceTests {
    private func supp(_ f: inout ClickDebounce, _ b: Int64, _ p: ClickPhase, _ t: TimeInterval) -> Bool {
        f.shouldSuppress(button: b, phase: p, at: t)
    }

    @Test func healthyClickPassesBothEdges() {
        var f = ClickDebounce(windowMs: 25)
        #expect(!supp(&f, 0, .down, 1.000))
        #expect(!supp(&f, 0, .up, 1.080))
        #expect(f.suppressedCount == 0)
    }

    @Test func bounceInsideWindowIsDroppedTogetherWithItsRelease() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.000)
        _ = supp(&f, 0, .up, 1.050)
        #expect(supp(&f, 0, .down, 1.060))
        #expect(supp(&f, 0, .up, 1.070))
        #expect(f.suppressedCount == 2)
    }

    @Test func realDoubleClickIsPreserved() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.000)
        _ = supp(&f, 0, .up, 1.040)
        #expect(!supp(&f, 0, .down, 1.040 + 0.090))
        #expect(!supp(&f, 0, .up, 1.200))
        #expect(f.suppressedCount == 0)
    }

    @Test func gapExactlyAtTheWindowIsNotABounce() {
        var f = ClickDebounce(windowMs: 40)
        _ = supp(&f, 0, .down, 5.0)
        _ = supp(&f, 0, .up, 5.1)
        #expect(!supp(&f, 0, .down, 5.14))
    }

    @Test func releaseOfAcceptedPressIsNeverSuppressed() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        _ = supp(&f, 0, .up, 1.01)
        _ = supp(&f, 0, .down, 1.015)
        f.reset()
        #expect(!supp(&f, 0, .up, 1.02))
    }

    @Test func dragWithAcceptedPressIsNotBroken() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        for i in 1...20 { #expect(!supp(&f, 0, .dragged, 1.0 + Double(i) * 0.005)) }
        #expect(!supp(&f, 0, .up, 1.5))
    }

    @Test func dragOfSuppressedPressIsSuppressedToo() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        _ = supp(&f, 0, .up, 1.01)
        #expect(supp(&f, 0, .down, 1.02))
        #expect(supp(&f, 0, .dragged, 1.025))
        #expect(supp(&f, 0, .up, 1.03))
        #expect(!supp(&f, 0, .dragged, 1.5))
    }

    @Test func quickClickAfterDragReleaseStillFollowsTheWindow() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        _ = supp(&f, 0, .dragged, 1.1)
        _ = supp(&f, 0, .up, 1.2)
        #expect(supp(&f, 0, .down, 1.21))
    }

    @Test func buttonsAreIndependent() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        _ = supp(&f, 0, .up, 1.01)
        #expect(!supp(&f, 1, .down, 1.015))
        #expect(!supp(&f, 2, .down, 1.016))
    }

    @Test func repeatedDownWhilePressedIsNoise() {
        var f = ClickDebounce(windowMs: 25)
        #expect(!supp(&f, 0, .down, 1.0))
        #expect(supp(&f, 0, .down, 1.004))
        #expect(!supp(&f, 0, .up, 1.1))
    }

    @Test func lostReleaseDoesNotLockTheButtonForever() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 1.0)
        #expect(!supp(&f, 0, .down, 1.0 + ClickDebounce.staleDownSeconds + 0.5))
    }

    @Test func unmatchedReleasePasses() {
        var f = ClickDebounce(windowMs: 25)
        #expect(!supp(&f, 0, .up, 1.0))
    }

    @Test func clockGoingBackwardsResetsTheButton() {
        var f = ClickDebounce(windowMs: 25)
        _ = supp(&f, 0, .down, 100)
        _ = supp(&f, 0, .up, 100.01)
        #expect(!supp(&f, 0, .down, 5))
    }

    @Test func windowCanBeChangedLive() {
        var f = ClickDebounce(windowMs: 5)
        _ = supp(&f, 0, .down, 1.0)
        _ = supp(&f, 0, .up, 1.01)
        f.windowSeconds = 0.1
        #expect(supp(&f, 0, .down, 1.05))
    }

    @Test func resolveMapsOnlyPrimarySecondaryAndMiddle() {
        #expect(ClickDebounce.resolve(type: .leftMouseDown, buttonNumber: 0)?.button == 0)
        #expect(ClickDebounce.resolve(type: .rightMouseUp, buttonNumber: 1)?.phase == .up)
        #expect(ClickDebounce.resolve(type: .otherMouseDown, buttonNumber: 2)?.button == 2)
        #expect(ClickDebounce.resolve(type: .otherMouseDown, buttonNumber: 3) == nil)
        #expect(ClickDebounce.resolve(type: .otherMouseDragged, buttonNumber: 4) == nil)
        #expect(ClickDebounce.resolve(type: .mouseMoved, buttonNumber: 0) == nil)
    }

    @Test func settingsChooseTheButtons() {
        var s = ClickDebounceSettings()
        s.middle = false
        #expect(s.covers(button: 0) && s.covers(button: 1) && !s.covers(button: 2) && !s.covers(button: 3))
        s.windowMs = 9999
        #expect(s.sanitized.windowMs == 120)
        s.windowMs = 0
        #expect(s.sanitized.windowMs == 5)
    }
}

@Suite struct KeyDebounceTests {
    private func filter(_ ms: Int = 30, keys: [Int64: Int] = [:], apps: [String] = []) -> KeyDebounce {
        var s = KeyDebounceSettings()
        s.globalWindowMs = ms
        s.keyWindows = keys
        s.ignoredApps = AppExceptionList(apps)
        return KeyDebounce(settings: s)
    }

    private func s(_ f: inout KeyDebounce, _ code: Int64, _ p: KeyPhase, _ t: TimeInterval, rep: Bool = false, app: String? = nil) -> Bool {
        f.shouldSuppress(keyCode: code, phase: p, isAutoRepeat: rep, at: t, frontmostBundleID: app)
    }

    @Test func normalTypingPasses() {
        var f = filter()
        for (i, code) in [Int64(0), 11, 8, 2].enumerated() {
            #expect(!s(&f, code, .down, 1 + Double(i) * 0.1))
            #expect(!s(&f, code, .up, 1.05 + Double(i) * 0.1))
        }
        #expect(f.suppressedCount == 0)
    }

    @Test func chatterAfterReleaseIsDroppedWithItsRelease() {
        var f = filter(30)
        _ = s(&f, 35, .down, 1.000)
        _ = s(&f, 35, .up, 1.060)
        #expect(s(&f, 35, .down, 1.070))
        #expect(s(&f, 35, .up, 1.080))
        #expect(!s(&f, 35, .down, 1.300))
    }

    @Test func doubleDownWithoutReleaseInsideWindowIsDropped() {
        var f = filter(30)
        #expect(!s(&f, 35, .down, 1.000))
        #expect(s(&f, 35, .down, 1.010))
        #expect(!s(&f, 35, .up, 1.100))
    }

    @Test func autorepeatAlwaysPasses() {
        var f = filter(500)
        _ = s(&f, 51, .down, 1.0)
        for i in 1...20 { #expect(!s(&f, 51, .down, 1.0 + Double(i) * 0.03, rep: true)) }
        #expect(f.suppressedCount == 0)
    }

    @Test func heldKeyThenQuickRetapAfterWindowPasses() {
        var f = filter(30)
        _ = s(&f, 51, .down, 1.0)
        _ = s(&f, 51, .down, 1.5, rep: true)
        _ = s(&f, 51, .up, 2.0)
        #expect(!s(&f, 51, .down, 2.2))
    }

    @Test func perKeyWindowOverridesGlobal() {
        var f = filter(10, keys: [35: 100])
        _ = s(&f, 35, .down, 1.0)
        _ = s(&f, 35, .up, 1.02)
        #expect(s(&f, 35, .down, 1.08))
        _ = s(&f, 0, .down, 1.0)
        _ = s(&f, 0, .up, 1.02)
        #expect(!s(&f, 0, .down, 1.08))
    }

    @Test func zeroWindowIgnoresThatKey() {
        var f = filter(100, keys: [49: 0])
        _ = s(&f, 49, .down, 1.0)
        _ = s(&f, 49, .up, 1.001)
        #expect(!s(&f, 49, .down, 1.002))
        #expect(f.suppressedCount == 0)
    }

    @Test func modifierKeysAreNeverFiltered() {
        var f = filter(500)
        for code in KeyDebounce.modifierKeyCodes {
            _ = s(&f, code, .down, 1.0)
            _ = s(&f, code, .up, 1.001)
            #expect(!s(&f, code, .down, 1.002))
        }
        #expect(f.suppressedCount == 0)
    }

    @Test func modifierSetCoversBothSidesAndFn() {
        for code: Int64 in [54, 55, 56, 58, 59, 60, 61, 62, 63, 57, 179] { #expect(KeyDebounce.modifierKeyCodes.contains(code)) }
        #expect(!KeyDebounce.modifierKeyCodes.contains(0))
    }

    @Test func keysAreIndependent() {
        var f = filter(50)
        _ = s(&f, 0, .down, 1.0)
        _ = s(&f, 0, .up, 1.01)
        #expect(!s(&f, 11, .down, 1.012))
    }

    @Test func ignoredAppDisablesTheFilter() {
        var f = filter(100, apps: ["com.game.rhythm"])
        _ = s(&f, 2, .down, 1.0, app: "com.game.rhythm")
        _ = s(&f, 2, .up, 1.005, app: "com.game.rhythm")
        #expect(!s(&f, 2, .down, 1.01, app: "com.game.rhythm"))
        _ = s(&f, 2, .up, 1.012, app: "com.game.rhythm")
        _ = s(&f, 2, .down, 1.02)
        _ = s(&f, 2, .up, 1.03)
        #expect(s(&f, 2, .down, 1.04))
    }

    @Test func ignoredAppPatternsSupportPrefix() {
        var f = filter(100, apps: ["com.valve.*"])
        _ = s(&f, 2, .down, 1.0, app: "com.valve.steam")
        _ = s(&f, 2, .up, 1.001, app: "com.valve.steam")
        #expect(!s(&f, 2, .down, 1.002, app: "com.valve.steam"))
    }

    @Test func unmatchedReleasePasses() {
        var f = filter()
        #expect(!s(&f, 0, .up, 1.0))
    }

    @Test func resetForgetsEverything() {
        var f = filter(100)
        _ = s(&f, 0, .down, 1.0)
        _ = s(&f, 0, .up, 1.01)
        f.reset()
        #expect(!s(&f, 0, .down, 1.02))
    }

    @Test func clockGoingBackwardsResetsTheKey() {
        var f = filter(100)
        _ = s(&f, 0, .down, 100)
        _ = s(&f, 0, .up, 100.01)
        #expect(!s(&f, 0, .down, 3))
    }

    @Test func windowsAreSanitizedAndEncoded() {
        var st = KeyDebounceSettings()
        st.globalWindowMs = 900
        st.keyWindows = [0: -5, 11: 70]
        #expect(st.sanitized.globalWindowMs == 500 && st.sanitized.keyWindows == [0: 0, 11: 70])
        let raw = KeyDebounceSettings.encode([11: 70, 0: 20])
        #expect(raw == "0:20,11:70")
        #expect(KeyDebounceSettings.decode(raw) == [0: 20, 11: 70])
        #expect(KeyDebounceSettings.decode("x:1,5:abc,7:9999,8:12") == [7: 500, 8: 12])
    }

    @Test func windowLookupFallsBackToGlobal() {
        var st = KeyDebounceSettings()
        st.globalWindowMs = 25
        st.keyWindows = [3: 0]
        #expect(st.windowMs(for: 3) == 0 && st.windowMs(for: 4) == 25)
    }
}

@Suite struct EventTimeTests {
    @Test func nanosecondTimestampsAreUsedAsIs() {
        let tb = EventTime.Timebase(numer: 125, denom: 3)
        let now = 5000.0
        #expect(abs(EventTime.seconds(raw: UInt64(now * 1e9), nowSeconds: now, timebase: tb) - now) < 1e-6)
    }

    @Test func machTickTimestampsAreConverted() {
        let tb = EventTime.Timebase(numer: 125, denom: 3)
        let now = 5000.0
        let ticks = UInt64(now * 1e9 * 3 / 125)
        #expect(abs(EventTime.seconds(raw: ticks, nowSeconds: now, timebase: tb) - now) < 1e-3)
    }

    @Test func identityTimebaseNeverMisreads() {
        let tb = EventTime.Timebase(numer: 1, denom: 1)
        #expect(abs(EventTime.seconds(raw: 7_000_000_000, nowSeconds: 7, timebase: tb) - 7) < 1e-9)
    }

    @Test func zeroDenominatorIsGuarded() {
        #expect(EventTime.Timebase(numer: 1, denom: 0).denom == 1)
    }

    @Test func eventWithoutTimestampFallsBackToNow() {
        let e = InpEvents.key(0, down: true)
        e.timestamp = 0
        #expect(EventTime.seconds(of: e, now: 42) == 42)
    }
}
