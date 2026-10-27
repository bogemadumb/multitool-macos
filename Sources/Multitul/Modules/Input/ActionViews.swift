import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

struct ComboField: View {
    @Binding var combo: KeyCombo?
    var placeholder = "Не задано"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : begin() } label: {
                if recording {
                    Text("Нажми сочетание…").font(.callout.weight(.medium)).padding(.horizontal, 6)
                } else if let c = combo {
                    KeyCaps(c.display)
                } else {
                    Text(placeholder).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6)
                }
            }
            .buttonStyle(.plain)
            .help("Нажми, чтобы записать сочетание. Esc — отмена")
            if combo != nil {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func begin() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 { stop(); return }
        combo = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: KeyCombo.carbonModifiers(from: e.modifierFlags))
        stop()
    }
}

private struct OptionalComboBinding {
    static func make(_ get: @escaping () -> KeyCombo?, _ set: @escaping (KeyCombo?) -> Void) -> Binding<KeyCombo?> { Binding(get: get, set: set) }
}

struct MouseNavigationView: View {
    @ObservedObject private var c = MouseNavigationController.shared

    private func binding<T>(_ kp: WritableKeyPath<MouseNavigationSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private func ruleBinding(_ i: Int, back: Bool) -> Binding<KeyCombo?> {
        OptionalComboBinding.make({ c.settings.rules.indices.contains(i) ? (back ? c.settings.rules[i].back : c.settings.rules[i].forward) : nil }, { v in
            var s = c.settings
            guard s.rules.indices.contains(i) else { return }
            if back { s.rules[i].back = v } else { s.rules[i].forward = v }
            c.update(s)
        })
    }

    var body: some View {
        ModuleSection(title: "Боковые кнопки мыши", subtitle: "«Назад» и «Вперёд» мыши листают страницы. Нажато с запуска: \(c.handled).", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            Picker(selection: binding(\.scope)) {
                ForEach(MouseNavScope.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Где работает", "Совместимые: Finder, браузеры, редакторы JetBrains и VS Code, Xcode. В остальных приложениях боковые кнопки остаются как были") }
            ToggleSetting(title: "Поменять кнопки местами", subtitle: "Нижняя боковая кнопка идёт вперёд, верхняя назад", isOn: binding(\.swapButtons))
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях боковые кнопки не трогаются", list: binding(\.exceptions))
        }
        Section {
            ForEach(Array(c.settings.rules.enumerated()), id: \.offset) { i, r in
                LabeledContent {
                    HStack(spacing: 10) {
                        Text("Назад").font(.caption).foregroundStyle(.secondary)
                        ComboField(combo: ruleBinding(i, back: true))
                        Text("Вперёд").font(.caption).foregroundStyle(.secondary)
                        ComboField(combo: ruleBinding(i, back: false))
                        Button { var s = c.settings; s.rules.remove(at: i); c.update(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                } label: { Text(appName(r.pattern)) }
            }
            Button("Добавить приложение…") {
                guard let bid = InputShared.shared.chooseApp() else { return }
                var s = c.settings
                s.rules.removeAll { $0.pattern == bid }
                s.rules.append(MouseNavRule(pattern: bid, back: MouseNavDefaults.standard.back, forward: MouseNavDefaults.standard.forward))
                c.update(s)
            }
        } header: { Text("Свои сочетания для приложений") } footer: {
            SectionFooter("Перебивают встроенные; пустое поле: кнопка в этом приложении работает как обычно.")
        }
    }
}

private enum ActionChoice: Hashable {
    case none, shortcut, mission, expose, left, right, middle, desktop, launchpad
    static let all: [ActionChoice] = [.none, .shortcut, .mission, .expose, .left, .right, .middle, .desktop, .launchpad]

    init(_ a: ButtonAction) {
        switch a {
        case .none: self = .none
        case .shortcut: self = .shortcut
        case .missionControl: self = .mission
        case .appExpose: self = .expose
        case .spaceLeft: self = .left
        case .spaceRight: self = .right
        case .middleClick: self = .middle
        case .showDesktop: self = .desktop
        case .launchpad: self = .launchpad
        }
    }

    var title: String {
        switch self {
        case .none: "Ничего"
        case .shortcut: "Сочетание клавиш"
        case .mission: "Mission Control"
        case .expose: "App Exposé"
        case .left: "Рабочий стол влево"
        case .right: "Рабочий стол вправо"
        case .middle: "Средний клик"
        case .desktop: "Показать рабочий стол"
        case .launchpad: "Launchpad"
        }
    }

    func action(keeping combo: KeyCombo?) -> ButtonAction {
        switch self {
        case .none: .none
        case .shortcut: combo.map { .shortcut($0) } ?? .none
        case .mission: .missionControl
        case .expose: .appExpose
        case .left: .spaceLeft
        case .right: .spaceRight
        case .middle: .middleClick
        case .desktop: .showDesktop
        case .launchpad: .launchpad
        }
    }
}

private struct ActionSlot: View {
    let title: String
    @Binding var action: ButtonAction
    @State private var shortcutMode = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(title, selection: Binding(get: { ActionChoice(action) }, set: { choice in
                    shortcutMode = choice == .shortcut
                    action = choice.action(keeping: action.keyCombo)
                })) {
                    ForEach(ActionChoice.all, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if ActionChoice(action) == .shortcut || shortcutMode && action == .none {
                    ComboField(combo: Binding(get: { action.keyCombo }, set: { v in action = v.map { .shortcut($0) } ?? .none }))
                }
            }
        } label: { Text(title) }
    }
}

struct ButtonShortcutsView: View {
    @ObservedObject private var c = ButtonShortcutsController.shared
    @State private var shortcutMode = Set<ButtonTrigger>()

    private func binding<T>(_ kp: WritableKeyPath<ButtonShortcutsSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private func mutate(_ trigger: ButtonTrigger, _ change: (inout ButtonBinding) -> Void) {
        var s = c.settings
        guard let i = s.bindings.firstIndex(where: { $0.trigger == trigger }) else { return }
        change(&s.bindings[i])
        c.update(s)
    }

    private func add(_ t: ButtonTrigger) {
        var s = c.settings
        if s.binding(for: t) == nil { s.bindings.append(ButtonBinding(trigger: t, click: .none, gesture: false)) }
        c.update(s)
        shortcutMode.insert(t)
    }

    var body: some View {
        ModuleSection(title: "Действия на кнопки мыши", subtitle: "Кнопка или наклон колеса нажимает своё сочетание; «держи и тяни» переключает рабочие столы.", ready: c.trusted && c.tapActive, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ValueSlider(symbol: "arrow.left.and.right", title: "Порог жеста", subtitle: "Сколько пикселей протянуть с зажатой кнопкой", unit: "px", range: ButtonShortcutsSettings.thresholdRange, value: binding(\.gestureThreshold), step: 5)
            ValueSlider(symbol: "timer", title: "Пауза колеса", subtitle: "Не срабатывать чаще этого интервала при наклоне колеса вбок", unit: "мс", range: ButtonShortcutsSettings.cooldownRange, value: binding(\.scrollCooldownMs), step: 25)
            ValueSlider(symbol: "hand.tap", title: "Время удержания", subtitle: "Сколько держать кнопку без движения, чтобы сработало «Удержание»", unit: "мс", range: ButtonShortcutsSettings.holdRange, value: binding(\.holdMs), step: 25)
            ValueSlider(symbol: "cursorarrow.click.2", title: "Окно двойного клика", subtitle: "Если назначен двойной клик, одиночный срабатывает с этой задержкой", unit: "мс", range: ButtonShortcutsSettings.doubleRange, value: binding(\.doubleMs), step: 25)
            ExceptionsEditor(title: "Исключения", subtitle: "В этих приложениях кнопки остаются как были", list: binding(\.exceptions))
        }
        Section {
            if c.learning {
                LabeledContent {
                    Button("Отмена") { c.cancelLearning() }
                } label: { StatusLabel("Нажми кнопку мыши", color: .orange) }
            } else {
                Button("Определить кнопку") { c.startLearning { add($0) } }.disabled(!c.running)
            }
            Menu("Добавить") {
                ForEach([2, 3, 4, 5, 6, 7, 8].map { Int64($0) }, id: \.self) { n in Button(ButtonTrigger.button(n).title) { add(.button(n)) } }
                Divider()
                Button(ButtonTrigger.scrollLeft.title) { add(.scrollLeft) }
                Button(ButtonTrigger.scrollRight.title) { add(.scrollRight) }
            }
        } header: { Text("Назначения") } footer: {
            SectionFooter("Жест: влево и вправо рабочие столы, вверх Mission Control, вниз App Exposé. Нужны включённые системные сочетания ⌃← ⌃→ ⌃↑ ⌃↓. Короткий клик без движения работает как назначено, а если не назначено, как обычный клик. «Удержание» и «Двойной клик» отдельные действия для тех же кнопок.")
        }
        if c.settings.bindings.isEmpty {
            Section { EmptyHint(text: "Назначений нет", symbol: "computermouse") }
        }
        ForEach(c.settings.bindings, id: \.trigger) { b in bindingSection(b) }
    }

    private func bindingSection(_ b: ButtonBinding) -> some View {
        let isButton: Bool = { if case .button = b.trigger { return true } else { return false } }()
        return Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("Действие", selection: Binding(get: { ActionChoice(b.click) }, set: { choice in
                        if choice == .shortcut { shortcutMode.insert(b.trigger) } else { shortcutMode.remove(b.trigger) }
                        mutate(b.trigger) { $0.click = choice.action(keeping: $0.click.keyCombo) }
                    })) {
                        ForEach(ActionChoice.all, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if ActionChoice(b.click) == .shortcut || shortcutMode.contains(b.trigger) && b.click == .none {
                        ComboField(combo: Binding(get: { b.click.keyCombo }, set: { v in mutate(b.trigger) { $0.click = v.map { .shortcut($0) } ?? .none } }))
                    }
                }
            } label: { Text("Клик") }
            if isButton {
                Toggle("Жест: держи и тяни", isOn: Binding(get: { b.gesture }, set: { v in mutate(b.trigger) { $0.gesture = v } }))
                ActionSlot(title: "Удержание", action: Binding(get: { b.hold }, set: { v in mutate(b.trigger) { $0.hold = v } }))
                ActionSlot(title: "Двойной клик", action: Binding(get: { b.doubleClick }, set: { v in mutate(b.trigger) { $0.doubleClick = v } }))
            }
            Button("Убрать назначение", role: .destructive) { var s = c.settings; s.bindings.removeAll { $0.trigger == b.trigger }; c.update(s) }
        } header: { Text(b.trigger.title) }
    }
}

struct MiddleClickView: View {
    @ObservedObject private var c = MiddleClickController.shared

    private func binding<T>(_ kp: WritableKeyPath<MiddleClickSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Средний клик на тачпаде", subtitle: "Нажатие \(c.required) пальцами: как нажатие колеса мыши. Превращено с запуска: \(c.converted).", ready: c.trusted && c.tapActive && !c.deviceMissing, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            if c.deviceMissing {
                ToolWarning(text: "Тачпад не найден или система не отдала касания: нажатие пальцами не распознаётся. Повтори после подключения тачпада или перезапуска модуля.")
            }
            if c.required == 4 {
                Label("В macOS включено перетаскивание тремя пальцами, оно занимает три пальца, поэтому кликать нужно четырьмя.", systemImage: "info.circle")
            }
            ToggleSetting(title: "Лёгкий тап тоже кликает", subtitle: "Короткое касание \(c.required) пальцами без нажатия. Свайпы и лежащие пальцы не считаются", isOn: binding(\.tapEnabled))
            if c.settings.tapEnabled {
                ValueSlider(symbol: "timer", title: "Длительность тапа", subtitle: "Дольше этого касание не считается тапом", unit: "мс", range: MiddleClickSettings.tapDurationRange, value: binding(\.tapMaxMs), step: 25)
            }
        }
    }
}

struct SuperKeyView: View {
    @ObservedObject private var c = SuperKeyController.shared

    private func binding<T>(_ kp: WritableKeyPath<SuperKeySettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private func modifier(_ mask: UInt32, _ glyph: String, _ name: String) -> some View {
        Toggle(glyph, isOn: Binding(get: { c.settings.modifiers & mask != 0 }, set: { on in
            var s = c.settings
            if on { s.modifiers |= mask } else { s.modifiers &= ~mask }
            c.update(s)
        }))
        .toggleStyle(.button)
        .help(name)
    }

    var body: some View {
        ModuleSection(title: "Супер-клавиша", subtitle: "Держишь \(c.settings.source.title) и жмёшь любую клавишу: нажимаются все выбранные модификаторы сразу.", ready: c.trusted && c.tapActive && !c.mappingFailed, onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            if c.mappingFailed {
                ToolWarning(text: "Не удалось переназначить Caps Lock через hidutil: супер-клавиша на Caps Lock не работает. Выбери правый модификатор или проверь систему.")
            }
            Picker(selection: binding(\.source)) {
                ForEach(SuperKeySource.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                SettingLabel("Клавиша", c.settings.source == .capsLock ? "Caps Lock переназначается на F18 на время работы модуля и возвращается при выключении. После аварийного выхода вернётся при следующем запуске" : "Правый модификатор перестаёт быть собой, пока модуль включён")
            }
            LabeledContent {
                HStack(spacing: 6) {
                    modifier(KeyCombo.ctrl, "⌃", "Control")
                    modifier(KeyCombo.opt, "⌥", "Option")
                    modifier(KeyCombo.shift, "⇧", "Shift")
                    modifier(KeyCombo.cmd, "⌘", "Command")
                }
            } label: { SettingLabel("Что нажимается", "Нужен хотя бы один модификатор") }
            Picker(selection: binding(\.solo)) {
                ForEach(SuperKeySolo.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Короткое нажатие", "Нажал и отпустил, не трогая другие клавиши") }
            ValueSlider(symbol: "timer", title: "Что считать коротким", subtitle: nil, unit: "мс", range: SuperKeySettings.tapRange, value: binding(\.tapMaxMs), step: 25)
            Toggle("Долгое удержание включает Caps Lock", isOn: binding(\.longHoldCapsLock))
            if c.settings.longHoldCapsLock {
                ValueSlider(symbol: "hourglass", title: "Сколько держать", subtitle: nil, unit: "мс", range: SuperKeySettings.longHoldRange, value: binding(\.longHoldMs), step: 50)
            }
            ExceptionsEditor(title: "Приложения, где супер-клавиша выключена", subtitle: "Там Caps Lock работает как обычно (по короткому нажатию), правый модификатор как обычный", list: binding(\.exceptions))
        }
    }
}

struct QuitProtectionView: View {
    @ObservedObject private var c = QuitProtectionController.shared

    private func protection(_ kp: WritableKeyPath<QuitProtectionSettings, KeyProtection>) -> Binding<KeyProtection> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Защита от случайных ⌘Q и ⌘W", subtitle: "Сочетание пропускается только после подтверждения.", ready: c.trusted && c.tapActive, readyText: "защищает", onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            ToggleSetting(title: "Показывать плашку", subtitle: "Подсказка на экране, как подтвердить", isOn: Binding(get: { c.settings.showHud }, set: { v in var s = c.settings; s.showHud = v; c.update(s) }))
        }
        ProtectionEditor(title: "⌘Q: выйти из приложения", p: protection(\.quit))
        ProtectionEditor(title: "⌘W: закрыть окно или вкладку", p: protection(\.close))
    }
}

private struct ProtectionEditor: View {
    let title: String
    @Binding var p: KeyProtection

    var body: some View {
        Section {
            Picker("Подтверждение", selection: $p.mode) {
                ForEach(ProtectionMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch p.mode {
            case .off: EmptyView()
            case .hold: ValueSlider(symbol: "hourglass", title: "Сколько держать", subtitle: nil, unit: "мс", range: KeyProtection.holdRange, value: $p.holdMs, step: 100)
            case .doublePress: ValueSlider(symbol: "timer", title: "Окно второго нажатия", subtitle: nil, unit: "мс", range: KeyProtection.doubleRange, value: $p.doubleWindowMs, step: 100)
            case .extraModifier:
                Picker(selection: $p.extra) {
                    ForEach([ScrollModifierKey.option, .shift, .control], id: \.self) { Text("\($0.glyph) \($0.title)").tag($0) }
                } label: { SettingLabel("Дополнительный модификатор", "Например, ⌘⌥Q вместо ⌘Q") }
            }
            if p.mode != .off {
                Picker("Приложения", selection: $p.scope) {
                    ForEach(ProtectionScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if p.scope != .all {
                    ExceptionsEditor(title: p.scope == .except ? "Не защищать в этих приложениях" : "Защищать только в этих приложениях", subtitle: "Шаблон com.vendor.* ловит все приложения вендора", list: $p.apps)
                }
            }
        } header: { Text(title) }
    }
}

struct SnippetsView: View {
    @ObservedObject private var c = SnippetsController.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var editing: Snippet?
    @State private var isNew = false
    @State private var query = ""

    private func binding<T>(_ kp: WritableKeyPath<SnippetSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    private var shown: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? c.snippets : c.snippets.filter { $0.trigger.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    var body: some View {
        let _ = hotkeys.overridesRevision
        ModuleSection(title: "Быстрые вставки текста", subtitle: "Набираешь триггер и пробел, Tab или Return: он заменяется текстом. Сработало с запуска: \(c.expanded).", ready: c.trusted && c.tapActive, readyText: "следит", onAppear: { c.refreshStatus() }) {
            InputNotices(c: c)
            if let m = c.message { ToolWarning(text: m) }
            LabeledContent {
                HotkeyRecorder(spec: c.spec, titles: [:])
            } label: { SettingLabel("Библиотека", "Меню с поиском: выбранный сниппет печатается в позиции курсора. По умолчанию не назначена") }
        }
        Section {
            TextField("Поиск", text: $query)
            if let e = editing { editor(e) }
            ForEach(shown) { s in row(s) }
            if c.snippets.isEmpty && editing == nil {
                Text("Пока пусто.").foregroundStyle(.secondary)
            }
            Button("Новый сниппет") { editing = Snippet(trigger: ";", body: ""); isNew = true }
            Button("Импорт…") { importFile() }
            Button("Экспорт…") { exportFile() }.disabled(c.snippets.isEmpty)
        } header: { Text("Сниппеты: \(c.snippets.count)") } footer: {
            if c.snippets.isEmpty && editing == nil {
                SectionFooter("Пример: триггер `;адрес`, текст с `{{date}}`. Переменные: {{date}}, {{time}}, {{datetime}} (формат после двоеточия, пояс после |, например {{date:dd.MM.yyyy|Europe/Moscow}}), {{clipboard}}, {{cursor}}. Чтобы напечатать `{{` буквально, поставь перед ним `\\`.")
            }
        }
        Section {
            Toggle("Учитывать регистр триггера", isOn: binding(\.caseSensitive))
            Toggle("Срабатывать и в неверной раскладке", isOn: binding(\.layoutInsensitive))
            Toggle("Возвращать буфер обмена после вставки", isOn: binding(\.restoreClipboard))
            Toggle("Оставлять пробел после вставки", isOn: binding(\.appendSpace))
            LabeledContent("Запускают") {
                HStack(spacing: 14) {
                    Toggle("Пробел", isOn: binding(\.useSpace)).toggleStyle(.checkbox)
                    Toggle("Tab", isOn: binding(\.useTab)).toggleStyle(.checkbox)
                    Toggle("Return", isOn: binding(\.useReturn)).toggleStyle(.checkbox)
                }
            }
            Picker(selection: binding(\.method)) {
                ForEach(SnippetMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Как вставлять", "Короткий однострочный текст печатается, длинный вставляется через буфер") }
            FieldSetting("Часовой пояс", "Пусто: системный. Например, Europe/Moscow", text: binding(\.timeZoneID))
            ExceptionsEditor(title: "Приложения-исключения", subtitle: "Там сниппеты не работают. Парольные поля и защищённый ввод пропускаются всегда", list: binding(\.exceptions),
                             resetTo: AppExceptionList(SnippetSettings.suggestedExceptions))
        } header: { Text("Параметры") }
    }

    private func row(_ s: Snippet) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text("\(s.uses)").foregroundStyle(.secondary).help("Сколько раз сработал")
                Button { editing = s; isNew = false } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                Button { c.run { try $0.delete(id: s.id) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        } label: {
            HStack(spacing: 10) {
                Toggle(s.trigger, isOn: Binding(get: { s.enabled }, set: { v in c.run { try $0.setEnabled(id: s.id, v) } })).labelsHidden()
                SettingLabel(s.trigger, s.title.isEmpty ? s.body.replacingOccurrences(of: "\n", with: " ") : s.title)
                    .font(.body.monospaced()).lineLimit(1)
            }
        }
    }

    private func editor(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Триггер", text: Binding(get: { editing?.trigger ?? "" }, set: { editing?.trigger = $0 }), prompt: Text("Минимум \(SnippetRules.minTriggerLength) символа, без пробелов"))
            TextField("Название", text: Binding(get: { editing?.title ?? "" }, set: { editing?.title = $0 }), prompt: Text("По желанию"))
            TextEditor(text: Binding(get: { editing?.body ?? "" }, set: { editing?.body = $0 }))
                .font(.body.monospaced()).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("Отмена") { editing = nil }
                Button("Сохранить") {
                    guard let e = editing else { return }
                    let ok = isNew ? c.run { _ = try $0.add(trigger: e.trigger, body: e.body, title: e.title) } : c.run { try $0.update(e) }
                    if ok { editing = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        var result = SnippetImportResult()
        if c.run({ result = try $0.importJSON(data, overwrite: false) }) {
            c.message = "Импорт: добавлено \(result.added), пропущено \(result.skipped)"
        }
    }

    private func exportFile() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "Сниппеты Мультитула.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        c.run { try $0.exportJSON().write(to: url, options: .atomic) }
    }
}
