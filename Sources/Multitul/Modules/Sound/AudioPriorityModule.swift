import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class AudioPriorityController: ObservableObject {
    static let shared = AudioPriorityController()

    @Published private(set) var config = AudioPriorityConfig()
    @Published private(set) var recent: [String] = []
    @Published private(set) var running = false

    private let store = SoundSettingsStore()
    private let hub = AudioDevicesHub.shared
    private var engine: AudioPriorityEngine?
    private var debounce: DispatchWorkItem?
    private let owner = "audioPriority"

    func start() {
        guard !running else { return }
        running = true
        config = store.loadPriority()
        let e = AudioPriorityEngine(hardware: hub.hal, config: config)
        e.onPlacement = { [weak self] scope, order in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.placed(scope, order) } }
        }
        engine = e
        hub.retain(owner) { [weak self] _ in self?.schedule() }
        hub.queue.async { [weak self] in
            e.prime()
            let actions = e.enforceAll()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(actions) } }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        debounce?.cancel()
        debounce = nil
        hub.release(owner)
        engine = nil
    }

    func update(_ new: AudioPriorityConfig) {
        let old = config
        config = new
        store.savePriority(new)
        let enforce = AudioScope.allCases.contains { old.rule($0) != new.rule($0) } || old.newDevice != new.newDevice
        guard let e = engine else { return }
        hub.queue.async { [weak self] in
            e.config = new
            guard enforce else { return }
            let actions = e.enforceAll()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(actions) } }
        }
    }

    func edit(_ scope: AudioScope, _ change: (inout AudioPriorityRule) -> Void) {
        var c = config
        var r = c.rule(scope)
        change(&r)
        r.order = AudioPriorityLogic.sanitized(r.order)
        c.setRule(scope, r)
        update(c)
    }

    private func placed(_ scope: AudioScope, _ order: [String]) {
        var c = config
        var r = c.rule(scope)
        r.order = order
        c.setRule(scope, r)
        config = c
        store.savePriority(c)
    }

    private func schedule() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    private func fire() {
        guard let e = engine else { return }
        hub.queue.async { [weak self] in
            let actions = e.refresh()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(actions) } }
        }
    }

    private func report(_ actions: [AudioPriorityAction]) {
        hub.refresh()
        for a in actions {
            let name = hub.name(of: a.to) ?? a.to
            let line = "\(a.scope.title): \(name)" + (a.success ? "" : " (не удалось)")
            recent = Array(([line] + recent).prefix(6))
            Log.write("audioPriority \(a.scope.rawValue) \(a.from ?? "-") -> \(a.to) \(a.reason.rawValue) ok=\(a.success)")
            if config.notify, a.success {
                Notifier.shared.post(title: "Приоритеты звука", body: line, id: "audiopriority-\(UUID().uuidString)")
            }
        }
    }
}

@MainActor
final class AudioPriorityModule: Module {
    let info = ModuleID.audioPriority.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        AudioPriorityController.shared.start()
        Log.write("module audioPriority start")
    }

    func stop() {
        AudioPriorityController.shared.stop()
        Log.write("module audioPriority stop")
    }
}

struct AudioPriorityView: View {
    @ObservedObject private var c = AudioPriorityController.shared
    @ObservedObject private var hub = AudioDevicesHub.shared

    private func binding<T>(_ kp: WritableKeyPath<AudioPriorityConfig, T>) -> Binding<T> {
        Binding(get: { c.config[keyPath: kp] }, set: { v in var s = c.config; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ForEach(AudioScope.allCases, id: \.self) { scope in scopeSection(scope) }
        Section {
            Picker(selection: binding(\.onConnect)) {
                ForEach(AudioConnectPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Когда подключилось новое устройство", "Работает для обоих списков") }
            Picker(selection: binding(\.newDevice)) {
                ForEach(AudioNewDevicePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Устройство, которого нет в списке", "Виртуальные и агрегатные в список сами не попадают") }
            ToggleSetting(title: "Переключать и звуковые эффекты", subtitle: "При смене вывода системный вывод (сигналы, уведомления) идёт туда же", isOn: binding(\.syncSystemOutput))
            ToggleSetting(title: "Уведомлять о переключении", subtitle: "Короткое уведомление, когда Мультитул сам сменил устройство", isOn: binding(\.notify))
        } header: { Text("Правила переключения") }
        if !c.recent.isEmpty {
            Section("Последние переключения") {
                ForEach(c.recent, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func scopeSection(_ scope: AudioScope) -> some View {
        let rule = c.config.rule(scope)
        let online = scope == .output ? hub.outputs() : hub.inputs()
        let active = scope == .output ? hub.defaultOutput : hub.defaultInput
        let addable = online.filter { !rule.order.contains($0.uid) && !rule.ignored.contains($0.uid) }
        return Section {
            ToggleSetting(title: scope == .output ? "Приоритеты вывода" : "Приоритеты ввода",
                          subtitle: scope == .output ? "Наушники и колонки: активным становится верхнее из подключённых" : "Микрофоны: например, не отдавать вход AirPods",
                          isOn: Binding(get: { rule.enabled }, set: { v in c.edit(scope) { $0.enabled = v } }))
            if rule.order.isEmpty { Text("Список пуст: подключённые устройства добавятся сами").foregroundStyle(.secondary) }
            ForEach(Array(rule.order.enumerated()), id: \.element) { i, uid in
                let isOnline = online.contains { $0.uid == uid }
                LabeledContent {
                    HStack(spacing: 8) {
                        if uid == active { StatusLabel("активно", color: .green) } else if !isOnline { Text("не подключено").foregroundStyle(.secondary) }
                        Button { c.edit(scope) { $0.order = AudioPriorityLogic.move($0.order, uid: uid, by: -1) } } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                        Button { c.edit(scope) { $0.order = AudioPriorityLogic.move($0.order, uid: uid, by: 1) } } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == rule.order.count - 1)
                        Button { c.edit(scope) { $0.order.removeAll { $0 == uid }; $0.ignored.insert(uid) } } label: { Image(systemName: "eye.slash") }.buttonStyle(.borderless).help("В игнорируемые")
                        Button { c.edit(scope) { $0.order.removeAll { $0 == uid } } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Убрать из списка")
                    }
                } label: {
                    Text("\(i + 1). \(hub.name(of: uid) ?? uid)").lineLimit(1).foregroundStyle(isOnline ? Color.primary : Color.secondary)
                }
            }
            if !addable.isEmpty {
                Menu("Добавить устройство") {
                    ForEach(addable) { d in Button(d.name) { c.edit(scope) { $0.order.append(d.uid) } } }
                }
                Menu("Игнорировать устройство") {
                    ForEach(addable) { d in Button(d.name) { c.edit(scope) { $0.ignored.insert(d.uid) } } }
                }
            }
            ForEach(rule.ignored.sorted(), id: \.self) { uid in
                LabeledContent {
                    Button("Вернуть") { c.edit(scope) { $0.ignored.remove(uid) } }
                } label: { Label(hub.name(of: uid) ?? uid, systemImage: "eye.slash").lineLimit(1) }
            }
        } header: { Text(scope == .output ? "Устройства вывода" : "Устройства ввода") } footer: {
            if !rule.ignored.isEmpty { SectionFooter("Игнорируемые устройства: Мультитул их не выбирает и не трогает.") }
        }
    }
}
