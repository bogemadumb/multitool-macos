import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

enum KeepAwakeCtlState: Equatable {
    case unknown, ready, missing(String)
}

struct KeepAwakeSnapshot: Equatable {
    var active = false
    var automationOn = false
    var closedLid = false
    var status = "Выключен"
    var title = ""
    var batterySuppressed = false
}

@MainActor
final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    @Published private(set) var settings = KeepAwakeSettings()
    @Published private(set) var snapshot = KeepAwakeSnapshot()
    @Published private(set) var ctlState = KeepAwakeCtlState.unknown
    @Published private(set) var foreignSleepDisabled = false
    @Published private(set) var running = false
    @Published var closedLidForNext = false

    private let store = KeepAwakeStore()
    private let markers = KeepAwakeMarkers()
    private var runner: KeepAwakeRunner?
    private var host: KeepAwakeSystemHost?
    private var timer: Timer?
    private var batteryCache: (at: Date, value: BatteryReading)?
    private var signalSource: DispatchSourceSignal?
    var onChange: (() -> Void)?

    var spec: HotkeySpec { KeepAwakeHotkeys.toggle }
    var engine: KeepAwakeEngine? { runner?.engine }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        let h = KeepAwakeSystemHost(markers: markers) { notice in
            Notifier.shared.post(title: "Keep Awake", body: notice.text, id: "keepawake-\(UUID().uuidString)")
        }
        host = h
        let r = KeepAwakeRunner(engine: KeepAwakeEngine(settings: settings), host: h, markers: markers)
        runner = r
        let plan = r.recoverOnStart()
        h.restoreDimIfPending()
        foreignSleepDisabled = plan == .foreignSleepDisabled
        Log.write("keepAwake start recovery=\(plan)")
        HotkeyManager.shared.register(spec, owner: ModuleID.keepAwake.rawValue) { [weak self] in self?.toggle() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkCtl()
        if settings.autoStart { startSession(minutes: settings.defaultMinutes, closedLid: false) }
        publish()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.keepAwake.rawValue)
        runner?.shutdown(inputs: inputs(force: true))
        host?.restoreDimIfPending()
        removeSignalHandler()
        runner = nil
        host = nil
        snapshot = KeepAwakeSnapshot()
        onChange?()
    }

    func checkCtl() {
        ctlState = .unknown
        Task.detached {
            let state: KeepAwakeCtlState
            do { _ = try PrivilegedCtl().selftest(); state = .ready } catch { state = .missing("\(error)") }
            await MainActor.run { KeepAwakeController.shared.ctlState = state }
        }
    }

    func toggle() {
        guard let r = runner else { return }
        if r.engine.session != nil { stopSession() } else { startSession(minutes: settings.defaultMinutes, closedLid: false) }
    }

    func startSession(minutes: Int, closedLid: Bool) {
        runner?.start(.minutes(minutes, from: Date(), closedLid: closedLid), inputs: inputs(force: true))
        afterChange()
    }

    func startUntil(_ date: Date, closedLid: Bool) {
        runner?.start(KeepAwakeSession(start: Date(), end: .at(date), closedLid: closedLid), inputs: inputs(force: true))
        afterChange()
    }

    func startUntilAppQuits(_ bundleID: String, closedLid: Bool) {
        runner?.start(KeepAwakeSession(start: Date(), end: .appQuits(bundleID: bundleID), closedLid: closedLid), inputs: inputs(force: true))
        afterChange()
    }

    func stopSession() {
        runner?.stop(inputs: inputs(force: true))
        afterChange()
    }

    func update(_ s: KeepAwakeSettings) {
        settings = s.sanitized
        store.save(settings)
        runner?.apply(settings: settings, inputs: inputs(force: true))
        afterChange()
    }

    private func afterChange() {
        updateSignalHandler()
        publish()
        objectWillChange.send()
    }

    private func tick() {
        guard let r = runner else { return }
        if r.engine.isActive || settings.automationEnabled || markers.lidFlag {
            r.tick(inputs(force: false))
            updateSignalHandler()
        }
        publish()
    }

    private func inputs(force: Bool) -> KeepAwakeInputs {
        let now = Date()
        let e = runner?.engine
        var apps: Set<String> = []
        var needApps = settings.autoApps && !settings.autoAppBundleIDs.isEmpty
        if case .appQuits? = e?.session?.end { needApps = true }
        if needApps { apps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        if force || batteryCache == nil || now.timeIntervalSince(batteryCache!.at) >= 10 {
            batteryCache = (now, PowerReader.read())
        }
        let lidRelevant = (e?.lidHeld ?? false) || (e?.session?.closedLid ?? false)
        return KeepAwakeInputs(now: now, battery: batteryCache?.value, runningApps: apps,
                               externalDisplays: settings.autoExternalDisplay ? ExternalDisplays.count() : 0,
                               lidClosed: lidRelevant ? LidState.isClosed() : false)
    }

    private func publish() {
        guard let e = runner?.engine else { return }
        let now = Date()
        let s = KeepAwakeSnapshot(active: e.isActive, automationOn: e.automationOn, closedLid: e.session?.closedLid ?? false,
                                  status: KeepAwakeFormat.status(engine: e, now: now),
                                  title: KeepAwakeFormat.menuTitle(session: e.session, now: now, showRemaining: settings.showRemaining),
                                  batterySuppressed: e.batterySuppressed)
        if s != snapshot { snapshot = s; onChange?() }
    }

    // While the lid is held, SIGTERM goes through the normal quit path so disablesleep is switched back.
    private func updateSignalHandler() {
        if runner?.engine.lidHeld == true {
            guard signalSource == nil else { return }
            signal(SIGTERM, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            src.setEventHandler { Log.write("keepAwake SIGTERM during closed lid"); NSApp.terminate(nil) }
            src.resume()
            signalSource = src
        } else {
            removeSignalHandler()
        }
    }

    private func removeSignalHandler() {
        guard let s = signalSource else { return }
        s.cancel()
        signalSource = nil
        signal(SIGTERM, SIG_DFL)
    }
}

@MainActor
final class KeepAwakeStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { KeepAwakeController.shared.toggle() }
    }

    private func showMenu() {
        let c = KeepAwakeController.shared
        let menu = NSMenu()
        let head = NSMenuItem(title: c.snapshot.status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        for m in KeepAwakeSettings.presetMinutes { menu.addItem(entry(KeepAwakeFormat.duration(minutes: m), tag: m)) }
        menu.addItem(entry("Бессрочно", tag: 0))
        menu.addItem(entry("Бессрочно, крышка закрыта", tag: Self.lidTag))
        if c.snapshot.active { menu.addItem(.separator()); menu.addItem(entry("Выключить", tag: Self.stopTag)) }
        menu.addItem(.separator())
        menu.addItem(entry("Настройки…", tag: Self.openTag))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    static let lidTag = 100_000, stopTag = 100_001, openTag = 100_002

    private func entry(_ title: String, tag: Int) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        i.target = self
        i.tag = tag
        return i
    }

    @objc private func picked(_ sender: NSMenuItem) {
        let c = KeepAwakeController.shared
        switch sender.tag {
        case Self.lidTag: c.startSession(minutes: 0, closedLid: true)
        case Self.stopTag: c.stopSession()
        case Self.openTag: AppController.shared.openSection(ModuleGroup.energy.rawValue)
        default: c.startSession(minutes: sender.tag, closedLid: false)
        }
    }

    func update(_ snap: KeepAwakeSnapshot, settings: KeepAwakeSettings) {
        guard let b = item.button else { return }
        let symbol = snap.active ? settings.iconKind.symbolOn : settings.iconKind.symbolOff
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Keep Awake")
        b.image?.isTemplate = true
        b.contentTintColor = snap.active ? Self.color(settings.iconTint) : nil
        b.title = snap.title
        b.imagePosition = snap.title.isEmpty ? .imageOnly : .imageLeft
        b.toolTip = "Keep Awake: " + snap.status
    }

    static func color(_ t: KeepAwakeIconTint) -> NSColor? {
        switch t {
        case .none: nil
        case .orange: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

@MainActor
final class KeepAwakeModule: Module {
    let info = ModuleID.keepAwake.info
    private var statusItem: KeepAwakeStatusItem?

    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(KeepAwakeTile()) }
    var panelPresentation: PanelPresentation { .module }

    func start() {
        let c = KeepAwakeController.shared
        statusItem = KeepAwakeStatusItem()
        c.onChange = { [weak self] in self?.render() }
        c.start()
        render()
        Log.write("module keepAwake start")
    }

    func stop() {
        let c = KeepAwakeController.shared
        c.onChange = nil
        c.stop()
        statusItem?.remove()
        statusItem = nil
        Log.write("module keepAwake stop")
    }

    private func render() {
        let c = KeepAwakeController.shared
        statusItem?.update(c.snapshot, settings: c.settings)
    }
}

struct KeepAwakeTile: View {
    @ObservedObject private var c = KeepAwakeController.shared

    var body: some View {
        ModuleTile(symbol: c.settings.iconKind.symbolOn,
                   title: "Keep Awake", status: c.snapshot.status, active: c.snapshot.active, action: { c.toggle() }, options: { options })
    }

    @ViewBuilder private var options: some View {
        ForEach(KeepAwakeSettings.presetMinutes, id: \.self) { m in
            Button(KeepAwakeFormat.duration(minutes: m)) { c.startSession(minutes: m, closedLid: false) }
        }
        Button("Бессрочно") { c.startSession(minutes: 0, closedLid: false) }
        Button("Бессрочно, крышка закрыта") { c.startSession(minutes: 0, closedLid: true) }
        if c.snapshot.active { Divider(); Button("Выключить") { c.stopSession() } }
    }
}

struct KeepAwakeView: View {
    @ObservedObject private var c = KeepAwakeController.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var untilTime = Date().addingTimeInterval(3600)
    @State private var appChoice = ""

    private func binding<T>(_ kp: WritableKeyPath<KeepAwakeSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        statusSection
        startSection
        optionsSection
        automationSection
        lidSection
    }

    private var statusSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if c.snapshot.active { StatusLabel(c.snapshot.automationOn && !c.snapshot.closedLid ? "по условию" : "активен", color: .green) }
                    Button(c.snapshot.active ? "Выключить" : "Включить") { c.toggle() }
                }
            } label: {
                Label {
                    SettingLabel(c.snapshot.status, c.snapshot.batterySuppressed ? "Заряд ниже порога: автоматика приостановлена" : "Сон системы" + (c.settings.allowDisplaySleep ? " запрещён, экран может гаснуть" : " и экрана запрещён"))
                } icon: { Image(systemName: c.snapshot.active ? c.settings.iconKind.symbolOn : c.settings.iconKind.symbolOff) }
            }
        } header: { Text("Keep Awake") }
    }

    private var startSection: some View {
        Section {
            Menu("Включить на время") {
                ForEach(KeepAwakeSettings.presetMinutes, id: \.self) { m in
                    Button(KeepAwakeFormat.duration(minutes: m)) { c.startSession(minutes: m, closedLid: c.closedLidForNext) }
                }
                Divider()
                Button("Бессрочно") { c.startSession(minutes: 0, closedLid: c.closedLidForNext) }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    DatePicker("До", selection: $untilTime, displayedComponents: .hourAndMinute).labelsHidden()
                    Button("Включить") {
                        let cal = Calendar.current
                        let h = cal.component(.hour, from: untilTime), m = cal.component(.minute, from: untilTime)
                        if let d = KeepAwakeUntil.next(hour: h, minute: m, after: Date()) { c.startUntil(d, closedLid: c.closedLidForNext) }
                    }
                }
            } label: { Text("До времени") }
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("Приложение", selection: $appChoice) {
                        Text("Выбери приложение").tag("")
                        ForEach(runningApps(), id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Включить") { if !appChoice.isEmpty { c.startUntilAppQuits(appChoice, closedLid: c.closedLidForNext) } }
                        .disabled(appChoice.isEmpty)
                }
            } label: { Text("Пока работает приложение") }
            Toggle(isOn: $c.closedLidForNext) { SettingLabel("С закрытой крышкой", "Отключает сон полностью, лучше от сети") }
                .disabled(c.ctlState != .ready)
        } header: { Text("Запустить") }
    }

    private var optionsSection: some View {
        Section {
            ToggleSetting(title: "Включать при запуске Мультитула", isOn: binding(\.autoStart))
            Picker(selection: binding(\.defaultMinutes)) {
                Text("Бессрочно").tag(0)
                ForEach(KeepAwakeSettings.presetMinutes, id: \.self) { Text(KeepAwakeFormat.duration(minutes: $0)).tag($0) }
            } label: { SettingLabel("Длительность по умолчанию", "Для горячей клавиши, клика по значку и автозапуска") }
            ToggleSetting(title: "Разрешить гаснуть экрану", subtitle: "Запрещается только сон системы; экран гаснет по обычным правилам", isOn: binding(\.allowDisplaySleep))
            ToggleSetting(title: "Показывать остаток рядом со значком", isOn: binding(\.showRemaining))
            ToggleSetting(title: "Оповещать об окончании", subtitle: "Таймер, закрытое приложение, предел крышки", isOn: binding(\.notifyOnEnd))
            Picker(selection: binding(\.batteryLimitPercent)) {
                ForEach(KeepAwakeSettings.batteryChoices, id: \.self) { Text($0 == 0 ? "Никогда" : "ниже \($0)%").tag($0) }
            } label: { SettingLabel("Защита батареи", "От аккумулятора ниже порога Keep Awake выключается и не включается") }
            ToggleSetting(title: "Лёгкое подёргивание курсора", subtitle: "Сдвиг на 1 пиксель и назад: чтобы мессенджеры не ставили «отошёл». Нужен «Универсальный доступ»", isOn: binding(\.jiggleEnabled))
            if c.settings.jiggleEnabled {
                Picker("Подёргивать раз в", selection: binding(\.jiggleMinutes)) {
                    ForEach(KeepAwakeSettings.jiggleChoices, id: \.self) { Text("\($0) мин").tag($0) }
                }
            }
            Picker("Вид значка", selection: binding(\.iconKind)) {
                ForEach(KeepAwakeIconKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Цвет значка, когда активен", selection: binding(\.iconTint)) {
                ForEach(KeepAwakeIconTint.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: { Text("Параметры") }
    }

    private var automationSection: some View {
        Section {
            Toggle("Подключён внешний монитор", isOn: binding(\.autoExternalDisplay))
            Toggle("Подключено питание", isOn: binding(\.autoOnPower))
            Toggle("Работает одно из выбранных приложений", isOn: binding(\.autoApps))
            if c.settings.autoApps {
                ForEach(c.settings.autoAppBundleIDs, id: \.self) { id in
                    LabeledContent {
                        Button("Убрать") { var s = c.settings; s.autoAppBundleIDs.removeAll { $0 == id }; c.update(s) }
                    } label: { Text(appName(id)) }
                }
                Menu("Добавить запущенное приложение") {
                    ForEach(runningApps(), id: \.id) { a in
                        Button(a.name) { var s = c.settings; s.autoAppBundleIDs.append(a.id); c.update(s) }
                    }
                }
            }
            if c.settings.automationEnabled {
                Picker("Сочетание условий", selection: Binding(get: { c.settings.match }, set: { var s = c.settings; s.match = $0; c.update(s) })) {
                    ForEach(KeepAwakeMatch.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } header: { Text("Автоматика") } footer: {
            SectionFooter("Keep Awake включается сам, пока выполняется условие.")
        }
    }

    private var lidSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    switch c.ctlState {
                    case .unknown: Text("проверяю…").foregroundStyle(.secondary)
                    case .ready: StatusLabel("доступна", color: .green)
                    case .missing: StatusLabel("не настроена", color: .orange)
                    }
                    Button("Проверить") { c.checkCtl() }
                }
            } label: { Text("Состояние") }
            if case .missing(let why) = c.ctlState {
                ToolWarning(text: "Нужен хелпер multitul-ctl и правило sudo (app/root/install-root.sh, один раз с паролем администратора). \(why)")
            }
            if c.foreignSleepDisabled {
                ToolWarning(text: "Сон отключён не Мультитулом (pmset disablesleep = 1). Мультитул это не трогает.")
            }
            ToggleSetting(title: "Гасить встроенный экран при закрытой крышке", subtitle: "Яркость уходит в ноль и возвращается при открытии, выключении и следующем запуске после сбоя", isOn: binding(\.dimOnLidClosed))
            Picker(selection: binding(\.lidMaxHours)) {
                ForEach(KeepAwakeSettings.lidLimitChoices, id: \.self) { Text($0 == 0 ? "Без предела" : "\($0) ч").tag($0) }
            } label: { SettingLabel("Предел времени с закрытой крышкой", "Предохранитель: сон возвращается сам") }
        } header: { Text("Закрытая крышка") } footer: {
            SectionFooter("Режим включает pmset disablesleep через multitul-ctl. Если Мультитул упал, при следующем запуске сон возвращается. Закрытый Mac в сумке нагревается: лучше от сети.")
        }
    }

    private func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != getpid() }
            .compactMap { a in a.bundleIdentifier.map { (id: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
    }
}
