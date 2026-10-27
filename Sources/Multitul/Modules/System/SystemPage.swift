import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct SystemPage: View {
    var enabled: Set<ModuleID> = []
    @ObservedObject private var hub = SystemHub.shared
    @State private var health = AgentHealth.checkLive()

    var body: some View {
        SettingsPage {
            if !health.isHealthy {
                Section { ToolWarning(text: health.status == .never ? "Сборщик истории не запускался. \(health.summary)" : "Сборщик истории молчит. \(health.summary)") }
            }
            SystemOverview(hub: hub)
            Section {
                NavigationLink(value: SystemRoute.processes) { Text("Процессы") }
                NavigationLink(value: SystemRoute.history) { Text("История") }
                NavigationLink(value: SystemRoute.energy) { Text("Энергия") }
                if enabled.contains(.fanControl) {
                    NavigationLink(value: SystemRoute.fans) { Text("Вентиляторы") }
                }
                if enabled.contains(.killProcess) {
                    NavigationLink(value: SystemRoute.kill) { Text("Завершение процессов") }
                }
                if enabled.contains(.portManager) {
                    NavigationLink(value: SystemRoute.ports) { Text("Порты") }
                }
                LabeledContent("Сборщик истории") {
                    StatusLabel(health.isHealthy ? "работает" : (health.status == .never ? "не запускался" : "молчит"), color: health.isHealthy ? .green : .orange)
                }
                .help(health.summary)
            } header: { Text("Подробнее") }
            SystemSettingsSections(hub: hub)
        }
        .navigationDestination(for: SystemRoute.self) { route in
            switch route {
            case .processes: SystemProcesses(hub: hub).navigationTitle("Процессы")
            case .history: SystemHistoryView(health: health).navigationTitle("История")
            case .energy: SystemEnergy(hub: hub).navigationTitle("Энергия")
            case .fans: FanControlView().navigationTitle("Вентиляторы")
            case .kill: KillProcessView().navigationTitle("Завершение процессов")
            case .ports: PortManagerView().navigationTitle("Порты")
            }
        }
        .onAppear { hub.pageAppeared() }
        .onDisappear { hub.pageDisappeared() }
        .task {
            while !Task.isCancelled {
                health = await Task.detached { AgentHealth.checkLive() }.value
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

func rateParts(_ bps: Double) -> (String, String) {
    let parts = SysFormat.rate(bps).split(separator: " ", maxSplits: 1).map(String.init)
    return (parts.first ?? "0", parts.count > 1 ? parts[1] : "")
}

func bytesParts(_ b: Double) -> (String, String) {
    let parts = SysFormat.diskBytes(b).split(separator: " ", maxSplits: 1).map(String.init)
    return (parts.first ?? "0", parts.count > 1 ? parts[1] : "")
}
