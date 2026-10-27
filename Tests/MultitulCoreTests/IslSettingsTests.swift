import Testing
import Foundation
@testable import MultitulCore

@Suite struct IslSettingsTests {
    @Test func defaultsMatchTheCatalog() {
        let s = IslSettings()
        #expect(s.hoverDelay == 0.25 && s.openOnHover && s.openOnScroll && s.glass && !s.hideMenuIcon)
        #expect(s.sizePreset == .standard && s.closeBehavior == .onLeave && s.start == .last)
        #expect(s.displayMode == .builtin && s.virtualPill && s.hideInFullscreen && s.avoidMenus)
    }

    @Test func freshStoreLoadsDefaults() {
        #expect(IslSettingsStore(WndMemoryStore()).load() == IslSettings())
    }

    @Test func defaultsWriteNothing() {
        let kv = WndMemoryStore()
        IslSettingsStore(kv).save(IslSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func everyFieldRoundTrips() {
        var s = IslSettings()
        s.sizePreset = .spacious
        s.openOnHover = false
        s.hoverDelay = 0.6
        s.openOnScroll = false
        s.openOnClick = false
        s.closeOnScrollUp = false
        s.closeBehavior = .manual
        s.leaveGrace = 1.2
        s.peekOnChange = false
        s.peekDuration = 5
        s.displayMode = .selected
        s.selectedDisplays = ["0610-a001-00000001", "builtin"]
        s.virtualPill = false
        s.hideInFullscreen = false
        s.avoidMenus = false
        s.glass = false
        s.hideMenuIcon = true
        s.start = .fixed("shelf")
        s.musicSwipe = .section
        s.mutedActivities = ["levels", "shots"]
        let kv = WndMemoryStore()
        IslSettingsStore(kv).save(s)
        #expect(IslSettingsStore(kv).load() == s)
    }

    @Test func eachChangedFieldWritesExactlyOneKey() {
        var s = IslSettings()
        s.glass = false
        let kv = WndMemoryStore()
        IslSettingsStore(kv).save(s)
        #expect(kv.values.keys.sorted() == ["notch.glass"])
    }

    @Test func settingBackToDefaultRemovesTheKey() {
        let kv = WndMemoryStore()
        let store = IslSettingsStore(kv)
        var s = IslSettings()
        s.hoverDelay = 0.8
        store.save(s)
        #expect(kv.values["notch.hoverDelay"] != nil)
        s.hoverDelay = 0.25
        store.save(s)
        #expect(kv.values.isEmpty)
    }

    @Test func outOfRangeValuesAreClamped() {
        var s = IslSettings()
        s.hoverDelay = 99
        s.leaveGrace = -4
        s.peekDuration = 0
        let c = s.sanitized
        #expect(c.hoverDelay == IslSettings.hoverDelayRange.upperBound)
        #expect(c.leaveGrace == IslSettings.leaveGraceRange.lowerBound)
        #expect(c.peekDuration == IslSettings.peekDurationRange.lowerBound)
    }

    @Test func nonFiniteValuesFallToTheLowerBound() {
        var s = IslSettings()
        s.hoverDelay = .nan
        s.leaveGrace = .infinity
        #expect(s.sanitized.hoverDelay == IslSettings.hoverDelayRange.lowerBound)
        #expect(s.sanitized.leaveGrace == IslSettings.leaveGraceRange.lowerBound)
    }

    @Test func storedGarbageIsSanitizedOnLoad() {
        let kv = WndMemoryStore()
        kv.set(77.0, forKey: "notch.hoverDelay")
        kv.set("nonsense", forKey: "notch.size")
        kv.set(5, forKey: "notch.glass")
        kv.set("id:", forKey: "notch.start")
        let s = IslSettingsStore(kv).load()
        #expect(s.hoverDelay == IslSettings.hoverDelayRange.upperBound && s.sizePreset == .standard && s.glass && s.start == .last)
    }

    @Test func emptyDisplayKeysAreDropped() {
        var s = IslSettings()
        s.selectedDisplays = ["", "ok", String(repeating: "x", count: 200)]
        #expect(s.sanitized.selectedDisplays == ["ok"])
    }

    @Test func startChoiceStoredForms() {
        #expect(IslStartChoice(stored: nil) == .last)
        #expect(IslStartChoice(stored: "last") == .last)
        #expect(IslStartChoice(stored: "auto") == .auto)
        #expect(IslStartChoice(stored: "id:music") == .fixed("music"))
        #expect(IslStartChoice(stored: "id:") == .last)
        #expect(IslStartChoice(stored: "junk") == .last)
        for c in [IslStartChoice.last, .auto, .fixed("shelf")] { #expect(IslStartChoice(stored: c.stored) == c) }
    }

    @Test func enumTitlesAreFilled() {
        for m in IslCloseBehavior.allCases { #expect(!m.title.isEmpty && !m.summary.isEmpty) }
        for m in IslSwipeAction.allCases { #expect(!m.title.isEmpty) }
        for m in IslSizePreset.allCases { #expect(!m.title.isEmpty && m.openSize.width > 300) }
    }

    @Test func keysAreAscii() {
        var s = IslSettings()
        s.sizePreset = .compact
        s.openOnHover = false
        s.hoverDelay = 0.9
        s.openOnScroll = false
        s.openOnClick = false
        s.closeOnScrollUp = false
        s.closeBehavior = .manual
        s.leaveGrace = 2
        s.peekOnChange = false
        s.peekDuration = 8
        s.displayMode = .all
        s.selectedDisplays = ["a"]
        s.virtualPill = false
        s.hideInFullscreen = false
        s.avoidMenus = false
        s.glass = false
        s.hideMenuIcon = true
        s.start = .auto
        s.musicSwipe = .section
        s.mutedActivities = ["x"]
        let kv = WndMemoryStore()
        IslSettingsStore(kv).save(s)
        #expect(kv.values.count == 20)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("notch.") && $0.allSatisfy { $0.isASCII } })
    }

    @Test func settingsDoNotTouchTheRealDefaults() {
        let kv = WndMemoryStore()
        var s = IslSettings()
        s.glass = false
        IslSettingsStore(kv).save(s)
        #expect(UserDefaults.standard.object(forKey: "notch.glass") == nil)
    }
}

@Suite struct IslModuleRegistrationTests {
    @Test func moduleLivesInTheIslandGroup() {
        let i = ModuleID.notch.info
        #expect(i.group == .island && i.id == .notch && !i.enabledByDefault)
        #expect(!i.title.isEmpty && !i.summary.isEmpty && !i.symbol.isEmpty)
        #expect(i.permissions == [.accessibility])
    }

    @Test func identifiersAreAscii() {
        #expect(ModuleID.notch.rawValue == "notch" && ModuleID.notch.enabledKey == "module.notch.enabled")
        #expect(IslHotkeys.toggle.id.allSatisfy { $0.isASCII })
    }

    @Test func hotkeyShipsUnassignedWithAHint() {
        #expect(IslHotkeys.toggle.defaultCombo.isNone)
        #expect(ModuleID.notch.info.hotkeys == [IslHotkeys.toggle])
        let hint = HotkeyHints.effective(IslHotkeys.toggle)
        #expect(hint == KeyCombo(keyCode: 34, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd))
        #expect(hint.display == "⌃⌥⌘I")
    }

    @Test func hotkeyDoesNotCollideWithAnythingElse() {
        let hint = HotkeyHints.effective(IslHotkeys.toggle)
        let others = HotkeyHints.allSpecs.filter { $0.id != IslHotkeys.toggle.id }.map { HotkeyHints.effective($0) }
        #expect(!others.contains(hint))
    }

    @Test func islandGroupHoldsTheCoreAndExtensionModules() {
        #expect(Set(ModuleID.allCases.filter { $0.info.group == .island }) == Set([ModuleID.notch] + IslExtModules.all))
    }

    @Test func conflictingAppsHaveTitles() {
        for a in IslConflictApp.allCases { #expect(!a.title.isEmpty) }
    }
}
