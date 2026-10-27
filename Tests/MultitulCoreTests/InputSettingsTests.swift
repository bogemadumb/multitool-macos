import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct InputSettingsTests {
    private func fresh() -> (InMemoryKeyValueStore, InputSettingsStore, String) {
        let name = "inp.settings.\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        return (d, InputSettingsStore(defaults: d), name)
    }

    @Test func defaultsMatchTheCatalog() {
        #expect(HorizontalScrollSettings().modifier == .shift)
        #expect(LinearScrollSettings().linesPerNotch == 3)
        #expect(FocusFollowsSettings().delayMs == 250 && FocusFollowsSettings().raise)
        #expect(SmoothScrollSettings().step == 40)
        #expect(ScrollInverterSettings().vertical && !ScrollInverterSettings().horizontal)
        #expect(MouseAccelerationSettings().disabled)
    }

    @Test func untouchedStoreReturnsDefaults() {
        let (d, s, n) = fresh()
        #expect(s.loadInverter() == ScrollInverterSettings())
        #expect(s.loadSmooth() == SmoothScrollSettings())
        #expect(s.loadKeys() == KeyDebounceSettings())
        #expect(s.loadFocus() == FocusFollowsSettings())
    }

    @Test func everyModuleSettingRoundTrips() {
        let (d, s, n) = fresh()
        var inv = ScrollInverterSettings(); inv.vertical = false; inv.horizontal = true; inv.exceptions = AppExceptionList(["com.a.b"])
        s.saveInverter(inv); #expect(s.loadInverter() == inv)
        var hz = HorizontalScrollSettings(); hz.modifier = .option; hz.exceptions = AppExceptionList(["x.y"])
        s.saveHorizontal(hz); #expect(s.loadHorizontal() == hz)
        var lin = LinearScrollSettings(); lin.linesPerNotch = 7
        s.saveLinear(lin); #expect(s.loadLinear() == lin)
        var sm = SmoothScrollSettings(); sm.step = 70; sm.response = 20; sm.coast = 55; sm.exceptions = AppExceptionList()
        s.saveSmooth(sm); #expect(s.loadSmooth() == sm)
        var ck = ClickDebounceSettings(); ck.windowMs = 60; ck.middle = false
        s.saveClick(ck); #expect(s.loadClick() == ck)
        var kb = KeyDebounceSettings(); kb.globalWindowMs = 44; kb.keyWindows = [0: 0, 49: 90]; kb.ignoredApps = AppExceptionList(["com.g.*"])
        s.saveKeys(kb); #expect(s.loadKeys() == kb)
        var ff = FocusFollowsSettings(); ff.delayMs = 700; ff.raise = false; ff.waitForStop = false; ff.exceptions = AppExceptionList(["a.b"])
        s.saveFocus(ff); #expect(s.loadFocus() == ff)
    }

    @Test func savingDefaultsRemovesKeysSoLaterDefaultChangesApply() {
        let (d, s, n) = fresh()
        var lin = LinearScrollSettings(); lin.linesPerNotch = 5
        s.saveLinear(lin)
        #expect(d.object(forKey: "input.linear.lines") != nil)
        s.saveLinear(LinearScrollSettings())
        #expect(d.object(forKey: "input.linear.lines") == nil)
    }

    @Test func emptyExceptionListIsStoredExplicitlyWhenDefaultIsNotEmpty() {
        let (d, s, n) = fresh()
        var sm = SmoothScrollSettings()
        sm.exceptions = AppExceptionList()
        s.saveSmooth(sm)
        #expect(s.loadSmooth().exceptions.isEmpty)
    }

    @Test func loadedValuesAreSanitized() {
        let (d, s, n) = fresh()
        d.set(5000, forKey: "input.focus.delayMs")
        d.set(0, forKey: "input.click.windowMs")
        d.set(99, forKey: "input.linear.lines")
        d.set(-3, forKey: "input.smooth.step")
        d.set("garbage", forKey: "input.horizontal.modifier")
        d.set("0:9999,bad", forKey: "input.keys.perKey")
        #expect(s.loadFocus().delayMs == 3000)
        #expect(s.loadClick().windowMs == 5)
        #expect(s.loadLinear().linesPerNotch == 10)
        #expect(s.loadSmooth().step == 10)
        #expect(s.loadHorizontal().modifier == .shift)
        #expect(s.loadKeys().keyWindows == [0: 500])
    }

    @Test func settingsKeysAreAsciiOnly() {
        let d = InMemoryKeyValueStore()
        let s = InputSettingsStore(defaults: d)
        var kb = KeyDebounceSettings(); kb.globalWindowMs = 1; kb.keyWindows = [1: 1]; kb.ignoredApps = AppExceptionList(["a"])
        s.saveKeys(kb)
        var ff = FocusFollowsSettings(); ff.delayMs = 500; ff.raise = false; ff.waitForStop = false; ff.exceptions = AppExceptionList(["q"])
        s.saveFocus(ff)
        s.saveHorizontal({ var h = HorizontalScrollSettings(); h.modifier = .control; return h }())
        let keys = Array(d.dictionaryRepresentation().keys)
        #expect(!keys.isEmpty && keys.allSatisfy { $0.hasPrefix("input.") && $0.allSatisfy(\.isASCII) })
    }
}

@Suite struct AppExceptionTests {
    @Test func exactAndPrefixMatching() {
        let l = AppExceptionList(["com.apple.Safari", "com.autodesk.*"])
        #expect(l.contains("com.apple.Safari"))
        #expect(!l.contains("com.apple.SafariTechnologyPreview"))
        #expect(l.contains("com.autodesk.Maya.2025"))
        #expect(!l.contains("com.autodeskx"))
        #expect(!l.contains(nil) && !l.contains(""))
    }

    @Test func entriesAreTrimmedAndDeduplicated() {
        var l = AppExceptionList(["  a.b ", "a.b", "", "c.d"])
        #expect(l.entries == ["a.b", "c.d"])
        l.add("c.d")
        l.add("e.f")
        #expect(l.entries == ["a.b", "c.d", "e.f"])
        l.remove("a.b")
        #expect(l.entries == ["c.d", "e.f"])
    }

    @Test func smoothScrollShipsDesignAndThreeDExceptions() {
        let l = SmoothScrollSettings().exceptions
        #expect(l.contains("org.blenderfoundation.blender") && l.contains("com.adobe.Photoshop") && l.contains("com.figma.Desktop"))
        #expect(!l.contains("com.apple.Safari"))
    }

    @Test func gateDoesNotAskTheWindowServerWhenTheListIsEmpty() {
        let r = InpResolver("com.apple.Safari")
        let g = ExceptionGate(resolver: r)
        #expect(!g.isExcepted(at: .zero) && r.lookups == 0)
    }

    @Test func gateMatchesTheAppUnderThePointer() {
        let r = InpResolver("com.figma.Desktop")
        let g = ExceptionGate(list: AppExceptionList(["com.figma.Desktop"]), resolver: r)
        #expect(g.isExcepted(at: CGPoint(x: 1, y: 1)) && r.lookups == 1)
        r.bundle = "com.apple.Safari"
        #expect(!g.isExcepted(at: CGPoint(x: 1, y: 1)))
        r.bundle = nil
        #expect(!g.isExcepted(at: CGPoint(x: 1, y: 1)))
    }
}

@Suite struct InputModuleRegistryTests {
    private let ids: [ModuleID] = [.scrollInverter, .scrollHorizontal, .linearScroll, .smoothScroll, .mouseAcceleration, .mouseClickDebounce, .keyboardDebounce, .focusFollowsMouse]

    @Test func eightModulesLiveInTheMouseAndKeyboardGroup() {
        #expect(ids.allSatisfy { $0.info.group == .input })
        #expect(ModuleID.allCases.filter { $0.info.group == .input }.count == 16)
        #expect(Set(ids.map(\.rawValue)).count == 8)
    }

    @Test func identifiersAreAscii() {
        #expect(ids.allSatisfy { $0.rawValue.allSatisfy(\.isASCII) && $0.enabledKey.allSatisfy(\.isASCII) })
    }

    @Test func disabledByDefaultAndWithoutHotkeys() {
        #expect(ids.allSatisfy { !$0.info.enabledByDefault && $0.info.hotkeys.isEmpty })
    }

    @Test func permissionsMatchTheCatalog() {
        for id in ids where id != .mouseAcceleration && id != .keyboardDebounce { #expect(id.info.permissions == [.accessibility]) }
        #expect(ModuleID.mouseAcceleration.info.permissions.isEmpty)
        #expect(ModuleID.keyboardDebounce.info.permissions.contains(.accessibility))
        #expect(ModuleID.keyboardDebounce.info.permissions.contains(.inputMonitoring))
    }

    @Test func titlesAreRussianAndUnique() {
        let titles = ids.map { $0.info.title }
        #expect(Set(titles).count == 8)
        #expect(titles.allSatisfy { $0.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } })
    }

    @Test func conflictsKnowMouseFixAndStayPerModule() {
        let running: [(bundleID: String?, name: String?)] = [("com.nuebling.mac-mouse-fix.helper", "Mac Mouse Fix Helper"), ("com.apple.finder", "Finder")]
        for id in [ModuleID.scrollInverter, .scrollHorizontal, .linearScroll, .smoothScroll, .mouseAcceleration] {
            #expect(InputConflicts.detect(running: running, for: id) == ["Mac Mouse Fix"])
        }
        for id in [ModuleID.keyboardDebounce, .mouseClickDebounce, .focusFollowsMouse] { #expect(InputConflicts.detect(running: running, for: id).isEmpty) }
        #expect(InputConflicts.detect(running: [("com.apple.finder", "Finder")], for: .smoothScroll).isEmpty)
    }

    @Test func conflictsAreFoundByNameToo() {
        #expect(InputConflicts.detect(running: [(nil, "Scroll Reverser")], for: .scrollInverter) == ["Scroll Reverser"])
        #expect(InputConflicts.detect(running: [("com.pilotmoon.scroll-reverser", nil)], for: .mouseAcceleration).isEmpty)
    }
}
