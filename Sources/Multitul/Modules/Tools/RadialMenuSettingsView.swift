import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

struct RadialMenuSections: View {
    @ObservedObject private var c = RadialMenuController.shared

    private func mutate(_ f: (inout RadialSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    private var profileIndex: Int { c.settings.profiles.firstIndex { $0.id == c.settings.activeProfileID } ?? 0 }

    var body: some View {
        ToolsPermissionNote(permission: .accessibility, text: "Сочетания, кнопка мыши и действия-клавиши работают через «Универсальный доступ»")
        Section {
            HStack {
                Spacer()
                RadialWheelView(state: c.previewState).scaleEffect(0.32).frame(width: 110, height: 110).clipped()
                Spacer()
            }
        } header: { Text("Радиальное меню") } footer: {
            SectionFooter("Держишь сочетание, наводишь на сектор, отпускаешь. Короткое нажатие оставляет колесо открытым: тогда выбирай кликом, цифрами 1–9 и 0, Esc закрывает. Подменю открывается выбором, назад — клик в центр или ⌫.")
        }
        Section {
            Toggle("Сочетание клавиш (держать)", isOn: Binding(get: { c.settings.trigger.hotkeyEnabled }, set: { v in mutate { $0.trigger.hotkeyEnabled = v } }))
            if c.settings.trigger.hotkeyEnabled {
                LabeledContent {
                    ComboField(combo: Binding(get: { c.settings.trigger.hotkey }, set: { v in
                        guard let v, !v.isNone, v.modifiers != 0 else { return }
                        mutate { $0.trigger.hotkey = v }
                    }))
                } label: { SettingLabel("Сочетание", "Модификаторы + клавиша, по умолчанию ⌃⌥⌘Space") }
            }
            Picker(selection: Binding(get: { c.settings.trigger.mouseButton ?? -1 }, set: { v in mutate { $0.trigger.mouseButton = v < 0 ? nil : v } })) {
                Text("Не использовать").tag(-1)
                ForEach(RadialTriggerConfig.buttonChoices, id: \.self) { Text(RadialTriggerConfig.buttonTitle($0)).tag($0) }
            } label: { SettingLabel("Кнопка мыши", "Удерживать боковую или среднюю кнопку; обычные левая и правая не подходят") }
            Toggle(isOn: Binding(get: { c.settings.trigger.fourFingerTap }, set: { v in mutate { $0.trigger.fourFingerTap = v } })) {
                SettingLabel("Тап четырьмя пальцами по трекпаду", "Колесо остаётся открытым")
            }
        } header: { Text("Как вызвать") } footer: {
            if c.settings.trigger.fourFingerTap {
                SectionFooter(c.touchFailed ? "Трекпад не отдал касания: тап не будет работать." : "Если в «Жестах трекпада» включены четыре пальца (Mission Control, Launchpad), система и колесо могут срабатывать вместе.", color: c.touchFailed ? .orange : .secondary)
            }
        }
        Section {
            Picker("Профиль", selection: Binding(get: { c.settings.activeProfileID }, set: { v in mutate { $0.activeProfileID = v } })) {
                ForEach(c.settings.profiles) { Text($0.name).tag($0.id) }
            }
            FieldSetting("Название", text: Binding(get: { c.settings.activeProfile.name }, set: { v in mutate { $0.profiles[profileIndex].name = v } }), prompt: "Профиль")
            FieldSetting("Приложения", "Bundle ID через запятую", text: Binding(get: { c.settings.activeProfile.bundleIDs.joined(separator: ", ") }, set: { v in
                mutate { $0.profiles[profileIndex].bundleIDs = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }), prompt: "com.apple.Safari")
            Button("Добавить активное приложение") {
                if let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, b != Bundle.main.bundleIdentifier {
                    mutate { if !$0.profiles[profileIndex].bundleIDs.contains(b) { $0.profiles[profileIndex].bundleIDs.append(b) } }
                }
            }
            Toggle("Подменять профиль, когда впереди приложение из списка", isOn: Binding(get: { c.settings.switchByApp }, set: { v in mutate { $0.switchByApp = v } }))
            Button("Новый профиль") {
                mutate { s in
                    guard s.profiles.count < RadialSettings.maxProfiles else { return }
                    let p = RadialProfile(name: "Профиль \(s.profiles.count + 1)")
                    s.profiles.append(p)
                    s.activeProfileID = p.id
                }
            }
            Button("Удалить профиль", role: .destructive) {
                mutate { s in
                    guard s.profiles.count > 1 else { return }
                    s.profiles.removeAll { $0.id == s.activeProfileID }
                    s.activeProfileID = s.profiles[0].id
                }
            }
            .disabled(c.settings.profiles.count < 2)
        } header: { Text("Профили") }
        Section {
            NavigationLink(value: ToolRoute.radialItems) {
                LabeledContent("Пункты колеса", value: "\(c.settings.activeProfile.items.count)")
            }
        } footer: { SectionFooter("До 12 пунктов, подменю — до 3 уровней.") }
        Section("Вид и отзывчивость") {
            StepperSetting("Мёртвая зона в центре", value: Binding(get: { Int(c.settings.innerRadius) }, set: { v in mutate { $0.innerRadius = Double(v) } }), in: Int(RadialSettings.innerRange.lowerBound)...Int(RadialSettings.innerRange.upperBound), step: 2, unit: " pt")
            StepperSetting("Радиус колеса", value: Binding(get: { Int(c.settings.ringRadius) }, set: { v in mutate { $0.ringRadius = Double(v) } }), in: Int(RadialSettings.ringRange.lowerBound)...Int(RadialSettings.ringRange.upperBound), step: 5, unit: " pt")
            StepperSetting("Быстрое нажатие короче", "Такое нажатие оставляет колесо открытым", value: Binding(get: { c.settings.stickyMs }, set: { v in mutate { $0.stickyMs = v } }), in: RadialSettings.stickyRange, step: 25, unit: " мс")
            Toggle("Подписи под значками", isOn: Binding(get: { c.settings.showTitles }, set: { v in mutate { $0.showTitles = v } }))
        }
    }
}

struct RadialItemsPage: View {
    @ObservedObject private var c = RadialMenuController.shared
    @State private var urlText = ""
    @State private var message = ""

    private func mutate(_ f: (inout RadialSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    private var profileIndex: Int { c.settings.profiles.firstIndex { $0.id == c.settings.activeProfileID } ?? 0 }

    private var itemsBinding: Binding<[RadialItem]> {
        Binding(get: { c.settings.activeProfile.items }, set: { v in mutate { $0.profiles[profileIndex].items = v } })
    }

    var body: some View {
        SettingsPage {
            Section {
                RadialItemsEditor(items: itemsBinding, depth: 1)
            } header: { Text("Пункты профиля «\(c.settings.activeProfile.name)»") } footer: {
                SectionFooter("До 12 пунктов, подменю — до 3 уровней.")
            }
            Section {
                RadialAddMenu(items: itemsBinding)
            }
            Section {
                TextField("Ссылка", text: $urlText, prompt: Text("example.com или https://…"))
                Button("Добавить ссылку") { addURL() }.disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Ссылка") } footer: {
                if !message.isEmpty { SectionFooter(message, color: .orange) }
            }
        }
    }

    private func addURL() {
        switch LauncherResolver.normalizeURL(urlText) {
        case .success(let u):
            guard itemsBinding.wrappedValue.count < RadialSettings.maxItems else { message = "В кольце уже 12 пунктов"; return }
            var items = itemsBinding.wrappedValue
            items.append(RadialItem(title: u.host ?? "Ссылка", action: .target(.url(u.absoluteString))))
            itemsBinding.wrappedValue = items
            urlText = ""
            message = ""
        case .failure(let e): message = e.message
        }
    }
}

struct RadialAddMenu: View {
    @Binding var items: [RadialItem]

    private func add(_ item: RadialItem) {
        guard items.count < RadialSettings.maxItems else { return }
        items.append(item)
    }

    var body: some View {
        Menu("Добавить") {
            Menu("Инструмент") { ForEach(LauncherTool.allCases) { t in Button(t.title) { add(RadialItem(title: t.title, action: .target(.tool(t)))) } } }
            Menu("Переключатель") { ForEach(QuickToggleID.allCases) { t in Button(t.title) { add(RadialItem(title: t.title, action: .target(.toggle(t)))) } } }
            Button("Приложение…") { pick(types: [.application], dir: "/Applications") { add(RadialItem(title: ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), action: .target(.app($0)))) } }
            Button("Файл или папка…") { pick(types: [.item, .folder], dir: NSHomeDirectory(), folders: true) { add(RadialItem(title: ($0 as NSString).lastPathComponent, action: .file($0))) } }
            Button("Скрипт…") { pick(types: [.item], dir: NSHomeDirectory()) { add(RadialItem(title: ($0 as NSString).lastPathComponent, action: .target(.script($0)))) } }
            Button("Сочетание клавиш") { add(RadialItem(title: "Сочетание", action: .keys(KeyCombo(keyCode: Keys.up, modifiers: KeyCombo.ctrl)))) }
            Button("Подменю") { add(RadialItem(title: "Подменю", action: .submenu([]))) }
        }
    }

    private func pick(types: [UTType], dir: String, folders: Bool = false, _ done: (String) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.canChooseDirectories = folders
        p.directoryURL = URL(fileURLWithPath: dir)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

struct RadialItemsEditor: View {
    @Binding var items: [RadialItem]
    let depth: Int

    var body: some View {
        ForEach(items) { item in
            LabeledContent {
                HStack(spacing: 10) {
                    if case .keys(let k) = item.action {
                        ComboField(combo: Binding(get: { k }, set: { v in if let v, !v.isNone { update(item.id) { $0.action = .keys(v) } } }))
                    }
                    Button { move(item.id, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { move(item.id, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            } label: {
                HStack {
                    Image(systemName: item.symbol).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Название", text: Binding(get: { item.title }, set: { v in update(item.id) { $0.title = v } }))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if item.isSubmenu {
                if depth >= RadialSettings.maxDepth {
                    ToolWarning(text: "Глубже подменю не бывает").padding(.leading, 28)
                } else {
                    LabeledContent {
                        RadialAddMenu(items: childBinding(item.id))
                    } label: { Text("Внутри подменю «\(item.title)»").foregroundStyle(.secondary) }
                    .padding(.leading, 28)
                    RadialItemsEditor(items: childBinding(item.id), depth: depth + 1).padding(.leading, 28)
                }
            }
        }
        if items.isEmpty && depth == 1 { ToolWarning(text: "Пунктов нет: колесо не откроется") }
    }

    private func update(_ id: String, _ f: (inout RadialItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        f(&item)
        items[i] = item
    }

    private func move(_ id: String, _ d: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), items.indices.contains(i + d) else { return }
        items.swapAt(i, i + d)
    }

    private func childBinding(_ id: String) -> Binding<[RadialItem]> {
        Binding(get: { items.first { $0.id == id }?.children ?? [] }, set: { v in update(id) { $0.action = .submenu(v) } })
    }
}
