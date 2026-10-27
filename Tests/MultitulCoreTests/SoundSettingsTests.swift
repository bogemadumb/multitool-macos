import Testing
import Foundation
@testable import MultitulCore

private func fresh() -> (InMemoryKeyValueStore, String) {
    let suite = "multitul.test.\(UUID().uuidString)"
    return (InMemoryKeyValueStore(), suite)
}

@Suite struct SoundSettingsTests {
    @Test func switcherDefaultsAndRoundTrip() {
        let (d, suite) = fresh()
        let st = SoundSettingsStore(defaults: d)
        #expect(st.loadSwitcher() == OutputSwitcherSettings())
        var s = OutputSwitcherSettings()
        s.cycle = ["a", "b"]
        s.syncSystemOutput = false
        s.showHud = false
        st.saveSwitcher(s)
        #expect(st.loadSwitcher() == s)
        st.saveSwitcher(OutputSwitcherSettings())
        #expect(d.object(forKey: "soundOutput.cycle") == nil)
        #expect(d.object(forKey: "soundOutput.hud") == nil)
    }

    @Test func priorityRoundTripKeepsOrderAndIgnoredSet() {
        let (d, suite) = fresh()
        let st = SoundSettingsStore(defaults: d)
        var c = AudioPriorityConfig()
        c.output = AudioPriorityRule(enabled: true, order: ["x", "y", "z"], ignored: ["q"])
        c.input = AudioPriorityRule(enabled: false, order: ["m"], ignored: [])
        c.onConnect = .onlyOnDisconnect
        c.newDevice = .adoptIfSystemChose
        c.syncSystemOutput = false
        c.notify = true
        st.savePriority(c)
        #expect(st.loadPriority() == c)
    }

    @Test func priorityLoadDropsDuplicatesAndGarbage() {
        let (d, suite) = fresh()
        d.set(["a", "a", "", "b"], forKey: "audioPriority.output.order")
        d.set("nonsense", forKey: "audioPriority.onConnect")
        let c = SoundSettingsStore(defaults: d).loadPriority()
        #expect(c.output.order == ["a", "b"])
        #expect(c.onConnect == .takeOverIfHigher)
    }

    @Test func micRoundTripAndDefaults() {
        let (d, suite) = fresh()
        let st = SoundSettingsStore(defaults: d)
        #expect(st.loadMic() == MicMuteSettings())
        var s = MicMuteSettings()
        s.scope = .defaultInput
        s.showIndicator = false
        st.saveMic(s)
        #expect(st.loadMic() == s)
        st.saveMic(MicMuteSettings())
        #expect(d.object(forKey: "micMute.scope") == nil)
    }

    @Test func namesRoundTrip() {
        let (d, suite) = fresh()
        let st = SoundSettingsStore(defaults: d)
        st.saveNames(["airpods": "AirPods Ивана"])
        #expect(st.loadNames() == ["airpods": "AirPods Ивана"])
        st.saveNames([:])
        #expect(st.loadNames().isEmpty)
    }
}

@Suite struct SoundModuleInfoTests {
    private let ids: [ModuleID] = [.soundOutputSwitcher, .audioPriority, .micMute, .musicBlock]

    @Test func fiveModulesLiveInTheSoundGroup() {
        #expect(ids.allSatisfy { $0.info.group == .sound })
        #expect(ModuleID.allCases.filter { $0.info.group == .sound }.count == 5)
    }

    @Test func identifiersAndSettingKeysAreAscii() {
        for id in ids {
            #expect(id.rawValue.allSatisfy { $0.isASCII })
            #expect(id.enabledKey.allSatisfy { $0.isASCII })
            for h in id.info.hotkeys { #expect(h.id.allSatisfy { $0.isASCII }) }
        }
    }

    @Test func hotkeysAreUnassignedByDefault() {
        let all = ids.flatMap { $0.info.hotkeys }
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.defaultCombo.isNone })
    }

    @Test func modulesAreOffByDefaultAndMusicBlockAsksForAccessibility() {
        #expect(ids.allSatisfy { !$0.info.enabledByDefault })
        #expect(ModuleID.musicBlock.info.permissions == [.accessibility])
        #expect(ModuleID.micMute.info.permissions.isEmpty)
    }

    @Test func hotkeyIdsAreUniqueAcrossAllModules() {
        let all = ModuleID.allCases.flatMap { $0.info.hotkeys.map(\.id) }
        #expect(Set(all).count == all.count)
    }

    @Test func halReadsDevicesWithoutCrashing() {
        let hal = CoreAudioHal()
        let devs = hal.devices()
        #expect(Set(devs.map(\.uid)).count == devs.count)
        #expect(devs.allSatisfy { !$0.uid.isEmpty && ($0.hasInput || $0.hasOutput) })
        if let uid = hal.defaultUID(.output) { #expect(!uid.isEmpty) }
    }
}
