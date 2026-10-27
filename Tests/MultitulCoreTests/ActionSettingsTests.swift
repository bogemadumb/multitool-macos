import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ActionStorageTests {
    @Test func buttonActionRoundTrips() {
        let all: [ButtonAction] = [.none, .shortcut(KeyCombo(keyCode: 13, modifiers: KeyCombo.cmd)), .missionControl, .appExpose, .spaceLeft, .spaceRight, .middleClick]
        for a in all { #expect(ButtonAction(storage: a.storage) == a) }
        #expect(ButtonAction(storage: "key:garbage") == nil)
        #expect(ButtonAction(storage: "nonsense") == nil)
    }

    @Test func shortcutNoneComboIsRejected() {
        #expect(ButtonAction(storage: "key:\(KeyCombo.none.stored)") == nil)
    }

    @Test func triggerRoundTrips() {
        for t in [ButtonTrigger.button(2), .button(5), .scrollLeft, .scrollRight] { #expect(ButtonTrigger(storage: t.storage) == t) }
        #expect(ButtonTrigger(storage: "b1") == nil)
        #expect(ButtonTrigger(storage: "b99") == nil)
        #expect(ButtonTrigger(storage: "x") == nil)
    }

    @Test func bindingRoundTripsAndRejectsGestureOnScroll() {
        let b = ButtonBinding(trigger: .button(3), click: .shortcut(KeyCombo(keyCode: 13, modifiers: KeyCombo.cmd)), gesture: true)
        #expect(ButtonBinding(storage: b.storage) == b)
        #expect(ButtonBinding(storage: "sl|mission|1") == nil)
        #expect(ButtonBinding(storage: "sl|mission|0") == ButtonBinding(trigger: .scrollLeft, click: .missionControl))
    }

    @Test func navRuleKeepsNilCombos() {
        let r = MouseNavRule(pattern: "com.test.*", back: KeyCombo(keyCode: 33, modifiers: KeyCombo.cmd), forward: nil)
        #expect(MouseNavRule(storage: r.storage) == r)
        #expect(MouseNavRule(storage: "|a|b") == nil)
    }

    @Test func comboFlagsAndAction() {
        let c = KeyCombo(keyCode: 12, modifiers: KeyCombo.cmd | KeyCombo.shift | KeyCombo.opt | KeyCombo.ctrl)
        #expect(c.cgFlags == [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        #expect(ButtonAction.missionControl.keyCombo == KeyCombo(keyCode: Keys.up, modifiers: KeyCombo.ctrl))
        #expect(ButtonAction.middleClick.keyCombo == nil)
    }
}

@Suite struct ActionSettingsStoreTests {
    @Test func defaultsAreNotWritten() {
        let d = actDefaults()
        let store = InputSettingsStore(defaults: d)
        store.saveNavigation(MouseNavigationSettings())
        store.saveButtons(ButtonShortcutsSettings())
        store.saveMiddle(MiddleClickSettings())
        store.saveSuperKey(SuperKeySettings())
        store.saveQuit(QuitProtectionSettings())
        store.saveSnippets(SnippetSettings())
        let keys = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("input.") }
        #expect(keys.isEmpty)
    }

    @Test func navigationRoundTrip() {
        let store = InputSettingsStore(defaults: actDefaults())
        var s = MouseNavigationSettings()
        s.scope = .allApps
        s.swapButtons = true
        s.rules = [MouseNavRule(pattern: "com.a.b", back: KeyCombo(keyCode: 1, modifiers: KeyCombo.cmd), forward: nil)]
        s.exceptions = AppExceptionList(["com.x.y"])
        store.saveNavigation(s)
        #expect(store.loadNavigation() == s)
    }

    @Test func buttonsRoundTripAndSanitize() {
        let store = InputSettingsStore(defaults: actDefaults())
        var s = ButtonShortcutsSettings()
        s.bindings = [ButtonBinding(trigger: .button(3), click: .spaceLeft), ButtonBinding(trigger: .button(3), click: .spaceRight)]
        s.gestureThreshold = 9999
        s.scrollCooldownMs = 1
        store.saveButtons(s)
        let l = store.loadButtons()
        #expect(l.bindings.count == 1)
        #expect(l.gestureThreshold == ButtonShortcutsSettings.thresholdRange.upperBound)
        #expect(l.scrollCooldownMs == ButtonShortcutsSettings.cooldownRange.lowerBound)
    }

    @Test func superKeyRoundTripAndModifierFallback() {
        let store = InputSettingsStore(defaults: actDefaults())
        var s = SuperKeySettings()
        s.source = .rightOption
        s.modifiers = KeyCombo.cmd | KeyCombo.shift
        s.solo = .escape
        s.longHoldCapsLock = false
        store.saveSuperKey(s)
        #expect(store.loadSuperKey() == s)
        var z = SuperKeySettings()
        z.modifiers = 0
        #expect(z.sanitized.modifiers == SuperKeySettings.defaultModifiers)
    }

    @Test func quitRoundTripAndDefaults() {
        let store = InputSettingsStore(defaults: actDefaults())
        let d = QuitProtectionSettings()
        #expect(d.quit.mode == .hold && d.close.mode == .off)
        var s = d
        s.close.mode = .doublePress
        s.close.scope = .except
        s.close.apps = AppExceptionList(["com.apple.Safari"])
        s.quit.extra = .shift
        s.quit.mode = .extraModifier
        store.saveQuit(s)
        #expect(store.loadQuit() == s)
    }

    @Test func protectionClampsAndScopes() {
        var p = KeyProtection(mode: .hold)
        p.holdMs = 5
        p.doubleWindowMs = 99999
        p.extra = .command
        let s = p.sanitized
        #expect(s.holdMs == KeyProtection.holdRange.lowerBound)
        #expect(s.doubleWindowMs == KeyProtection.doubleRange.upperBound)
        #expect(s.extra == .option)
        var except = KeyProtection(mode: .hold)
        except.scope = .except
        except.apps = AppExceptionList(["com.a"])
        #expect(!except.covers("com.a") && except.covers("com.b") && except.covers(nil))
        except.scope = .only
        #expect(except.covers("com.a") && !except.covers("com.b") && !except.covers(nil))
    }

    @Test func snippetSettingsRoundTripAndTerminatorGuard() {
        let store = InputSettingsStore(defaults: actDefaults())
        var s = SnippetSettings()
        s.caseSensitive = true
        s.method = .paste
        s.timeZoneID = "Europe/Moscow"
        s.useTab = false
        s.exceptions = AppExceptionList(["com.a"])
        store.saveSnippets(s)
        #expect(store.loadSnippets() == s)
        var none = SnippetSettings()
        none.useSpace = false; none.useTab = false; none.useReturn = false
        #expect(none.sanitized.useSpace)
    }

    @Test func middleClickClamps() {
        var s = MiddleClickSettings()
        s.tapMaxMs = 5
        #expect(s.sanitized.tapMaxMs == MiddleClickSettings.tapDurationRange.lowerBound)
    }
}

@Suite struct ActionModuleRegistryTests {
    private let ids: [ModuleID] = [.mouseNavigation, .mouseButtonShortcuts, .middleClick, .superKey, .quitProtection, .textSnippets]

    @Test func sixModulesJoinTheInputGroupDisabled() {
        #expect(ids.allSatisfy { $0.info.group == .input && !$0.info.enabledByDefault })
        #expect(ids.allSatisfy { $0.info.permissions.contains(.accessibility) })
        #expect(ids.allSatisfy { $0.rawValue.allSatisfy(\.isASCII) && $0.enabledKey.allSatisfy(\.isASCII) })
    }

    @Test func keyboardInterceptingModulesAskInputMonitoring() {
        for id in [ModuleID.superKey, .quitProtection, .textSnippets] { #expect(id.info.permissions.contains(.inputMonitoring)) }
    }

    @Test func onlySnippetsOwnAHotkeyAndItIsUnassigned() {
        #expect(ids.flatMap { $0.info.hotkeys }.map(\.id) == ["snippets.library"])
        #expect(SnippetHotkeys.library.defaultCombo.isNone)
    }

    @Test func priorityChainOrder() {
        #expect(InputPriority.debounce > InputPriority.superKey)
        #expect(InputPriority.superKey > InputPriority.middleClick)
        #expect(InputPriority.buttonShortcuts > InputPriority.horizontal)
        #expect(InputPriority.buttonShortcuts > InputPriority.navigation)
        #expect(InputPriority.superKey > InputPriority.quitProtection)
        #expect(InputPriority.quitProtection > InputPriority.snippets)
        #expect(InputPriority.snippets > InputPriority.linear)
    }
}
