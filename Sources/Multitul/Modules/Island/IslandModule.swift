import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

@MainActor
final class NotchModule: Module {
    let info = ModuleID.notch.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        let c = IslandController.shared
        c.start()
        if let n = IslConflictDetector.notice(c.conflicts) { HUD.show(n) }
    }

    func stop() { IslandController.shared.stop() }
}

struct IslandPage: View {
    var enabled: Set<ModuleID> = []

    var body: some View {
        SettingsPage {
            IslandSettingsSections()
            Section {
                NavigationLink(value: IslandRoute.sections) {
                    Label("Порядок и видимость разделов", systemImage: "list.bullet")
                }
                NavigationLink(value: IslandRoute.shortcuts) {
                    Label("Кнопки раздела «Ярлыки»", systemImage: "square.grid.2x2")
                }
                NavigationLink(value: IslandRoute.extensions) {
                    Label("Расширения острова", systemImage: "puzzlepiece.extension")
                }
            } header: { Text("Подробнее") }
        }
        .navigationDestination(for: IslandRoute.self) { route in
            switch route {
            case .sections: IslandSectionsPage().navigationTitle("Разделы")
            case .shortcuts: IslandShortcutsPage().navigationTitle("Ярлыки")
            case .extensions: IslandExtensionsPage(enabled: enabled).navigationTitle("Расширения")
            }
        }
    }
}

struct IslandSettingsSections: View {
    @ObservedObject private var ctl = IslandController.shared
    @ObservedObject private var music = IslandMusic.shared

    private func binding<T>(_ kp: WritableKeyPath<IslSettings, T>) -> Binding<T> {
        Binding(get: { ctl.settings[keyPath: kp] }, set: { v in var s = ctl.settings; s[keyPath: kp] = v; ctl.update(s) })
    }

    private var startBinding: Binding<String> {
        Binding(get: { ctl.settings.start.stored }, set: { v in var s = ctl.settings; s.start = IslStartChoice(stored: v); ctl.update(s) })
    }

    private var screensCount: Int {
        IslDisplaySelector.select(ctl.screens, mode: ctl.settings.displayMode, selected: ctl.settings.selectedDisplays, virtualPill: ctl.settings.virtualPill).count
    }

    var body: some View {
        Group {
            Section {
                LabeledContent("Состояние", value: ctl.running ? "работает, дисплеев с островом: \(screensCount)" : "модуль выключен")
                if let n = IslConflictDetector.notice(ctl.conflicts) {
                    ToolWarning(text: n)
                    Button("Закрыть конфликтующие") { ctl.terminateConflicts() }
                }
            } header: { Text("Остров вокруг выреза") }
            ToolsPermissionNote(permission: .accessibility, text: "Без «Универсального доступа» остров не знает, где в строке меню заканчиваются меню приложения, и не слышит Esc.")
            Section("Как открывается") {
                Toggle(isOn: binding(\.openOnHover)) { SettingLabel("Открывать при наведении", "Курсор на вырезе или капсуле открывает остров после короткой паузы") }
                SliderSetting("Задержка наведения", "\(String(format: "%.2f", ctl.settings.hoverDelay)) с; по умолчанию 0,25", value: binding(\.hoverDelay), in: IslSettings.hoverDelayRange)
                Toggle(isOn: binding(\.openOnScroll)) { SettingLabel("Открывать прокруткой вниз", "Два пальца вниз по вырезу на тачпаде или колесо мыши") }
                Toggle(isOn: binding(\.closeOnScrollUp)) { SettingLabel("Закрывать прокруткой вверх", "Только по верхнему ряду открытого острова; списки внутри прокручиваются как обычно") }
                Toggle(isOn: binding(\.openOnClick)) { SettingLabel("Открывать кликом", "Клик по закрытому острову открывает, по верхнему ряду открытого — закрывает") }
            }
            Section("Как закрывается") {
                Picker(selection: binding(\.closeBehavior)) {
                    ForEach(IslCloseBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Поведение при закрытии", ctl.settings.closeBehavior.summary) }
                if ctl.settings.closeBehavior == .onLeave {
                    SliderSetting("Пауза перед закрытием", "\(String(format: "%.1f", ctl.settings.leaveGrace)) с", value: binding(\.leaveGrace), in: IslSettings.leaveGraceRange)
                }
                Toggle(isOn: binding(\.peekOnChange)) { SettingLabel("Всплывать при событиях", "Смена трека, снимок, запись экрана: остров ненадолго показывает подробности") }
                if ctl.settings.peekOnChange {
                    SliderSetting("Сколько держится", "\(String(format: "%.1f", ctl.settings.peekDuration)) с", value: binding(\.peekDuration), in: IslSettings.peekDurationRange)
                }
            }
            Section("Вид") {
                Picker(selection: binding(\.sizePreset)) {
                    ForEach(IslSizePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Размер", "Ширина и высота открытого острова") }
                Picker(selection: startBinding) {
                    Text("Последний открытый").tag(IslStartChoice.last.stored)
                    Text("По активности (играет музыка, идёт запись)").tag(IslStartChoice.auto.stored)
                    ForEach(ctl.descriptors) { d in Text(d.title).tag(IslStartChoice.fixed(d.id.rawValue).stored) }
                } label: { SettingLabel("Раздел при открытии", "Какой раздел показывается сразу после открытия") }
                Picker(selection: binding(\.musicSwipe)) {
                    ForEach(IslSwipeAction.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Свайп влево-вправо над музыкой", "В других разделах свайп всегда листает разделы") }
                Toggle(isOn: binding(\.glass)) { SettingLabel("Стеклянный вид", "Открытый остров полупрозрачный с размытием; закрытый всегда чёрный, чтобы слиться с вырезом") }
                Toggle(isOn: binding(\.avoidMenus)) { SettingLabel("Не перекрывать меню", "Крылья закрытого острова сжимаются, чтобы не закрывать пункты меню активного приложения (нужен «Универсальный доступ»)") }
                Toggle(isOn: binding(\.hideInFullscreen)) { SettingLabel("Прятать в полноэкранном режиме", "В приложениях на весь экран остров не показывается; сочетание всё равно работает") }
                Toggle(isOn: binding(\.hideMenuIcon)) { SettingLabel("Скрыть значок в строке меню", "Настройки Мультитула тогда открываются шестерёнкой в верхнем ряду острова (или сочетанием «Открыть окно»)") }
            }
            Section("Дисплеи") {
                Picker(selection: binding(\.displayMode)) {
                    ForEach(IslDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Где показывать", ctl.settings.displayMode.title) }
                Toggle(isOn: binding(\.virtualPill)) { SettingLabel("Капсула на дисплеях без выреза", "Виртуальный остров в центре верхнего края") }
                ForEach(ctl.screens, id: \.id) { s in
                    let notch = IslNotchDetector.hasHardwareNotch(s)
                    if ctl.settings.displayMode == .selected {
                        Toggle(isOn: Binding(get: { ctl.settings.selectedDisplays.contains(s.key) }, set: { v in
                            var n = ctl.settings
                            if v { n.selectedDisplays.insert(s.key) } else { n.selectedDisplays.remove(s.key) }
                            ctl.update(n)
                        })) { Label(s.name.isEmpty ? "Дисплей \(s.id)" : s.name, systemImage: notch ? "macbook" : "display") }
                    } else {
                        LabeledContent {
                            Text(notch ? "вырез" : "без выреза").foregroundStyle(.secondary)
                        } label: { Label(s.name.isEmpty ? "Дисплей \(s.id)" : s.name, systemImage: notch ? "macbook" : "display") }
                    }
                }
            }
            Section("Живая активность в закрытом острове") {
                ForEach(ctl.descriptors) { d in
                    let on = !ctl.settings.mutedActivities.contains(d.id.rawValue)
                    Toggle(isOn: Binding(get: { on }, set: { v in var s = ctl.settings; if v { s.mutedActivities.remove(d.id.rawValue) } else { s.mutedActivities.insert(d.id.rawValue) }; ctl.update(s) })) {
                        Label(d.title, systemImage: d.symbol)
                    }
                }
            }
            if !music.notes.isEmpty {
                Section { ForEach(music.notes, id: \.self) { ToolWarning(text: $0) } }
            }
        }
        .onAppear { ctl.refreshConflicts() }
    }
}

struct IslandSectionsPage: View {
    @ObservedObject private var ctl = IslandController.shared

    var body: some View {
        let _ = ctl.revision
        let order = ctl.layout.resolved(known: ctl.descriptors)
        SettingsPage {
            Section {
                ForEach(order) { d in
                    let section = ctl.registry.section(d.id)
                    let hidden = ctl.layout.hidden.contains(d.id.rawValue)
                    LabeledContent {
                        HStack(spacing: 10) {
                            Button { var l = ctl.layout; l.nudge(d.id.rawValue, by: -1, known: ctl.descriptors); ctl.updateLayout(l) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                            Button { var l = ctl.layout; l.nudge(d.id.rawValue, by: 1, known: ctl.descriptors); ctl.updateLayout(l) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            Toggle("Показывать", isOn: Binding(get: { !hidden }, set: { v in var l = ctl.layout; l.setHidden(d.id.rawValue, !v); ctl.updateLayout(l) })).labelsHidden()
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title)
                                Text(section?.availability.reason ?? d.summary).font(.caption)
                                    .foregroundStyle(section?.availability.isAvailable == false ? Color.orange : Color.secondary).lineLimit(1)
                            }
                        } icon: { Image(systemName: d.symbol) }
                    }
                }
                .onMove { from, to in
                    var ids = order.map(\.id.rawValue)
                    ids.move(fromOffsets: from, toOffset: to)
                    var l = ctl.layout
                    l.order = ids
                    ctl.updateLayout(l)
                }
            } header: { Text("Порядок и видимость разделов") } footer: {
                SectionFooter("Тяни за строку или жми стрелки. Раздел без нужного модуля в острове не показывается, даже если включён здесь.")
            }
            Section { Button("Сбросить порядок") { ctl.resetLayout() } }
        }
    }
}

struct IslandShortcutsPage: View {
    @ObservedObject private var ctl = IslandController.shared
    @State private var kind = 0
    @State private var value = ""
    @State private var title = ""
    @State private var error = ""
    private let checker = FileSystemLauncherChecker()

    private func mutate(_ f: (inout IslShortcutList) -> Void) {
        var l = ctl.shortcuts
        f(&l)
        ctl.updateShortcuts(l)
    }

    var body: some View {
        SettingsPage {
            Section {
                if ctl.shortcuts.items.isEmpty {
                    ContentUnavailableView("Кнопок нет", systemImage: "square.grid.2x2", description: Text("Добавьте инструмент, переключатель, приложение, ссылку или скрипт"))
                }
                ForEach(ctl.shortcuts.items) { item in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Button { mutate { $0.nudge(item.id, by: -1) } } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                            Button { mutate { $0.nudge(item.id, by: 1) } } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            Button { mutate { $0.remove(id: item.id) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    } label: {
                        Label {
                            SettingLabel(item.title, item.target.kindTitle)
                        } icon: { Image(systemName: item.symbol) }
                    }
                }
            } header: { Text("Кнопки раздела «Ярлыки»") } footer: {
                SectionFooter("До \(IslShortcutList.maxItems) кнопок: инструменты Мультитула, переключатели, приложения, ссылки и скрипты. Порядок меняется стрелками.")
            }
            Section {
                Picker("Что добавить", selection: $kind) {
                    Text("Инструмент").tag(0)
                    Text("Переключатель").tag(1)
                    Text("Приложение").tag(2)
                    Text("Ссылка").tag(3)
                    Text("Скрипт").tag(4)
                }
                if kind == 0 {
                    Menu("Выбрать инструмент") { ForEach(LauncherTool.allCases) { t in Button(t.title) { add(.tool(t)) } } }
                } else if kind == 1 {
                    Menu("Выбрать переключатель") { ForEach(QuickToggleID.allCases) { t in Button(t.title) { add(.toggle(t)) } } }
                } else {
                    TextField(kind == 3 ? "Ссылка" : "Путь или bundle id", text: $value, prompt: Text(kind == 3 ? "https://…" : "Путь или bundle id"))
                    if kind != 3 { Button("Выбрать файл…") { pick() } }
                    TextField("Название", text: $title, prompt: Text("необязательно"))
                    Button("Добавить") { addTyped() }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Добавить") } footer: {
                if !error.isEmpty { SectionFooter(error, color: .orange) }
            }
            Section { Button("Вернуть набор по умолчанию") { mutate { $0.reset() } } }
        }
    }

    private func add(_ t: LauncherTarget) {
        var l = ctl.shortcuts
        switch l.add(t, title: title, fs: checker) {
        case .success: error = ""; ctl.updateShortcuts(l)
        case .failure(let e): error = e.message
        }
    }

    private func addTyped() {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case 2: add(.app(v))
        case 3: add(.url(v))
        default: add(.script(v))
        }
        if error.isEmpty { value = ""; title = "" }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        if kind == 2 { p.allowedContentTypes = [.application] }
        if p.runModal() == .OK, let u = p.url { value = u.path }
    }
}

struct IslandExtLink<Content: View>: View {
    let module: ModuleID
    let enabled: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationLink {
            Group {
                if enabled {
                    SettingsPage { content() }
                } else {
                    ContentUnavailableView {
                        Label("\(module.info.title): модуль выключен", systemImage: module.info.symbol)
                    } description: {
                        Text("Включите модуль на странице «Модули», чтобы он заработал и появились его настройки.")
                    }
                }
            }
            .navigationTitle(module.info.title)
        } label: {
            LabeledContent {
                Text(enabled ? "включён" : "выключен").foregroundStyle(.secondary)
            } label: { Label(module.info.title, systemImage: module.info.symbol) }
        }
    }
}

struct IslandExtensionsPage: View {
    let enabled: Set<ModuleID>

    var body: some View {
        SettingsPage {
            Section {
                IslandExtLink(module: .notchCalendar, enabled: enabled.contains(.notchCalendar)) { IslandCalendarSettings(service: .shared) }
                IslandExtLink(module: .notchNotifications, enabled: enabled.contains(.notchNotifications)) { IslandNotificationsSettings(service: .shared) }
                IslandExtLink(module: .notchTimer, enabled: enabled.contains(.notchTimer)) { IslandTimerSettings(service: .shared) }
                IslandExtLink(module: .notchAccessories, enabled: enabled.contains(.notchAccessories)) { IslandAccessoriesSettings(service: .shared) }
                IslandExtLink(module: .notchLyrics, enabled: enabled.contains(.notchLyrics)) { IslandLyricsSettings(service: .shared) }
                IslandExtLink(module: .notchQueue, enabled: enabled.contains(.notchQueue)) { IslandQueueSettings(service: .shared) }
                IslandExtLink(module: .notchLiveEq, enabled: enabled.contains(.notchLiveEq)) { IslandLiveEqSettings(service: .shared) }
                IslandExtLink(module: .notchDownloads, enabled: enabled.contains(.notchDownloads)) { IslandDownloadsSettings(service: .shared) }
                IslandExtLink(module: .notchWatch, enabled: enabled.contains(.notchWatch)) { IslandWatchSettings(service: .shared) }
                IslandExtLink(module: .notchMascot, enabled: enabled.contains(.notchMascot)) { IslandMascotSettings(service: .shared) }
            } header: { Text("Расширения острова") } footer: {
                SectionFooter("Каждое расширение включается отдельно на странице «Модули» и работает, пока включён сам «Остров».")
            }
        }
    }
}
