import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct ModulesPage: View {
    @ObservedObject var runtime: ModuleRuntime
    @ObservedObject private var perms = Permissions.shared
    @State private var query = ""
    @State private var filter = ModuleFilter.all

    var body: some View {
        let _ = runtime.revision
        let sections = ModuleList.sections(query: query, filter: filter, isEnabled: { runtime.isEnabled($0) }, status: { perms.state($0) })
        SettingsPage {
            Section {
                TextField("Поиск по модулям", text: $query, prompt: Text("Название или что делает"))
                Picker("Показывать", selection: $filter) {
                    ForEach(ModuleFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if sections.isEmpty {
                Section {
                    ContentUnavailableView(filter == .needsPermissions && query.isEmpty ? "Всё выдано" : "Ничего не найдено",
                                           systemImage: filter == .needsPermissions && query.isEmpty ? "checkmark.shield" : "magnifyingglass")
                }
            }
            ForEach(sections) { s in
                Section {
                    ForEach(s.modules, id: \.id) { info in
                        ModuleToggleRow(info: info, runtime: runtime, perms: perms)
                    }
                } header: { Text(s.group.title) }
            }
        }
        .onAppear { perms.refresh() }
    }
}

private struct ModuleToggleRow: View {
    let info: ModuleInfo
    @ObservedObject var runtime: ModuleRuntime
    @ObservedObject var perms: Permissions

    private var symbol: String {
        NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil) != nil ? info.symbol : "puzzlepiece.extension"
    }

    private var tint: UInt32 {
        switch info.id {
        case .monitorMemory: return 0x32ADE6
        case .killProcess: return 0xFF453A
        case .portManager: return 0x30B0C7
        default: break
        }
        switch info.group {
        case .net: return 0x0A84FF
        case .system: return 0x6E7B8B
        case .clean: return 0x5E5CE6
        case .displays: return 0x5AC8FA
        case .windows: return 0x30B0C7
        case .input: return 0x98989D
        case .clip: return 0xFF6A3D
        case .sound: return 0xFF2D92
        case .energy: return 0x30D158
        case .tools: return 0x4C6EF5
        case .island: return 0x1C1C20
        }
    }

    var body: some View {
        let on = runtime.isEnabled(info.id)
        let missing = on ? ModuleList.missingPermissions(info, status: { perms.state($0) }) : []
        Toggle(isOn: Binding(get: { runtime.isEnabled(info.id) }, set: { runtime.setEnabled(info.id, $0) })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.title)
                        if !missing.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Нет доступа: " + missing.map(\.title).joined(separator: ", "))
                        }
                    }
                    if !info.summary.isEmpty {
                        Text(info.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                SettingsIcon(symbol: symbol, color: Color(nsColor: NSColor(hex: tint)), size: 22)
            }
        }
        .help(info.summary)
    }
}
