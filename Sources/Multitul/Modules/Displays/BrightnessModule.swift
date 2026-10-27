import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class BrightnessWorker: @unchecked Sendable {
    typealias Publish = @Sendable ([BrightnessRow], [DisplaySnapshot], Set<UInt32>) -> Void

    private let queue = DispatchQueue(label: "dev.multitool.app.brightness.io")
    private let engine: BrightnessEngine
    private var flushQueued = false
    private let onPublish: Publish

    init(store: BrightnessStore, onPublish: @escaping Publish) {
        engine = BrightnessEngine(store: store, factory: LiveBrightnessFactory())
        self.onPublish = onPublish
    }

    private func publish() { onPublish(engine.rows, engine.snapshots, engine.controllable) }

    func reconcile(_ snaps: [DisplaySnapshot]) {
        queue.async { self.engine.reconcile(snaps); self.publish() }
    }

    func set(id: String, value: Double) {
        queue.async { self.engine.set(id: id, value: value); self.pump() }
    }

    private func pump() {
        guard let wait = engine.flush(), !flushQueued else { return }
        flushQueued = true
        queue.asyncAfter(deadline: .now() + wait + 0.005) {
            self.flushQueued = false
            self.pump()
        }
    }

    func setContrast(id: String, value: Double) { queue.async { _ = self.engine.setContrast(id: id, value: value) } }

    func setPower(id: String, on: Bool) {
        queue.async { Log.write("brightness power \(id) on=\(on) ok=\(self.engine.setPower(id: id, on: on))") }
    }

    func setForceSoftware(id: String, _ on: Bool) {
        queue.async { self.engine.setForceSoftware(id: id, on); self.publish() }
    }

    func apply(_ s: BrightnessSettings) {
        queue.async {
            let changed = self.engine.settings.softwareFloorPercent != s.softwareFloorPercent
            self.engine.settings = s
            if changed { self.engine.reconcile(self.engine.snapshots) }
            self.publish()
        }
    }

    func releaseAll() { queue.sync { engine.releaseAll() } }
}

@MainActor
final class BrightnessController: ObservableObject {
    static let shared = BrightnessController()

    @Published private(set) var rows: [BrightnessRow] = []
    @Published private(set) var settings = BrightnessSettings()
    @Published private(set) var keyboardLevel: Double?
    @Published private(set) var keyboardAvailable = false
    @Published private(set) var tapFailed = false
    @Published private(set) var running = false

    private let store = BrightnessStore()
    private var worker: BrightnessWorker!
    private let keyboard = CoreBrightnessKeyboard()
    private var router = BrightnessKeyRouter()
    private var snapshots: [DisplaySnapshot] = []
    private var controllable: Set<UInt32> = []
    private var tapToken: EventTapHub.Token?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: DispatchWorkItem?

    private init() {
        worker = BrightnessWorker(store: store) { [weak self] r, s, c in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.rows = r
                    self.snapshots = s
                    self.controllable = c
                    Log.write("brightness displays: " + r.map { "\($0.id)=\($0.method.rawValue)" }.joined(separator: ", "))
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadSettings()
        applySettingsToRouter()
        keyboardAvailable = keyboard.isAvailable
        keyboardLevel = keyboard.level()
        refreshDisplays()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(after: 0.6) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(after: 2.5) }
        })
        let hk = HotkeyManager.shared
        let owner = ModuleID.brightness.rawValue
        hk.register(BrightnessHotkeys.displayDown, owner: owner) { [weak self] in self?.hotkeyDisplay(up: false) }
        hk.register(BrightnessHotkeys.displayUp, owner: owner) { [weak self] in self?.hotkeyDisplay(up: true) }
        hk.register(BrightnessHotkeys.keyboardDown, owner: owner) { [weak self] in self?.adjustKeyboard(up: false, fine: false) }
        hk.register(BrightnessHotkeys.keyboardUp, owner: owner) { [weak self] in self?.adjustKeyboard(up: true, fine: false) }
        applyTap()
    }

    func stop() {
        guard running else { return }
        running = false
        HotkeyManager.shared.unregisterAll(owner: ModuleID.brightness.rawValue)
        removeTap()
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        refreshTask?.cancel()
        worker.releaseAll()
        rows = []
        snapshots = []
        controllable = []
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshTask?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshDisplays() } }
        refreshTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func refreshDisplays() {
        guard running else { return }
        worker.reconcile(LiveDisplayEnumerator.snapshots())
    }

    func setBrightness(id: String, value: Double) {
        let v = BrightnessStep.clamp(value)
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].value = v }
        worker.set(id: id, value: v)
    }

    func setContrast(id: String, value: Double) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].contrast = value }
        worker.setContrast(id: id, value: value)
    }

    func setPower(id: String, on: Bool) { worker.setPower(id: id, on: on) }

    func setForceSoftware(id: String, _ on: Bool) { worker.setForceSoftware(id: id, on) }

    func update(_ s: BrightnessSettings) {
        settings = s
        store.saveSettings(s)
        applySettingsToRouter()
        worker.apply(s)
        if running { applyTap() }
    }

    private func applySettingsToRouter() {
        router.followCursor = settings.followCursor
        router.fineAlways = settings.fineAlways
        router.handleKeyboardKeys = settings.keyboardKeys
    }

    private func applyTap() {
        if settings.interceptKeys {
            if tapToken == nil, let type = CGEventType(rawValue: 14) {
                tapToken = EventTapHub.shared.subscribe(types: [type]) { [weak self] _, event in
                    MainActor.assumeIsolated { self?.handle(event) ?? .pass }
                }
            }
            tapFailed = EventTapHub.shared.lastStartFailed
        } else {
            removeTap()
        }
    }

    private func removeTap() {
        if let t = tapToken { EventTapHub.shared.unsubscribe(t); tapToken = nil }
        tapFailed = false
    }

    private func cursor() -> CGPoint? { CGEvent(source: nil)?.location }

    private func handle(_ event: CGEvent) -> EventTapAction {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              let key = SystemKeyEvent(subtype: Int(ns.subtype.rawValue), data1: ns.data1) else { return .pass }
        let decision = router.decide(key, modifiers: KeyModifiers(cgFlags: event.flags), cursor: cursor(), displays: snapshots,
                                     controllable: controllable, keyboardAvailable: keyboardAvailable)
        switch decision {
        case .pass: return .pass
        case .swallow: return .drop
        case .adjustDisplay(let id, let up, let fine):
            adjustDisplay(cgID: id, up: up, fine: fine)
            return .drop
        case .adjustKeyboard(let up, let fine):
            adjustKeyboard(up: up, fine: fine)
            return .drop
        }
    }

    private func hotkeyDisplay(up: Bool) {
        guard let id = BrightnessRouter.target(cursor: cursor(), displays: snapshots, controllable: controllable, followCursor: settings.followCursor) else { return }
        adjustDisplay(cgID: id, up: up, fine: settings.fineAlways)
    }

    private func adjustDisplay(cgID: UInt32, up: Bool, fine: Bool) {
        guard let row = rows.first(where: { $0.cgID == cgID }) else { return }
        let v = BrightnessStep.next(row.value, up: up, fine: fine)
        setBrightness(id: row.id, value: v)
        if settings.showOSD { BrightnessOSD.show(symbol: row.isBuiltin ? "sun.max" : "display", value: v, displayID: cgID) }
    }

    func adjustKeyboard(up: Bool, fine: Bool) {
        guard keyboardAvailable else { return }
        let cur = keyboard.level() ?? keyboardLevel ?? 0
        setKeyboard(KeyboardBacklightLogic.next(current: cur, up: up, fine: fine))
        if settings.showOSD { BrightnessOSD.show(symbol: "light.max", value: keyboardLevel ?? 0, displayID: nil) }
    }

    func setKeyboard(_ v: Double) {
        guard keyboardAvailable else { return }
        let c = BrightnessStep.clamp(v)
        if keyboard.setLevel(c) {
            keyboardLevel = c
            if c > 0 { store.keyboardLast = c }
        }
    }

    func toggleKeyboard() {
        let cur = keyboard.level() ?? keyboardLevel ?? 0
        setKeyboard(cur > 0 ? 0 : KeyboardBacklightLogic.onLevel(lastNonZero: store.keyboardLast))
    }
}

@MainActor
final class BrightnessModule: Module {
    let info = ModuleID.brightness.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var panelCard: AnyView? { AnyView(BrightnessPanelCard()) }

    func start() {
        BrightnessController.shared.start()
        Log.write("module brightness start")
    }

    func stop() {
        BrightnessController.shared.stop()
        Log.write("module brightness stop")
    }
}

func brightnessMethodStyle(_ m: BrightnessMethod) -> PillStyle {
    switch m {
    case .builtin, .ddc: .ok
    case .software: .neutral
    case .unavailable: .warn
    }
}

struct BrightnessPanelCard: View {
    @ObservedObject private var c = BrightnessController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(c.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(row.isBuiltin ? "Дисплей" : row.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if row.method != .builtin && row.method != .ddc { Pill(row.method.title, style: brightnessMethodStyle(row.method)) }
                    }
                    CapsuleSlider(symbol: row.isBuiltin ? "sun.max.fill" : "display", value: Binding(get: { row.value * 100 }, set: { c.setBrightness(id: row.id, value: $0 / 100) }),
                                  enabled: row.method != .unavailable)
                        .help("\(row.name) · \(row.method.title)")
                }
            }
            if c.keyboardAvailable {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Подсветка клавиатуры").font(.callout.weight(.semibold)).lineLimit(1)
                    CapsuleSlider(symbol: "light.max", value: Binding(get: { (c.keyboardLevel ?? 0) * 100 }, set: { c.setKeyboard($0 / 100) }))
                }
            }
            if c.rows.isEmpty { Text("Дисплеи не найдены").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BrightnessView: View {
    var showMain: Bool
    var showExtra: Bool
    var canToggleMonitor = false
    @ObservedObject private var c = BrightnessController.shared

    private func methodColor(_ m: BrightnessMethod) -> Color {
        switch m {
        case .builtin, .ddc: .green
        case .software: .secondary
        case .unavailable: .orange
        }
    }

    var body: some View {
        Group {
            if showMain {
                if c.rows.isEmpty {
                    Section { EmptyHint(text: c.running ? "Дисплеи не найдены" : "Модуль запускается…", symbol: "display") }
                }
                ForEach(c.rows) { row in displaySection(row) }
                if c.keyboardAvailable { keyboardSection }
                keysSection
                hotkeysSection
            }
            if showExtra { ExtraBrightnessSections() }
        }
        .onAppear { if showMain { c.refreshDisplays() } }
    }

    private func displaySection(_ row: BrightnessRow) -> some View {
        Section {
            LabeledContent("Способ") { StatusLabel(row.method.title, color: methodColor(row.method)) }
            SymbolSlider("Яркость", symbol: "sun.max", value: Binding(get: { row.value * 100 }, set: { c.setBrightness(id: row.id, value: $0 / 100) }))
                .disabled(row.method == .unavailable)
            if let contrast = row.contrast {
                SymbolSlider("Контраст", symbol: "circle.lefthalf.filled", value: Binding(get: { contrast * 100 }, set: { c.setContrast(id: row.id, value: $0 / 100) }))
            }
            if !row.isBuiltin {
                Toggle("Только программно", isOn: Binding(get: { row.forcedSoftware }, set: { c.setForceSoftware(id: row.id, $0) }))
                if row.canPower {
                    Button("Усыпить (DDC)") { c.setPower(id: row.id, on: false) }
                    Button("Разбудить") { c.setPower(id: row.id, on: true) }
                }
                if canToggleMonitor {
                    Button("Убрать из раскладки") { MonitorToggleController.shared.run(.off) }
                }
            }
        } header: {
            Label(row.name, systemImage: row.isBuiltin ? "laptopcomputer" : "display")
        } footer: { SectionFooter(methodNote(row)) }
    }

    private func methodNote(_ row: BrightnessRow) -> String {
        switch row.method {
        case .builtin: "Системная яркость экрана"
        case .ddc: "Железная яркость монитора по DDC/CI"
        case .software: "Программное затемнение: картинка темнее, подсветка прежняя"
        case .unavailable: "Управление этим экраном недоступно"
        }
    }

    private var keyboardSection: some View {
        Section {
            LabeledContent {
                Button("Вкл / выкл") { c.toggleKeyboard() }
            } label: { SettingLabel("Подсветка клавиатуры", "Через CoreBrightness; клавиши подсветки на клавиатуре тоже перехватываются, если включено ниже") }
            SymbolSlider("Уровень", symbol: "light.min", value: Binding(get: { (c.keyboardLevel ?? 0) * 100 }, set: { c.setKeyboard($0 / 100) }))
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<BrightnessSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var keysSection: some View {
        Section {
            if c.settings.interceptKeys && c.tapFailed {
                ToolWarning(text: "Перехват не запустился: выдай Мультитулу «Универсальный доступ» в Настройках macOS и перезапусти модуль.")
            }
            Toggle(isOn: binding(\.interceptKeys)) { SettingLabel("Перехватывать клавиши яркости", "Нужен доступ «Универсальный доступ». Без него клавиши работают как обычно.") }
            Toggle(isOn: binding(\.followCursor)) { SettingLabel("Менять экран под курсором", "Выключено: клавиши меняют главный экран") }
            Toggle(isOn: binding(\.fineAlways)) { SettingLabel("Мелкие шаги всегда", "Шаг 1/64 вместо 1/16. ⌥⇧ + клавиша даёт мелкий шаг в любом случае") }
            Toggle(isOn: binding(\.showOSD)) { SettingLabel("Индикатор яркости", "Своя плашка с процентами вместо системной") }
            Toggle("Клавиши подсветки клавиатуры", isOn: binding(\.keyboardKeys))
            StepperSetting("Минимум программного затемнения", "Ниже этого процента картинка не гаснет: чтобы не потерять экран", value: binding(\.softwareFloorPercent), in: 0...30, step: 2, unit: "%")
        } header: { Text("Клавиши яркости") }
    }

    private var hotkeysSection: some View {
        Section {
            ForEach(BrightnessHotkeys.all, id: \.id) { spec in
                LabeledContent(spec.title) { HotkeyRecorder(spec: spec, titles: [:]) }
            }
        } header: { Text("Горячие клавиши") } footer: {
            SectionFooter("По умолчанию не назначены. Удобно: ⇧⌘- и ⇧⌘= для экрана, ⌥⌘- и ⌥⌘= для подсветки.")
        }
    }
}
