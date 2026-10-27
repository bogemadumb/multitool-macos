import Testing
import Foundation
@testable import MultitulCore

private let toolModules: [ModuleID] = [.quickLauncher, .quickToggles, .colorPicker, .screenOcr, .cleaningMode, .cameraPreview, .scratchpad]

@Suite struct ToolsCatalogTests {
    @Test func theSevenModulesLiveInTheToolsGroup() {
        for id in toolModules { #expect(id.info.group == .tools && id.info.id == id, "\(id)") }
        let inGroup = Set(ModuleID.allCases.filter { $0.info.group == .tools })
        #expect(inGroup == Set(toolModules).union([.autoPip, .demoClock, .mediaTools, .homebrewManager, .appUpdates, .commandBar, .radialMenu, .screenshot, .screenRecorder]))
    }

    @Test func autoPipStaysInTheToolsGroup() {
        #expect(ModuleID.autoPip.info.group == .tools)
    }

    @Test func modulesAreOffByDefault() {
        for id in toolModules { #expect(!id.info.enabledByDefault, "\(id)") }
    }

    @Test func identifiersAreAscii() {
        for id in toolModules {
            #expect(id.rawValue.allSatisfy { $0.isASCII } && id.enabledKey.allSatisfy { $0.isASCII })
            #expect(id.info.hotkeys.allSatisfy { $0.id.allSatisfy { $0.isASCII } })
        }
    }

    @Test func titlesAndSummariesAreFilled() {
        for id in toolModules { #expect(!id.info.title.isEmpty && !id.info.summary.isEmpty && !id.info.symbol.isEmpty) }
    }

    @Test func permissionsFollowTheCatalog() {
        #expect(ModuleID.quickLauncher.info.permissions.isEmpty)
        #expect(ModuleID.quickToggles.info.permissions == [.automation])
        #expect(ModuleID.colorPicker.info.permissions == [.screenRecording])
        #expect(ModuleID.screenOcr.info.permissions == [.screenRecording])
        #expect(ModuleID.cleaningMode.info.permissions == [.accessibility])
        #expect(ModuleID.cameraPreview.info.permissions == [.camera])
        #expect(ModuleID.scratchpad.info.permissions.isEmpty)
    }

    @Test func hotkeysShipUnassigned() {
        for id in toolModules { for spec in id.info.hotkeys { #expect(spec.defaultCombo.isNone, "\(spec.id)") } }
    }

    @Test func eachModuleOwnsTheExpectedSpecs() {
        #expect(ModuleID.colorPicker.info.hotkeys == [ToolsHotkeys.colorPick])
        #expect(ModuleID.screenOcr.info.hotkeys == [ToolsHotkeys.ocrCapture])
        #expect(ModuleID.cleaningMode.info.hotkeys == [ToolsHotkeys.cleaningToggle])
        #expect(ModuleID.cameraPreview.info.hotkeys == [CameraHotkeys.toggle])
        #expect(ModuleID.scratchpad.info.hotkeys == [ScratchpadHotkeys.toggle])
        #expect(ModuleID.quickToggles.info.hotkeys.isEmpty)
    }

    @Test func hotkeyIdsAreUniqueAcrossTheWholeApp() {
        let all = HotkeyHints.allSpecs.map(\.id)
        #expect(Set(all).count == all.count)
    }

    @Test func catalogSuggestionsAreRegisteredAsHints() {
        let layer = KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd
        #expect(HotkeyHints.suggested[LauncherHotkeys.toggle.id]?.display == "⌃⌘V")
        #expect(HotkeyHints.suggested[ToolsHotkeys.colorPick.id]?.display == KeyCombo(keyCode: 8, modifiers: layer).display)
        #expect(HotkeyHints.suggested[ToolsHotkeys.colorPick.id]?.display == "⌃⌥⌘C")
        #expect(HotkeyHints.suggested[ToolsHotkeys.ocrCapture.id]?.display == "⌃⌥⌘T")
        #expect(HotkeyHints.suggested[CameraHotkeys.toggle.id]?.display == "⌃⌥⌘W")
        #expect(HotkeyHints.suggested[ScratchpadHotkeys.toggle.id]?.display == "⌃⌥⌘N")
    }

    @Test func effectiveComboUsesTheHintOnlyWhenUnassigned() {
        #expect(HotkeyHints.effective(ToolsHotkeys.colorPick).display == "⌃⌥⌘C")
        #expect(HotkeyHints.effective(ToolsHotkeys.cleaningToggle).isNone)
        #expect(HotkeyHints.effective(LauncherHotkeys.slots[0]).isNone)
    }

    @Test func hintsDoNotCollideWithTheRestOfTheCatalog() {
        let hints = ToolsHintCombos.all
        let others = HotkeyHints.suggested.filter { hints[$0.key] == nil }
        for (id, combo) in hints { #expect(!others.values.contains(combo), "\(id) \(combo.display)") }
        #expect(Set(hints.values).count == hints.count)
    }

    @Test func hintsAvoidInterceptedSystemKeys() {
        for (id, combo) in ToolsHintCombos.all { #expect(!InterceptedKeys.all.contains { $0.combo == combo }, "\(id)") }
    }

    @Test func launcherToolsPointAtRealToolModules() {
        let mapped = Set(LauncherTool.allCases.map(\.module))
        #expect(mapped.isSuperset(of: [.colorPicker, .screenOcr, .scratchpad, .cameraPreview, .cleaningMode, .shelf, .clipboardHistory]))
    }
}
