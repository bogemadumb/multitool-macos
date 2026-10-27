import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class GameModeController: ObservableObject {
    static let shared = GameModeController()

    @Published private(set) var settings = GameModeSettings()
    @Published private(set) var isOn = false
    @Published private(set) var legacyActive = false
    @Published private(set) var busy = false

    private let store = GameModeSettingsStore()
    private let state = GameModeFileState()
    private var engine: GameModeEngine?
    private var poll: Timer?
    private let queue = DispatchQueue(label: "dev.multitool.app.gamemode")

    var spec: HotkeySpec { GameModeHotkeys.toggle }

    func start() {
        guard engine == nil else { return }
        settings = store.load()
        engine = GameModeEngine(store: state, settings: { [store] in store.load() }, notify: { text in
            Notifier.shared.post(title: "Игровой режим", body: text, id: "gamemode")
        })
        refresh()
        HotkeyManager.shared.register(spec, owner: ModuleID.gameMode.rawValue) { [weak self] in self?.toggle() }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.gameMode.rawValue)
        engine = nil
    }

    func refresh() {
        isOn = state.load().active
        legacyActive = GameModeLegacy.isActive()
    }

    func toggle() {
        guard let e = engine, !busy else { return }
        busy = true
        queue.async {
            let r = e.toggle()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.refresh()
                    Log.write("gameMode toggle -> \(r)")
                }
            }
        }
    }

    func update(_ s: GameModeSettings) {
        settings = s.sanitized
        store.save(settings)
    }
}

@MainActor
final class GameModeModule: Module {
    let info = ModuleID.gameMode.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(GameModeTile()) }
    var panelPresentation: PanelPresentation { .module }

    func start() {
        GameModeController.shared.start()
        Log.write("module gameMode start")
    }

    func stop() {
        GameModeController.shared.stop()
        Log.write("module gameMode stop")
    }
}

struct GameModeTile: View {
    @ObservedObject private var c = GameModeController.shared

    var body: some View {
        ModuleTile(symbol: "gamecontroller.fill", title: "Игровой режим", status: c.isOn ? "Включён" : "Выключен", active: c.isOn) { c.toggle() }
    }
}

struct GameModeView: View {
    @ObservedObject private var c = GameModeController.shared
    @State private var newAppName = ""
    @State private var newAppID = ""
    @State private var newLabel = ""
    @State private var newPattern = ""
    @State private var newPath = ""

    private func binding<T>(_ kp: WritableKeyPath<GameModeSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    StatusLabel(c.isOn ? "вкл" : "выкл", color: c.isOn ? .green : .secondary)
                    Button(c.isOn ? "Выключить" : "Включить") { c.toggle() }.disabled(c.busy)
                }
            } label: { Label(c.isOn ? "Игровой режим включён" : "Игровой режим выключен", systemImage: "gamecontroller") }
            if c.legacyActive {
                ToolWarning(text: "Старый скрипт gamemode сейчас включён (флаг в Application Support/gamemode). Выключи его командой «gamemode off», иначе прежние углы не вернутся.")
            }
            ToggleSetting(title: "F1–F12 как обычные клавиши", subtitle: "fnState + activateSettings, без перелогина; при выключении возвращается прежнее значение", isOn: binding(\.fnKeys))
            ToggleSetting(title: "Отключить активные углы", subtitle: "Прежние значения сохраняются и возвращаются; Dock перезапускается", isOn: binding(\.disableCorners))
            if c.settings.disableCorners {
                ForEach(GameModeSettings.allCorners, id: \.self) { corner in
                    Toggle(cornerTitle(corner), isOn: Binding(get: { c.settings.corners.contains(corner) },
                                                              set: { on in var s = c.settings; s.corners.removeAll { $0 == corner }; if on { s.corners.append(corner) }; c.update(s) }))
                        .toggleStyle(.checkbox)
                }
            }
            ToggleSetting(title: "Уведомление при включении и выключении", isOn: binding(\.notify))
        } header: { Text("Игровой режим") } footer: {
            SectionFooter("Выключение возвращает прежние углы, F-клавиши и закрытые программы." + (c.isOn ? " Менять списки ниже можно после выключения: возврат идёт по тому, что закрыли при включении." : "") + " Консольная замена старой команде: Multitul --gamemode on | off | toggle | status.")
        }
        .onAppear { c.refresh() }
        agentsSection
        appsSection
    }

    private func cornerTitle(_ c: String) -> String {
        switch c {
        case "tl": "↖ левый верх"
        case "tr": "↗ правый верх"
        case "bl": "↙ левый низ"
        default: "↘ правый низ"
        }
    }

    private var agentsSection: some View {
        Section {
            ForEach(c.settings.agents, id: \.self) { a in
                LabeledContent {
                    Button("Убрать") { var s = c.settings; s.agents.removeAll { $0 == a }; c.update(s) }.disabled(c.isOn)
                } label: { SettingLabel(a.title, "\(a.launchLabel), \(a.relaunchPath)") }
            }
            FieldSetting("launchd-метка", text: $newLabel)
            FieldSetting("Имя процесса", text: $newPattern)
            FieldSetting("Путь к программе", text: $newPath, prompt: "/путь/к/Helper.app")
            Button("Добавить") {
                let a = GameModeAgent(launchLabel: newLabel.trimmingCharacters(in: .whitespaces), processPattern: newPattern.trimmingCharacters(in: .whitespaces), relaunchPath: newPath.trimmingCharacters(in: .whitespaces))
                guard a.isValid else { return }
                var s = c.settings; s.agents.append(a); c.update(s)
                newLabel = ""; newPattern = ""; newPath = ""
            }
            .disabled(c.isOn)
        } header: { Text("Выгружаемые агенты (launchd)") } footer: {
            SectionFooter("На время режима выгружаются из launchd и завершаются; потом запускаются напрямую. Пример: Mac Mouse Fix, который забирал колёсико.")
        }
    }

    private var appsSection: some View {
        Section {
            ForEach(c.settings.apps, id: \.self) { a in
                LabeledContent {
                    Button("Убрать") { var s = c.settings; s.apps.removeAll { $0 == a }; c.update(s) }.disabled(c.isOn)
                } label: { SettingLabel(a.name, a.bundleID) }
            }
            FieldSetting("Имя процесса", text: $newAppName)
            FieldSetting("Bundle ID", text: $newAppID)
            Menu("Из запущенных") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? "?") { newAppName = app.localizedName ?? ""; newAppID = app.bundleIdentifier ?? "" }
                }
            }
            Button("Добавить") {
                let a = GameModeApp(name: newAppName.trimmingCharacters(in: .whitespaces), bundleID: newAppID.trimmingCharacters(in: .whitespaces))
                guard a.isValid else { return }
                var s = c.settings; s.apps.append(a); c.update(s)
                newAppName = ""; newAppID = ""
            }
            .disabled(c.isOn)
        } header: { Text("Закрываемые приложения") } footer: {
            SectionFooter("Закрываются при включении, при выключении запускаются снова в фоне. Пример: Atoll у выреза.")
        }
    }
}
