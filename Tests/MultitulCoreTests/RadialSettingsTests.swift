import Testing
import Foundation
@testable import MultitulCore

private func it(_ i: Int) -> RadialItem { RadialItem(id: "i\(i)", title: "П\(i)", action: .target(.url("https://e.com/\(i)"))) }

@Suite struct RadialSettingsTests {
    @Test func defaultsAreReasonable() {
        let s = RadialSettings()
        #expect(s.profiles.count == 1 && s.activeProfile.items.count == 8 && s.activeProfile.items.count <= RadialSettings.maxItems)
        #expect(s.trigger.hotkey.display == "⌃⌥⌘Space" && s.trigger.hotkeyEnabled && s.trigger.mouseButton == nil && !s.trigger.fourFingerTap)
        #expect(s.stickyMs == 250 && s.innerRadius == 34 && s.ringRadius == 150 && s.showTitles && s.switchByApp)
    }

    @Test func defaultProfileUsesRealModulesAndShortcuts() {
        for item in RadialDefaults.mainProfile.items {
            switch item.action {
            case .target(let t): if case .tool(let tool) = t { #expect(ModuleID.allCases.contains(tool.module)) }
            case .keys(let k): #expect(!k.isNone && k.modifiers != 0)
            default: Issue.record("unexpected default action")
            }
        }
        #expect(Set(RadialDefaults.mainProfile.items.map(\.id)).count == RadialDefaults.mainProfile.items.count)
    }

    @Test func sanitizingTrimsToTwelveItemsAndDropsDuplicates() {
        var s = RadialSettings()
        s.profiles = [RadialProfile(id: "p", name: "P", items: (0..<20).map(it) + [it(0)])]
        s.activeProfileID = "p"
        let t = s.sanitized
        #expect(t.activeProfile.items.count == 12 && t.activeProfile.items.map(\.id) == (0..<12).map { "i\($0)" })
    }

    @Test func nestedSubmenusAreTrimmedAndDepthLimited() {
        let l3 = RadialItem(id: "l3", title: "3", action: .submenu([it(30)]))
        let l2 = RadialItem(id: "l2", title: "2", action: .submenu([l3] + (0..<20).map(it)))
        let l1 = RadialItem(id: "l1", title: "1", action: .submenu([l2]))
        var s = RadialSettings()
        s.profiles = [RadialProfile(id: "p", name: "P", items: [l1])]
        s.activeProfileID = "p"
        let root = s.sanitized.activeProfile.items[0]
        let level2 = root.children[0]
        #expect(level2.children.count == 12)
        let level3 = level2.children[0]
        #expect(level3.isSubmenu && level3.children.isEmpty)
    }

    @Test func profilesAreLimitedAndUnique() {
        var s = RadialSettings()
        s.profiles = (0..<12).map { RadialProfile(id: "p\($0 % 10)", name: "N\($0)", items: [it($0)]) }
        #expect(s.sanitized.profiles.count == RadialSettings.maxProfiles)
        #expect(Set(s.sanitized.profiles.map(\.id)).count == s.sanitized.profiles.count)
    }

    @Test func missingActiveProfileFallsBack() {
        var s = RadialSettings()
        s.profiles = [RadialProfile(id: "a", name: "A", items: [it(1)]), RadialProfile(id: "b", name: "B", items: [it(2)])]
        s.activeProfileID = "zzz"
        #expect(s.sanitized.activeProfileID == "a")
        s.profiles = []
        #expect(s.sanitized.profiles.count == 1)
    }

    @Test func emptyProfileNameBecomesProfile() {
        var s = RadialSettings()
        s.profiles = [RadialProfile(id: "a", name: "   ", items: [it(1)])]
        s.activeProfileID = "a"
        #expect(s.sanitized.profiles[0].name == "Профиль")
    }

    @Test func numbersAreClamped() {
        var s = RadialSettings()
        s.stickyMs = 5
        s.innerRadius = 3
        s.ringRadius = 9999
        let t = s.sanitized
        #expect(t.stickyMs == 100 && t.innerRadius == 18 && t.ringRadius == 260)
        s.stickyMs = 99999
        s.innerRadius = 65
        s.ringRadius = 80
        let u = s.sanitized
        #expect(u.stickyMs == 1000 && u.innerRadius == 65 && u.ringRadius >= u.innerRadius + 50)
    }

    @Test func badTriggersAreReset() {
        var s = RadialSettings()
        s.trigger.mouseButton = 0
        s.trigger.hotkey = KeyCombo(keyCode: Keys.space, modifiers: 0)
        let t = s.sanitized
        #expect(t.trigger.mouseButton == nil && t.trigger.hotkey == RadialTriggerConfig.defaultHotkey)
        s.trigger.mouseButton = 3
        s.trigger.hotkey = .none
        #expect(s.sanitized.trigger.mouseButton == 3 && s.sanitized.trigger.hotkey == RadialTriggerConfig.defaultHotkey)
    }

    @Test func profileLookupByBundleID() {
        var s = RadialSettings()
        let a = RadialProfile(id: "a", name: "A", items: [it(1)])
        let b = RadialProfile(id: "b", name: "B", items: [it(2)], bundleIDs: ["com.apple.Safari", "org.mozilla.firefox"])
        s.profiles = [a, b]
        s.activeProfileID = "a"
        #expect(s.profile(forBundleID: "org.mozilla.firefox").id == "b")
        #expect(s.profile(forBundleID: "com.other").id == "a" && s.profile(forBundleID: nil).id == "a")
        s.switchByApp = false
        #expect(s.profile(forBundleID: "com.apple.Safari").id == "a")
    }

    @Test func geometryComesFromTheSettings() {
        var s = RadialSettings()
        s.innerRadius = 40
        s.ringRadius = 200
        #expect(s.geometry.innerRadius == 40 && s.geometry.outerRadius == 200)
    }

    @Test func buttonTitles() {
        for b in RadialTriggerConfig.buttonChoices { #expect(!RadialTriggerConfig.buttonTitle(b).isEmpty) }
        #expect(RadialTriggerConfig.buttonTitle(3) == "Боковая «назад»")
    }
}

@Suite struct RadialStoreTests {
    private func rich() -> RadialSettings {
        var s = RadialSettings()
        let sub = RadialItem(id: "sub", title: "Папка", symbol: "folder", action: .submenu([
            RadialItem(id: "f", title: "Файл", action: .file("/Users/me/Documents/a b.pdf")),
            RadialItem(id: "k", title: "Копия", action: .keys(KeyCombo(keyCode: 8, modifiers: KeyCombo.cmd))),
            RadialItem(id: "deep", title: "Ещё", action: .submenu([RadialItem(id: "t", title: "Блокнот", action: .target(.tool(.scratchpad)))]))
        ]))
        s.profiles = [RadialProfile(id: "main", name: "Основной", items: [sub, RadialItem(id: "app", title: "Заметки", action: .target(.app("com.apple.Notes"))),
                                                                          RadialItem(id: "s", title: "Скрипт", action: .target(.script("/s/a.sh"))), RadialItem(id: "u", title: "Сайт", action: .target(.url("https://a.b")))]),
                      RadialProfile(id: "safari", name: "Safari", items: [RadialItem(id: "t2", title: "Тема", action: .target(.toggle(.darkMode)))], bundleIDs: ["com.apple.Safari"])]
        s.activeProfileID = "safari"
        s.trigger.hotkeyEnabled = false
        s.trigger.hotkey = KeyCombo(keyCode: 9, modifiers: KeyCombo.cmd | KeyCombo.shift)
        s.trigger.mouseButton = 4
        s.trigger.fourFingerTap = true
        s.stickyMs = 400
        s.innerRadius = 40
        s.ringRadius = 180
        s.showTitles = false
        s.switchByApp = false
        return s
    }

    @Test func defaultsWriteNothing() {
        let kv = WndMemoryStore()
        RadialSettingsStore(kv).save(RadialSettings())
        #expect(kv.values.isEmpty)
        #expect(RadialSettingsStore(kv).load() == RadialSettings())
    }

    @Test func everythingRoundTripsIncludingNestedMenus() {
        let kv = WndMemoryStore()
        RadialSettingsStore(kv).save(rich())
        #expect(RadialSettingsStore(kv).load() == rich().sanitized)
    }

    @Test func keysAreLatinAndJsonUsesLatinKeys() {
        let kv = WndMemoryStore()
        RadialSettingsStore(kv).save(rich())
        #expect(kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) && $0.hasPrefix("radialMenu.") })
        let json = kv.values["radialMenu.profiles"] as? String ?? ""
        #expect(json.contains("\"children\"") && json.contains("\"bundleIDs\"") && json.contains("\"kind\""))
    }

    @Test func brokenJsonFallsBackToTheDefaultProfile() {
        let kv = WndMemoryStore()
        kv.values["radialMenu.profiles"] = "[{oops"
        #expect(RadialSettingsStore(kv).load().profiles == RadialSettings().profiles)
        kv.values["radialMenu.profiles"] = "[]"
        #expect(RadialSettingsStore(kv).load().profiles == RadialSettings().profiles)
    }

    @Test func unknownItemKindsAreDropped() {
        let json = "[{\"id\":\"p\",\"name\":\"P\",\"bundleIDs\":[],\"items\":[{\"id\":\"a\",\"title\":\"A\",\"symbol\":\"x\",\"kind\":\"teleport\",\"value\":\"\"},{\"id\":\"b\",\"title\":\"B\",\"symbol\":\"x\",\"kind\":\"file\",\"value\":\"/tmp/a\"},{\"id\":\"c\",\"title\":\"C\",\"symbol\":\"x\",\"kind\":\"keys\",\"value\":\"nonsense\"}]}]"
        let s = RadialSettings()
        let decoded = RadialSettingsStore.decode(json)
        #expect(decoded?.first?.items.map(\.id) == ["b"])
        _ = s
    }

    @Test func outOfRangeStoredValuesAreClamped() {
        let kv = WndMemoryStore()
        kv.values["radialMenu.stickyMs"] = 1
        kv.values["radialMenu.mouseButton"] = 0
        kv.values["radialMenu.innerRadius"] = 500.0
        let s = RadialSettingsStore(kv).load()
        #expect(s.stickyMs == 100 && s.trigger.mouseButton == nil && s.innerRadius == 70)
    }

    @Test func clearingTheMouseButtonRemovesTheKey() {
        let kv = WndMemoryStore()
        let store = RadialSettingsStore(kv)
        var s = RadialSettings()
        s.trigger.mouseButton = 3
        store.save(s)
        #expect(kv.values["radialMenu.mouseButton"] as? Int == 3)
        s.trigger.mouseButton = nil
        store.save(s)
        #expect(kv.values["radialMenu.mouseButton"] == nil)
    }
}

@Suite struct RadialResolverTests {
    private let fs = CbFakeFS()

    @Test func targetsGoThroughTheLauncherRules() {
        fs.files = ["/Applications/Notes.app"]
        fs.bundles = ["com.apple.Notes": "/Applications/Notes.app"]
        #expect(RadialResolver.resolve(RadialItem(title: "n", action: .target(.app("com.apple.Notes"))), fs: fs) == .success(.launcher(.openApp("/Applications/Notes.app"))))
        #expect(RadialResolver.resolve(RadialItem(title: "n", action: .target(.tool(.scratchpad))), fs: fs) == .success(.launcher(.tool(.scratchpad))))
        #expect(RadialResolver.resolve(RadialItem(title: "n", action: .target(.app("nope"))), fs: fs) == .failure(.appNotFound))
        #expect(RadialResolver.resolve(RadialItem(title: "n", action: .target(.url("javascript:alert(1)"))), fs: fs) == .failure(.blockedScheme("javascript")))
    }

    @Test func filesNeedAnAbsoluteExistingPath() {
        fs.files = ["/Users/me/a.pdf"]
        #expect(RadialResolver.resolve(RadialItem(title: "f", action: .file("/Users/me/a.pdf")), fs: fs) == .success(.openPath("/Users/me/a.pdf")))
        #expect(RadialResolver.resolve(RadialItem(title: "f", action: .file("/Users/me/missing")), fs: fs) == .failure(.scriptNotFound))
        #expect(RadialResolver.resolve(RadialItem(title: "f", action: .file("a.pdf")), fs: fs) == .failure(.scriptNotAbsolute))
        #expect(RadialResolver.resolve(RadialItem(title: "f", action: .file("  ")), fs: fs) == .failure(.emptyValue))
    }

    @Test func keysAndSubmenus() {
        let k = KeyCombo(keyCode: Keys.up, modifiers: KeyCombo.ctrl)
        #expect(RadialResolver.resolve(RadialItem(title: "k", action: .keys(k)), fs: fs) == .success(.keys(k)))
        #expect(RadialResolver.resolve(RadialItem(title: "k", action: .keys(.none)), fs: fs) == .failure(.emptyValue))
        #expect(RadialResolver.resolve(RadialItem(title: "s", action: .submenu([it(1)])), fs: fs) == .failure(.emptyValue))
    }

    @Test func itemSymbolsAndDetails() {
        #expect(RadialItem(title: "a", action: .file("/x")).symbol == "doc")
        #expect(RadialItem(title: "a", action: .keys(KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd))).symbol == "keyboard")
        #expect(RadialItem(title: "a", symbol: "star", action: .keys(.none)).symbol == "star")
        #expect(RadialItem(title: "a", action: .submenu([it(1), it(2)])).detail == "Подменю · пунктов: 2")
        #expect(RadialItem(title: "a", action: .keys(KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd))).detail == "Сочетание · ⌘A")
        #expect(RadialItem(title: "a", action: .target(.tool(.scratchpad))).detail == "Инструмент")
        #expect(RadialAction.file("/x").kindTitle == "Файл или папка")
    }
}
