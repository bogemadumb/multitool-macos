import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class MicMuteController: ObservableObject {
    static let shared = MicMuteController()

    @Published private(set) var settings = MicMuteSettings()
    @Published private(set) var isMuted = false
    @Published private(set) var failed: [String] = []
    @Published private(set) var pending = 0
    @Published private(set) var running = false

    private let store = SoundSettingsStore()
    private let claims = MicDefaultsStore()
    private let hub = AudioDevicesHub.shared
    private var engine: MicMuteEngine?
    private var debounce: DispatchWorkItem?
    private let owner = "micMute"
    var onChange: (() -> Void)?

    var spec: HotkeySpec { SoundHotkeys.micToggle }

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadMic()
        let e = MicMuteEngine(hardware: hub.hal, input: hub.hal, store: claims, scope: settings.scope)
        engine = e
        isMuted = claims.active
        hub.retain(owner) { [weak self] _ in self?.schedule() }
        HotkeyManager.shared.register(spec, owner: ModuleID.micMute.rawValue) { [weak self] in self?.toggle() }
        hub.queue.async { [weak self] in
            let r = e.reassert()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, announce: nil) } }
        }
        onChange?()
    }

    func stop() {
        guard running else { return }
        running = false
        debounce?.cancel()
        debounce = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.micMute.rawValue)
        if let e = engine {
            let done = DispatchSemaphore(value: 0)
            hub.queue.async {
                _ = e.setMuted(false)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 1.5)
        }
        hub.release(owner)
        engine = nil
        isMuted = false
        failed = []
        onChange?()
    }

    func toggle() { setMuted(!isMuted) }

    func setMuted(_ on: Bool) {
        guard let e = engine else { return }
        isMuted = on
        onChange?()
        hub.queue.async { [weak self] in
            let r = e.setMuted(on)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, announce: on) } }
        }
    }

    func update(_ s: MicMuteSettings) {
        let scopeChanged = s.scope != settings.scope
        settings = s
        store.saveMic(s)
        if let e = engine, scopeChanged {
            hub.queue.async { [weak self] in
                e.scope = s.scope
                let r = e.reassert()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, announce: nil) } }
            }
        }
        onChange?()
    }

    private func schedule() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reassert() } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func reassert() {
        guard let e = engine else { return }
        hub.queue.async { [weak self] in
            guard e.isMuted || !e.claimedUIDs.isEmpty else { return }
            let r = e.reassert()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, announce: nil) } }
        }
    }

    private func finish(_ r: MicMuteReport, announce: Bool?) {
        isMuted = engine?.isMuted ?? false
        failed = r.failed
        pending = r.pending.count
        Log.write("micMute muted=\(isMuted) set=\(r.muted.count) released=\(r.released.count) failed=\(r.failed.count) pending=\(r.pending.count)")
        if let on = announce, settings.showHud {
            if !r.failed.isEmpty && on { HUD.show("Микрофон: не все устройства заглушены") } else { HUD.show(on ? "Микрофон выключен" : "Микрофон включён") }
        }
        onChange?()
    }
}

@MainActor
final class MicMuteStatusItem: NSObject {
    private var item: NSStatusItem?
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) { self.onClick = onClick }

    func render(visible: Bool) {
        if !visible {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.button?.target = self
            it.button?.action = #selector(clicked)
            it.button?.sendAction(on: [.leftMouseDown])
            item = it
        }
        let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let img = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Микрофон выключен")?.withSymbolConfiguration(cfg)
        img?.isTemplate = false
        item?.button?.image = img
        item?.button?.toolTip = "Микрофон выключен. Нажми, чтобы включить"
    }

    func remove() { render(visible: false) }

    @objc private func clicked() { onClick() }
}

@MainActor
final class MicMuteModule: Module {
    let info = ModuleID.micMute.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(MicMuteTile()) }
    private var statusItem: MicMuteStatusItem?

    func start() {
        let c = MicMuteController.shared
        statusItem = MicMuteStatusItem { MicMuteController.shared.toggle() }
        c.onChange = { [weak self] in self?.render() }
        c.start()
        render()
        Log.write("module micMute start")
    }

    func stop() {
        let c = MicMuteController.shared
        c.stop()
        c.onChange = nil
        statusItem?.remove()
        statusItem = nil
        Log.write("module micMute stop")
    }

    private func render() {
        let c = MicMuteController.shared
        statusItem?.render(visible: c.isMuted && c.settings.showIndicator)
    }
}

struct MicMuteTile: View {
    @ObservedObject private var c = MicMuteController.shared

    var body: some View {
        QuickTile(symbol: c.isMuted ? "mic.slash.fill" : "mic.fill", caption: "Микрофон", active: c.isMuted, help: c.isMuted ? "Микрофон выключен" : "Микрофон включён") { c.toggle() }
    }
}

struct MicMuteView: View {
    @ObservedObject private var c = MicMuteController.shared
    @ObservedObject private var hub = AudioDevicesHub.shared

    private func binding<T>(_ kp: WritableKeyPath<MicMuteSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    StatusLabel(c.isMuted ? "заглушен" : "работает", color: c.isMuted ? .orange : .green)
                    Button(c.isMuted ? "Включить" : "Выключить") { c.toggle() }
                }
            } label: { Label(c.isMuted ? "Микрофон выключен" : "Микрофон включён", systemImage: c.isMuted ? "mic.slash.fill" : "mic.fill") }
            Picker(selection: binding(\.scope)) {
                ForEach(MicMuteScope.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Что глушить", "Приложение может слушать не системный микрофон, а свою гарнитуру: «все» надёжнее") }
            ToggleSetting(title: "Красный микрофон в строке меню", subtitle: "Пока микрофон заглушен; клик по значку включает его", isOn: binding(\.showIndicator))
            ToggleSetting(title: "Показывать плашку", subtitle: "Короткая надпись на экране при включении и выключении", isOn: binding(\.showHud))
            if c.isMuted && !c.failed.isEmpty {
                ToolWarning(text: "Не удалось заглушить: \(c.failed.map { hub.name(of: $0) ?? $0 }.joined(separator: ", ")). У устройства нет ни переключателя, ни регулятора входа.")
            }
        } header: { Text("Микрофон") } footer: {
            SectionFooter("Глушит микрофоны во всех приложениях; прежняя громкость возвращается при включении." + (c.pending > 0 ? " Отключённых устройств, которым вернут уровень при подключении: \(c.pending)." : ""))
        }
    }
}
