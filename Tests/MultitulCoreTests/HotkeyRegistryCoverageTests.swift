import Testing
@testable import MultitulCore

@Suite struct HotkeyRegistryCoverageTests {
    @Test func everyHotkeyRemovedFromModulePagesIsInRegistry() {
        let removed: [HotkeySpec] = ShotHotkeys.all + RecHotkeys.all + [
            ToolsHotkeys.cleaningToggle, GameModeHotkeys.toggle, ScratchpadHotkeys.toggle, ModuleID.vpn.info.hotkeys[0],
            ModuleID.monitorToggle.info.hotkeys[0], CameraHotkeys.toggle, ToolsHotkeys.ocrCapture, ToolsHotkeys.colorPick,
            KeepAwakeHotkeys.toggle, SoundHotkeys.micToggle, SoundHotkeys.outputNext, CommandBarHotkeys.toggle,
            LauncherHotkeys.toggle, IslHotkeys.toggle]
        let ids = Set(HotkeyRegistry.rows.map(\.spec.id))
        for s in removed { #expect(ids.contains(s.id), "\(s.id) missing in HotkeyRegistry") }
        #expect(removed.count >= 20)
    }
}
