import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

private struct PermissionNote: View {
    let needsRecording: Bool

    var body: some View {
        if needsRecording && !SCKRecordingProbe.granted {
            ToolWarning(text: "Нет доступа «Запись экрана»: вместо превью показываются значки приложений, заголовки окон других приложений тоже могут быть пустыми. Выдай доступ на странице «Права».")
        }
    }
}

enum SCKRecordingProbe {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }
}

struct AppRulesEditor: View {
    @Binding var rules: AppRules

    var body: some View {
        NavigationLink(value: WindowsRoute.switcherRules) {
            LabeledContent {
                Text(rules.isEmpty ? "нет" : "\(rules.sortedKeys.count)")
            } label: { SettingLabel("Правила для приложений", "Как приложение появляется в переключателе. Без правила работают общие настройки выше.") }
        }
    }
}

struct SwitcherRulesPage: View {
    @ObservedObject private var c = SwitcherController.shared

    var body: some View {
        AppRulesPage(rules: Binding(get: { c.settings.rules }, set: { v in var s = c.settings; s.rules = v; c.update(s) }))
    }
}

private struct AppRulesPage: View {
    @Binding var rules: AppRules

    var body: some View {
        SettingsPage {
            Section {
                if rules.isEmpty { EmptyHint(text: "Правил нет", symbol: "app.dashed") }
                ForEach(rules.sortedKeys, id: \.self) { bid in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Picker("Поведение", selection: Binding(get: { rules[bid] ?? .windowsOnly }, set: { v in var r = rules; r.set(bid, v); rules = r })) {
                                ForEach(AppRuleBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button { var r = rules; r.set(bid, nil); rules = r } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    } label: { SettingLabel(appName(bid), appName(bid) == bid ? nil : bid) }
                }
            } footer: { SectionFooter("Как приложение появляется в переключателе. Без правила работают общие настройки.") }
            Section {
                Button("Добавить приложение…") {
                    if let bid = InputShared.shared.chooseApp() { var r = rules; r.set(bid, .windowsOnly); rules = r }
                }
            }
        }
    }
}

struct SwitcherView: View {
    @ObservedObject private var c = SwitcherController.shared

    private func binding<T>(_ kp: WritableKeyPath<SwitcherSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var columnsBinding: Binding<Int> {
        Binding(get: { c.settings.maxColumns == 0 ? 1 : c.settings.maxColumns }, set: { v in var s = c.settings; s.maxColumns = v <= 1 ? 0 : v; c.update(s) })
    }

    private func comboBinding(_ kp: WritableKeyPath<SwitcherSettings, KeyCombo>) -> Binding<KeyCombo?> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in
            guard let v, SwitcherSettings.isUsableTrigger(v) else { return }
            var s = c.settings; s[keyPath: kp] = v; c.update(s)
        })
    }

    var body: some View {
        ModuleSection(title: "Переключатель окон", subtitle: "\(c.settings.effectiveAppsTrigger.display) листает окна, \(c.settings.effectiveWindowsTrigger.display) окна текущего приложения. Держишь, листаешь, отпускаешь.",
                      ready: c.healthy, readyText: c.holdingNative ? "⌘Tab заменён" : "работает", onAppear: { c.refreshStatus() }) {
            WindowNotices(c: c)
            PermissionNote(needsRecording: c.settings.layout == .windows)
            if let n = c.takeoverNote { ToolWarning(text: n) }
            ChoiceSetting(title: "Вид", subtitle: "Простой список обходится без права «Запись экрана»", options: SwitcherLayout.allCases, label: { $0.title }, value: binding(\.layout))
            ToggleSetting(title: "Заменить системные ⌘Tab и ⌘`", subtitle: "Системный переключатель отключается на время работы модуля и возвращается при выключении, выходе и после сбоя. Выключишь: задай свои сочетания", isOn: binding(\.takeOverSystem))
            if !c.settings.takeOverSystem {
                LabeledContent {
                    ComboField(combo: comboBinding(\.appsTrigger))
                } label: { SettingLabel("Сочетание для приложений", "Нужен ⌘, ⌥ или ⌃: его держишь, пока листаешь") }
                LabeledContent {
                    ComboField(combo: comboBinding(\.windowsTrigger))
                } label: { SettingLabel("Сочетание для окон приложения", "Только окна приложения, которое сейчас впереди") }
            }
            ValueSlider(symbol: "timer", title: "Задержка появления", subtitle: "Быстрое нажатие и отпускание переключает без панели", unit: "мс", range: SwitcherSettings.delayRange, value: binding(\.appearanceDelayMs), step: 25)
            if c.settings.layout == .windows {
                ChoiceSetting(title: "Размер превью", subtitle: nil, options: PreviewSize.allCases, label: { $0.title }, value: binding(\.previewSize))
            }
            ToggleSetting(title: "Подсказки клавиш", subtitle: "Строка с W, Q, M, H, S внизу панели", isOn: binding(\.showShortcutHints))
            ExceptionsEditor(title: "Приложения без превью", subtitle: "Для них вместо миниатюры значок: не снимаем картинку окна (пароли, банк, приватные чаты)", list: binding(\.previewExcluded))
            AppRulesEditor(rules: binding(\.rules))
        }
        Section {
            LabeledContent {
                Stepper(value: columnsBinding, in: 1...SwitcherSettings.columnsRange.upperBound) { Text(c.settings.maxColumns == 0 ? "авто" : "\(c.settings.maxColumns)").monospacedDigit() }
            } label: { SettingLabel("Максимум столбцов", c.settings.maxColumns == 0 ? "Автоматически по ширине экрана" : "Не больше \(c.settings.maxColumns) в ряду") }
            if c.settings.layout == .windows {
                ToggleSetting(title: "Минимальные превью", subtitle: "Без подписей под миниатюрами", isOn: binding(\.minimalPreviews))
            }
            ToggleSetting(title: "Поиск закрепляет панель", subtitle: "S начинает поиск по названию окна или приложения, панель остаётся открытой после отпускания клавиши; Return выбирает, Esc очищает. Раскладка не важна", isOn: binding(\.searchPin))
            ToggleSetting(title: "Выбор без анимации", subtitle: "Выделение и прокрутка перескакивают сразу, панель появляется без плавности", isOn: binding(\.instantSelection))
            ToggleSetting(title: "Одно окно на приложение", subtitle: "Все окна приложения склеиваются в одну позицию списка (значки приложений делают это сами)", isOn: binding(\.mergeWindows))
            ToggleSetting(title: "Показывать окна в полноэкранном режиме", subtitle: "Полноэкранные окна других столов остаются в списке", isOn: binding(\.showFullscreen))
            ChoiceSetting(title: "Свёрнутые окна", subtitle: nil, options: MinimizedPlacement.allCases, label: { $0.title }, value: binding(\.minimized))
            if c.settings.minimized != .normal {
                ToggleSetting(title: "Спрятанные приложения считать свёрнутыми", subtitle: "Окна скрытых через ⌘H приложений идут по тому же правилу, что и свёрнутые", isOn: binding(\.hiddenLikeMinimized))
            }
            ChoiceSetting(title: "На каком экране панель", subtitle: nil, options: SwitcherScreenPlacement.allCases, label: { $0.title }, value: binding(\.screenPlacement))
            ToggleSetting(title: "Только окна текущего дисплея", subtitle: "Дисплей выбирается по правилу выше", isOn: binding(\.currentDisplayOnly))
            ToggleSetting(title: "Только окна текущего рабочего стола", subtitle: "Полноэкранные окна других столов остаются, пока включён показ полноэкранных", isOn: binding(\.currentSpaceOnly))
            if !c.settings.takeOverSystem {
                ChoiceSetting(title: "Приложения без окон", subtitle: nil, options: WindowlessApps.allCases, label: { $0.title }, value: binding(\.windowless))
            }
        } header: { Text("Переключатель: дополнительно") } footer: {
            SectionFooter((c.settings.takeOverSystem ? "Приложения без окон показываются все, как в системном ⌘Tab (пока заменяется системный переключатель). " : "") + "Внутри переключателя: ⇧⇥ или ← назад, ↑↓ по строкам, W закрыть окно, Q выйти из приложения, M свернуть или вернуть, H спрятать приложение, S поиск, Esc отмена. Клик по миниатюре выбирает её.")
        }
    }
}

struct DockPreviewView: View {
    @ObservedObject private var c = DockPreviewController.shared

    private func binding<T>(_ kp: WritableKeyPath<DockPreviewSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Превью окон из Dock", subtitle: "Наведи курсор на значок запущенного приложения. Показано с запуска: \(c.shown). Правый клик по миниатюре: свернуть, на другой дисплей, левая или правая половина, на весь экран, закрыть окно, выйти из приложения.", ready: c.healthy, onAppear: { c.refreshStatus() }) {
            WindowNotices(c: c)
            PermissionNote(needsRecording: true)
            ValueSlider(symbol: "timer", title: "Задержка появления", subtitle: "Сколько курсор должен постоять на значке", unit: "мс", range: DockPreviewSettings.openDelayRange, value: binding(\.openDelayMs), step: 50)
            ValueSlider(symbol: "timer.circle", title: "Задержка скрытия", subtitle: "Время дойти курсором от значка до панели", unit: "мс", range: DockPreviewSettings.closeDelayRange, value: binding(\.closeDelayMs), step: 50)
            ValueSlider(symbol: "circle.lefthalf.filled", title: "Прозрачность панели", subtitle: nil, unit: "%", range: DockPreviewSettings.opacityRange, value: binding(\.opacityPercent), step: 5)
            ChoiceSetting(title: "Размер превью", subtitle: nil, options: PreviewSize.allCases, label: { $0.title }, value: binding(\.previewSize))
            ToggleSetting(title: "Минимальные превью", subtitle: "Без подписей под миниатюрами", isOn: binding(\.minimalPreviews))
            ToggleSetting(title: "Подписи окон", subtitle: "Название окна под миниатюрой", isOn: binding(\.showTitles))
            ToggleSetting(title: "Только окна текущего рабочего стола", subtitle: "Выключено: окна со всех столов", isOn: binding(\.currentSpaceOnly))
            ToggleSetting(title: "Показывать свёрнутые окна", subtitle: "Клик по свёрнутому вернёт его", isOn: binding(\.showMinimized))
            ChoiceSetting(title: "Порядок окон", subtitle: nil, options: DockPreviewOrder.allCases, label: { $0.title }, value: binding(\.order))
            ToggleSetting(title: "× закрывает всё приложение", subtitle: "Крестик на миниатюре завершает приложение целиком, а не одно окно", isOn: binding(\.quitAppOnClose))
            ToggleSetting(title: "Средняя кнопка закрывает окно", subtitle: "Клик колесом по миниатюре", isOn: binding(\.middleClickCloses))
            ExceptionsEditor(title: "Исключения", subtitle: "Для этих приложений панель при наведении на значок не появляется", list: binding(\.exceptions))
            ExceptionsEditor(title: "Приложения без превью", subtitle: "Показываем значок вместо картинки окна", list: binding(\.previewExcluded))
        }
    }
}
