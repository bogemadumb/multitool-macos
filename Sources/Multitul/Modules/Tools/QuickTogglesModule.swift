import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class QuickTogglesController: ObservableObject {
    static let shared = QuickTogglesController()

    @Published private(set) var settings = QuickToggleSettings()
    @Published private(set) var darkMode = false
    @Published private(set) var iconsHidden = false
    @Published private(set) var busy: QuickToggleID?
    @Published private(set) var lastMessage = ""

    private let store = QuickToggleSettingsStore()
    private let driver = SystemToggleDriver()
    private let queue = DispatchQueue(label: "dev.multitool.app.quicktoggles", qos: .userInitiated)
    private var registry: QuickToggleRegistry

    private init() {
        registry = QuickToggleRegistry(driver: driver)
    }

    func start() {
        settings = store.load()
        registry = QuickToggleRegistry(driver: driver, settings: settings)
        refresh()
    }

    func refresh() {
        darkMode = registry.state(of: .darkMode) ?? false
        iconsHidden = registry.state(of: .desktopIcons) ?? false
    }

    func state(_ id: QuickToggleID) -> Bool {
        switch id {
        case .darkMode: darkMode
        case .desktopIcons: iconsHidden
        default: false
        }
    }

    func update(_ s: QuickToggleSettings) {
        settings = s.sanitized
        store.save(settings)
        registry.settings = settings
    }

    func perform(_ id: QuickToggleID, confirmed: Bool = false) {
        guard busy == nil else { return }
        busy = id
        let reg = registry
        queue.async { [weak self] in
            let result = reg.perform(id, confirmed: confirmed)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(id, result) } }
        }
    }

    private func finish(_ id: QuickToggleID, _ result: QuickToggleResult) {
        busy = nil
        refresh()
        lastMessage = result.message
        Log.write("quickToggles \(id.rawValue): \(result.message)")
        if case .needsConfirmation(let prompt) = result {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = prompt
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Очистить")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn { perform(id, confirmed: true) }
            return
        }
        if settings.showHud { HUD.show(result.message) }
    }
}

@MainActor
final class QuickTogglesModule: Module {
    let info = ModuleID.quickToggles.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var panelCard: AnyView? { AnyView(QuickTogglesGrid()) }

    func start() {
        QuickTogglesController.shared.start()
        Log.write("module quickToggles start")
    }

    func stop() { Log.write("module quickToggles stop") }
}

struct QuickTogglesGrid: View {
    @ObservedObject private var c = QuickTogglesController.shared

    var body: some View {
        let ids = c.settings.enabled
        if !ids.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ids) { id in
                    QuickTile(symbol: id.symbol, caption: id.caption, active: id.isSwitch && c.state(id), help: id.title) { c.perform(id) }
                }
            }
        }
    }
}

struct QuickTogglesSections: View {
    @ObservedObject private var c = QuickTogglesController.shared

    private func isOn(_ id: QuickToggleID) -> Binding<Bool> {
        Binding(get: { c.settings.enabled.contains(id) }, set: { on in
            var s = c.settings
            if on { s.enabled = QuickToggleID.allCases.filter { s.enabled.contains($0) || $0 == id } } else { s.enabled.removeAll { $0 == id } }
            c.update(s)
        })
    }

    var body: some View {
        Section {
            ForEach(QuickToggleID.allCases) { id in
                LabeledContent {
                    HStack(spacing: 12) {
                        Button(id.isSwitch ? "Переключить" : "Выполнить") { c.perform(id) }.disabled(c.busy != nil)
                        Toggle("Показывать в панели menu bar", isOn: isOn(id)).labelsHidden().help("Показывать в панели menu bar")
                    }
                } label: {
                    Label {
                        SettingLabel(id.title, id.summary)
                    } icon: { Image(systemName: id.symbol) }
                }
            }
        } header: { Text("Быстрые переключатели") } footer: {
            SectionFooter("Действия живут в панели menu bar и в быстрой палитре; переключатель справа показывает действие в панели. Очистка Корзины идёт через Finder: при первом запуске macOS спросит разрешение на «Автоматизацию». Подсчёт предметов в Корзине требует «Полный доступ к диску», без него подтверждение будет без числа.")
        }
        Section {
            Toggle(isOn: Binding(get: { c.settings.confirmTrash }, set: { v in var s = c.settings; s.confirmTrash = v; c.update(s) })) { SettingLabel("Подтверждать очистку Корзины", "Спрашивает перед удалением; выключи, если нужна очистка одним кликом") }
            Toggle(isOn: Binding(get: { c.settings.showHud }, set: { v in var s = c.settings; s.showHud = v; c.update(s) })) { SettingLabel("Показывать плашку", "Короткая надпись на экране с результатом") }
            if c.busy != nil { LabeledContent("Состояние", value: "выполняется") }
            if !c.lastMessage.isEmpty { LabeledContent("Последнее", value: c.lastMessage) }
        } header: { Text("Параметры переключателей") }
        .onAppear { c.refresh() }
    }
}
