import SwiftUI
import Charts
import MultitulCore
import MultitulUI

struct SystemOverview: View {
    @ObservedObject var hub: SystemHub

    private var groups: [ProcGroup] { SystemParsers.groupProcesses(hub.processes) }

    var body: some View {
        let s = hub.snapshot
        let h = hub.history
        let en = hub.enabled
        if en.isEmpty {
            Section {
                ContentUnavailableView("Мониторинг выключен", systemImage: "gauge.with.dots.needle.0percent", description: Text("Включите монитор процессора, памяти, сети, диска или питания на странице «Модули»."))
            }
        }
        if en.contains(.cpu) { cpuSections(s, h) }
        if en.contains(.gpu) { gpuSection(s, h) }
        if en.contains(.memory) { memorySections(s, h) }
        if en.contains(.network) { networkSections(s, h) }
        if en.contains(.disk) { diskSections(s, h) }
        if en.contains(.power) { powerSection(s) }
        if en.contains(.devices) { devicesSection(s) }
    }

    @ViewBuilder private func cpuSections(_ s: LiveSnapshot, _ h: NamedHistory) -> some View {
        let l = s.cpu
        let temp = h.values(HistoryKey.tempCPU)
        Section {
            LabeledContent {
                Text(l.map { SysFormat.percent($0.total) + "%" } ?? "—").monospacedDigit()
            } label: {
                SettingLabel("Загрузка", [l.map { "польз. \(SysFormat.percent($0.user))%, сист. \(SysFormat.percent($0.system))%" },
                                          s.temps.cpu.map { SysFormat.temperature($0) }].compactMap { $0 }.joined(separator: ", ").nilIfEmpty)
            }
            ChartBlock(title: "За последние минуты", current: "", legend: temp.count > 1 ? [("CPU", loadColor(l?.total ?? 0)), ("температура", .orange)] : [],
                       series: [ChartSeries(values: h.values(HistoryKey.cpu), color: loadColor(l?.total ?? 0), filled: true)]
                       + (temp.count > 1 ? [ChartSeries(values: temp, color: .orange, dashed: true)] : []))
            if s.perCore.isEmpty {
                EmptyHint(text: "Ждём первый замер…")
            } else {
                coreChart(s.perCore)
            }
        } header: { Label("Процессор", systemImage: "cpu") }
        TopRows(title: "Больше всего грузят процессор",
                rows: groups.sorted { $0.cpu > $1.cpu }.prefix(5).map { ($0.name, String(format: "%.0f%%", $0.cpu)) })
    }

    private func coreChart(_ loads: [CPULoad]) -> some View {
        Chart {
            ForEach(Array(loads.enumerated()), id: \.offset) { i, l in
                BarMark(x: .value("Ядро", "\(i + 1)"), y: .value("Загрузка", l.total * 100))
                    .foregroundStyle(loadColor(l.total))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.caption2) }
            }
        }
        .frame(height: 90)
    }

    private func gpuSection(_ s: LiveSnapshot, _ h: NamedHistory) -> some View {
        Section {
            LabeledContent {
                Text(s.gpu.map { SysFormat.percent($0.utilization) + "%" } ?? "—").monospacedDigit()
            } label: {
                SettingLabel("Загрузка", [s.gpu?.name, s.temps.gpu.map { SysFormat.temperature($0) }].compactMap { $0 }.joined(separator: ", ").nilIfEmpty)
            }
            ChartBlock(title: "За последние минуты", current: "", series: [ChartSeries(values: h.values(HistoryKey.gpu), color: loadColor(s.gpu?.utilization ?? 0), filled: true)])
        } header: { Label("Графика", systemImage: "display") }
    }

    @ViewBuilder private func memorySections(_ s: LiveSnapshot, _ h: NamedHistory) -> some View {
        Section {
            if let m = s.memory {
                let c = m.composition
                let parts: [(String, Double, Color)] = [
                    ("Приложения", Double(c.appBytes), .accentColor),
                    ("Закреплена", Double(c.wiredBytes), .orange),
                    ("Сжатая", Double(c.compressedBytes), .red),
                    ("Кэш файлов", Double(c.cachedBytes), .green),
                    ("Свободно", Double(c.freeBytes), .gray)
                ]
                LabeledContent {
                    Text(SysFormat.diskBytes(Double(c.usedBytes)) + " из " + SysFormat.diskBytes(Double(c.totalBytes))).monospacedDigit()
                } label: { SettingLabel("Занято", "давление: \(m.pressure.title.lowercased())") }
                Chart(parts, id: \.0) { p in
                    BarMark(x: .value("Объём", p.1)).foregroundStyle(by: .value("Тип", p.0))
                }
                .chartForegroundStyleScale(domain: parts.map(\.0), range: parts.map(\.2))
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 28)
                ForEach(parts, id: \.0) { p in
                    LabeledContent { Text(SysFormat.diskBytes(p.1)).monospacedDigit() } label: { StatusLabel(p.0, color: p.2) }
                }
                LabeledContent("Своп", value: "\(SysFormat.diskBytes(Double(m.swapUsedBytes))) из \(SysFormat.diskBytes(Double(m.swapTotalBytes)))")
            } else {
                EmptyHint(text: "Ждём первый замер…")
            }
            ChartBlock(title: "Использование памяти", current: s.memory.map { SysFormat.percent($0.composition.usedFraction) + "%" } ?? "—",
                       series: [ChartSeries(values: h.values(HistoryKey.memory), color: .accentColor, filled: true)])
        } header: { Label("Память", systemImage: "memorychip") }
        TopRows(title: "Больше всего памяти",
                rows: groups.sorted { $0.rssBytes > $1.rssBytes }.prefix(5).map { ($0.name, SysFormat.bytes(Double($0.rssBytes))) })
    }

    @ViewBuilder private func networkSections(_ s: LiveSnapshot, _ h: NamedHistory) -> some View {
        let down = h.values(HistoryKey.netDown)
        let up = h.values(HistoryKey.netUp)
        let n = s.network
        let first = hub.uploadFirst
        Section {
            LabeledContent {
                Text(n == nil ? "—" : (first ? "↑ \(SysFormat.rate(n?.upBps ?? 0))   ↓ \(SysFormat.rate(n?.downBps ?? 0))" : "↓ \(SysFormat.rate(n?.downBps ?? 0))   ↑ \(SysFormat.rate(n?.upBps ?? 0))")).monospacedDigit()
            } label: { Text("Скорость") }
            ChartBlock(title: "Скорость сети", current: "", legend: [("загрузка", .accentColor), ("отдача", .orange)],
                       series: [ChartSeries(values: down, color: .accentColor, filled: true), ChartSeries(values: up, color: .orange)],
                       range: autoRange(down + up + [0, 1024], floor: 0), format: { SysFormat.rate($0) })
            LabeledContent("Локальный IP", value: n?.localIP ?? "—")
            LabeledContent("Загружено за сеанс", value: SysFormat.bytes(Double(n?.sessionDownBytes ?? 0)))
            LabeledContent("Отдано за сеанс", value: SysFormat.bytes(Double(n?.sessionUpBytes ?? 0)))
            LabeledContent {
                if let r = hub.lastSpeedTest {
                    Text(String(format: "↓ %.0f  ↑ %.0f Мбит/с", r.downMbps, r.upMbps) + (r.rttMs.map { String(format: ", %.0f мс", $0) } ?? "")).monospacedDigit()
                }
            } label: {
                Button(hub.speedTestRunning ? "Измеряем…" : "Измерить скорость интернета") { hub.runSpeedTest() }
                    .disabled(hub.speedTestRunning)
            }
        } header: { Label("Сеть", systemImage: "arrow.up.arrow.down") }
        TopRows(title: "Больше всего трафика", rows: hub.netProcesses.prefix(5).map { ($0.name, SysFormat.rate($0.total)) })
    }

    @ViewBuilder private func diskSections(_ s: LiveSnapshot, _ h: NamedHistory) -> some View {
        let excluded = Set(UserDefaults.standard.stringArray(forKey: "monitor.disk.excluded") ?? [])
        let vols = (s.disk?.volumes ?? []).filter { !excluded.contains($0.path) }
        Section {
            if let d = s.disk {
                LabeledContent("Состояние SMART") {
                    StatusLabel(d.smart.title, color: d.smart == .verified ? .green : (d.smart == .failing ? .orange : .secondary))
                }
            }
            if vols.isEmpty { EmptyHint(text: "Ждём первый замер…") }
            ForEach(vols) { v in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text("свободно \(SysFormat.diskBytes(Double(v.freeBytes))) из \(SysFormat.diskBytes(Double(v.totalBytes)))").monospacedDigit()
                    } label: { SettingLabel(v.name, (v.isEjectable || !v.isInternal) ? "внешний" : nil) }
                    ProgressView(value: min(max(v.usedFraction, 0), 1)).tint(v.freeFraction < 0.1 ? Color.red : (v.freeFraction < 0.2 ? Color.orange : Color.accentColor))
                }
            }
            ChartBlock(title: "Чтение и запись", current: s.disk.map { "чт \(SysFormat.rate($0.readBps)), зап \(SysFormat.rate($0.writeBps))" } ?? "—",
                       legend: [("чтение", .accentColor), ("запись", .orange)],
                       series: [ChartSeries(values: h.values(HistoryKey.diskRead), color: .accentColor, filled: true), ChartSeries(values: h.values(HistoryKey.diskWrite), color: .orange)],
                       range: autoRange(h.values(HistoryKey.diskRead) + h.values(HistoryKey.diskWrite) + [0, 1024 * 1024], floor: 0), format: { SysFormat.rate($0) })
        } header: { Label("Диск", systemImage: "internaldrive") }
    }

    private func powerSection(_ s: LiveSnapshot) -> some View {
        let b = s.battery
        let has = b?.hasBattery == true
        var parts: [String] = []
        if let b {
            parts.append(b.onAC ? (b.isCharging ? "заряжается" : "от сети") : "от батареи")
            if let t = b.timeRemainingMin { parts.append("ещё \(SysFormat.minutes(t))") }
            if let w = b.systemPowerW { parts.append(String(format: "%.1f Вт", w).replacingOccurrences(of: ".", with: ",")) }
        }
        let pct = Double(b?.percent ?? 0) / 100
        return Section {
            LabeledContent {
                Text(has ? "\(b?.percent ?? 0)%" : (b == nil ? "—" : "сеть")).monospacedDigit()
            } label: { SettingLabel("Заряд", parts.joined(separator: ", ").nilIfEmpty) }
            if has { ProgressView(value: min(max(pct, 0), 1)).tint((b?.onAC ?? true) ? Color.green : (pct <= 0.1 ? Color.red : (pct <= 0.2 ? Color.orange : Color.green))) }
        } header: { Label("Питание", systemImage: "battery.100percent") }
    }

    private func devicesSection(_ s: LiveSnapshot) -> some View {
        Section {
            if s.devices.isEmpty {
                EmptyHint(text: "Внешних USB-устройств нет", symbol: "cable.connector")
            } else {
                ForEach(s.devices, id: \.id) { d in
                    LabeledContent(d.name, value: d.vendor ?? String(format: "%04X:%04X", d.vendorID, d.productID))
                }
            }
        } header: { Label("Подключённые USB-устройства", systemImage: "cable.connector") }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
