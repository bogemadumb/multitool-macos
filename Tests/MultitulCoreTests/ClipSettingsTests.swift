import Testing
import Foundation
@testable import MultitulCore

private func freshDefaults() -> (InMemoryKeyValueStore, String) {
    let suite = "multitul.test.clip.\(UUID().uuidString)"
    return (InMemoryKeyValueStore(), suite)
}

@Suite struct ClipSettingsStoreTests {
    @Test func defaultsMatchTheCatalog() {
        let (d, suite) = freshDefaults()
        let s = ClipSettingsStore(defaults: d).loadClipboard()
        #expect(s == ClipSettings())
        #expect(s.maxItems == 50)
        #expect(s.keepImages == false && s.keepFiles == false)
        #expect(s.skipSensitive && s.skipConcealed)
        #expect(s.ignoredApps.contains("com.1password.1password"))
    }

    @Test func clipboardRoundTripWritesOnlyDifferences() {
        let (d, suite) = freshDefaults()
        let st = ClipSettingsStore(defaults: d)
        var s = ClipSettings()
        s.maxItems = 200
        s.keepImages = true
        s.maxAgeDays = 0
        s.autoClearSeconds = 60
        s.ignoredApps = ["a.b.c"]
        s.clearOnLock = true
        st.saveClipboard(s)
        #expect(st.loadClipboard() == s)
        #expect(d.object(forKey: "clipboard.keepFiles") == nil)
        #expect(d.integer(forKey: "clipboard.maxItems") == 200)
        st.saveClipboard(ClipSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("clipboard.") }.isEmpty)
    }

    @Test func sanitizingClampsAndDedupes() {
        var s = ClipSettings()
        s.maxItems = 1
        s.maxAgeDays = -4
        s.maxItemKB = 1
        s.autoClearSeconds = 99999
        s.pollInterval = 0
        s.ignoredApps = [" x.y ", "x.y", "", "z.w"]
        let c = s.sanitized
        #expect(c.maxItems == 5 && c.maxAgeDays == 0 && c.maxItemKB == 16 && c.autoClearSeconds == 3600 && c.pollInterval == 0.2)
        #expect(c.ignoredApps == ["x.y", "z.w"])
    }

    @Test func urlSettingsAndRulesRoundTrip() {
        let (d, suite) = freshDefaults()
        let st = ClipSettingsStore(defaults: d)
        var s = UrlCleanerSettings()
        s.cleanOnCopy = false
        s.rules.unwrapRedirects = true
        s.rules.added = ["": ["ref_code"], "shop.ru": ["src", "trk*"]]
        s.rules.disabled = ["": ["fbclid"]]
        s.rules.disabledSites = ["youtube.com"]
        st.saveUrl(s)
        #expect(st.loadUrl() == s)
        st.saveUrl(UrlCleanerSettings())
        #expect(st.loadUrl() == UrlCleanerSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("urlCleaner.") }.isEmpty)
    }

    @Test func dmgFinderAndPlainRoundTrip() {
        let (d, suite) = freshDefaults()
        let st = ClipSettingsStore(defaults: d)
        var dmg = DmgSettings()
        dmg.askFirst = false
        dmg.destination = .user
        dmg.trashDmg = true
        dmg.watchDownloads = true
        st.saveDmg(dmg)
        #expect(st.loadDmg() == dmg)
        var cut = FinderCutSettings()
        cut.pasteImage = false
        st.saveFinderCut(cut)
        #expect(st.loadFinderCut() == cut)
        var plain = PastePlainSettings()
        plain.trimEdges = true
        st.savePlain(plain)
        #expect(st.loadPlain().trimEdges)
        d.set("garbage", forKey: "dmg.destination")
        #expect(st.loadDmg().destination == .system)
    }
}

@Suite struct ClipModuleInfoTests {
    private let ids: [ModuleID] = [.clipboardHistory, .pastePlain, .urlCleaner, .dmgInstaller, .finderCutPaste, .finderRename]

    @Test func sevenModulesLiveInTheClipGroup() {
        #expect(ids.allSatisfy { $0.info.group == .clip })
        #expect(ModuleID.allCases.filter { $0.info.group == .clip }.count == 7)
        #expect(ModuleGroup.clip.title == "Буфер и файлы")
    }

    @Test func identifiersAndKeysAreAscii() {
        for id in ids {
            #expect(id.rawValue.allSatisfy { $0.isASCII })
            #expect(id.enabledKey.allSatisfy { $0.isASCII })
            for h in id.info.hotkeys { #expect(h.id.allSatisfy { $0.isASCII }) }
        }
    }

    @Test func hotkeysAreUnassignedAndUnique() {
        let specs = ids.flatMap { $0.info.hotkeys }
        #expect(specs.count == 4)
        #expect(specs.allSatisfy { $0.defaultCombo.isNone })
        let all = ModuleID.allCases.flatMap { $0.info.hotkeys.map(\.id) }
        #expect(Set(all).count == all.count)
    }

    @Test func modulesAreOffByDefaultWithTheRightPermissions() {
        #expect(ids.allSatisfy { !$0.info.enabledByDefault })
        #expect(ModuleID.clipboardHistory.info.permissions == [.accessibility])
        #expect(ModuleID.pastePlain.info.permissions == [.accessibility])
        #expect(ModuleID.urlCleaner.info.permissions.isEmpty)
        #expect(ModuleID.dmgInstaller.info.permissions.contains(.appManagement))
        #expect(ModuleID.finderCutPaste.info.permissions == [.accessibility, .automation])
        #expect(Permission.appManagement.settingsURL.hasSuffix("Privacy_AppBundles"))
    }

    @Test func settingKeysAreAsciiAcrossTheStore() {
        let (d, suite) = freshDefaults()
        let st = ClipSettingsStore(defaults: d)
        var s = ClipSettings(); s.maxItems = 77; s.keepFiles = true; s.clearOnSleep = true; s.menuBarPreview = true; s.pasteOnPick = false
        st.saveClipboard(s)
        var u = UrlCleanerSettings(); u.cleanOnCopy = false; u.rules.added = ["": ["x"]]
        st.saveUrl(u)
        var m = DmgSettings(); m.reveal = false; m.watchDownloads = true
        st.saveDmg(m)
        let keys = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("clipboard.") || $0.hasPrefix("urlCleaner.") || $0.hasPrefix("dmg.") }
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test func runtimeStartsAndStopsEachModuleIndependently() async {
        await MainActor.run {
            let d = InMemoryKeyValueStore()
            let rt = ModuleRuntime(defaults: d, ids: ids) { FakeModule($0) }
            rt.startEnabled()
            #expect(rt.activeModules.isEmpty)
            rt.setEnabled(.urlCleaner, true)
            rt.setEnabled(.finderRename, true)
            #expect(rt.isRunning(.urlCleaner) && rt.isRunning(.finderRename) && !rt.isRunning(.pastePlain))
            #expect(rt.modules(in: .clip).count == 2)
            rt.setEnabled(.urlCleaner, false)
            #expect(!rt.isRunning(.urlCleaner) && rt.isRunning(.finderRename))
        }
    }
}
