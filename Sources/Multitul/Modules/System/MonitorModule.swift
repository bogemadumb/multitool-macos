import SwiftUI
import MultitulCore
import MultitulUI

@MainActor
final class MonitorModule: Module {
    let info: ModuleInfo
    let metric: SystemMetric

    init(id: ModuleID) {
        info = id.info
        metric = id.monitorMetric ?? .cpu
    }

    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    var panelCard: AnyView? {
        guard SystemHub.shared.panelOwner == metric else { return nil }
        return AnyView(SystemPanelCard())
    }

    func start() {
        if metric == .cpu, let spec = info.hotkeys.first {
            HotkeyManager.shared.register(spec, owner: info.id.rawValue) { AppController.shared.openSection(ModuleGroup.system.rawValue) }
        }
        SystemHub.shared.acquire(metric)
        Log.write("monitor \(metric.rawValue) start")
    }

    func stop() {
        HotkeyManager.shared.unregisterAll(owner: info.id.rawValue)
        SystemHub.shared.release(metric)
        Log.write("monitor \(metric.rawValue) stop")
    }
}

struct SystemPanelCard: View {
    @ObservedObject private var hub = SystemHub.shared

    private var picked: [SystemMetric] {
        Array([SystemMetric.cpu, .memory, .network, .power, .disk, .gpu].filter { hub.enabled.contains($0) }.prefix(4))
    }

    var body: some View {
        let s = hub.snapshot
        HStack(alignment: .top, spacing: 6) {
            ForEach(picked, id: \.self) { m in cell(m, s).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { hub.panelAppeared() }
        .onDisappear { hub.panelDisappeared() }
    }

    @ViewBuilder private func cell(_ m: SystemMetric, _ s: LiveSnapshot) -> some View {
        let v = MenuBarValues.make(m, snapshot: s, history: hub.history, uploadFirst: hub.uploadFirst)
        let (value, unit) = split(v)
        VStack(alignment: .leading, spacing: 1) {
            Text(m.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline.monospacedDigit()).foregroundStyle(v.level == .normal ? Color.primary : v.level.color).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .help(v.lines.isEmpty ? m.title : v.lines.joined(separator: "\n"))
    }

    private func split(_ v: MenuBarValue) -> (String, String) {
        switch v.metric {
        case .network:
            let p = rateParts(hub.snapshot.network?.downBps ?? 0)
            return hub.snapshot.network == nil ? ("—", "") : (p.0, p.1)
        case .cpu, .gpu, .memory:
            return v.text.hasSuffix("%") ? (String(v.text.dropLast()), "%") : (v.text, "")
        case .power:
            return v.text.hasSuffix("%") ? (v.text.replacingOccurrences(of: "⚡", with: "↯ ").dropLast().description, "%") : (v.text, "")
        default:
            return (v.text, "")
        }
    }
}
