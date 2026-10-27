import SwiftUI
import MultitulCore
import MultitulUI

struct PermissionsPage: View {
    @ObservedObject var runtime: ModuleRuntime
    @ObservedObject private var perms = Permissions.shared

    var body: some View {
        let _ = runtime.revision
        let usages = PermissionPortal.usages(isEnabled: { runtime.isEnabled($0) })
        let needed = usages.filter { !$0.enabled.isEmpty }
        let rest = usages.filter { $0.enabled.isEmpty }
        let blocked = PermissionPortal.blockedModules(isEnabled: { runtime.isEnabled($0) }, status: { perms.state($0) })
        SettingsPage {
            if !blocked.isEmpty {
                Section {
                    ToolWarning(text: "Не хватает прав для включённых модулей: " + blocked.map(\.title).joined(separator: ", "))
                }
            }
            if !needed.isEmpty {
                Section {
                    ForEach(needed, id: \.permission) { PermissionRow(usage: $0, perms: perms) }
                } header: { Text("Нужны включённым модулям") }
            }
            Section {
                ForEach(rest, id: \.permission) { PermissionRow(usage: $0, perms: perms) }
            } header: { Text("Пока не нужны") } footer: {
                SectionFooter("Статус «Не проверяется» значит, что macOS не даёт узнать его из приложения: смотри в Системных настройках.")
            }
        }
        .onAppear { perms.refresh() }
    }
}

private struct PermissionRow: View {
    let usage: PermissionUsage
    @ObservedObject var perms: Permissions

    private var status: (text: String, color: Color) {
        switch perms.state(usage.permission) {
        case .granted: ("Выдано", .green)
        case .denied: ("Нет доступа", .orange)
        case .undetermined: ("Не запрошено", .orange)
        case .unknown: ("Не проверяется", .secondary)
        }
    }

    private static func tint(_ p: Permission) -> UInt32 {
        switch p {
        case .accessibility: 0x0A84FF
        case .screenRecording: 0xAF52DE
        case .inputMonitoring: 0x6E7B8B
        case .automation: 0x8E8E93
        case .notifications: 0xFF3B30
        case .fullDiskAccess: 0x5E5CE6
        case .camera: 0x48484A
        case .microphone: 0xFF9500
        case .calendars: 0xFF3B30
        case .bluetooth: 0x0A84FF
        case .systemAudio: 0xFF2D92
        case .appManagement: 0x5E5CE6
        }
    }

    var body: some View {
        let p = usage.permission
        LabeledContent {
            HStack(spacing: 12) {
                StatusLabel(status.text, color: status.color)
                Button(perms.state(p) == .undetermined ? "Запросить" : "Открыть настройки") { perms.openSettings(p) }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title)
                    Text(PermissionPortal.purpose(p)).font(.caption).foregroundStyle(.secondary)
                    Text(PermissionPortal.summary(usage).replacingOccurrences(of: "и ещё ", with: "и\u{00A0}ещё\u{00A0}")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } icon: {
                SettingsIcon(symbol: p.symbol, color: Color(nsColor: NSColor(hex: Self.tint(p))), size: 22)
            }
        }
        .help(usage.all.isEmpty ? "Пока ни один модуль не требует" : "Модули: " + usage.all.joined(separator: ", "))
    }
}
