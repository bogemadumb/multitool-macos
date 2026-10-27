import SwiftUI
import MultitulCore
import MultitulUI

struct HistoryData: Sendable {
    var points: [SystemPoint] = []
    var top: [ProcAverage] = []
    var offenders: [ProcAverage] = []
}

struct SystemHistoryView: View {
    var health: AgentHealth
    @State private var range = 0
    @State private var data = HistoryData()
    @State private var loaded = false

    private var seconds: TimeInterval { range == 0 ? 3600 : 86400 }

    var body: some View {
        SettingsPage {
            Section {
                Picker("Период", selection: $range) {
                    Text("1 ч").tag(0)
                    Text("24 ч").tag(1)
                }
                .pickerStyle(.segmented)
            } footer: { SectionFooter("Данные пишет фоновый сборщик каждые 30 секунд, хранится 7 дней.") }
            if loaded && data.points.isEmpty {
                Section { ContentUnavailableView("Истории пока нет", systemImage: "clock.arrow.circlepath", description: Text(health.summary)) }
            } else {
                content
            }
        }
        .task(id: range) {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func reload() async {
        let secs = seconds
        let d = await Task.detached { () -> HistoryData in
            guard let store = SystemHub.openHistoryStore() else { return HistoryData() }
            return HistoryData(points: SystemHistory.series(store, range: secs),
                               top: SystemHistory.topProcesses(store, range: secs, limit: 8),
                               offenders: SystemHistory.weeklyOffenders(store))
        }.value
        data = d
        loaded = true
    }

    @ViewBuilder private var content: some View {
        let p = data.points
        let cpu = p.compactMap(\.cpuTotal)
        let mem = p.compactMap(\.memUsedPct)
        let temp = p.compactMap(\.tempCPU)
        let batt = p.compactMap { $0.battPct.map(Double.init) }
        let disk = p.compactMap(\.diskFreeGb)
        let swap = p.compactMap(\.swapMb)
        Section {
            ChartBlock(title: "Процессор", current: cpu.last.map { String(format: "%.0f%%", $0) } ?? "—",
                       series: [ChartSeries(values: cpu, color: .accentColor, filled: true)])
            ChartBlock(title: "Память", current: mem.last.map { String(format: "%.0f%%", $0) } ?? "—",
                       series: [ChartSeries(values: mem, color: .green, filled: true)])
            if !temp.isEmpty {
                ChartBlock(title: "Температура процессора", current: temp.last.map { SysFormat.temperature($0) } ?? "—",
                           series: [ChartSeries(values: temp, color: .orange, filled: true)], range: autoRange(temp, floor: 0))
            }
            if !swap.isEmpty {
                ChartBlock(title: "Своп, МБ", current: swap.last.map { String(format: "%.0f", $0) } ?? "—",
                           series: [ChartSeries(values: swap, color: .accentColor, filled: true)], range: autoRange(swap + [0], floor: 0))
            }
            if !batt.isEmpty {
                ChartBlock(title: "Батарея", current: batt.last.map { String(format: "%.0f%%", $0) } ?? "—",
                           series: [ChartSeries(values: batt, color: .green, filled: true)])
            }
            ChartBlock(title: "Свободно на диске, ГБ", current: disk.last.map { String(format: "%.0f", $0) } ?? "—",
                       series: [ChartSeries(values: disk, color: .accentColor, filled: true)], range: autoRange(disk, floor: 0))
        } header: { Text("Графики") }
        TopRows(title: "Средняя нагрузка процессора за период",
                rows: data.top.map { ($0.name, String(format: "%.1f%%, до %@", $0.avgCpu, SysFormat.bytes($0.maxRssMb * 1_048_576))) })
        TopRows(title: "Нарушители недели", rows: data.offenders.map { ($0.name, String(format: "%.1f%%", $0.avgCpu)) })
    }
}
