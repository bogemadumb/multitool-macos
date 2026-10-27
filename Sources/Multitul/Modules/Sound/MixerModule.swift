import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class MixerRuntime: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.multitool.app.mixer")
    let driver = MixLiveDriver()
    private let engine: MixEngine
    private let publishHandler: @Sendable (MixSnapshot, [String: MixLevels]) -> Void
    private let levelsHandler: @Sendable ([String: MixLevels]) -> Void
    private var timer: DispatchSourceTimer?
    private var fast = false
    private var tick = 0

    init(hardware: AudioHardware, onGuard: @escaping @Sendable (MixGuardAction, String) -> Void,
         onPublish: @escaping @Sendable (MixSnapshot, [String: MixLevels]) -> Void, onLevels: @escaping @Sendable ([String: MixLevels]) -> Void) {
        engine = MixEngine(driver: driver, hardware: hardware, volumes: driver, store: MixSettingsStore())
        engine.onGuard = onGuard
        publishHandler = onPublish
        levelsHandler = onLevels
    }

    func start() {
        queue.async { [self] in
            engine.start()
            driver.startListening(queue: queue) { [weak self] in self?.async { $0.refresh() } }
            rearm()
            publish()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            driver.stopListening()
            engine.stop()
        }
    }

    func async(_ work: @escaping @Sendable (MixEngine) -> Void) {
        queue.async { [self] in
            work(engine)
            publish()
        }
    }

    func setFast(_ on: Bool) {
        queue.async { [self] in
            guard fast != on else { return }
            fast = on
            rearm()
        }
    }

    private func rearm() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval: TimeInterval = fast ? 0.1 : 2
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            if !fast || tick % 20 == 0 {
                engine.refresh()
                publish()
            } else {
                levelsHandler(engine.levels())
            }
        }
        t.resume()
        timer = t
    }

    private func publish() { publishHandler(engine.snapshot(), engine.levels()) }
}

@MainActor
final class MixerController: ObservableObject {
    static let shared = MixerController()

    @Published private(set) var snapshot = MixSnapshot()
    @Published private(set) var levels: [String: MixLevels] = [:]
    @Published private(set) var running = false

    let supported = MixLiveDriver.isSupported

    private let hub = AudioDevicesHub.shared
    private let owner = "mixer"
    private var runtime: MixerRuntime?
    private var observers: [NSObjectProtocol] = []
    private var viewers = 0
    private var hooks: [String: MixLevelDemand] = [:]

    func start() {
        guard !running, supported else { return }
        running = true
        let rt = MixerRuntime(hardware: hub.hal, onGuard: { action, name in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HUD.show("Микшер: громкость \(name) снижена до \(Int((action.to * 100).rounded()))%") }
            }
        }, onPublish: { snap, lv in
            DispatchQueue.main.async { MainActor.assumeIsolated { MixerController.shared.apply(snap, lv) } }
        }, onLevels: { lv in
            DispatchQueue.main.async { MainActor.assumeIsolated { MixerController.shared.setLevels(lv) } }
        })
        runtime = rt
        rt.driver.setRunningApps(Self.runningApps())
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appsChanged() }
            })
        }
        hub.retain(owner) { [weak self] event in self?.runtime?.async { $0.handle(event) } }
        HotkeyManager.shared.register(MixHotkeys.muteFront, owner: ModuleID.mixer.rawValue) { [weak self] in self?.muteFront() }
        HotkeyManager.shared.register(MixHotkeys.resetAll, owner: ModuleID.mixer.rawValue) { [weak self] in self?.resetAll() }
        rt.start()
        pushDemand()
    }

    func stop() {
        guard running else { return }
        running = false
        HotkeyManager.shared.unregisterAll(owner: ModuleID.mixer.rawValue)
        hub.release(owner)
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        runtime?.stop()
        runtime = nil
        snapshot = MixSnapshot()
        levels = [:]
        viewers = 0
    }

    private static func runningApps() -> [MixRunningApp] {
        NSWorkspace.shared.runningApplications.map {
            MixRunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "Приложение",
                          bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
    }

    private func appsChanged() {
        guard let runtime else { return }
        runtime.driver.setRunningApps(Self.runningApps())
        runtime.async { $0.refresh() }
    }

    private func apply(_ snap: MixSnapshot, _ lv: [String: MixLevels]) {
        guard running else { return }
        if snapshot != snap { snapshot = snap }
        setLevels(lv)
    }

    private func setLevels(_ lv: [String: MixLevels]) {
        guard running else { return }
        if lv != levels { levels = lv }
    }

    // MARK: viewers and hooks for the island's live equalizer

    func viewerAppeared() {
        viewers += 1
        pushDemand()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        pushDemand()
    }

    // Island live equalizer: request levels and spectrum bands for apps (bundle ids) while they are on screen.
    func requestLevels(owner: String, keys: Set<String>, bands: Bool) {
        hooks[owner] = MixLevelDemand(allApps: false, keys: keys, bandKeys: bands ? keys : [])
        pushDemand()
    }

    func releaseLevels(owner: String) {
        hooks[owner] = nil
        pushDemand()
    }

    private func pushDemand() {
        guard let runtime else { return }
        let ui = viewers > 0 ? MixLevelDemand(allApps: true) : MixLevelDemand.none
        let extra = hooks
        runtime.setFast(viewers > 0 || !extra.isEmpty)
        runtime.async { engine in
            engine.setDemand(owner: "ui", ui)
            for (k, v) in extra { engine.setDemand(owner: "hook." + k, v) }
        }
    }

    // MARK: intents

    func setVolume(_ key: String, _ v: Double, commit: Bool) { runtime?.async { $0.setVolume(key, v, persist: commit) } }
    func toggleMute(_ key: String) { runtime?.async { $0.toggleMute(key) } }
    func setOutput(_ key: String, _ uid: String?) { runtime?.async { $0.setOutput(key, uid) } }
    func setPinned(_ key: String, _ on: Bool) { runtime?.async { $0.setPinned(key, on) } }
    func reset(_ key: String) { runtime?.async { $0.reset(key) } }
    func resetAll() { runtime?.async { $0.resetAll() } }
    func move(_ key: String, before target: String) { runtime?.async { $0.moveRow(key, before: target) } }
    func nudge(_ key: String, by delta: Int) { runtime?.async { $0.nudgeRow(key, by: delta) } }
    func update(_ s: MixSettings) { runtime?.async { $0.update(settings: s) } }

    func muteFront() {
        guard let runtime, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier
        let name = app.localizedName ?? "Приложение"
        runtime.async { engine in
            guard let key = engine.key(forPID: pid, bundleID: bid) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { HUD.show("Микшер: \(name) сейчас не выводит звук") } }
                return
            }
            engine.toggleMute(key)
            let muted = engine.apps[key]?.muted ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { HUD.show("Микшер: \(name) — " + (muted ? "без звука" : "звук включён")) } }
        }
    }
}

@MainActor
final class MixerModule: Module {
    let info = ModuleID.mixer.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var panelCard: AnyView? { AnyView(MixerCard()) }

    func start() {
        MixerController.shared.start()
        Log.write("module mixer start supported=\(MixerController.shared.supported)")
    }

    func stop() {
        MixerController.shared.stop()
        Log.write("module mixer stop")
    }
}

@MainActor
enum MixerIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ key: String) -> NSImage {
        if let i = cache[key] { return i }
        var img: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) { img = NSWorkspace.shared.icon(forFile: url.path) }
        let value = img ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[key] = value
        return value
    }
}

struct MixerLevelBar: View {
    var levels: MixLevels?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill((levels?.peak ?? 0) > 0.98 ? Theme.danger : Theme.ok)
                    .frame(width: g.size.width * CGFloat(MixLevels.barValue(levels?.peak ?? 0)))
            }
        }
        .frame(height: 3)
    }
}

struct MixerRowView: View {
    let row: MixAppRow
    let options: [MixRouteOption]
    let maxBoost: Double
    let fine: Bool
    let levels: MixLevels?
    let processing: Bool
    let error: MixTapError?
    let offlineRoute: Bool
    var compact = false

    @ObservedObject private var c = MixerController.shared
    @State private var draft: Double?

    private var value: Double { draft ?? row.setting.volume }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: MixerIcons.icon(row.key)).resizable().frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                    .opacity(row.isRunning ? 1 : 0.4)
                Text(row.name).font(.callout.weight(.medium)).lineLimit(1).frame(width: compact ? 78 : 140, alignment: .leading)
                Slider(value: Binding(get: { value }, set: { v in
                    let s = MixGain.snapped(v, maxBoost: maxBoost)
                    draft = s
                    c.setVolume(row.key, s, commit: false)
                }), in: 0...maxBoost, onEditingChanged: { editing in
                    if !editing, let d = draft { c.setVolume(row.key, d, commit: true); draft = nil }
                })
                .controlSize(.small)
                .disabled(!row.isRunning)
                Text(MixGain.label(value)).font(Theme.Fonts.number).foregroundStyle(value > 1 ? Theme.warn : Theme.muted).frame(width: 44, alignment: .trailing)
                Button { c.toggleMute(row.key) } label: {
                    Image(systemName: row.setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                        .foregroundStyle(row.setting.muted ? Theme.danger : Theme.muted)
                }
                .buttonStyle(.plain)
                .disabled(!row.isRunning)
            }
            if levels != nil { MixerLevelBar(levels: levels).padding(.leading, compact ? 26 : 30) }
            if !compact {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(options) { o in
                            Button { c.setOutput(row.key, o.uid) } label: {
                                Text(o.name + (o.transport == .airplay ? " (AirPlay)" : "") + (o.uid == row.setting.outputUID || (o.uid == nil && row.setting.outputUID == nil) ? "  ✓" : ""))
                            }
                        }
                    } label: {
                        Label(routeTitle, systemImage: "hifispeaker").font(.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    if offlineRoute { Pill("устройство не подключено", style: .warn) }
                    if let error { Pill(error.text, style: .warn) }
                    else if processing { Pill("обрабатывается", style: .ok) }
                    Spacer()
                    Button { c.setPinned(row.key, !row.setting.pinned) } label: { Image(systemName: row.setting.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
                    Button { c.nudge(row.key, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { c.nudge(row.key, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    Button("Сбросить") { c.reset(row.key) }.controlSize(.small).disabled(row.setting.isNeutral || !(row.setting.needsProcessing))
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
    }

    private var routeTitle: String {
        guard let uid = row.setting.outputUID else { return "Как в системе" }
        return options.first { $0.uid == uid }?.name ?? "Устройство не найдено"
    }
}

struct MixerCard: View {
    @ObservedObject private var c = MixerController.shared

    var body: some View {
        let s = c.snapshot
        VStack(alignment: .leading, spacing: 4) {
            Text("Микшер").font(.callout.weight(.semibold))
            ForEach(s.rows) { r in
                MixerRowView(row: r, options: s.options, maxBoost: s.settings.maxBoost, fine: s.settings.fineSteps, levels: c.levels[r.key],
                             processing: s.processing.contains(r.key), error: s.errors[r.key], offlineRoute: s.fallbackKeys.contains(r.key), compact: true)
            }
            if s.rows.isEmpty { Text("Сейчас ничего не играет").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { c.viewerAppeared() }
        .onDisappear { c.viewerDisappeared() }
    }
}

struct MixerAppRow: View {
    let row: MixAppRow
    let options: [MixRouteOption]
    let maxBoost: Double
    let levels: MixLevels?
    let processing: Bool
    let error: MixTapError?
    let offlineRoute: Bool

    @ObservedObject private var c = MixerController.shared
    @State private var draft: Double?

    private var value: Double { draft ?? row.setting.volume }

    private var routeTitle: String {
        guard let uid = row.setting.outputUID else { return "Как в системе" }
        return options.first { $0.uid == uid }?.name ?? "Устройство не найдено"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { value }, set: { v in
                        let s = MixGain.snapped(v, maxBoost: maxBoost)
                        draft = s
                        c.setVolume(row.key, s, commit: false)
                    }), in: 0...maxBoost, onEditingChanged: { editing in
                        if !editing, let d = draft { c.setVolume(row.key, d, commit: true); draft = nil }
                    })
                    .frame(minWidth: 110, maxWidth: 200)
                    .disabled(!row.isRunning)
                    Text(MixGain.label(value)).monospacedDigit().foregroundStyle(value > 1 ? Color.orange : Color.secondary).frame(minWidth: 44, alignment: .trailing)
                    Button { c.toggleMute(row.key) } label: {
                        Image(systemName: row.setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!row.isRunning)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: MixerIcons.icon(row.key)).resizable().frame(width: 20, height: 20).opacity(row.isRunning ? 1 : 0.4)
                    Text(row.name).lineLimit(1)
                }
            }
            if levels != nil { ProgressView(value: min(max(MixLevels.barValue(levels?.peak ?? 0), 0), 1)).tint((levels?.peak ?? 0) > 0.98 ? Color.red : Color.green) }
            HStack(spacing: 8) {
                Menu {
                    ForEach(options) { o in
                        Button { c.setOutput(row.key, o.uid) } label: {
                            Text(o.name + (o.transport == .airplay ? " (AirPlay)" : "") + (o.uid == row.setting.outputUID || (o.uid == nil && row.setting.outputUID == nil) ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Label(routeTitle, systemImage: "hifispeaker").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                if offlineRoute { StatusLabel("устройство не подключено", color: .orange).font(.caption) }
                if let error { StatusLabel(error.text, color: .orange).font(.caption) }
                else if processing { StatusLabel("обрабатывается", color: .green).font(.caption) }
                Spacer()
                Button { c.setPinned(row.key, !row.setting.pinned) } label: { Image(systemName: row.setting.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
                Button { c.nudge(row.key, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button { c.nudge(row.key, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                Button("Сбросить") { c.reset(row.key) }.controlSize(.small).disabled(row.setting.isNeutral || !(row.setting.needsProcessing))
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 2)
    }
}

struct MixerView: View {
    @ObservedObject private var c = MixerController.shared

    private func binding<T>(_ kp: WritableKeyPath<MixSettings, T>) -> Binding<T> {
        Binding(get: { c.snapshot.settings[keyPath: kp] }, set: { v in var s = c.snapshot.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        let s = c.snapshot
        Section {
            LabeledContent("Состояние") {
                StatusLabel(c.supported ? (c.running ? "работает" : "выключен") : "нужна macOS 14.2", color: c.supported && c.running ? .green : .orange)
            }
        } header: {
            Text("Громкость по приложениям")
                .onAppear { c.viewerAppeared() }
                .onDisappear { c.viewerDisappeared() }
        } footer: {
            SectionFooter("Звук приложения перехватывается, обрабатывается и уходит на выбранное устройство. Приложения, которых не трогали, идут как обычно.")
        }
        Section {
            if s.rows.isEmpty {
                ContentUnavailableView("Сейчас ничего не играет", systemImage: "speaker.slash", description: Text("Закреплённые и настроенные приложения остаются в списке."))
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
            ForEach(s.rows) { r in
                MixerAppRow(row: r, options: s.options, maxBoost: s.settings.maxBoost, levels: c.levels[r.key],
                            processing: s.processing.contains(r.key), error: s.errors[r.key], offlineRoute: s.fallbackKeys.contains(r.key))
                    .onDrag { NSEvent.modifierFlags.contains(.command) ? NSItemProvider(object: r.key as NSString) : NSItemProvider() }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        guard let p = providers.first else { return false }
                        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                            guard let key = obj as? String else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { c.move(key, before: r.key) } }
                        }
                        return true
                    }
            }
            Button("Сбросить всё к 100%") { c.resetAll() }
        } header: { Text("Приложения") } footer: {
            SectionFooter("Порядок: ⌘ + перетаскивание или стрелки.")
        }
        Section {
            Picker(selection: Binding(get: { Int(s.settings.maxBoost * 100) }, set: { v in var n = s.settings; n.maxBoost = Double(v) / 100; c.update(n) })) {
                ForEach(MixGain.allowedMaxBoosts, id: \.self) { b in Text("\(Int(b * 100))%").tag(Int(b * 100)) }
            } label: { SettingLabel("Максимум усиления", "Выше 100% включается ограничитель: звук не хрипит и не клипует") }
            ToggleSetting(title: "Скрывать неактивные", subtitle: "В списке только то, что играет (или играло в последние секунды), закреплённое и настроенное", isOn: binding(\.hideInactive))
            ToggleSetting(title: "Мелкие шаги громкости", subtitle: "Шаг клавиш громкости в микшере 1% вместо 5%", isOn: binding(\.fineSteps))
            ToggleSetting(title: "Индикаторы уровня", subtitle: "Пока микшер открыт, слушает играющие приложения, чтобы показать уровень", isOn: binding(\.showMeters))
            ToggleSetting(title: "Снижать громкость при отключении наушников", subtitle: "Если вывод ушёл с Bluetooth, USB или AirPlay на встроенные динамики, громкость динамиков не выше заданной", isOn: binding(\.headphoneGuard))
            if s.settings.headphoneGuard {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(s.settings.guardCapPercent) }, set: { v in var n = s.settings; n.guardCapPercent = Int(v); c.update(n) }), in: 5...100, step: 5).frame(minWidth: 110, maxWidth: 200)
                        Text("\(s.settings.guardCapPercent)%").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                    }
                } label: { Text("Предел для динамиков") }
            }
        } header: { Text("Настройки микшера") }
        Section("Горячие клавиши") {
            LabeledContent("Заглушить приложение на переднем плане") { HotkeyRecorder(spec: MixHotkeys.muteFront, titles: [:]) }
            LabeledContent("Сбросить все приложения к 100%") { HotkeyRecorder(spec: MixHotkeys.resetAll, titles: [:]) }
        }
    }
}
