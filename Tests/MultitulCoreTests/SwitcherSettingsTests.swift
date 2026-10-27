import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct SwitcherSettingsTests {
    @Test func defaultsMatchTheCatalog() {
        let s = SwitcherSettings()
        #expect(s.layout == .windows && s.takeOverSystem && s.searchPin && s.showFullscreen)
        #expect(s.appearanceDelayMs == 100 && s.maxColumns == 0 && s.minimized == .normal && s.windowless == .all)
        #expect(!s.currentSpaceOnly && !s.currentDisplayOnly && !s.mergeWindows)
    }

    @Test func systemTriggersAreCommandTabAndCommandBacktick() {
        let s = SwitcherSettings()
        #expect(s.effectiveAppsTrigger == KeyCombo(keyCode: Keys.tab, modifiers: KeyCombo.cmd))
        #expect(s.effectiveWindowsTrigger == KeyCombo(keyCode: 50, modifiers: KeyCombo.cmd))
        #expect(s.effectiveAppsTrigger.display == "⌘⇥" && s.effectiveWindowsTrigger.display == "⌘`")
    }

    @Test func customTriggersApplyOnlyWithoutTakeover() {
        var s = SwitcherSettings()
        s.appsTrigger = KeyCombo(keyCode: 0, modifiers: KeyCombo.ctrl)
        #expect(s.effectiveAppsTrigger == SwitcherSettings.systemAppsTrigger)
        s.takeOverSystem = false
        #expect(s.effectiveAppsTrigger == KeyCombo(keyCode: 0, modifiers: KeyCombo.ctrl))
        #expect(s.effectiveWindowsTrigger == SwitcherSettings.customWindowsTrigger)
    }

    @Test func windowlessIsForcedToAllWhileReplacingTheSystemSwitcher() {
        var s = SwitcherSettings()
        s.windowless = .off
        #expect(s.effectiveWindowless == .all)
        s.takeOverSystem = false
        #expect(s.effectiveWindowless == .off)
    }

    @Test func sanitizingClampsRangesAndRepairsTriggers() {
        var s = SwitcherSettings()
        s.appearanceDelayMs = 99_999
        s.maxColumns = 1
        s.appsTrigger = .none
        s.windowsTrigger = KeyCombo(keyCode: 9, modifiers: KeyCombo.shift)
        let f = s.sanitized
        #expect(f.appearanceDelayMs == 1000 && f.maxColumns == 2)
        #expect(f.appsTrigger == SwitcherSettings.customAppsTrigger && f.windowsTrigger == SwitcherSettings.customWindowsTrigger)
        s.appearanceDelayMs = -5
        s.maxColumns = 99
        #expect(s.sanitized.appearanceDelayMs == 0 && s.sanitized.maxColumns == 10)
        s.maxColumns = -3
        #expect(s.sanitized.maxColumns == 0)
    }

    @Test func identicalTriggersFallBackToDefaults() {
        var s = SwitcherSettings()
        s.appsTrigger = KeyCombo(keyCode: 0, modifiers: KeyCombo.opt)
        s.windowsTrigger = KeyCombo(keyCode: 0, modifiers: KeyCombo.opt)
        let f = s.sanitized
        #expect(f.appsTrigger != f.windowsTrigger)
    }

    @Test func triggerNeedsAHoldableModifier() {
        #expect(!SwitcherSettings.isUsableTrigger(KeyCombo(keyCode: Keys.tab, modifiers: 0)))
        #expect(!SwitcherSettings.isUsableTrigger(KeyCombo(keyCode: Keys.tab, modifiers: KeyCombo.shift)))
        #expect(!SwitcherSettings.isUsableTrigger(.none))
        #expect(!SwitcherSettings.isUsableTrigger(KeyCombo(keyCode: Keys.escape, modifiers: KeyCombo.cmd)))
        #expect(SwitcherSettings.isUsableTrigger(KeyCombo(keyCode: Keys.tab, modifiers: KeyCombo.ctrl)))
    }

    @Test func filterMirrorsTheSettings() {
        var s = SwitcherSettings()
        s.currentSpaceOnly = true
        s.minimized = .end
        s.layout = .icons
        s.rules.set("com.x", .hidden)
        let f = s.filter(ownPID: 77)
        #expect(f.currentSpaceOnly && f.minimized == .end && f.mergeWindows && f.ownPID == 77 && f.rules["com.x"] == .hidden)
        s.layout = .windows
        #expect(!s.filter(ownPID: 1).mergeWindows)
    }

    @Test func appRulesMatchExactAndWildcardAndRoundTrip() {
        var r = AppRules()
        r.set("com.apple.finder", .showWithoutWindows)
        r.set("com.adobe.*", .hidden)
        #expect(r["com.apple.finder"] == .showWithoutWindows && r["com.adobe.Photoshop"] == .hidden && r["com.other"] == nil && r[nil] == nil)
        let back = AppRules(stored: r.stored)
        #expect(back == r)
        #expect(AppRules(stored: ["broken", "x|nonsense", "|hidden", "a|windowsOnly"]).map == ["a": .windowsOnly])
        r.set("com.apple.finder", nil)
        #expect(r["com.apple.finder"] == nil)
    }

    @Test func storeRoundTripsEveryField() {
        let kv = WndMemoryStore()
        let store = SwitcherSettingsStore(kv)
        var s = SwitcherSettings()
        s.layout = .simple
        s.takeOverSystem = false
        s.appsTrigger = KeyCombo(keyCode: 0, modifiers: KeyCombo.ctrl)
        s.appearanceDelayMs = 250
        s.maxColumns = 5
        s.minimized = .hidden
        s.screenPlacement = .menuBar
        s.windowless = .finder
        s.previewSize = .xlarge
        s.minimalPreviews = true
        s.searchPin = false
        s.rules.set("com.a", .windowsOnly)
        s.previewExcluded = AppExceptionList(["com.bank"])
        store.saveSwitcher(s)
        #expect(store.loadSwitcher() == s.sanitized)
    }

    @Test func defaultsAreNeverWrittenToTheStore() {
        let kv = WndMemoryStore()
        let store = SwitcherSettingsStore(kv)
        store.saveSwitcher(SwitcherSettings())
        store.saveDockPreview(DockPreviewSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func storeKeysAreAsciiAndPrefixed() {
        let kv = WndMemoryStore()
        let store = SwitcherSettingsStore(kv)
        var s = SwitcherSettings()
        s.layout = .icons
        s.rules.set("com.a", .hidden)
        s.previewExcluded = AppExceptionList(["x"])
        var d = DockPreviewSettings()
        d.quitAppOnClose = true
        d.exceptions = AppExceptionList(["y"])
        store.saveSwitcher(s)
        store.saveDockPreview(d)
        #expect(kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) && ($0.hasPrefix("windowSwitcher.") || $0.hasPrefix("dockPreview.")) })
        #expect(!kv.values.isEmpty)
    }

    @Test func dockPreviewSettingsRoundTripAndSanitize() {
        let kv = WndMemoryStore()
        let store = SwitcherSettingsStore(kv)
        var d = DockPreviewSettings()
        d.openDelayMs = 600
        d.closeDelayMs = 450
        d.opacityPercent = 55
        d.currentSpaceOnly = true
        d.order = .creation
        d.quitAppOnClose = true
        d.middleClickCloses = false
        d.showMinimized = false
        d.showTitles = false
        d.previewSize = .small
        d.minimalPreviews = true
        d.exceptions = AppExceptionList(["com.a"])
        d.previewExcluded = AppExceptionList(["com.b"])
        store.saveDockPreview(d)
        #expect(store.loadDockPreview() == d)
        var bad = DockPreviewSettings()
        bad.openDelayMs = 99_999
        bad.closeDelayMs = 0
        bad.opacityPercent = 5
        let f = bad.sanitized
        #expect(f.openDelayMs == 1500 && f.closeDelayMs == 100 && f.opacityPercent == 30)
        #expect(abs(DockPreviewSettings().opacity - 0.9) < 0.0001)
    }

    @Test func dockFilterHidesMinimizedOnRequestAndNeverShowsWindowless() {
        var d = DockPreviewSettings()
        #expect(d.filter(ownPID: 1).minimized == .normal && d.filter(ownPID: 1).windowless == .off)
        d.showMinimized = false
        d.currentSpaceOnly = true
        #expect(d.filter(ownPID: 1).minimized == .hidden && d.filter(ownPID: 1).currentSpaceOnly)
    }

    @Test func previewSizesGrow() {
        let w = PreviewSize.allCases.map(\.thumbWidth)
        #expect(w == w.sorted() && Set(w).count == 4)
    }
}

@Suite struct SwitcherModuleInfoTests {
    @Test func bothModulesLiveInTheWindowsGroupAndAreOffByDefault() {
        for id in [ModuleID.windowSwitcher, .dockPreview] {
            #expect(id.info.group == .windows && !id.info.enabledByDefault)
            #expect(id.rawValue.allSatisfy(\.isASCII) && id.enabledKey.allSatisfy(\.isASCII))
            #expect(id.info.permissions.contains(.accessibility) && id.info.permissions.contains(.screenRecording))
            #expect(id.info.hotkeys.isEmpty && !id.info.summary.isEmpty)
            #expect(id.info.title.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) })
        }
    }

    @Test func interceptedCatalogReservesCommandTabAndBacktick() {
        let ids = InterceptedKeys.all.map(\.id)
        #expect(ids.contains(InterceptedKeys.switcherAppsID) && ids.contains(InterceptedKeys.switcherWindowsID))
        #expect(InterceptedKeys.switcherApps == KeyCombo(keyCode: 48, modifiers: KeyCombo.cmd))
        #expect(InterceptedKeys.switcherWindows == KeyCombo(keyCode: 50, modifiers: KeyCombo.cmd))
        #expect(InterceptedKeys.title(of: InterceptedKeys.switcherAppsID) != nil)
    }

    @Test func eventTapPrioritiesFitTheChain() {
        #expect(InputPriority.switcher > InputPriority.windowRing)
        #expect(InputPriority.switcher > InputPriority.quitProtection)
        #expect(InputPriority.switcher < InputPriority.superKey)
        #expect(InputPriority.dockPreview < InputPriority.dockClick && InputPriority.dockPreview > InputPriority.edgeSnap)
        let all = [InputPriority.debounce, InputPriority.superKey, InputPriority.switcher, InputPriority.windowRing, InputPriority.windowGesture, InputPriority.dockClick, InputPriority.dockPreview]
        #expect(Set(all).count == all.count)
    }

    @Test func conflictNoticeNamesOtherSwitchers() {
        let running: [(bundleID: String?, name: String?)] = [("com.lwouis.alt-tab-macos", "AltTab"), ("com.ethanbills.DockDoor", "DockDoor"), ("com.example.switcher", "Example"), ("com.apple.finder", "Finder")]
        #expect(WindowConflicts.detect(running: running, for: .windowSwitcher, extraBundleIDs: ["com.example.switcher"]) == ["AltTab", "DockDoor", "com.example.switcher"])
        #expect(WindowConflicts.detect(running: running, for: .dockPreview, extraBundleIDs: ["com.example.switcher"]) == ["DockDoor", "com.example.switcher"])
        #expect(WindowConflicts.detect(running: running, for: .spacesOrder, extraBundleIDs: []).isEmpty)
    }

    @Test func conflictNoticeDoesNotFireOnLookalikeNames() {
        let running: [(bundleID: String?, name: String?)] = [("com.nintendo.switch", "Nintendo Switch Online"), (nil, "Dock Utility")]
        #expect(WindowConflicts.detect(running: running, for: .windowSwitcher).isEmpty)
        #expect(WindowConflicts.detect(running: running, for: .dockPreview).isEmpty)
    }

    @Test func existingStageFifteenConflictsStayIntact() {
        let running: [(bundleID: String?, name: String?)] = [("com.knollsoft.Rectangle", "Rectangle")]
        #expect(WindowConflicts.detect(running: running, for: .windowLayout) == ["Rectangle"])
        #expect(WindowConflicts.detect(running: running, for: .windowSwitcher).isEmpty)
    }
}

@MainActor
@Suite struct SwitcherReservationTests {
    private func manager() -> (HotkeyManager, FakeHotkeyBackend) {
        let be = FakeHotkeyBackend()
        return (HotkeyManager(backend: be, defaults: actDefaults()), be)
    }

    @Test func reservingTheTriggersBlocksARegularHotkeyOnThem() {
        let (hm, be) = manager()
        let s = SwitcherSettings()
        hm.reserve(id: InterceptedKeys.switcherAppsID, title: "a", combo: s.effectiveAppsTrigger)
        hm.reserve(id: InterceptedKeys.switcherWindowsID, title: "w", combo: s.effectiveWindowsTrigger)
        let spec = HotkeySpec(id: "test.cmdtab", title: "T", defaultCombo: SwitcherSettings.systemAppsTrigger)
        #expect(hm.register(spec, owner: "t") {} == .conflict(with: InterceptedKeys.switcherAppsID))
        #expect(be.live.isEmpty)
        hm.release(id: InterceptedKeys.switcherAppsID)
        #expect(hm.state(of: "test.cmdtab") == .active)
    }

    @Test func recordingCommandTabForAnotherActionIsRefusedWhileEnabled() {
        let (hm, _) = manager()
        hm.reserve(id: InterceptedKeys.switcherAppsID, title: "a", combo: SwitcherSettings.systemAppsTrigger)
        #expect(hm.setCombo(SnippetHotkeys.library, to: SwitcherSettings.systemAppsTrigger) == .conflict(with: InterceptedKeys.switcherAppsID))
    }
}
