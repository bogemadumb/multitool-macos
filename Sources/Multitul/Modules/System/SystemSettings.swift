import SwiftUI
import MultitulCore
import MultitulUI

struct SystemSettingsSections: View {
    @ObservedObject var hub: SystemHub
    @AppStorage("monitor.network.uploadFirst") private var uploadFirst = false
    @AppStorage("monitor.disk.ejectReminder") private var ejectReminder = true
    @AppStorage("monitor.alert.cpuThreshold") private var cpuThreshold = 0.9
    @AppStorage("monitor.alert.temperatureThreshold") private var tempThreshold = 90.0
    @AppStorage("monitor.alert.batteryTemperatureThreshold") private var battTempThreshold = 40.0
    @AppStorage("monitor.alert.diskFreePercent") private var diskPercent = 10.0
    @AppStorage("monitor.alert.batteryPercent") private var batteryPercent = 15
    @AppStorage("monitor.alert.cooldownMinutes") private var cooldown = 30
    @State private var excluded = Set(UserDefaults.standard.stringArray(forKey: "monitor.disk.excluded") ?? [])

    var body: some View {
        menuBarSection
        alertsSection
        displaySection
    }

    private var menuBarSection: some View {
        Section {
            Toggle(isOn: Binding(get: { hub.layout.combined }, set: { hub.layout.combined = $0 })) {
                SettingLabel("Один общий блок", "Выключено: у каждого показателя свой значок в строке меню")
            }
            ForEach(hub.layout.items, id: \.metric) { item in
                let on = hub.enabled.contains(item.metric)
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("Вид", selection: Binding(get: { item.style }, set: { hub.layout.setStyle(item.metric, $0) })) {
                            ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { hub.layout.moveUp(item.metric) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { hub.layout.moveDown(item.metric) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Toggle("Показывать", isOn: Binding(get: { item.visible }, set: { hub.layout.setVisible(item.metric, $0) }))
                            .labelsHidden()
                    }
                    .disabled(!on)
                } label: {
                    Label {
                        SettingLabel(item.metric.title, on ? nil : "Модуль выключен на странице «Модули»")
                    } icon: { Image(systemName: item.metric.symbol) }
                }
            }
        } header: { Text("Строка меню") }
    }

    private func alertToggle(_ kind: AlertKind) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: AlertSettings.key(kind)) }, set: { v in
            UserDefaults.standard.set(v, forKey: AlertSettings.key(kind))
            if v { Notifier.shared.requestAuthorization() }
            hub.reconfigure()
        })
    }

    private func alertRow<C: View>(_ kind: AlertKind, _ subtitle: String, @ViewBuilder control: () -> C) -> some View {
        LabeledContent {
            HStack(spacing: 12) {
                control()
                Toggle(kind.title, isOn: alertToggle(kind)).labelsHidden()
            }
        } label: { SettingLabel(kind.title, subtitle) }
    }

    private var alertsSection: some View {
        Section {
            alertRow(.cpu, "Нагрузка выше порога дольше 12 секунд") {
                Stepper("\(Int(cpuThreshold * 100))%", value: Binding(get: { Int(cpuThreshold * 100) }, set: { cpuThreshold = Double($0) / 100 }), in: 50...100, step: 5)
            }
            alertRow(.temperature, "Температура процессора выше порога") {
                Stepper("\(Int(tempThreshold))°", value: Binding(get: { Int(tempThreshold) }, set: { tempThreshold = Double($0) }), in: 70...105, step: 5)
            }
            alertRow(.batteryTemperature, "Температура батареи выше порога") {
                Stepper("\(Int(battTempThreshold))°", value: Binding(get: { Int(battTempThreshold) }, set: { battTempThreshold = Double($0) }), in: 30...50, step: 1)
            }
            alertRow(.memory, "Давление памяти стало критическим") { EmptyView() }
            alertRow(.disk, "Свободного места меньше порога на встроенном диске") {
                Stepper("\(Int(diskPercent))%", value: Binding(get: { Int(diskPercent) }, set: { diskPercent = Double($0) }), in: 2...30, step: 1)
            }
            alertRow(.battery, "Заряд ниже порога, адаптер не подключён") {
                Stepper("\(batteryPercent)%", value: $batteryPercent, in: 5...50, step: 5)
            }
            StepperSetting("Не повторять чаще", "Одно и то же уведомление не придёт раньше этого срока", value: $cooldown, in: 1...720, step: 5, unit: " мин")
        } header: { Text("Уведомления") }
    }

    private var displaySection: some View {
        Section {
            Toggle(isOn: $uploadFirst) { SettingLabel("Сначала отдача", "В сети отдача идёт выше загрузки") }
            Toggle(isOn: $ejectReminder) { SettingLabel("Напоминать об извлечении", "Если внешний диск пропал без «Извлечь»") }
            ForEach(hub.snapshot.disk?.volumes ?? []) { v in
                Toggle(isOn: Binding(get: { !excluded.contains(v.path) }, set: { on in
                    if on { excluded.remove(v.path) } else { excluded.insert(v.path) }
                    UserDefaults.standard.set(Array(excluded), forKey: "monitor.disk.excluded")
                })) { SettingLabel(v.name, "Показывать в мониторе диска") }
            }
        } header: { Text("Показ") }
    }
}
