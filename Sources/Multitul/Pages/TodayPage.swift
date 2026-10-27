import SwiftUI
import MultitulCore
import MultitulUI

@MainActor
final class TodayModel: ObservableObject {
    @Published private(set) var disk: DiskVolume?
    @Published private(set) var battery = BatteryReading()

    func refresh() async {
        let (d, b) = await Task.detached { () -> (DiskVolume?, BatteryReading) in
            let v = DiskReader.volumes()
            return (v.first { $0.path == "/" } ?? v.first { $0.isInternal }, PowerReader.read())
        }.value
        disk = d
        battery = b
    }
}

private extension TodayTone {
    var color: Color {
        switch self {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

private func gbText(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return (gb >= 100 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)).replacingOccurrences(of: ".", with: ",") + " ГБ"
}

struct TodayPage: View {
    @ObservedObject var runtime: ModuleRuntime
    var open: (String) -> Void
    @StateObject private var model = TodayModel()
    @ObservedObject private var storozh = StorozhController.shared
    @ObservedObject private var perms = Permissions.shared

    private var vpnController: VpnController? { (runtime.activeModules.first { $0.info.id == .vpn } as? VpnModule)?.controller }

    private var warnings: [String] {
        guard runtime.isEnabled(.storozh) else { return [] }
        return storozh.open.map { "\($0.name): \(DetectorKind(rawValue: $0.kind)?.title ?? $0.kind)" }
    }

    private var input: TodayInput {
        var x = TodayInput()
        if let c = vpnController { x.vpnEnabled = true; x.vpnState = c.state }
        x.diskFreeBytes = model.disk?.freeBytes
        x.diskTotalBytes = model.disk?.totalBytes
        if model.battery.hasBattery { x.batteryPercent = model.battery.percent; x.batteryOnAC = model.battery.onAC }
        x.warnings = warnings
        x.blockedModules = PermissionPortal.blockedModules(isEnabled: { runtime.isEnabled($0) }, status: { perms.state($0) }).count
        return x
    }

    var body: some View {
        let _ = runtime.revision
        let attention = TodayLogic.attention(input)
        SettingsPage {
            Section {
                vpnRow
                diskRow
                if model.battery.hasBattery { batteryRow }
                guardRow
            }
            Section {
                if attention.isEmpty {
                    Label("Всё в порядке", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ForEach(attention) { item in
                    TodayLink(action: { open(item.section) }) {
                        Label {
                            Text(item.text)
                        } icon: {
                            Image(systemName: item.tone == .bad ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(item.tone.color)
                        }
                    } trailing: { EmptyView() }
                }
            } header: { Text("Требует внимания") }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private var vpnRow: some View {
        if let c = vpnController {
            TodayVpnRow(controller: c) { open("net") }
        } else {
            summaryRow("VPN", "shield.lefthalf.filled", 0x0a84ff, "Модуль выключен", .neutral, nil, "net")
        }
    }

    @ViewBuilder private var diskRow: some View {
        if let d = model.disk {
            summaryRow("Диск", "internaldrive.fill", 0x5e5ce6, gbText(d.freeBytes) + " свободно", TodayLogic.diskTone(free: d.freeBytes, total: d.totalBytes), d.usedFraction, "storage")
        } else {
            summaryRow("Диск", "internaldrive.fill", 0x5e5ce6, "Читаю…", .neutral, nil, "storage")
        }
    }

    private var batteryRow: some View {
        let b = model.battery
        let state = b.isCharging ? "заряжается" : (b.onAC ? "от сети" : "от батареи")
        return summaryRow("Батарея", "battery.100percent", 0x30d158, b.percent.map { "\($0)% · \(state)" } ?? "Нет данных",
                          TodayLogic.batteryTone(percent: b.percent, onAC: b.onAC), b.percent.map { Double($0) / 100 }, "system")
    }

    @ViewBuilder private var guardRow: some View {
        if !runtime.isEnabled(.storozh) {
            summaryRow("Сторож", "binoculars.fill", 0x30d158, "Модуль выключен", .neutral, nil, "guard")
        } else {
            let n = warnings.count
            summaryRow("Сторож", "binoculars.fill", 0x30d158, n == 0 ? "Всё спокойно" : "Предупреждений: \(n)", n == 0 ? .good : .warn, nil, "guard")
        }
    }

    private func summaryRow(_ title: String, _ symbol: String, _ color: UInt32, _ value: String, _ tone: TodayTone, _ progress: Double?, _ section: String) -> some View {
        TodaySummaryRow(title: title, symbol: symbol, color: color, value: value, tone: tone, progress: progress) { open(section) }
    }
}

struct TodayLink<Lead: View, Trailing: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Lead
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label()
                Spacer(minLength: 8)
                trailing()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TodaySummaryRow: View {
    let title: String
    let symbol: String
    let color: UInt32
    let value: String
    let tone: TodayTone
    let progress: Double?
    let action: () -> Void

    var body: some View {
        TodayLink(action: action) {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(symbol: symbol, color: Color(nsColor: NSColor(hex: color)), size: 22)
            }
        } trailing: {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(tone.color).frame(width: 80)
            }
            Text(value).foregroundStyle(tone == .neutral ? Color.secondary : tone.color).monospacedDigit()
        }
    }
}

private struct TodayVpnRow: View {
    @ObservedObject var controller: VpnController
    let action: () -> Void

    var body: some View {
        let s = controller.state
        let value = s.title + ((s == .ok || s == .slow || s == .degraded) ? controller.delayMs.map { " · \($0) мс" } ?? "" : "")
        TodaySummaryRow(title: "VPN", symbol: "shield.lefthalf.filled", color: 0x0a84ff, value: value, tone: TodayLogic.vpnTone(s), progress: nil, action: action)
    }
}
