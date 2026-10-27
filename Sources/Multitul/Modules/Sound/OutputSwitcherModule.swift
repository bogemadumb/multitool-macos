import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class OutputSwitcherController: ObservableObject {
    static let shared = OutputSwitcherController()

    @Published private(set) var settings = OutputSwitcherSettings()
    @Published private(set) var running = false

    private let store = SoundSettingsStore()
    private let hub = AudioDevicesHub.shared
    private var switcher: OutputSwitcher?
    private let owner = "soundOutput"

    var spec: HotkeySpec { SoundHotkeys.outputNext }

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadSwitcher()
        switcher = OutputSwitcher(hardware: hub.hal, settings: settings)
        hub.retain(owner) { _ in }
        HotkeyManager.shared.register(spec, owner: ModuleID.soundOutputSwitcher.rawValue) { [weak self] in self?.next() }
    }

    func stop() {
        guard running else { return }
        running = false
        HotkeyManager.shared.unregisterAll(owner: ModuleID.soundOutputSwitcher.rawValue)
        hub.release(owner)
        switcher = nil
    }

    func update(_ s: OutputSwitcherSettings) {
        settings = s
        store.saveSwitcher(s)
    }

    func setMember(_ uid: String, on: Bool) {
        var s = settings
        s.cycle = OutputCycle.setMember(s.cycle, uid: uid, on: on)
        update(s)
    }

    func move(_ uid: String, by delta: Int) {
        var s = settings
        s.cycle = AudioPriorityLogic.move(s.cycle, uid: uid, by: delta)
        update(s)
    }

    func select(_ uid: String) { hub.choose(.output, uid: uid, syncSystem: settings.syncSystemOutput) }

    func next() {
        guard let sw = switcher else { return }
        let s = settings
        let hal = hub.hal
        hub.queue.async {
            sw.settings = s
            let r = sw.switchNext()
            let name = r.uid.flatMap { uid in hal.devices().first { $0.uid == uid }?.name }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.write("soundOutput next -> \(r.status) \(r.uid ?? "-")")
                    AudioDevicesHub.shared.refresh()
                    guard s.showHud else { return }
                    switch r.status {
                    case .switched: HUD.show("Вывод: " + (name ?? "устройство"))
                    case .nothingToSwitch: HUD.show(s.cycle.isEmpty ? "Вывод: цикл не настроен" : "Вывод: переключаться некуда")
                    case .failed: HUD.show("Вывод: не удалось переключить")
                    }
                }
            }
        }
    }
}

@MainActor
final class OutputSwitcherModule: Module {
    let info = ModuleID.soundOutputSwitcher.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(OutputSwitcherTile()) }
    var panelCard: AnyView? { AnyView(OutputSwitcherCard()) }

    func start() {
        OutputSwitcherController.shared.start()
        Log.write("module soundOutputSwitcher start")
    }

    func stop() {
        OutputSwitcherController.shared.stop()
        Log.write("module soundOutputSwitcher stop")
    }
}

struct OutputSwitcherTile: View {
    @ObservedObject private var hub = AudioDevicesHub.shared
    @ObservedObject private var c = OutputSwitcherController.shared

    var body: some View {
        QuickTile(symbol: "hifispeaker.2", caption: "Вывод", help: hub.name(of: hub.defaultOutput) ?? "Вывод звука", action: { c.next() })
    }
}

@MainActor
final class PanelVolumeModel: ObservableObject {
    @Published var volume = 0.0
    @Published var muted = false
    @Published var available = false
    private let driver = IslSystemLevels()
    private var listener: IslVolumeListener?
    private var localUntil = Date.distantPast

    func start() {
        read()
        let l = IslVolumeListener { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.read() } }
        }
        l.start()
        listener = l
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    private func read() {
        guard Date() >= localUntil else { return }
        let v = driver.outputVolume()
        available = v != nil
        if let v { volume = Double(v) }
        muted = driver.isMuted() ?? false
    }

    func set(_ percent: Double) {
        let c = IslLevelsMath.clamp(percent / 100)
        localUntil = Date().addingTimeInterval(0.5)
        volume = c
        if muted, c > 0, driver.setMuted(false) { muted = false }
        _ = driver.setOutputVolume(Float(c))
    }
}

struct OutputSwitcherCard: View {
    @ObservedObject private var hub = AudioDevicesHub.shared
    @ObservedObject private var c = OutputSwitcherController.shared
    @StateObject private var vol = PanelVolumeModel()
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Звук").font(.callout.weight(.semibold))
                    Text("· " + (hub.name(of: hub.defaultOutput) ?? "нет устройства")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Устройства вывода")
            CapsuleSlider(symbol: IslLevelsMath.volumeSymbol(vol.volume, muted: vol.muted), value: Binding(get: { vol.muted ? 0 : vol.volume * 100 }, set: { vol.set($0) }),
                          enabled: vol.available)
            if expanded {
                ForEach(hub.outputs()) { d in
                    Button { c.select(d.uid) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: d.transport.symbol).frame(width: 16).foregroundStyle(.secondary)
                            Text(d.name).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            if d.uid == hub.defaultOutput { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if hub.outputs().isEmpty { Text("Устройств вывода нет").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { vol.start() }
        .onDisappear { vol.stop() }
    }
}

struct OutputSwitcherView: View {
    @ObservedObject private var hub = AudioDevicesHub.shared
    @ObservedObject private var c = OutputSwitcherController.shared

    private var rows: [(uid: String, name: String, member: Bool, online: Bool, transport: AudioTransport?)] {
        let outs = hub.outputs()
        var list: [(uid: String, name: String, member: Bool, online: Bool, transport: AudioTransport?)] = []
        for uid in c.settings.cycle {
            let d = outs.first { $0.uid == uid }
            list.append((uid, d?.name ?? hub.name(of: uid) ?? uid, true, d != nil, d?.transport))
        }
        for d in outs where !c.settings.cycle.contains(d.uid) { list.append((d.uid, d.name, false, true, d.transport)) }
        return list
    }

    private func binding<T>(_ kp: WritableKeyPath<OutputSwitcherSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent {
                Button("Следующее") { c.next() }
            } label: { SettingLabel("Сейчас: \(hub.name(of: hub.defaultOutput) ?? "—")", "Сочетание переходит к следующему отмеченному устройству; недоступные пропускаются") }
            ToggleSetting(title: "Переключать и звуковые эффекты", subtitle: "Системный вывод (сигналы, уведомления) идёт на то же устройство", isOn: binding(\.syncSystemOutput))
            ToggleSetting(title: "Показывать плашку", subtitle: "Название устройства на экране после переключения", isOn: binding(\.showHud))
        } header: { Text("Вывод звука") }
        Section {
            if rows.isEmpty { EmptyHint(text: "Устройства вывода не найдены", symbol: "speaker.slash") }
            ForEach(rows, id: \.uid) { r in
                LabeledContent {
                    HStack(spacing: 8) {
                        if r.uid == hub.defaultOutput { StatusLabel("активно", color: .green) }
                        else if !r.online { Text("не подключено").foregroundStyle(.secondary) }
                        if r.member {
                            Button { c.move(r.uid, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                            Button { c.move(r.uid, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        }
                        if r.online { Button("Выбрать") { c.select(r.uid) }.disabled(r.uid == hub.defaultOutput) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Toggle(r.name, isOn: Binding(get: { r.member }, set: { c.setMember(r.uid, on: $0) })).toggleStyle(.checkbox).labelsHidden()
                        Label(r.name, systemImage: r.transport?.symbol ?? "speaker.slash").lineLimit(1).foregroundStyle(r.online ? Color.primary : Color.secondary)
                    }
                }
            }
        } header: { Text("Устройства в цикле") }
    }
}
