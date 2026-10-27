import SwiftUI
import MultitulCore
import MultitulUI

struct EnergyData: Sendable {
    var top: [PowerRow] = []
    var battery: BatteryHistoryInfo?
}

struct SystemEnergy: View {
    @ObservedObject var hub: SystemHub
    @State private var data = EnergyData()

    var body: some View {
        let s = hub.snapshot
        SettingsPage {
            batterySection(s)
            thermalSection(s)
            TopRows(title: "Энергоёмкие приложения, замер раз в 5 минут", rows: data.top.prefix(8).map { ($0.name, String(format: "%.1f", $0.power)) })
            if let acc = s.battery?.accessories, !acc.isEmpty {
                Section("Аксессуары") {
                    ForEach(acc) { a in LabeledContent(a.name, value: "\(a.percent)%") }
                }
            }
        }
        .onAppear { hub.pageAppeared() }
        .onDisappear { hub.pageDisappeared() }
        .task {
            while !Task.isCancelled {
                let d = await Task.detached { () -> EnergyData in
                    guard let store = SystemHub.openHistoryStore() else { return EnergyData() }
                    return EnergyData(top: SystemHistory.topEnergy(store), battery: SystemHistory.battery(store))
                }.value
                data = d
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func batterySection(_ s: LiveSnapshot) -> some View {
        Section {
            if !hub.enabled.contains(.power) {
                EmptyHint(text: "Включите модуль «Монитор: питание»", symbol: "battery.100percent")
            } else if let b = s.battery, b.hasBattery {
                LabeledContent("Состояние") {
                    StatusLabel(b.isCharged ? "заряжена" : (b.isCharging ? "заряжается" : (b.onAC ? "от сети" : "разряжается")), color: b.onAC ? .green : .secondary)
                }
                LabeledContent("Заряд", value: b.percent.map { "\($0)%" } ?? "—")
                LabeledContent("Осталось", value: b.timeRemainingMin.map(SysFormat.minutes) ?? (b.isCharged ? "—" : "считается…"))
                LabeledContent("Здоровье", value: b.healthPercent.map { String(format: "%.1f%%", $0).replacingOccurrences(of: ".", with: ",") } ?? (data.battery?.healthPct.map { String(format: "%.1f%%", $0) } ?? "—"))
                LabeledContent("Циклов", value: (b.cycles ?? data.battery?.cycles).map(String.init) ?? "—")
                if let m = b.maxCapacityMAh, let d = b.designCapacityMAh {
                    LabeledContent("Ёмкость", value: String(format: "%.0f из %.0f мА·ч", m, d))
                }
                LabeledContent("Температура", value: (b.temperatureC ?? s.temps.battery).map { SysFormat.temperature($0) } ?? "—")
                LabeledContent("Адаптер", value: b.adapterWatts.map { String(format: "%.0f Вт", $0) } ?? "—")
                LabeledContent("Система потребляет", value: b.systemPowerW.map { String(format: "%.1f Вт", $0).replacingOccurrences(of: ".", with: ",") } ?? "—")
                LabeledContent("Расход за час", value: data.battery?.drainPctPerHour.map { String(format: "%.1f%%", $0).replacingOccurrences(of: ".", with: ",") } ?? "нужно 10 мин без сети")
            } else {
                EmptyHint(text: s.battery == nil ? "Ждём первый замер…" : "Батареи нет, питание от сети", symbol: "powerplug")
            }
        } header: { Text("Батарея") }
    }

    private func thermalSection(_ s: LiveSnapshot) -> some View {
        let states = ["Номинальное", "Умеренное", "Серьёзное", "Критическое"]
        return Section {
            LabeledContent("Состояние системы") {
                StatusLabel(states[min(max(s.thermalState, 0), 3)], color: s.thermalState == 0 ? .green : .orange)
            }
            LabeledContent("Процессор", value: s.temps.cpu.map { SysFormat.temperature($0) } ?? "нет датчика")
            LabeledContent("Графика", value: s.temps.gpu.map { SysFormat.temperature($0) } ?? "нет датчика")
            LabeledContent("Батарея", value: (s.temps.battery ?? s.battery?.temperatureC).map { SysFormat.temperature($0) } ?? "нет датчика")
        } header: { Text("Тепло") } footer: {
            if s.temps.isEmpty { SectionFooter("Датчики читаются через AppleSMC; если ключей нет, показывается только тепловое состояние системы.") }
        }
    }
}
