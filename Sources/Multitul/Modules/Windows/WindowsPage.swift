import SwiftUI
import MultitulCore
import MultitulUI

struct WindowsPage: View {
    var enabled: Set<ModuleID> = []
    var extras: [Module] = []

    var body: some View {
        SettingsPage {
            if enabled.contains(.windowLayout) { WindowLayoutView() }
            if enabled.contains(.windowSwitcher) { SwitcherView() }
            if enabled.contains(.dockPreview) { DockPreviewView() }
            if enabled.contains(.windowMaximizer) { MaximizerView() }
            if enabled.contains(.autoQuit) { AutoQuitView() }
            if enabled.contains(.dockClick) { DockClickView() }
            if enabled.contains(.spacesOrder) { SpacesOrderView() }
            ForEach(extras, id: \.info.id) { m in
                Section(m.info.title) { m.settingsView }
            }
        }
        .navigationDestination(for: WindowsRoute.self) { route in
            switch route {
            case .shortcuts: WindowShortcutsPage().navigationTitle("Сочетания раскладки")
            case .customLayouts: WindowCustomLayoutsPage().navigationTitle("Свои макеты")
            case .snapZones: WindowSnapZonesPage().navigationTitle("Зоны краёв")
            case .switcherRules: SwitcherRulesPage().navigationTitle("Правила для приложений")
            }
        }
    }
}

struct MaximizerView: View {
    @ObservedObject private var c = MaximizerController.shared

    private func binding<T>(_ kp: WritableKeyPath<MaximizerSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Зелёная кнопка: максимум", subtitle: "Развернуто: \(c.maximized), возвращено: \(c.restored). Option+клик: обычное поведение macOS.", ready: c.healthy, onAppear: { c.refreshStatus() }) {
            WindowNotices(c: c)
            ToggleSetting(title: "Второй клик возвращает размер", subtitle: "Окно уже на весь экран: клик по зелёной кнопке вернёт прежние размер и место", isOn: binding(\.toggleRestores))
            ValueSlider(symbol: "rectangle.inset.filled", title: "Отступ от краёв", subtitle: "Окно разворачивается с отступом от краёв рабочей области", unit: "пт", range: MaximizerSettings.insetRange, value: binding(\.inset))
            ExceptionsEditor(title: "Где кнопка остаётся стандартной", subtitle: "Игры, эмуляторы, видеоплееры: в них зелёная кнопка уводит в полноэкранный режим", list: binding(\.excluded), resetTo: AppExceptionList(MaximizerSettings.suggestedExcluded))
        }
    }
}

struct AutoQuitView: View {
    @ObservedObject private var c = AutoQuitController.shared

    var body: some View {
        ModuleSection(title: "Выход при закрытии последнего окна", subtitle: "Слежу за приложениями: \(c.watched). Завершено с запуска: \(c.quitCount). Всегда в исключениях: \(AutoQuitSettings.mandatoryExceptions.map(appName).joined(separator: ", ")). Приложения без Dock-значка (утилиты в строке меню), спрятанные приложения, свёрнутые окна и окна на других столах приложение не закрывают.", ready: c.trusted, onAppear: { c.refreshStatus() }) {
            if !c.trusted {
                ToolWarning(text: "Нужен «Универсальный доступ»: без него не видно, когда закрывается окно.")
                Button("Повторить") { c.retry() }
            }
            ValueSlider(symbol: "timer", title: "Пауза перед выходом", subtitle: "Столько ждём после закрытия окна: за это время успевает появиться диалог «Сохранить?»", unit: "мс", range: AutoQuitSettings.delayRange, value: Binding(get: { c.settings.delayMs }, set: { v in var s = c.settings; s.delayMs = v; c.update(s) }), step: 50)
            ExceptionsEditor(title: "Исключения", subtitle: "Эти приложения не завершаются, когда закрыто последнее окно", list: Binding(get: { c.settings.exceptions }, set: { v in var s = c.settings; s.exceptions = v; c.update(s) }))
        }
    }
}

struct DockClickView: View {
    @ObservedObject private var c = DockClickController.shared

    private func binding<T>(_ kp: WritableKeyPath<DockClickSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Клик по значку в Dock", subtitle: "Сработало с запуска: \(c.handled).", ready: c.healthy, onAppear: { c.refreshStatus() }) {
            WindowNotices(c: c)
            Picker(selection: binding(\.mode)) {
                ForEach(DockClickMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Клик по значку активного приложения", "Что делать, когда нажимаешь на значок приложения, которое уже впереди") }
            ToggleSetting(title: "Перебирать окна по кругу", subtitle: "Если у приложения два окна и больше, клик по значку выводит следующее, как ⌘`", isOn: binding(\.cycleWindows))
            ExceptionsEditor(title: "Исключения", subtitle: "Для этих приложений клик по значку остаётся стандартным", list: binding(\.exceptions))
        }
    }
}

struct SpacesOrderView: View {
    @ObservedObject private var c = SpacesOrderController.shared

    var body: some View {
        Section {
            LabeledContent("Состояние") { StatusLabel(c.holding ? "держу порядок" : "не держу", color: c.holding ? .green : .secondary) }
            if let m = c.message {
                ToolWarning(text: m)
                Button("Проверить") { c.recheck() }
            }
        } header: { Text("Фиксированный порядок рабочих столов") } footer: {
            SectionFooter("Desktop 1, 2, 3 стоят на своих местах и не переставляются по последнему использованию. Модуль выключает в Dock настройку «Автоматически переупорядочивать Spaces» и один раз перезапускает Dock (на секунду мигнёт панель). Что было до этого, запоминается; при выключении модуля настройка возвращается. Если порядок включить обратно в Системных настройках, модуль это заметит и отпустит настройку.")
        }
    }
}
