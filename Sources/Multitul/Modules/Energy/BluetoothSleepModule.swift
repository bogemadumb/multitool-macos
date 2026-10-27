import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class BluetoothSleepController: ObservableObject {
    static let shared = BluetoothSleepController()

    @Published private(set) var settings = BluetoothSleepSettings()
    @Published private(set) var available = true
    @Published private(set) var lastEvent = "—"
    @Published private(set) var owes = false

    private let store = BluetoothDefaultsStore()
    private var logic: BluetoothSleepLogic?
    private var observers: [NSObjectProtocol] = []
    private var restoreTask: DispatchWorkItem?

    func start() {
        guard logic == nil else { return }
        settings = store.loadSettings()
        let power = IOBluetoothPower()
        available = power.isAvailable
        let l = BluetoothSleepLogic(power: power, store: store, settings: settings)
        logic = l
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestore(attempt: 0, delay: TimeInterval(self?.settings.restoreDelaySeconds ?? 2)) }
        })
        if l.owesRestore {
            Log.write("bluetoothSleep restore owed at start")
            scheduleRestore(attempt: 0, delay: 3)
        }
        owes = l.owesRestore
    }

    func stop() {
        restoreTask?.cancel()
        restoreTask = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        logic = nil
    }

    func update(_ s: BluetoothSleepSettings) {
        settings = s
        store.save(s)
        logic?.settings = s
    }

    private func willSleep() {
        guard let l = logic else { return }
        restoreTask?.cancel()
        let r = l.willSleep()
        record("сон: \(describe(r))")
        owes = l.owesRestore
        if r == .turnedOff, settings.notify { Notifier.shared.post(title: "Bluetooth", body: "Выключен на время сна", id: "bluetoothsleep-off") }
    }

    private func scheduleRestore(attempt: Int, delay: TimeInterval) {
        guard logic?.owesRestore == true else { return }
        restoreTask?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restore(attempt: attempt) } }
        restoreTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func restore(attempt: Int) {
        guard let l = logic else { return }
        let r = l.restore(attempt: attempt)
        record("пробуждение: \(describe(r))")
        owes = l.owesRestore
        switch r {
        case .retry(let after): scheduleRestore(attempt: attempt + 1, delay: after)
        case .restored: if settings.notify { Notifier.shared.post(title: "Bluetooth", body: "Включён после сна", id: "bluetoothsleep-on") }
        default: break
        }
    }

    private func record(_ text: String) {
        lastEvent = text
        Log.write("bluetoothSleep \(text)")
    }

    private func describe(_ r: BluetoothSleepOutcome) -> String {
        switch r {
        case .skipped(let why): "пропущено (\(why))"
        case .turnedOff: "Bluetooth выключен"
        case .failedToTurnOff: "не удалось выключить"
        case .notOwed: "включать нечего"
        case .restored: "Bluetooth включён"
        case .alreadyOn: "уже включён"
        case .retry(let after): "не вышло, повтор через \(Int(after)) с"
        case .gaveUp: "не удалось включить, повторю при следующем запуске"
        }
    }
}

@MainActor
final class BluetoothSleepModule: Module {
    let info = ModuleID.bluetoothSleep.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        BluetoothSleepController.shared.start()
        Log.write("module bluetoothSleep start")
    }

    func stop() {
        BluetoothSleepController.shared.stop()
        Log.write("module bluetoothSleep stop")
    }
}

struct BluetoothSleepView: View {
    @ObservedObject private var c = BluetoothSleepController.shared

    private func binding<T>(_ kp: WritableKeyPath<BluetoothSleepSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent("Состояние") {
                if !c.available { StatusLabel("API недоступен", color: .orange) }
                else if c.owes { StatusLabel("ждёт включения", color: .orange) }
                else { StatusLabel("готов", color: .green) }
            }
            if !c.available {
                ToolWarning(text: "Системные функции IOBluetooth в этой версии macOS не найдены: модуль ничего не делает.")
            }
            ToggleSetting(title: "Включать при пробуждении", subtitle: "Только если Bluetooth выключил сам Мультитул; выключенный тобой остаётся выключенным", isOn: binding(\.restoreOnWake))
            Picker(selection: binding(\.restoreDelaySeconds)) {
                ForEach(BluetoothSleepSettings.delayChoices, id: \.self) { Text($0 == 0 ? "Сразу" : "\($0) с").tag($0) }
            } label: { SettingLabel("Пауза после пробуждения", "Перед включением Bluetooth дать системе проснуться") }
            ToggleSetting(title: "Уведомлять", subtitle: "Короткое уведомление при выключении и включении", isOn: binding(\.notify))
        } header: { Text("Bluetooth на время сна") } footer: {
            SectionFooter("Наушники в сумке не цепляются к спящему Маку. Последнее событие: \(c.lastEvent)")
        }
    }
}
