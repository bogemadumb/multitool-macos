import SwiftUI
import MultitulCore
import MultitulUI

struct SoundPage: View {
    var enabled: Set<ModuleID> = []

    var body: some View {
        SettingsPage {
            if enabled.contains(.soundOutputSwitcher) { OutputSwitcherView() }
            if enabled.contains(.audioPriority) { AudioPriorityView() }
            if enabled.contains(.micMute) { MicMuteView() }
            if enabled.contains(.musicBlock) { MusicBlockView() }
            if enabled.contains(.mixer) { MixerView() }
        }
    }
}
