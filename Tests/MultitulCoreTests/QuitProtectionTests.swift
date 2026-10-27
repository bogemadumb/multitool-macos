import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct QuitProtectionEngineTests {
    private struct Rig {
        let engine: QuitProtectionEngine
        let timers: ActTimers
        let keys: ActKeys
        let front: ActFront
        let clock: ActClock
        let hud: HudLog
    }

    final class HudLog { var lines: [String] = [] }

    private func rig(_ settings: QuitProtectionSettings = QuitProtectionSettings(), bundle: String? = "com.apple.Safari") -> Rig {
        let timers = ActTimers()
        let keys = ActKeys()
        let front = ActFront(bundle, name: "Safari")
        let clock = ActClock()
        let log = HudLog()
        let e = QuitProtectionEngine(settings: settings, frontmost: front, timers: timers, keys: keys, hud: { log.lines.append($0) }, clock: { clock.now })
        return Rig(engine: e, timers: timers, keys: keys, front: front, clock: clock, hud: log)
    }

    @Test func plainKeysAndOtherCombosPass() {
        let r = rig()
        #expect(r.engine.keyDown(keyCode: 0, flags: .maskCommand, isRepeat: false) == .pass)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: [], isRepeat: false) == .pass)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: [.maskCommand, .maskShift], isRepeat: false) == .pass)
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: .maskCommand, isRepeat: false) == .pass)
    }

    @Test func holdSwallowsThenPostsAfterTimer() {
        let r = rig()
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .drop)
        #expect(r.timers.items.count == 1 && r.timers.items[0].delay == 1.0)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: true) == .drop)
        #expect(r.timers.items.count == 1)
        r.timers.fireAll()
        #expect(r.keys.posts.count == 1 && r.keys.posts[0].code == Keys.q && r.keys.posts[0].flags == .maskCommand)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: true) == .drop)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .drop)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .pass)
        #expect(r.engine.confirmedCount == 1)
    }

    @Test func releasingEarlyCancelsTheTimer() {
        let r = rig()
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .drop)
        #expect(r.timers.items[0].handle.cancelled)
        r.timers.fireAll()
        #expect(r.keys.posts.isEmpty)
    }

    @Test func releasingCommandCancelsHoldAndKeepsKeySwallowed() {
        let r = rig()
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        r.engine.flagsChanged([])
        r.timers.fireAll()
        #expect(r.keys.posts.isEmpty)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .drop)
    }

    @Test func holdDurationFollowsSettings() {
        var s = QuitProtectionSettings()
        s.quit.holdMs = 2500
        let r = rig(s)
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        #expect(r.timers.items[0].delay == 2.5)
    }

    @Test func doublePressPassesSecondWithinWindow() {
        var s = QuitProtectionSettings()
        s.quit.mode = .doublePress
        let r = rig(s)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .drop)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .drop)
        r.clock.now += 1.0
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .pass)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .pass)
        #expect(r.engine.confirmedCount == 1)
    }

    @Test func doublePressTooLateOrInOtherAppStartsOver() {
        var s = QuitProtectionSettings()
        s.quit.mode = .doublePress
        let r = rig(s)
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        _ = r.engine.keyUp(keyCode: Keys.q)
        r.clock.now += 5
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .drop)
        _ = r.engine.keyUp(keyCode: Keys.q)
        r.front.set("com.apple.finder")
        r.clock.now += 0.5
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .drop)
    }

    @Test func extraModifierRewritesAndPlainIsBlocked() {
        var s = QuitProtectionSettings()
        s.close.mode = .extraModifier
        s.close.extra = .option
        let r = rig(s)
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: .maskCommand, isRepeat: false) == .drop)
        #expect(r.engine.keyUp(keyCode: Keys.w) == .drop)
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: [.maskCommand, .maskAlternate], isRepeat: false) == .rewrite(.maskCommand))
    }

    @Test func extraModifierKeepsOtherFlagsLikeCapsLock() {
        var s = QuitProtectionSettings()
        s.quit.mode = .extraModifier
        s.quit.extra = .shift
        let r = rig(s)
        let d = r.engine.keyDown(keyCode: Keys.q, flags: [.maskCommand, .maskShift, .maskAlphaShift], isRepeat: false)
        #expect(d == .rewrite([.maskCommand, .maskAlphaShift]))
    }

    @Test func offModeAndExcludedAppsPass() {
        var s = QuitProtectionSettings()
        s.quit.scope = .except
        s.quit.apps = AppExceptionList(["com.apple.Safari"])
        let r = rig(s)
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .pass)
        r.front.set("com.apple.finder")
        #expect(r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false) == .drop)
    }

    @Test func onlyScopeProtectsListedAppsOnly() {
        var s = QuitProtectionSettings()
        s.close.mode = .hold
        s.close.scope = .only
        s.close.apps = AppExceptionList(["com.google.Chrome*"])
        let r = rig(s, bundle: "com.apple.Safari")
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: .maskCommand, isRepeat: false) == .pass)
        r.front.set("com.google.Chrome")
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: .maskCommand, isRepeat: false) == .drop)
    }

    @Test func qAndWAreIndependent() {
        var s = QuitProtectionSettings()
        s.close.mode = .doublePress
        let r = rig(s)
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        #expect(r.engine.keyDown(keyCode: Keys.w, flags: .maskCommand, isRepeat: false) == .drop)
        #expect(r.timers.items.count == 1)
    }

    @Test func hudTextNamesKeyAndApp() {
        let r = rig()
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        #expect(r.hud.lines.count == 1 && r.hud.lines[0].contains("⌘Q") && r.hud.lines[0].contains("Safari"))
    }

    @Test func hudCanBeSilenced() {
        var s = QuitProtectionSettings()
        s.showHud = false
        let r = rig(s)
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        #expect(r.hud.lines.isEmpty)
    }

    @Test func resetCancelsEverything() {
        let r = rig()
        _ = r.engine.keyDown(keyCode: Keys.q, flags: .maskCommand, isRepeat: false)
        r.engine.reset()
        #expect(r.timers.items[0].handle.cancelled)
        #expect(r.engine.keyUp(keyCode: Keys.q) == .pass)
    }

    @Test func reservedCombosFollowModes() {
        var s = QuitProtectionSettings()
        #expect(s.reservedCombos == [InterceptedKeys.quit])
        s.close.mode = .hold
        s.quit.mode = .off
        #expect(s.reservedCombos == [InterceptedKeys.close])
    }
}

@Suite struct QuitProtectionStageTests {
    private func rig(_ settings: QuitProtectionSettings = QuitProtectionSettings()) -> (InpTapBackend, ActTimers, ActKeys) {
        let (hub, be) = actHub()
        let timers = ActTimers()
        let keys = ActKeys()
        let e = QuitProtectionEngine(settings: settings, frontmost: ActFront("com.example.app"), timers: timers, keys: keys)
        actKeep(QuitProtectionStage(hub: hub, engine: e)).start()
        return (be, timers, keys)
    }

    @Test func commandQIsHeldBackThenReleasedByTimer() {
        let (be, timers, keys) = rig()
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.q), down: true, flags: .maskCommand)) == .drop)
        timers.fireAll()
        #expect(keys.codes() == [Keys.q])
        #expect(be.fire(.keyUp, ActEvents.key(UInt16(Keys.q), down: false, flags: .maskCommand)) == .drop)
    }

    @Test func commandReleaseViaFlagsChangedCancels() {
        let (be, timers, keys) = rig()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.q), down: true, flags: .maskCommand))
        #expect(be.fire(.flagsChanged, ActEvents.flags(55, raw: 0)) == .pass)
        timers.fireAll()
        #expect(keys.posts.isEmpty)
    }

    @Test func extraModifierRewritesTheLiveEvent() {
        var s = QuitProtectionSettings()
        s.quit.mode = .extraModifier
        let (be, _, _) = rig(s)
        let e = ActEvents.key(UInt16(Keys.q), down: true, flags: [.maskCommand, .maskAlternate])
        #expect(be.fire(.keyDown, e) == .modified)
        #expect(e.flags.contains(.maskCommand) && !e.flags.contains(.maskAlternate))
    }

    @Test func syntheticConfirmedPostIsNotInterceptedAgain() {
        let (be, timers, keys) = rig()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.q), down: true, flags: .maskCommand))
        timers.fireAll()
        let posted = ActEvents.key(UInt16(Keys.q), down: true, flags: .maskCommand)
        EventTapHub.markSynthetic(posted)
        #expect(be.fire(.keyDown, posted) == .pass)
        #expect(keys.posts.count == 1)
    }

    @Test func unrelatedKeysAreUntouched() {
        let (be, timers, _) = rig()
        #expect(be.fire(.keyDown, ActEvents.key(0, down: true, flags: .maskCommand)) == .pass)
        #expect(be.fire(.keyUp, ActEvents.key(0, down: false, flags: .maskCommand)) == .pass)
        #expect(timers.items.isEmpty)
    }
}
