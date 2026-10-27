import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func store() -> (WindowSettingsStore, WndMemoryStore) {
    let m = WndMemoryStore()
    return (WindowSettingsStore(m), m)
}

@Suite struct WindowLayoutSettingsStoreTests {
    @Test func defaultsRoundTripWithoutWritingAnything() {
        let (s, m) = store()
        s.saveLayout(WindowLayoutSettings())
        #expect(m.values.isEmpty)
        #expect(s.loadLayout() == WindowLayoutSettings())
    }

    @Test func defaultsMatchTheCatalog() {
        let d = WindowLayoutSettings()
        #expect(d.shortcutsEnabled && d.cursorDisplayEnabled)
        #expect(!d.edge.enabled && !d.gesture.enabled && !d.ring.enabled)
        #expect(d.gaps == .none && d.marginPercent == 5 && d.repeatMode == .none)
        #expect(d.ring.trigger == KeyCombo(keyCode: Keys.space, modifiers: KeyCombo.ctrl | KeyCombo.opt))
    }

    @Test func everySettingRoundTrips() {
        let (s, _) = store()
        var x = WindowLayoutSettings()
        x.shortcutsEnabled = false
        x.cursorDisplayEnabled = false
        x.gaps = WindowGaps(window: 16, screen: 8)
        x.marginPercent = 12
        x.repeatMode = .cycleSizes
        x.ignoredApps = AppExceptionList(["com.a.b", "com.c.*"])
        x.custom[3] = CustomLayout(name: "Колонка", rect: FractionRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
        x.edge.enabled = true
        x.edge.disabledZones = [.top, .bottomLeft]
        x.edge.distance = 20
        x.edge.showPreview = false
        x.edge.layout.setPartCount(3, for: .top)
        x.gesture.enabled = true
        x.gesture.move = [.command, .option]
        x.gesture.resize = [.command, .option, .shift]
        x.gesture.raiseWindow = true
        x.ring.enabled = true
        x.ring.trigger = KeyCombo(keyCode: 3, modifiers: KeyCombo.cmd | KeyCombo.shift)
        s.saveLayout(x)
        #expect(s.loadLayout() == x.sanitized)
    }

    @Test func returningToDefaultsRemovesTheKeys() {
        let (s, m) = store()
        var x = WindowLayoutSettings()
        x.gaps = WindowGaps(window: 8, screen: 8)
        x.edge.enabled = true
        x.custom[1] = CustomLayout(name: "a", rect: .full)
        s.saveLayout(x)
        #expect(!m.values.isEmpty)
        s.saveLayout(WindowLayoutSettings())
        #expect(m.values.isEmpty)
    }

    @Test func outOfRangeValuesAreSanitizedOnLoad() {
        let (s, m) = store()
        m.values["windowLayout.gap.window"] = 9999
        m.values["windowLayout.gap.screen"] = -4
        m.values["windowLayout.marginPercent"] = 90.0
        m.values["windowLayout.edge.distance"] = 1
        let x = s.loadLayout()
        #expect(x.gaps == WindowGaps(window: 128, screen: 0))
        #expect(x.marginPercent == 25 && x.edge.distance == 4)
    }

    @Test func garbageValuesFallBackToDefaults() {
        let (s, m) = store()
        m.values["windowLayout.repeatMode"] = "banana"
        m.values["windowLayout.edge.disabledZones"] = "nowhere,left"
        m.values["windowLayout.gesture.move"] = "999"
        m.values["windowLayout.ring.trigger"] = "garbage"
        m.values["windowLayout.custom.2.rect"] = "1,2"
        m.values["windowLayout.shortcutsEnabled"] = "yes"
        let x = s.loadLayout()
        #expect(x.repeatMode == .none && x.edge.disabledZones == [.left])
        #expect(x.gesture.move == GestureSettings().move && x.ring.trigger == RingSettings.defaultTrigger)
        #expect(x.custom.isEmpty && x.shortcutsEnabled)
    }

    @Test func customSlotsOutsideTheRangeAreIgnored() {
        let (s, m) = store()
        m.values["windowLayout.custom.9.rect"] = "0,0,0.5,0.5"
        #expect(s.loadLayout().custom.isEmpty)
    }

    @Test func customNameDefaultsWhenMissing() {
        let (s, m) = store()
        m.values["windowLayout.custom.4.rect"] = "0.1,0.1,0.5,0.5"
        #expect(s.loadLayout().custom[4]?.name == "Макет 4")
    }

    @Test func clearingACustomSlotRemovesItsKeys() {
        let (s, m) = store()
        var x = WindowLayoutSettings()
        x.custom[5] = CustomLayout(name: "n", rect: .full)
        s.saveLayout(x)
        x.custom[5] = nil
        s.saveLayout(x)
        #expect(m.values.keys.allSatisfy { !$0.contains("custom") })
    }

    @Test func ringTriggerWithoutModifiersIsStillAccepted() {
        let (s, m) = store()
        m.values["windowLayout.ring.trigger"] = KeyCombo(keyCode: 49, modifiers: 0).stored
        #expect(s.loadLayout().ring.trigger.keyCode == 49)
    }

    @Test func gestureValidity() {
        var g = GestureSettings()
        #expect(g.isValid)
        g.resize = g.move
        #expect(!g.isValid)
        g.resize = [.command]
        g.move = []
        #expect(!g.isValid)
    }

    @Test func allStoredKeysAreAsciiAndNamespaced() {
        let (s, m) = store()
        var x = WindowLayoutSettings()
        x.shortcutsEnabled = false; x.cursorDisplayEnabled = false; x.gaps = WindowGaps(window: 8, screen: 8); x.marginPercent = 9
        x.repeatMode = .crossDisplay; x.ignoredApps = AppExceptionList(["a"]); x.custom[1] = CustomLayout(name: "x", rect: .full)
        x.edge.enabled = true; x.edge.disabledZones = [.top]; x.edge.layout.setPartCount(2, for: .left); x.edge.distance = 9; x.edge.showPreview = false
        x.gesture.enabled = true; x.gesture.move = [.shift]; x.gesture.resize = [.shift, .control]; x.gesture.raiseWindow = true
        x.ring.enabled = true; x.ring.trigger = KeyCombo(keyCode: 1, modifiers: KeyCombo.cmd)
        s.saveLayout(x)
        #expect(m.values.count >= 20)
        #expect(m.values.keys.allSatisfy { $0.hasPrefix("windowLayout.") && $0.allSatisfy { $0.isASCII } })
    }
}

@Suite struct OtherWindowSettingsStoreTests {
    @Test func maximizerDefaultsAreNotStored() {
        let (s, m) = store()
        s.saveMaximizer(MaximizerSettings())
        #expect(m.values.isEmpty)
        #expect(s.loadMaximizer() == MaximizerSettings())
    }

    @Test func maximizerRoundTrip() {
        let (s, _) = store()
        var x = MaximizerSettings()
        x.excluded = AppExceptionList(["com.game.*"])
        x.inset = 10
        x.toggleRestores = false
        s.saveMaximizer(x)
        #expect(s.loadMaximizer() == x)
    }

    @Test func emptyExclusionListIsRemembered() {
        let (s, _) = store()
        var x = MaximizerSettings()
        x.excluded = AppExceptionList()
        s.saveMaximizer(x)
        #expect(s.loadMaximizer().excluded.isEmpty)
    }

    @Test func maximizerInsetIsSanitized() {
        let (s, m) = store()
        m.values["windowMaximizer.inset"] = 500
        #expect(s.loadMaximizer().inset == 64)
    }

    @Test func autoQuitRoundTrip() {
        let (s, m) = store()
        var x = AutoQuitSettings()
        x.exceptions = AppExceptionList(["com.x.y"])
        x.delayMs = 900
        s.saveAutoQuit(x)
        #expect(s.loadAutoQuit() == x)
        s.saveAutoQuit(AutoQuitSettings())
        #expect(m.values.isEmpty)
    }

    @Test func autoQuitDelayIsSanitized() {
        let (s, m) = store()
        m.values["autoQuit.delayMs"] = 1
        #expect(s.loadAutoQuit().delayMs == 150)
    }

    @Test func dockClickRoundTrip() {
        let (s, m) = store()
        var x = DockClickSettings()
        x.mode = .hide
        x.cycleWindows = true
        x.exceptions = AppExceptionList(["com.k.l"])
        s.saveDockClick(x)
        #expect(s.loadDockClick() == x)
        s.saveDockClick(DockClickSettings())
        #expect(m.values.isEmpty)
    }

    @Test func dockClickUnknownModeFallsBack() {
        let (s, m) = store()
        m.values["dockClick.mode"] = "explode"
        #expect(s.loadDockClick().mode == .minimize)
    }

    @Test func userDefaultsConformsToTheKeyValueProtocol() {
        let kv: KeyValueStoring = UserDefaults.standard
        _ = WindowSettingsStore(kv)
        #expect(kv is UserDefaults)
    }
}
