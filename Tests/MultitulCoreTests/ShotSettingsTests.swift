import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShotSettingsTests {
    @Test func defaultsAreSafe() {
        let s = ShotSettings()
        #expect(s.format == .png && s.saveToDisk && s.copyToClipboard && !s.addToShelf && !s.takeOverSystemKeys)
        #expect(s.afterCapture == .overlay && s.timerSeconds == 0 && s.freezeScreen && s.confirmOnRelease)
        #expect(s.linkTTL == .hours24 && !s.watermark.isActive && s.background.isNone)
    }

    @Test func roundTripThroughTheStore() {
        let kv = WndMemoryStore()
        var s = ShotSettings()
        s.saveDirectory = "~/Pictures/Мои снимки"
        s.nameTemplate = "shot-{counter:3}"
        s.format = .jpeg
        s.quality = 0.55
        s.saveToDisk = false
        s.afterCapture = .editor
        s.openEditorImmediately = true
        s.addToShelf = true
        s.timerSeconds = 5
        s.background = .gradient(.red, .blue, angle: 90)
        s.windowPadding = 40
        s.historyLimit = 250
        s.overlayCorner = .topLeft
        s.linkTTL = .hours6
        s.watermark.enabled = true
        s.watermark.text = "Иван"
        ShotSettingsStore(kv).save(s)
        let back = ShotSettingsStore(kv).load()
        #expect(back == s.sanitized)
    }

    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        ShotSettingsStore(kv).save(ShotSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func settingKeysAreAsciiAndPrefixed() {
        let kv = WndMemoryStore()
        var s = ShotSettings()
        s.saveDirectory = "/x"; s.nameTemplate = "t"; s.format = .heic; s.quality = 0.5; s.saveToDisk = false; s.copyToClipboard = false
        s.afterCapture = .pin; s.openEditorImmediately = true; s.addToShelf = true; s.includeCursor = true; s.freezeScreen = false
        s.confirmOnRelease = false; s.timerSeconds = 3; s.windowShadow = false; s.windowPadding = 9; s.background = .solid(.black)
        s.backgroundCorner = 3; s.downscaleRetina = true; s.recordHistory = false; s.indexText = false; s.historyLimit = 99
        s.historyKeepDays = 5; s.overlaySeconds = 3; s.overlayCorner = .bottomLeft; s.linkTTL = .hour1; s.takeOverSystemKeys = true
        s.scrollMaxHeight = 5000; s.watermark.enabled = true; s.watermark.text = "w"; s.watermark.corner = .topLeft; s.watermark.opacity = 0.2; s.watermark.fontSize = 20
        ShotSettingsStore(kv).save(s)
        #expect(kv.values.count >= 28)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("screenshot.") && $0.allSatisfy(\.isASCII) })
    }

    @Test func sanitizeClampsEverything() {
        var s = ShotSettings()
        s.quality = 5; s.timerSeconds = 999; s.windowPadding = -4; s.historyLimit = 1; s.historyKeepDays = -3; s.overlaySeconds = 500
        s.scrollMaxHeight = 5; s.backgroundCorner = 900; s.nameTemplate = "   "
        let c = s.sanitized
        #expect(c.quality == 1 && c.timerSeconds == 60 && c.windowPadding == 0 && c.historyLimit == ShotSettings.historyLimitRange.lowerBound)
        #expect(c.historyKeepDays == 0 && c.overlaySeconds == 60 && c.scrollMaxHeight == 2000 && c.backgroundCorner == 80)
        #expect(c.nameTemplate == ShotNaming.defaultTemplate)
    }

    @Test func timerChoicesAreKept() {
        for t in ShotSettings.timerChoices { var s = ShotSettings(); s.timerSeconds = t; #expect(s.sanitized.timerSeconds == t) }
    }

    @Test func resolvedDirectoryHandlesTildeAndDefault() {
        var s = ShotSettings()
        #expect(s.resolvedDirectory(home: "/Users/m") == "/Users/m/Pictures/Screenshots")
        s.saveDirectory = "~/Desktop/Shots"
        #expect(s.resolvedDirectory(home: "/Users/m") == "/Users/m/Desktop/Shots")
        s.saveDirectory = "~"
        #expect(s.resolvedDirectory(home: "/Users/m") == "/Users/m")
        s.saveDirectory = "/Volumes/Диск/снимки"
        #expect(s.resolvedDirectory(home: "/Users/m") == "/Volumes/Диск/снимки")
    }

    @Test func formatsMapToExtensionsAndMime() {
        #expect(ShotFormat.jpeg.fileExtension == "jpg" && ShotFormat.jpeg.mimeType == "image/jpeg" && ShotFormat.png.typeIdentifier == "public.png")
        #expect(ShotFormat.from(fileExtension: "JPG") == .jpeg && ShotFormat.from(fileExtension: "jpeg") == .jpeg && ShotFormat.from(fileExtension: "gif") == nil)
        #expect(!ShotFormat.png.usesQuality && ShotFormat.heic.usesQuality && !ShotFormat.jpeg.keepsAlpha)
    }

    @Test func colorHexRoundTrips() {
        #expect(ShotColor(hex: "#FF3B30") == .red)
        #expect(ShotColor(hex: "ff3b3080")?.a == 0x80)
        #expect(ShotColor.red.hex == "#FF3B30" && ShotColor(1, 2, 3, 4).hex == "#01020304")
        #expect(ShotColor(hex: "#12") == nil && ShotColor(hex: "zzzzzz") == nil)
        #expect(ShotColor.blue.withAlpha(0.5).a == 128)
    }

    @Test func colorsEncodeAsStrings() throws {
        let d = try JSONEncoder().encode([ShotColor.green])
        #expect(String(decoding: d, as: UTF8.self) == ##"["#34C759"]"##)
        #expect(try JSONDecoder().decode([ShotColor].self, from: d) == [.green])
        #expect(throws: (any Error).self) { try JSONDecoder().decode([ShotColor].self, from: Data(#"["nope"]"#.utf8)) }
    }

    @Test func backgroundStoredFormRoundTrips() {
        for b in [ShotBackground.none, .solid(.white), .gradient(.red, .blue, angle: 135)] { #expect(ShotBackground(stored: b.stored) == b) }
        #expect(ShotBackground(stored: "garbage") == .none)
        #expect(ShotBackground(stored: "gradient:#FF0000:#0000FF:-90") == .gradient(ShotColor(255, 0, 0), ShotColor(0, 0, 255), angle: 270))
        #expect(ShotBackground.presets.count >= 5 && ShotBackground.presets.allSatisfy { ShotBackground(stored: $0.value.stored) == $0.value })
    }

    @Test func watermarkIsActiveOnlyWithText() {
        var w = ShotWatermark()
        w.enabled = true
        #expect(!w.isActive)
        w.text = "  "
        #expect(!w.isActive)
        w.text = "x"
        #expect(w.isActive)
        w.opacity = 9
        w.fontSize = 1
        #expect(w.sanitized.opacity == 1 && w.sanitized.fontSize == 8)
    }

    @Test func linkTTLValues() {
        #expect(ShotLinkTTL.allCases.map(\.hours) == [1, 6, 24])
        #expect(ShotLinkTTL.hours6.seconds == 21600)
    }

    @Test func cornerHelpers() {
        #expect(ShotCorner.topRight.isRight && ShotCorner.topRight.isTop && !ShotCorner.bottomLeft.isRight && !ShotCorner.bottomLeft.isTop)
    }
}

@Suite struct ShotCatalogTests {
    @Test func moduleLivesInTools() {
        let i = ModuleID.screenshot.info
        #expect(i.group == .tools && i.id == .screenshot && !i.enabledByDefault)
        #expect(i.permissions == [.screenRecording])
        #expect(!i.title.isEmpty && !i.summary.isEmpty && !i.symbol.isEmpty)
    }

    @Test func identifiersAreAscii() {
        #expect(ModuleID.screenshot.rawValue.allSatisfy(\.isASCII) && ModuleID.screenshot.enabledKey == "module.screenshot.enabled")
        #expect(ShotHotkeys.all.allSatisfy { $0.id.allSatisfy(\.isASCII) && $0.id.hasPrefix("screenshot.") })
        #expect(ShotSystemKeys.entries.allSatisfy { $0.spec.id.allSatisfy(\.isASCII) })
    }

    @Test func allCatalogHotkeysShipUnassigned() {
        #expect(ModuleID.screenshot.info.hotkeys.count == ShotHotkeys.all.count)
        #expect(ShotHotkeys.all.allSatisfy { $0.defaultCombo.isNone })
    }

    @Test func hintsUseTheControlOptionCommandLayer() {
        let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd
        #expect(HotkeyHints.suggested[ShotHotkeys.area.id] == KeyCombo(keyCode: 21, modifiers: layer))
        #expect(HotkeyHints.suggested[ShotHotkeys.screen.id]?.display == "⌃⌥⌘3")
        #expect(HotkeyHints.suggested[ShotHotkeys.area.id]?.display == "⌃⌥⌘4")
        #expect(HotkeyHints.suggested[ShotHotkeys.link.id]?.display == "⌃⌥⌘U")
        #expect(HotkeyHints.suggested[ShotHotkeys.editLast.id]?.display == "⌃⌥⌘E")
        #expect(HotkeyHints.suggested[ShotHotkeys.history.id]?.display == "⌃⌥⌘H")
        #expect(HotkeyHints.suggested[ShotHotkeys.editClipboard.id]?.display == "⌃⌥⌘P")
        #expect(HotkeyHints.suggested[ShotHotkeys.window.id] == nil)
    }

    @Test func systemShortcutEntriesCoverTheFiveNativeKeys() {
        #expect(ShotSystemKeys.symbolicIDs == [28, 29, 30, 31, 184])
        let combos = ShotSystemKeys.entries.map(\.spec.defaultCombo)
        #expect(Set(combos).count == 5)
        #expect(ShotSystemKeys.entries.filter(\.clipboardOnly).count == 2)
        #expect(ShotSystemKeys.entries.first { $0.symbolicID == 184 }?.mode == nil)
        #expect(combos.contains(KeyCombo(keyCode: 21, modifiers: KeyCombo.shift | KeyCombo.cmd)))
    }

    @Test func systemShortcutsAreNotInTheCatalogSoTheyCannotCollide() {
        let ids = Set(HotkeyHints.allSpecs.map(\.id))
        for e in ShotSystemKeys.entries { #expect(!ids.contains(e.spec.id)) }
    }

    @Test func modesAndActionsHaveTitles() {
        #expect(ShotMode.allCases.count == 5 && ShotMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
        #expect(ShotAfterAction.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(AnnotationTool.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }
}

@Suite struct ShotTakeoverTests {
    private func make() -> (SystemShortcutTakeover, SwcHotKeys, WndMemoryStore) {
        let d = SwcHotKeys()
        for id in ShotSystemKeys.symbolicIDs { d.state[id] = true }
        let kv = WndMemoryStore()
        return (SystemShortcutTakeover(driver: d, store: kv, journalKey: ShotSystemKeys.journalKey), d, kv)
    }

    @Test func holdsAndRestoresThroughTheOwnJournal() {
        let (t, d, kv) = make()
        #expect(t.hold(ids: ShotSystemKeys.symbolicIDs) == .held([28, 29, 30, 31, 184]))
        #expect(d.state[30] == false && d.state[184] == false)
        #expect(kv.values[ShotSystemKeys.journalKey] != nil && kv.values[SystemShortcutTakeover.journalKey] == nil)
        #expect(t.release() == .released([28, 29, 30, 31, 184]))
        #expect(d.state[30] == true && kv.values[ShotSystemKeys.journalKey] == nil)
    }

    @Test func doesNotTouchKeysTheUserAlreadyDisabled() {
        let (t, d, _) = make()
        d.state[31] = false
        #expect(t.hold(ids: ShotSystemKeys.symbolicIDs) == .held([28, 29, 30, 184]))
        _ = t.release()
        #expect(d.state[31] == false)
    }

    @Test func failureKeepsTheJournalForWhatWasDisabled() {
        let (t, d, _) = make()
        d.failIDs = [184]
        if case .failed = t.hold(ids: ShotSystemKeys.symbolicIDs) {} else { Issue.record("expected failure") }
        #expect(t.journal == [28, 29, 30, 31])
        d.failIDs = []
        #expect(t.release() == .released([28, 29, 30, 31]))
    }

    @Test func staleJournalIsRecoveredWhenTheModuleIsOff() {
        let (t, d, _) = make()
        _ = t.hold(ids: [30, 31])
        #expect(t.recoverStale(moduleEnabled: true) == nil)
        #expect(t.recoverStale(moduleEnabled: false) == .released([30, 31]))
        #expect(d.state[30] == true)
    }

    @Test func switcherJournalIsUntouched() {
        let d = SwcHotKeys()
        let kv = WndMemoryStore()
        let sw = SystemShortcutTakeover(driver: d, store: kv)
        _ = sw.hold()
        let shot = SystemShortcutTakeover(driver: d, store: kv, journalKey: ShotSystemKeys.journalKey)
        #expect(shot.journal.isEmpty && shot.release() == .nothingToRelease)
        #expect(sw.isHolding)
    }
}
