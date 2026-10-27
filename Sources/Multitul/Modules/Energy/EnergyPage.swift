import SwiftUI
import MultitulCore
import MultitulUI

struct EnergyPage: View {
    var enabled: Set<ModuleID> = []

    var body: some View {
        SettingsPage {
            if enabled.contains(.keepAwake) { KeepAwakeView() }
            if enabled.contains(.gameMode) { GameModeView() }
            if enabled.contains(.bluetoothSleep) { BluetoothSleepView() }
        }
    }
}
