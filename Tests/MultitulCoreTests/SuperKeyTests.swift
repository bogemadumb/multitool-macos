import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct SuperKeyMathTests {
    @Test func capsAddsConfiguredModifiers() {
        let f = SuperKeyMath.transformed([], source: .capsLock, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd)
        #expect(f == [.maskControl, .maskAlternate, .maskCommand])
    }

    @Test func rightModifierOwnFlagIsStrippedUnlessLeftHeld() {
        let rightCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        let out = SuperKeyMath.transformed(rightCmd, source: .rightCommand, modifiers: KeyCombo.ctrl | KeyCombo.opt)
        #expect(out == [.maskControl, .maskAlternate])
        let both = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10 | 0x08)
        #expect(SuperKeyMath.transformed(both, source: .rightCommand, modifiers: KeyCombo.ctrl).contains(.maskCommand))
    }

    @Test func otherHeldModifiersSurvive() {
        let f = SuperKeyMath.transformed(.maskShift, source: .capsLock, modifiers: KeyCombo.cmd)
        #expect(f == [.maskShift, .maskCommand])
    }

    @Test func sourceKeyCodesAreDistinct() {
        #expect(Set(SuperKeySource.allCases.map(\.keyCode)).count == SuperKeySource.allCases.count)
        #expect(SuperKeySource.capsLock.keyCode == Keys.f18)
    }
}

@Suite struct HIDMappingTests {
    @Test func parsesHidutilOutput() {
        let text = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
        )
        """
        #expect(HIDKeyMapping.parse(text) == [HIDMapping.capsToF18])
        #expect(HIDKeyMapping.parse("(null)").isEmpty)
        #expect(HIDKeyMapping.parse("garbage").isEmpty)
    }

    @Test func mergeKeepsForeignMappingsAndReplacesOwnSource() {
        let foreign = HIDMapping(source: 0x7_0000_00E0, destination: 0x7_0000_00E3)
        let old = HIDMapping(source: HIDMapping.capsToF18.source, destination: 0x7_0000_0029)
        let merged = HIDKeyMapping.merged([foreign, old], adding: .capsToF18)
        #expect(merged == [foreign, .capsToF18])
        #expect(HIDKeyMapping.removing(merged, .capsToF18) == [foreign])
    }

    @Test func argumentIsJsonWithLatinKeys() {
        let arg = HIDKeyMapping.argument([.capsToF18])
        #expect(arg.allSatisfy { $0.isASCII })
        let obj = try? JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: [[String: UInt64]]]
        #expect(obj?["UserKeyMapping"]?.first?["HIDKeyboardModifierMappingSrc"] == 30064771129)
    }

    @Test func guardJournalsAndRecoversAfterCrash() {
        let d = actDefaults()
        let r = ActRemapper()
        let g = SuperKeyRemapGuard(remapper: r, defaults: d)
        #expect(g.engage() && g.applied)
        let after = SuperKeyRemapGuard(remapper: r, defaults: d)
        after.recoverStale()
        #expect(!after.applied && r.removed == [.capsToF18])
        after.recoverStale()
        #expect(r.removed.count == 1)
    }

    @Test func guardKeepsJournalWhenRemovalFails() {
        let d = actDefaults()
        let r = ActRemapper()
        let g = SuperKeyRemapGuard(remapper: r, defaults: d)
        g.engage()
        r.failRemove = true
        g.disengage()
        #expect(g.applied)
    }

    @Test func failedApplyIsNotJournaled() {
        let r = ActRemapper()
        r.failApply = true
        let g = SuperKeyRemapGuard(remapper: r, defaults: actDefaults())
        #expect(!g.engage() && !g.applied)
    }
}

@Suite struct SuperKeyEngineTests {
    private func rig(_ settings: SuperKeySettings = SuperKeySettings(), bundle: String? = "com.example.app") -> (SuperKeyEngine, ActCaps, ActSource, ActKeys) {
        let caps = ActCaps()
        let src = ActSource()
        let keys = ActKeys()
        return (SuperKeyEngine(settings: settings, caps: caps, input: src, keys: keys, frontmostBundle: { bundle }), caps, src, keys)
    }

    @Test func holdingAddsModifiersToOtherKeys() {
        let (e, _, _, _) = rig()
        #expect(e.sourceChanged(down: true, at: 1) == .drop)
        #expect(e.modifiedFlags([]) == [.maskControl, .maskAlternate, .maskCommand])
        #expect(e.sourceChanged(down: false, at: 2) == .drop)
        #expect(e.modifiedFlags([]) == nil)
    }

    @Test func tapRunsSoloActionOnce() {
        var s = SuperKeySettings()
        s.solo = .inputSource
        let (e, _, src, _) = rig(s)
        e.sourceChanged(down: true, at: 1)
        e.sourceChanged(down: false, at: 1.1)
        #expect(src.switches == 1 && e.soloCount == 1)
    }

    @Test func tapAfterUsingAsModifierDoesNothing() {
        let (e, _, src, _) = rig()
        e.sourceChanged(down: true, at: 1)
        _ = e.modifiedFlags([])
        e.sourceChanged(down: false, at: 1.1)
        #expect(src.switches == 0)
    }

    @Test func soloVariants() {
        var s = SuperKeySettings()
        s.solo = .escape
        let (e, caps, _, keys) = rig(s)
        e.sourceChanged(down: true, at: 1); e.sourceChanged(down: false, at: 1.05)
        #expect(keys.codes() == [Keys.escape])
        var c = SuperKeySettings()
        c.solo = .capsLock
        let (e2, caps2, _, _) = rig(c)
        e2.sourceChanged(down: true, at: 1); e2.sourceChanged(down: false, at: 1.05)
        #expect(caps2.toggles == 1 && caps.toggles == 0)
        var n = SuperKeySettings()
        n.solo = .none
        let (e3, caps3, src3, keys3) = rig(n)
        e3.sourceChanged(down: true, at: 1); e3.sourceChanged(down: false, at: 1.05)
        #expect(caps3.toggles == 0 && src3.switches == 0 && keys3.posts.isEmpty)
    }

    @Test func longHoldTogglesCapsLockButMiddleHoldDoesNot() {
        let (e, caps, src, _) = rig()
        e.sourceChanged(down: true, at: 1); e.sourceChanged(down: false, at: 1.4)
        #expect(caps.toggles == 0 && src.switches == 0)
        e.sourceChanged(down: true, at: 5); e.sourceChanged(down: false, at: 6)
        #expect(caps.toggles == 1)
    }

    @Test func longHoldCanBeDisabled() {
        var s = SuperKeySettings()
        s.longHoldCapsLock = false
        let (e, caps, _, _) = rig(s)
        e.sourceChanged(down: true, at: 1); e.sourceChanged(down: false, at: 9)
        #expect(caps.toggles == 0)
    }

    @Test func autorepeatDoesNotRestartThePress() {
        let (e, _, src, _) = rig()
        e.sourceChanged(down: true, at: 1)
        #expect(e.sourceChanged(down: true, isRepeat: true, at: 1.2) == .drop)
        e.sourceChanged(down: false, at: 1.3)
        #expect(src.switches == 0 && e.soloCount == 0)
    }

    @Test func excludedAppDisablesCapsAndEmulatesNativeToggle() {
        var s = SuperKeySettings()
        s.exceptions = AppExceptionList(["com.game"])
        let (e, caps, src, _) = rig(s, bundle: "com.game")
        #expect(e.sourceChanged(down: true, at: 1) == .drop)
        #expect(e.modifiedFlags([]) == nil)
        #expect(e.sourceChanged(down: false, at: 1.1) == .drop)
        #expect(caps.toggles == 1 && src.switches == 0)
    }

    @Test func excludedAppLeavesRightModifierAlone() {
        var s = SuperKeySettings()
        s.source = .rightCommand
        s.exceptions = AppExceptionList(["com.game"])
        let (e, caps, _, _) = rig(s, bundle: "com.game")
        #expect(e.sourceChanged(down: true, at: 1) == .pass)
        #expect(e.sourceChanged(down: false, at: 1.1) == .pass)
        #expect(caps.toggles == 0)
    }

    @Test func resetReleasesStuckHold() {
        let (e, _, _, _) = rig()
        e.sourceChanged(down: true, at: 1)
        e.reset()
        #expect(!e.isHeld && e.modifiedFlags([]) == nil)
    }
}

@Suite struct SuperKeyStageTests {
    private func rig(_ settings: SuperKeySettings = SuperKeySettings()) -> (InpTapBackend, ActCaps, ActSource, SuperKeyService, ActRemapper, InMemoryKeyValueStore) {
        let (hub, be) = actHub()
        let caps = ActCaps()
        let src = ActSource()
        let remap = ActRemapper()
        let d = actDefaults()
        let svc = SuperKeyService(hub: hub, settings: settings, caps: caps, input: src, keys: ActKeys(), remap: SuperKeyRemapGuard(remapper: remap, defaults: d),
                                  frontmostBundle: { "com.example.app" }, clock: { 100 })
        actKeep(svc).start()
        return (be, caps, src, svc, remap, d)
    }

    @Test func capsSourceRemapsAndModifiesKeyDowns() {
        let (be, _, src, svc, remap, _) = rig()
        #expect(remap.applied == [.capsToF18] && !svc.mappingFailed)
        #expect(be.fire(.keyDown, ActEvents.key(UInt16(Keys.f18), down: true)) == .drop)
        let h = ActEvents.key(4, down: true)
        #expect(be.fire(.keyDown, h) == .modified)
        #expect(h.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]))
        let up = ActEvents.key(4, down: false)
        #expect(be.fire(.keyUp, up) == .modified)
        #expect(be.fire(.keyUp, ActEvents.key(UInt16(Keys.f18), down: false)) == .drop)
        #expect(be.fire(.keyDown, ActEvents.key(4, down: true)) == .pass)
        #expect(src.switches == 0)
    }

    @Test func capsTapSwitchesInputSource() {
        let (be, _, src, _, _, _) = rig()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.f18), down: true))
        be.fire(.keyUp, ActEvents.key(UInt16(Keys.f18), down: false))
        #expect(src.switches == 1)
    }

    @Test func rightCommandViaFlagsChanged() {
        var s = SuperKeySettings()
        s.source = .rightCommand
        s.modifiers = KeyCombo.ctrl | KeyCombo.opt
        let (be, _, _, _, remap, _) = rig(s)
        #expect(remap.applied.isEmpty)
        let down = ActEvents.flags(UInt16(Keys.rightCommand), raw: CGEventFlags.maskCommand.rawValue | 0x10)
        #expect(be.fire(.flagsChanged, down) == .drop)
        let key = ActEvents.key(4, down: true, flags: [.maskCommand])
        key.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        #expect(be.fire(.keyDown, key) == .modified)
        #expect(key.flags.contains(.maskControl) && key.flags.contains(.maskAlternate) && !key.flags.contains(.maskCommand))
        let up = ActEvents.flags(UInt16(Keys.rightCommand), raw: 0)
        #expect(be.fire(.flagsChanged, up) == .drop)
    }

    @Test func otherModifierKeysFlagsChangedPass() {
        var s = SuperKeySettings()
        s.source = .rightCommand
        let (be, _, _, _, _, _) = rig(s)
        #expect(be.fire(.flagsChanged, ActEvents.flags(UInt16(Keys.rightShift), raw: CGEventFlags.maskShift.rawValue | 0x04)) == .pass)
    }

    @Test func remapFailureIsVisibleAndStopRestores() {
        let (hub, _) = actHub()
        let remap = ActRemapper()
        remap.failApply = true
        let svc = SuperKeyService(hub: hub, settings: SuperKeySettings(), caps: ActCaps(), input: ActSource(), keys: ActKeys(),
                                  remap: SuperKeyRemapGuard(remapper: remap, defaults: actDefaults()), frontmostBundle: { nil })
        svc.start()
        #expect(svc.mappingFailed)
        let ok = rig()
        ok.3.stop()
        #expect(ok.4.removed == [.capsToF18] && !ok.3.isRunning)
    }

    @Test func switchingSourceAwayFromCapsRestoresTheKey() {
        let r = rig()
        var s = r.3.settings
        s.source = .rightOption
        r.3.update(s)
        #expect(r.4.removed == [.capsToF18])
        var back = s
        back.source = .capsLock
        r.3.update(back)
        #expect(r.4.applied.count == 2)
    }

    @Test func mouseClicksGetModifiersWhileHeld() {
        let (be, _, _, _, _, _) = rig()
        be.fire(.keyDown, ActEvents.key(UInt16(Keys.f18), down: true))
        let click = ActEvents.left(.leftMouseDown)
        #expect(be.fire(.leftMouseDown, click) == .modified)
        #expect(click.flags.contains(.maskCommand))
    }
}
