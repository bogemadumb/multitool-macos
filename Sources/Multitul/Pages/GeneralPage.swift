import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

private enum HelperState: Equatable {
    case notInstalled, installed, checking, ok, failed(String)

    var text: String {
        switch self {
        case .notInstalled: "Не установлен"
        case .installed: "Установлен"
        case .checking: "Проверяю…"
        case .ok: "Работает"
        case .failed: "Не отвечает"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .notInstalled, .failed: .orange
        case .installed, .checking: .secondary
        }
    }
}

struct GeneralPage: View {
    @State private var autostart = Autostart.isEnabled()
    @State private var agent = AgentHealth.checkLive()
    @State private var helper: HelperState = FileManager.default.isExecutableFile(atPath: PrivilegedCtl.defaultBinary) ? .installed : .notInstalled
    @AppStorage("ui.appearance") private var appearance = "system"

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    private var bundleID: String { Bundle.main.bundleIdentifier ?? Autostart.label }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: Binding(get: { autostart }, set: { v in autostart = v; if !Autostart.set(v) { autostart = Autostart.isEnabled() } })) {
                    SettingLabel("Запускать при входе", "Меняет RunAtLoad в LaunchAgent \(Autostart.label)")
                }
                Picker("Оформление", selection: $appearance) {
                    Text("Системное").tag("system")
                    Text("Светлое").tag("light")
                    Text("Тёмное").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent {
                    StatusLabel(agent.isHealthy ? "Работает" : (agent.status == .never ? "Не запускался" : "Молчит"), color: agent.isHealthy ? .green : .orange)
                } label: {
                    SettingLabel("Фоновый сборщик", agent.pid.flatMap { agent.isHealthy ? "pid \($0)" : nil } ?? agent.summary)
                }
                LabeledContent {
                    HStack(spacing: 12) {
                        StatusLabel(helper.text, color: helper.color)
                        Button("Проверить") { checkHelper() }.disabled(helper == .notInstalled || helper == .checking)
                    }
                } label: {
                    SettingLabel("Root-помощник", "multitul-ctl: VPN, вентиляторы, очистка памяти, запрет сна")
                }
                if case .failed(let m) = helper { ToolWarning(text: m) }
            } header: { Text("Службы") }
            Section {
                LabeledContent("Версия", value: version)
                LabeledContent("Идентификатор", value: bundleID)
                LabeledContent("Журнал") {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.path)]) }
                }
                LabeledContent("База данных") {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: MultitulPaths.dbPath)]) }
                }
            } header: { Text("О программе") }
        }
        .onAppear { autostart = Autostart.isEnabled() }
        .task {
            while !Task.isCancelled {
                agent = await Task.detached { AgentHealth.checkLive() }.value
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func checkHelper() {
        helper = .checking
        Task {
            do {
                _ = try await PrivilegedCtl().runAsync(.selftest)
                helper = .ok
            } catch {
                helper = .failed("\(error)")
            }
        }
    }
}
