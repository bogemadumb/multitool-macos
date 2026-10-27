import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct InputPage: View {
    var enabled: Set<ModuleID> = []
    var extras: [Module] = []

    private var hasLinks: Bool { enabled.contains(.mouseNavigation) || enabled.contains(.mouseButtonShortcuts) || enabled.contains(.textSnippets) }

    var body: some View {
        SettingsPage {
            if enabled.contains(.scrollInverter) { ScrollInverterView() }
            if enabled.contains(.scrollHorizontal) { HorizontalScrollView() }
            if enabled.contains(.smoothScroll) { SmoothScrollView() }
            if enabled.contains(.linearScroll) { LinearScrollView() }
            if enabled.contains(.scrollZoom) { ScrollZoomView() }
            if enabled.contains(.mouseAcceleration) { MouseAccelerationView() }
            if enabled.contains(.focusFollowsMouse) { FocusFollowsView() }
            if enabled.contains(.mouseClickDebounce) { ClickDebounceView() }
            if enabled.contains(.keyboardDebounce) { KeyDebounceView() }
            if enabled.contains(.middleClick) { MiddleClickView() }
            if enabled.contains(.superKey) { SuperKeyView() }
            if enabled.contains(.quitProtection) { QuitProtectionView() }
            if hasLinks {
                Section("Подробнее") {
                    if enabled.contains(.mouseNavigation) {
                        NavigationLink(value: InputRoute.mouseButtons) { Text("Боковые кнопки мыши") }
                    }
                    if enabled.contains(.mouseButtonShortcuts) {
                        NavigationLink(value: InputRoute.buttonActions) { Text("Действия на кнопки мыши") }
                    }
                    if enabled.contains(.textSnippets) {
                        NavigationLink(value: InputRoute.snippets) { Text("Быстрые вставки текста") }
                    }
                }
            }
            ForEach(extras, id: \.info.id) { m in
                Section(m.info.title) { m.settingsView }
            }
        }
        .navigationDestination(for: InputRoute.self) { route in
            switch route {
            case .mouseButtons: SettingsPage { MouseNavigationView() }.navigationTitle("Боковые кнопки мыши")
            case .buttonActions: SettingsPage { ButtonShortcutsView() }.navigationTitle("Действия на кнопки мыши")
            case .snippets: SettingsPage { SnippetsView() }.navigationTitle("Быстрые вставки текста")
            }
        }
    }
}

struct InputNotices: View {
    @ObservedObject var c: InputTapController
    var trustNeeded = true

    var body: some View {
        if trustNeeded && (!c.trusted || !c.tapActive) {
            ToolWarning(text: "Нужен «Универсальный доступ» (для фильтра клавиатуры ещё «Мониторинг ввода»): без него события не видны. Выдай доступ на странице «Права» и нажми «Повторить».")
            Button("Повторить") { c.restart(); c.refreshStatus() }
        }
        if !c.conflicts.isEmpty {
            ToolWarning(text: "Запущено: \(c.conflicts.joined(separator: ", ")). Оно тоже меняет прокрутку или курсор, результат может удваиваться. Игровой режим закрывает Mac Mouse Fix на время игры.")
        }
    }
}

struct ValueSlider: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let unit: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    var step = 1

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                    .frame(minWidth: 110, maxWidth: 200)
                Text("\(value) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 64, alignment: .trailing)
            }
        } label: { SettingLabel(title, subtitle) }
    }
}

func appName(_ bundleID: String) -> String {
    if bundleID.hasSuffix("*") { return bundleID }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
    return bundleID
}

struct ExceptionsEditor: View {
    let title: String
    let subtitle: String
    @Binding var list: AppExceptionList
    var resetTo: AppExceptionList?

    var body: some View {
        NavigationLink {
            ExceptionsPage(title: title, subtitle: subtitle, list: $list, resetTo: resetTo).navigationTitle(title)
        } label: {
            LabeledContent {
                Text(list.isEmpty ? "нет" : "\(list.entries.count)")
            } label: { SettingLabel(title, subtitle) }
        }
    }
}

struct ExceptionsPage: View {
    let title: String
    let subtitle: String
    @Binding var list: AppExceptionList
    var resetTo: AppExceptionList?

    var body: some View {
        SettingsPage {
            Section {
                if list.isEmpty { EmptyHint(text: "Список пуст: функция работает во всех приложениях", symbol: "app.dashed") }
                ForEach(list.entries, id: \.self) { bid in
                    LabeledContent {
                        Button { var l = list; l.remove(bid); list = l } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    } label: { SettingLabel(appName(bid), appName(bid) == bid ? nil : bid) }
                }
            } header: { Text(title) } footer: { SectionFooter(subtitle) }
            Section {
                Button("Добавить приложение…") {
                    if let bid = InputShared.shared.chooseApp() { var l = list; l.add(bid); list = l }
                }
                if let resetTo { Button("Вернуть список по умолчанию") { list = resetTo } }
            }
        }
    }
}

struct ScrollInverterView: View {
    @ObservedObject private var c = ScrollInverterController.shared

    private func binding<T>(_ kp: WritableKeyPath<ScrollInverterSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Направление скролла мыши", subtitle: "Колесо мыши разворачивается, тачпад и Magic Mouse остаются «натуральными».", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ToggleSetting(title: "Развернуть вертикальную прокрутку", subtitle: "Колесо вверх двигает страницу вверх, как в Windows", isOn: binding(\.vertical))
            ToggleSetting(title: "Развернуть горизонтальную прокрутку", subtitle: "Боковое колесо и прокрутка вбок с зажатой клавишей", isOn: binding(\.horizontal))
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях направление не меняется", list: binding(\.exceptions))
        }
    }
}

struct HorizontalScrollView: View {
    @ObservedObject private var c = HorizontalScrollController.shared

    private func binding<T>(_ kp: WritableKeyPath<HorizontalScrollSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Горизонтальный скролл по клавише", subtitle: "Пока держишь клавишу, колесо мыши листает вбок.", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            Picker(selection: binding(\.modifier)) {
                ForEach(ScrollModifierKey.allCases, id: \.self) { Text("\($0.glyph) \($0.title)").tag($0) }
            } label: { SettingLabel("Клавиша", "Остальные модификаторы при этом не должны быть нажаты") }
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях колесо с клавишей работает как обычно", list: binding(\.exceptions))
        }
    }
}

struct LinearScrollView: View {
    @ObservedObject private var c = LinearScrollController.shared

    private func binding<T>(_ kp: WritableKeyPath<LinearScrollSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Линейный скролл", subtitle: "Один щелчок колеса: всегда одинаковое число строк, без разгона.", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "text.line.first.and.arrowtriangle.forward", title: "Строк на щелчок", subtitle: "Быстрое кручение не добавляет строк", unit: "стр.", range: LinearScrollSettings.linesRange, value: binding(\.linesPerNotch))
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях разгон остаётся системным", list: binding(\.exceptions))
        }
    }
}

struct SmoothScrollView: View {
    @ObservedObject private var c = SmoothScrollController.shared

    private func binding<T>(_ kp: WritableKeyPath<SmoothScrollSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Плавная прокрутка", subtitle: "Щелчок колеса превращается в короткое скольжение, как на тачпаде.", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "ruler", title: "Длина щелчка", subtitle: "Сколько пикселей проезжает один щелчок", unit: "px", range: SmoothScrollSettings.stepRange, value: binding(\.step), step: 5)
            ValueSlider(symbol: "bolt", title: "Отзывчивость", subtitle: "Выше: скольжение быстрее догоняет колесо", unit: "%", range: SmoothScrollSettings.responseRange, value: binding(\.response), step: 5)
            ValueSlider(symbol: "wind", title: "Выбег", subtitle: "Выше: дольше затухает в конце", unit: "%", range: SmoothScrollSettings.coastRange, value: binding(\.coast), step: 5)
            ExceptionsEditor(title: "Исключения", subtitle: "3D- и дизайн-приложения, где колесо управляет масштабом и камерой; шаблон com.vendor.* ловит все приложения вендора",
                             list: binding(\.exceptions), resetTo: AppExceptionList(SmoothScrollSettings.suggestedExceptions))
        }
    }
}

struct MouseAccelerationView: View {
    @ObservedObject private var c = MouseAccelerationController.shared

    var body: some View {
        ModuleSection(title: "Ускорение курсора выключено", subtitle: "Курсор двигается строго пропорционально руке. Прежние значения возвращаются при выключении модуля, выходе из Мультитула и после сбоя; тачпад не трогается.", onAppear: { c.refresh() }) {
            LabeledContent("Состояние") { StatusLabel(c.running ? "применено" : "выключено", color: c.running ? .green : .secondary) }
            if !c.conflicts.isEmpty {
                ToolWarning(text: "Запущено: \(c.conflicts.joined(separator: ", ")). Оно тоже меняет ускорение, настройки могут перебивать друг друга.")
            }
            LabeledContent {
                Button("Обновить") { c.refresh() }
            } label: { SettingLabel("Найденные мыши", "\(c.devices.count)") }
            ForEach(c.devices, id: \.registryID) { d in
                Text("\(d.name) · \(d.key)").font(.caption).foregroundStyle(.secondary)
            }
            if c.devices.isEmpty { Text("Подключи мышь: тачпад и клавиатуры не затрагиваются").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FocusFollowsView: View {
    @ObservedObject private var c = FocusFollowsController.shared

    private func binding<T>(_ kp: WritableKeyPath<FocusFollowsSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Фокус за курсором", subtitle: "Окно под курсором выходит вперёд, когда курсор над ним постоял. Передач фокуса с запуска: \(c.focused).", ready: c.trusted && c.tapActive, readyText: "следит", onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "timer", title: "Задержка", subtitle: "Сколько курсор должен постоять над окном", unit: "мс", range: FocusFollowsSettings.delayRange, value: binding(\.delayMs), step: 50)
            ToggleSetting(title: "Поднимать окно наверх", subtitle: "Выключено: окно получает фокус, но остаётся на своём месте (для окна другого приложения macOS всё равно выводит его вперёд)", isOn: binding(\.raise))
            if !c.settings.raise {
                ToggleSetting(title: "Ждать остановки курсора", subtitle: "Включено: отсчёт задержки идёт с последнего движения; выключено: с входа в окно", isOn: binding(\.waitForStop))
            }
            ExceptionsEditor(title: "Исключения", subtitle: "Эти приложения фокус за курсором не получают", list: binding(\.exceptions))
        }
    }
}

struct ClickDebounceView: View {
    @ObservedObject private var c = ClickDebounceController.shared

    private func binding<T>(_ kp: WritableKeyPath<ClickDebounceSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Фильтр дребезга кнопок мыши", subtitle: "Ложный повторный клик сразу после отпускания игнорируется вместе с парным отпусканием. Отфильтровано: \(c.suppressed).", ready: c.trusted && c.tapActive, readyText: "фильтрует", onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "timer", title: "Окно дребезга", subtitle: "Нажатие раньше этого срока после отпускания считается ложным. Настоящий двойной клик медленнее: держи до 50–60 мс", unit: "мс", range: ClickDebounceSettings.windowRange, value: binding(\.windowMs))
            ToggleSetting(title: "Левая кнопка", isOn: binding(\.left))
            ToggleSetting(title: "Правая кнопка", isOn: binding(\.right))
            ToggleSetting(title: "Средняя кнопка (колесо)", subtitle: "Боковые кнопки фильтр не трогает", isOn: binding(\.middle))
        }
    }
}

struct KeyDebounceView: View {
    @ObservedObject private var c = KeyDebounceController.shared
    @State private var pickedKey: Int64 = 0
    @State private var pickedWindow = 60

    private func binding<T>(_ kp: WritableKeyPath<KeyDebounceSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private static let keyChoices: [(Int64, String)] = KeyCombo.names.map { (Int64($0.key), $0.value) }.sorted { $0.1 < $1.1 }

    private func label(_ code: Int64) -> String { KeyCombo.names[UInt32(code)] ?? "#\(code)" }

    var body: some View {
        ModuleSection(title: "Фильтр залипания клавиш", subtitle: "Слишком быстрый повтор той же клавиши отбрасывается; автоповтор при удержании и модификаторы не трогаются. Отфильтровано: \(c.suppressed).", ready: c.trusted && c.tapActive, readyText: "фильтрует", onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "timer", title: "Общее окно", subtitle: "0: фильтр выключен для всех клавиш без своего значения", unit: "мс", range: KeyDebounceSettings.windowRange, value: binding(\.globalWindowMs))
            NavigationLink {
                keyWindowsPage.navigationTitle("Свои значения для клавиш")
            } label: {
                LabeledContent {
                    Text(c.settings.keyWindows.isEmpty ? "нет" : "\(c.settings.keyWindows.count)")
                } label: { SettingLabel("Свои значения для клавиш", "0 мс: эту клавишу не фильтровать (например, для игр и быстрого набора одной клавиши)") }
            }
            ExceptionsEditor(title: "Приложения-исключения", subtitle: "Когда одно из них впереди, фильтр не действует", list: binding(\.ignoredApps))
        }
    }

    private var keyWindowsPage: some View {
        SettingsPage {
            Section("Добавить") {
                Picker("Клавиша", selection: $pickedKey) {
                    ForEach(Self.keyChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Stepper("\(pickedWindow) мс", value: $pickedWindow, in: KeyDebounceSettings.windowRange, step: 5)
                Button("Добавить") { c.setWindow(pickedWindow, for: pickedKey) }
            }
            Section("Свои значения") {
                if c.settings.keyWindows.isEmpty { EmptyHint(text: "Своих значений нет", symbol: "keyboard") }
                ForEach(c.settings.keyWindows.keys.sorted(), id: \.self) { code in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Stepper("\(c.settings.keyWindows[code] ?? 0) мс", value: Binding(get: { c.settings.keyWindows[code] ?? 0 }, set: { c.setWindow($0, for: code) }), in: KeyDebounceSettings.windowRange, step: 5)
                            Button { c.setWindow(nil, for: code) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    } label: { Text(label(code)) }
                }
            }
        }
    }
}

struct ScrollZoomView: View {
    @ObservedObject private var c = ScrollZoomController.shared

    private func binding<T>(_ kp: WritableKeyPath<ScrollZoomSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Зум по ⌘ + колесо", subtitle: "Колесо мыши с зажатым ⌘ масштабирует, как щипок на тачпаде.", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ToggleSetting(title: "⌘ + колесо = зум", subtitle: "Прокрутка вверх приближает, вниз отдаляет; работает и без плавной прокрутки. Приложения, которые не понимают щипок, зум не получат", isOn: binding(\.cmdZoom))
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях ⌘ + колесо остаётся обычным", list: binding(\.exceptions))
        }
    }
}
