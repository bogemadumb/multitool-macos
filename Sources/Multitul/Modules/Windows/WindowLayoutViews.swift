import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

let windowHotkeyTitles: [String: String] = Dictionary(uniqueKeysWithValues: WindowHotkeys.all.map { ($0.id, $0.title) })

struct LayoutThumb: View {
    let fraction: FractionRect?
    var width: CGFloat = 34
    var height: CGFloat = 22

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            if let f = fraction {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(width * f.w, 2), height: max(height * f.h, 2))
                    .offset(x: width * f.x, y: height * f.y)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .frame(width: width, height: height)
    }
}

struct WindowNotices: View {
    @ObservedObject var c: WindowsTapController

    var body: some View {
        if !c.healthy {
            ToolWarning(text: c.trusted ? "Перехват мыши и клавиатуры не запустился. Нажми «Повторить»; если не помогает, проверь доступ на странице «Права»." : "Нужен «Универсальный доступ»: без него окна двигать нельзя. Выдай доступ на странице «Права» и нажми «Повторить».")
            Button("Повторить") { c.restart(); c.refreshStatus() }
        }
        if !c.conflicts.isEmpty {
            ToolWarning(text: "Запущено: \(c.conflicts.joined(separator: ", ")). Оно тоже управляет окнами, сочетания и жесты могут спорить. Выключи одно из двух.")
        }
    }
}

struct WindowLayoutView: View {
    @ObservedObject private var c = WindowLayoutController.shared

    private func binding<T>(_ kp: WritableKeyPath<WindowLayoutSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        ModuleSection(title: "Раскладка окон", subtitle: "Половины, трети, четверти, шестые доли, центр, максимум, возврат, перенос на другой дисплей.", ready: c.healthy, onAppear: { c.refreshStatus(); c.refreshSystemTiling() }) {
            WindowNotices(c: c)
            if let m = c.lastMessage { ToolWarning(text: m) }
            ToggleSetting(title: "Глобальные сочетания", subtitle: "Выключено: клавиши не перехватываются, остаются перетаскивание и жесты", isOn: binding(\.shortcutsEnabled))
            ToggleSetting(title: "Курсор на следующий дисплей", subtitle: "Отдельное сочетание переносит курсор на соседний экран", isOn: binding(\.cursorDisplayEnabled))
            NavigationLink(value: WindowsRoute.shortcuts) { Text("Сочетания") }
            NavigationLink(value: WindowsRoute.customLayouts) {
                LabeledContent("Свои макеты", value: c.settings.custom.isEmpty ? "нет" : "\(c.settings.custom.count)")
            }
        }
        edgeSections
        Section {
            GapRow(symbol: "rectangle.split.2x1", title: "Между окнами", subtitle: "Зазор между соседними окнами раскладки", value: Binding(get: { c.settings.gaps.window }, set: { v in var s = c.settings; s.gaps.window = v; c.update(s) }))
            GapRow(symbol: "rectangle.inset.filled", title: "От краёв экрана", subtitle: "Отступ окон от краёв рабочей области", value: Binding(get: { c.settings.gaps.screen }, set: { v in var s = c.settings; s.gaps.screen = v; c.update(s) }))
            Picker(selection: binding(\.repeatMode)) {
                ForEach(LayoutRepeat.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Та же клавиша ещё раз", "Что делает повторное нажатие половины: размеры меняются 1/2, 2/3, 1/3, либо окно уходит на соседний дисплей") }
        } header: { Text("Отступы и повтор") } footer: {
            SectionFooter("«Вернуть прежний размер» помнит до \(WindowHistory.perWindowLimit) положений каждого окна, пока работает Мультитул.")
        }
    }

    @ViewBuilder private var edgeSections: some View {
        Section {
            if c.systemTilingOn {
                ToolWarning(text: "В macOS включена своя раскладка по краям (Системные настройки, Рабочий стол и Dock, Окна). Обе подсветки будут показываться вместе: выключи системную.")
                Button("Открыть настройки macOS") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) }
            }
            ToggleSetting(title: "Перетаскивание к краю экрана", subtitle: "Тянешь окно к краю или углу: появляется подсветка, отпустил: окно встало", isOn: Binding(get: { c.settings.edge.enabled }, set: { v in var s = c.settings; s.edge.enabled = v; c.update(s) }))
            if c.settings.edge.enabled {
                ToggleSetting(title: "Подсветка при перетаскивании", subtitle: "Прямоугольник, куда встанет окно", isOn: Binding(get: { c.settings.edge.showPreview }, set: { v in var s = c.settings; s.edge.showPreview = v; c.update(s) }))
                ValueSlider(symbol: "arrow.left.and.right.square", title: "Зона у края", subtitle: "Насколько близко к краю нужно подвести курсор", unit: "пт", range: EdgeSnapSettings.distanceRange, value: Binding(get: { c.settings.edge.distance }, set: { v in var s = c.settings; s.edge.distance = v; c.update(s) }))
                NavigationLink(value: WindowsRoute.snapZones) { Text("Что делает каждая зона") }
            }
        } header: { Text("Края экрана") }
        Section {
            ToggleSetting(title: "Жест с модификаторами", subtitle: "Держишь клавиши и тянешь окно мышью или тачпадом из любого места окна", isOn: Binding(get: { c.settings.gesture.enabled }, set: { v in var s = c.settings; s.gesture.enabled = v; c.update(s) }))
            if c.settings.gesture.enabled {
                ModifierPicker(title: "Переместить окно", value: Binding(get: { c.settings.gesture.move }, set: { v in var s = c.settings; s.gesture.move = v; c.update(s) }))
                ModifierPicker(title: "Изменить размер", value: Binding(get: { c.settings.gesture.resize }, set: { v in var s = c.settings; s.gesture.resize = v; c.update(s) }))
                if !c.settings.gesture.isValid {
                    ToolWarning(text: "Наборы клавиш должны быть непустыми и разными, иначе жест выключен")
                }
                ToggleSetting(title: "Поднимать окно при жесте", subtitle: "Окно выходит вперёд, как только начал его тянуть", isOn: Binding(get: { c.settings.gesture.raiseWindow }, set: { v in var s = c.settings; s.gesture.raiseWindow = v; c.update(s) }))
            }
            ToggleSetting(title: "Кольцо", subtitle: "Держишь сочетание, двигаешь курсор в сторону, отпускаешь: окно встало туда. Стрелки: половины, диагонали: углы, Return: максимум, Esc: отмена", isOn: Binding(get: { c.settings.ring.enabled }, set: { v in var s = c.settings; s.ring.enabled = v; c.update(s) }))
            if c.settings.ring.enabled {
                LabeledContent {
                    ComboField(combo: Binding(get: { c.settings.ring.trigger }, set: { v in
                        guard let v, v.modifiers != 0, !v.isNone else { return }
                        var s = c.settings; s.ring.trigger = v; c.update(s)
                    }))
                } label: { SettingLabel("Клавиша кольца", "Модификаторы + клавиша, по умолчанию ⌃⌥Space") }
            }
            ExceptionsEditor(title: "Игнорируемые приложения", subtitle: "Пока такое приложение впереди, сочетания, края и жесты раскладки выключены", list: binding(\.ignoredApps))
        } header: { Text("Жесты и кольцо") } footer: {
            SectionFooter("Размер жестом меняется от ближайшего угла или края окна: тянешь за ту часть, где стоит курсор.")
        }
    }
}

struct WindowCustomLayoutsPage: View {
    @ObservedObject private var c = WindowLayoutController.shared

    var body: some View {
        SettingsPage { CustomLayoutsEditor(settings: Binding(get: { c.settings.custom }, set: { v in var s = c.settings; s.custom = v; c.update(s) })) }
    }
}

struct WindowSnapZonesPage: View {
    @ObservedObject private var c = WindowLayoutController.shared

    var body: some View {
        SettingsPage { SnapZoneEditor(settings: Binding(get: { c.settings.edge }, set: { v in var s = c.settings; s.edge = v; c.update(s) })) }
    }
}

struct WindowShortcutsPage: View {
    @ObservedObject private var c = WindowLayoutController.shared

    private func binding<T>(_ kp: WritableKeyPath<WindowLayoutSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    @State private var confirmReset = false

    var body: some View {
        SettingsPage {
            Section {
                Button("Подставить рекомендованные сочетания") { c.applyHintCombos() }
                Button("Убрать все сочетания", role: .destructive) { confirmReset = true }
            } footer: {
                SectionFooter("По умолчанию сочетания не заняты. Рекомендация: ⌃⌥ + стрелки: половины, U, I, J, K: углы, Return: максимум, C: центр, R: вернуть, D, F, G: трети, E, T: две трети, ⌃⌥⌘→: следующий дисплей.")
            }
            ForEach(WindowLayoutGroup.allCases, id: \.self) { g in
                let actions = WindowLayoutAction.allCases.filter { $0.group == g }
                Section {
                    ForEach(actions, id: \.self) { a in
                        ActionRow(action: a, custom: c.settings.custom[a.customSlot ?? 0], marginPercent: c.settings.marginPercent) { c.run(a) }
                    }
                    if g == .other {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Slider(value: binding(\.marginPercent), in: WindowLayoutSettings.marginRange, step: 1).frame(minWidth: 110, maxWidth: 200)
                                Text("\(Int(c.settings.marginPercent)) %").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                            }
                        } label: { Text("Поля у «Максимум с полями»") }
                    }
                } header: { Text(g.title) }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        HotkeyRecorder(spec: WindowHotkeys.cursorNextDisplay, titles: windowHotkeyTitles)
                        Button("Выполнить") { c.moveCursorToNextDisplay() }
                    }
                } label: { Text("Курсор на следующий дисплей") }
            }
        }
        .confirmationDialog("Убрать все сочетания раскладки?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Убрать", role: .destructive) { c.resetCombos() }
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct ActionRow: View {
    let action: WindowLayoutAction
    let custom: CustomLayout?
    let marginPercent: Double
    let run: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                HotkeyRecorder(spec: WindowHotkeys.spec(for: action), titles: windowHotkeyTitles)
                Button { run() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Применить к активному окну")
            }
        } label: {
            HStack(spacing: 10) {
                LayoutThumb(fraction: action.customSlot != nil ? custom?.rect : (action == .marginMaximize ? FractionRect(x: marginPercent / 100, y: marginPercent / 100, w: 1 - 2 * marginPercent / 100, h: 1 - 2 * marginPercent / 100) : action.fraction))
                Text(action.customSlot != nil ? (custom.map { "\(action.title): \($0.name)" } ?? "\(action.title) (не задан)") : action.title)
            }
        }
    }
}

struct GapRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var value: Int

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(title, selection: Binding(get: { WindowGaps.presets.contains(value) ? value : -1 }, set: { if $0 >= 0 { value = $0 } })) {
                    ForEach(WindowGaps.presets, id: \.self) { Text($0 == 0 ? "Нет" : "\($0) пт").tag($0) }
                    if !WindowGaps.presets.contains(value) { Text("\(value) пт").tag(-1) }
                }
                .labelsHidden()
                .fixedSize()
                Stepper(title, value: $value, in: WindowGaps.range).labelsHidden()
            }
        } label: { SettingLabel(title, subtitle) }
    }
}

struct ModifierPicker: View {
    let title: String
    @Binding var value: GestureModifiers

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                ForEach(GestureModifiers.order, id: \.0.rawValue) { m, glyph in
                    Toggle(glyph, isOn: Binding(get: { value.contains(m) }, set: { on in if on { value.insert(m) } else { value.remove(m) } })).toggleStyle(.checkbox)
                }
                KeyCaps(value.glyphs.isEmpty ? "—" : value.glyphs)
            }
        } label: { Text(title) }
    }
}

struct SnapZoneEditor: View {
    @Binding var settings: EdgeSnapSettings

    private func actionMenu(_ zone: SnapZone, part: Int) -> some View {
        let current = settings.layout.actions(for: zone)[part]
        return Menu {
            ForEach(WindowLayoutGroup.allCases.filter { $0 != .other }, id: \.self) { g in
                Menu(g.title) {
                    ForEach(WindowLayoutAction.snapTargets.filter { $0.group == g }, id: \.self) { a in
                        Button(a.title) { var l = settings.layout; l.setAction(a, for: zone, part: part); settings.layout = l }
                    }
                }
            }
            Divider()
            Button(WindowLayoutAction.maximize.title) { var l = settings.layout; l.setAction(.maximize, for: zone, part: part); settings.layout = l }
            Button(WindowLayoutAction.marginMaximize.title) { var l = settings.layout; l.setAction(.marginMaximize, for: zone, part: part); settings.layout = l }
        } label: {
            HStack(spacing: 4) {
                LayoutThumb(fraction: current.fraction ?? (current == .marginMaximize ? FractionRect(x: 0.08, y: 0.08, w: 0.84, h: 0.84) : nil), width: 26, height: 17)
                Text(current.title).font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    var body: some View {
        Section {
            ForEach(SnapZone.allCases, id: \.self) { z in
                LabeledContent {
                    HStack(spacing: 10) {
                        if z.maximumParts > 1 {
                            Picker("Частей", selection: Binding(get: { settings.layout.actions(for: z).count }, set: { n in var l = settings.layout; l.setPartCount(n, for: z); settings.layout = l })) {
                                ForEach(1...z.maximumParts, id: \.self) { Text($0 == 1 ? "1 часть" : "\($0) части").tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        ForEach(0..<settings.layout.actions(for: z).count, id: \.self) { i in actionMenu(z, part: i) }
                    }
                    .disabled(settings.disabledZones.contains(z))
                } label: {
                    Toggle(z.title, isOn: Binding(get: { !settings.disabledZones.contains(z) }, set: { on in if on { settings.disabledZones.remove(z) } else { settings.disabledZones.insert(z) } })).toggleStyle(.checkbox)
                }
            }
            if !settings.layout.isDefault { Button("Вернуть по умолчанию") { settings.layout.reset() } }
        } header: { Text("Что делает каждая зона") } footer: {
            SectionFooter("У краёв можно разбить зону на части: например, верхний край на три трети.")
        }
    }
}

struct CustomLayoutsEditor: View {
    @Binding var settings: [Int: CustomLayout]

    private func rect(_ slot: Int) -> FractionRect { settings[slot]?.rect ?? FractionRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5) }

    private func set(_ slot: Int, _ kp: WritableKeyPath<FractionRect, Double>, _ pct: Double) {
        var r = rect(slot)
        r[keyPath: kp] = pct / 100
        settings[slot] = CustomLayout(name: settings[slot]?.name ?? "Макет \(slot)", rect: r)
    }

    private func slider(_ slot: Int, _ label: String, _ kp: WritableKeyPath<FractionRect, Double>) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { rect(slot)[keyPath: kp] * 100 }, set: { set(slot, kp, $0.rounded()) }), in: 0...100, step: 1).frame(minWidth: 110, maxWidth: 200)
                Text("\(Int((rect(slot)[keyPath: kp] * 100).rounded()))").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
            }
        } label: { Text(label) }
    }

    var body: some View {
        ForEach(Array(WindowLayoutAction.customSlots), id: \.self) { slot in
            Section {
                Toggle(isOn: Binding(get: { settings[slot] != nil }, set: { on in
                    if on { settings[slot] = CustomLayout(name: "Макет \(slot)", rect: rect(slot)) } else { settings[slot] = nil }
                })) {
                    HStack(spacing: 10) {
                        LayoutThumb(fraction: settings[slot]?.rect, width: 40, height: 26)
                        Text("Использовать")
                    }
                }
                if settings[slot] != nil {
                    FieldSetting("Название", text: Binding(get: { settings[slot]?.name ?? "" }, set: { settings[slot] = CustomLayout(name: $0, rect: rect(slot)) }))
                    slider(slot, "Слева, %", \.x)
                    slider(slot, "Сверху, %", \.y)
                    slider(slot, "Ширина, %", \.w)
                    slider(slot, "Высота, %", \.h)
                }
            } header: { Text("Свой макет \(slot)") } footer: {
                if slot == WindowLayoutAction.customSlots.lowerBound {
                    SectionFooter("Восемь своих макетов: прямоугольник в долях экрана (от левого верхнего угла). Сочетания для них: на странице «Сочетания», группа «Свои макеты». Макеты можно ставить и на зоны краёв.")
                }
            }
        }
    }
}

struct WindowLayoutPanelCard: View {
    @ObservedObject private var c = WindowLayoutController.shared
    private let actions: [WindowLayoutAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize, .center, .restore, .nextDisplay]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Раскладка окон").font(.callout.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(actions, id: \.self) { a in
                    Button { c.runFromPanel(a) } label: {
                        LayoutThumb(fraction: a.fraction ?? (a == .center ? FractionRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5) : nil), width: 44, height: 28)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(a.title)
                }
            }
            if let m = c.lastMessage { Text(m).font(.caption).foregroundStyle(Theme.warn) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
