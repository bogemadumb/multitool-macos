import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class MonitorToggleController: ObservableObject {
    static let shared = MonitorToggleController()

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    @Published private(set) var canSwitch = true

    private let provider = CGSDisplayProvider()
    private var observer: NSObjectProtocol?
    private var service: MonitorToggleService { MonitorToggleService(provider: provider, protectedIDs: { TvProtectedDisplays.ids }) }
    var spec: HotkeySpec { ModuleID.monitorToggle.info.hotkeys[0] }
    var state: MonitorState { MonitorLogic.state(displays) }

    func start() {
        canSwitch = provider.canSwitch
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        HotkeyManager.shared.register(spec, owner: ModuleID.monitorToggle.rawValue) { [weak self] in self?.run(.toggle, hud: true) }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        HotkeyManager.shared.unregisterAll(owner: ModuleID.monitorToggle.rawValue)
    }

    func refresh() { displays = service.snapshot() }

    func run(_ cmd: MonitorCommand, hud: Bool = false) {
        let r = service.run(cmd)
        message = r.message
        isError = r.isFailure
        Log.write("monitorToggle \(cmd.rawValue) -> \(r)")
        if hud { HUD.show(r.isFailure ? "Монитор: " + r.message : "Монитор: " + r.message) }
        refresh()
    }
}

@MainActor
final class MonitorToggleModule: Module {
    let info = ModuleID.monitorToggle.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(MonitorToggleTile()) }
    var panelPresentation: PanelPresentation { .module }

    func start() {
        MonitorToggleController.shared.start()
        Log.write("module monitorToggle start")
    }

    func stop() {
        MonitorToggleController.shared.stop()
        Log.write("module monitorToggle stop")
    }
}

struct MonitorToggleTile: View {
    @ObservedObject private var c = MonitorToggleController.shared

    var body: some View {
        ModuleTile(symbol: "display", title: "Монитор", status: c.state == .on ? "Включён" : "Выключен", active: c.state == .on, enabled: c.canSwitch) {
            c.run(.toggle)
        }
    }
}

struct MonitorToggleView: View {
    @ObservedObject private var c = MonitorToggleController.shared

    var body: some View {
        Section {
            LabeledContent("Состояние") {
                StatusLabel(c.state == .on ? "включён" : "выключен", color: c.state == .on ? .green : .secondary)
            }
            if !c.canSwitch {
                ToolWarning(text: "Системная функция CGSConfigureDisplayEnabled в этой версии macOS не найдена: переключение недоступно.")
            }
            if let m = c.message {
                if c.isError { ToolWarning(text: m) } else { Text(m).foregroundStyle(.secondary) }
            }
            Button("Выключить") { c.run(.off) }
            Button("Включить") { c.run(.on) }
            Button("Переключить") { c.run(.toggle) }
            Button("Обновить") { c.refresh() }
        } header: { Text(c.state == .on ? "Внешний монитор включён" : "Внешний монитор выключен") } footer: {
            SectionFooter("Убирает экран из раскладки macOS: окна и курсор не уезжают на выключенный монитор. Подсветку не гасит. Если монитор не вернулся: двойной клик по «вернуть-монитор.command» в папке app/tools проекта; не помогло: вынуть и вставить переходник USB-C.")
        }
        Section("Дисплеи") {
            ForEach(MonitorLogic.statusLines(c.displays).dropLast(), id: \.self) { line in
                Text(line).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .onAppear { c.refresh() }
    }
}
