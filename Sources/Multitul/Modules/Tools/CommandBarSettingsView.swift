import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

struct CommandBarSections: View {
    @ObservedObject private var c = CommandBarController.shared

    private func mutate(_ f: (inout CommandBarSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    private func flag(_ kp: WritableKeyPath<CommandBarSettings, Bool>) -> Binding<Bool> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in mutate { $0[keyPath: kp] = v } })
    }

    private func number(_ kp: WritableKeyPath<CommandBarSettings, Int>) -> Binding<Int> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in mutate { $0[keyPath: kp] = v } })
    }

    private var ratesStatus: String {
        guard let t = c.ratesService.table else { return "Курсы ещё не загружались" }
        return "Курсы на \(t.date ?? "неизвестную дату"), валют: \(t.rates.count)"
    }

    var body: some View {
        ToolsPermissionNote(permission: .accessibility, text: "Пункты меню приложений, вставка и перетаскивание читаются через «Универсальный доступ»")
        Section {
            Button("Показать строку") { c.toggle() }
        } header: { Text("Командная строка") } footer: {
            SectionFooter("Одно поле поверх всего. Набранное не сохраняется: запоминается только то, что ты запустил. Префиксы: = расчёт · win окна · f файлы · clip буфер · menu меню · : эмодзи · kill процесс · rm удалить приложение · run скрипт · > команды · ? поиск в сети. Без префикса ищется всё сразу.")
        }
        Section {
            ForEach(CbProviderID.allCases) { p in
                Toggle(isOn: Binding(get: { c.settings.isEnabled(p) }, set: { on in
                    mutate { if on { $0.disabledProviders.remove(p) } else { $0.disabledProviders.insert(p) } }
                })) { Label(p.title, systemImage: p.symbol) }
                if p.globalByDefault {
                    Toggle(isOn: Binding(get: { !c.settings.excludedFromGlobal.contains(p) }, set: { on in
                        mutate { if on { $0.excludedFromGlobal.remove(p) } else { $0.excludedFromGlobal.insert(p) } }
                    })) { Text("Искать «\(p.title)» в общем поиске").foregroundStyle(.secondary) }
                    .disabled(!c.settings.isEnabled(p))
                }
            }
        } header: { Text("Что искать") } footer: {
            SectionFooter("Процессы работают при включённом модуле «Завершение процессов», удаление приложений — при включённом «Удаление приложений», сниппеты и буфер — при включённых их модулях.")
        }
        Section {
            StepperSetting("Строк в выдаче", value: number(\.maxResults), in: CommandBarSettings.maxResultsRange)
            StepperSetting("Записей буфера в выдаче", value: number(\.clipboardLimit), in: 1...20)
            Toggle("Закрывать строку после запуска", isOn: flag(\.closeAfterRun))
            Toggle("Показывать цифры ⌘1–9", isOn: flag(\.showNumbers))
            Toggle(isOn: flag(\.pasteResults)) { SettingLabel("Вставлять результат в приложение", "Выключено: результат только копируется") }
            Toggle(isOn: flag(\.useFrecency)) { SettingLabel("Поднимать часто запускаемое", "Учёт частоты и давности") }
            LabeledContent("Запомнено пунктов", value: "\(c.usageKeyCount)")
            Button("Забыть всё", role: .destructive) { c.clearUsage() }
        } header: { Text("Общее") }
        Section {
            Picker("Углы в sin, cos, tan", selection: Binding(get: { c.settings.calcAngle }, set: { v in mutate { $0.calcAngle = v } })) {
                ForEach(CalcAngle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Десятичная запятая в результате", isOn: flag(\.decimalComma))
            Toggle("Пробелы между тысячами", isOn: flag(\.grouping))
            Toggle(isOn: flag(\.currencyOnline)) { SettingLabel("Загружать курсы валют", "ЦБ РФ через cbr-xml-daily.ru, не чаще раза в 6 часов") }
            LabeledContent("Курсы", value: ratesStatus)
            Button("Обновить сейчас") { c.refreshRates(force: true) }
        } header: { Text("Калькулятор, единицы, валюты") } footer: {
            SectionFooter("Из строки в сеть уходит только запрос таблицы курсов, набранный текст никуда не отправляется.")
        }
        Section {
            NavigationLink(value: ToolRoute.commandFiles) {
                LabeledContent("Файлы и скрипты", value: "\(c.settings.fileFolders.count) папок")
            }
            NavigationLink(value: ToolRoute.commandEntries) {
                LabeledContent("Мои пункты", value: "\(c.settings.userEntries.count)")
            }
            NavigationLink(value: ToolRoute.commandSlots) { Text("Сочетания для пунктов") }
            NavigationLink(value: ToolRoute.commandQuicklinks) {
                LabeledContent("Быстрые ссылки и поиск в сети", value: "\(c.settings.quicklinks.count)")
            }
        } header: { Text("Подробнее") }
    }
}

struct CommandFilesPage: View {
    @ObservedObject private var c = CommandBarController.shared

    private func mutate(_ f: (inout CommandBarSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    var body: some View {
        SettingsPage {
            Section {
                if c.settings.fileFolders.isEmpty { ToolWarning(text: "Папок нет: файлы не ищутся") }
                ForEach(c.settings.fileFolders, id: \.self) { f in
                    LabeledContent {
                        Button { mutate { $0.fileFolders.removeAll { $0 == f } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    } label: { Label(f, systemImage: "folder").lineLimit(1) }
                }
                Button("Добавить папку…") { addFolder() }
                StepperSetting("Файлов в выдаче", value: Binding(get: { c.settings.fileLimit }, set: { v in mutate { $0.fileLimit = v } }), in: CommandBarSettings.fileLimitRange)
            } header: { Text("Папки для поиска файлов") }
            Section {
                FieldSetting("Папка скриптов", text: Binding(get: { c.settings.scriptsFolder }, set: { v in mutate { $0.scriptsFolder = v } }), prompt: MultitulPaths.home + "/scripts")
                Button("Открыть папку") { openScriptsFolder() }
            } header: { Text("Скрипты") } footer: {
                SectionFooter("Скрипты .sh, .zsh, .command, .py, .scpt, .applescript из этой папки находятся по имени и запускаются из строки.")
            }
        }
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Добавить"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        mutate { s in for u in p.urls where !s.fileFolders.contains(u.path) { s.fileFolders.append(u.path) } }
    }

    private func openScriptsFolder() {
        let dir = c.settings.resolvedScriptsFolder
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}

struct CommandEntriesPage: View {
    @ObservedObject private var c = CommandBarController.shared
    @State private var urlText = ""
    @State private var message = ""

    private func mutate(_ f: (inout CommandBarSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    var body: some View {
        SettingsPage {
            if c.settings.userEntries.isEmpty {
                Section {
                    ContentUnavailableView("Пунктов нет", systemImage: "list.bullet", description: Text("Добавьте приложение, скрипт, ссылку или инструмент, дайте ему свои имена через запятую и, если нужно, номер сочетания"))
                }
            }
            ForEach(c.settings.userEntries) { e in
                CommandEntrySection(entry: e) { updated in mutate { s in if let i = s.userEntries.firstIndex(where: { $0.id == e.id }) { s.userEntries[i] = updated } } }
                    remove: { mutate { $0.userEntries.removeAll { $0.id == e.id } } }
            }
            Section {
                addMenu
            }
            Section {
                TextField("Ссылка", text: $urlText, prompt: Text("example.com или https://…"))
                Button("Добавить ссылку") { addEntry(.url(urlText)); if message.isEmpty { urlText = "" } }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Ссылка") } footer: {
                if !message.isEmpty { SectionFooter(message, color: .orange) }
            }
            Section {
                Toggle("Искать и в Быстрой палитре", isOn: Binding(get: { c.settings.includeLauncherItems }, set: { v in mutate { $0.includeLauncherItems = v } }))
            }
        }
    }

    private func addEntry(_ t: LauncherTarget) {
        var target = t
        if case .url(let raw) = t {
            switch LauncherResolver.normalizeURL(raw) {
            case .success(let u): target = .url(u.absoluteString)
            case .failure(let e): message = e.message; return
            }
        }
        message = ""
        mutate { s in
            guard s.userEntries.count < CommandBarSettings.maxEntries else { return }
            s.userEntries.append(CbUserEntry(title: "", target: target))
        }
    }

    private var addMenu: some View {
        Menu("Добавить") {
            Menu("Инструмент") { ForEach(LauncherTool.allCases.filter { $0 != .commandBar }) { t in Button(t.title) { addEntry(.tool(t)) } } }
            Menu("Переключатель") { ForEach(QuickToggleID.allCases) { t in Button(t.title) { addEntry(.toggle(t)) } } }
            Button("Приложение…") { pick(types: [.application], dir: "/Applications") { addEntry(.app($0)) } }
            Button("Скрипт…") { pick(types: [.item], dir: NSHomeDirectory()) { addEntry(.script($0)) } }
        }
    }

    private func pick(types: [UTType], dir: String, _ done: (String) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: dir)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

struct CommandSlotsPage: View {
    @ObservedObject private var c = CommandBarController.shared

    var body: some View {
        SettingsPage {
            Section {
                ForEach(1...CommandBarSettings.slotCount, id: \.self) { n in
                    HotkeyLine(c.settings.entry(slot: n)?.title ?? "Пункт \(n) не назначен", spec: CommandBarHotkeys.slots[n - 1])
                }
            } footer: {
                SectionFooter("Сочетание запускает мой пункт с этим номером из любого приложения, строка не открывается.")
            }
        }
    }
}

struct CommandQuicklinksPage: View {
    @ObservedObject private var c = CommandBarController.shared
    @State private var newLink = (name: "", keyword: "", template: "")

    private func mutate(_ f: (inout CommandBarSettings) -> Void) {
        var s = c.settings
        f(&s)
        c.update(s)
    }

    var body: some View {
        SettingsPage {
            Section {
                ForEach(c.settings.quicklinks) { l in
                    LabeledContent {
                        Button { mutate { $0.quicklinks.removeAll { $0.id == l.id } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    } label: {
                        Label {
                            SettingLabel("\(l.name) · \(l.keyword)", l.template)
                        } icon: { Image(systemName: l.symbol) }
                    }
                }
                Button("Сбросить к стандартным", role: .destructive) { mutate { $0.quicklinks = CbQuicklink.defaults } }
            } header: { Text("Быстрые ссылки") } footer: {
                SectionFooter("Ключ и текст: «g погода» ищет в Google. В адресе {query} заменяется на текст запроса.")
            }
            Section("Новая ссылка") {
                TextField("Название", text: $newLink.name)
                TextField("Ключ", text: $newLink.keyword)
                TextField("Адрес", text: $newLink.template, prompt: Text("https://…?q={query}"))
                Button("Добавить") {
                    mutate { $0.quicklinks.append(CbQuicklink(name: newLink.name, keyword: newLink.keyword, template: newLink.template)) }
                    newLink = ("", "", "")
                }
                .disabled(newLink.name.isEmpty || newLink.keyword.isEmpty || newLink.template.isEmpty)
            }
            Section("Поиск в сети") {
                Toggle("Предлагать поиск в сети, если ничего не нашлось", isOn: Binding(get: { c.settings.webFallback }, set: { v in mutate { $0.webFallback = v } }))
                Picker("Поисковик", selection: Binding(get: { c.settings.webEngine?.id ?? "" }, set: { v in mutate { $0.webEngineID = v } })) {
                    ForEach(c.settings.quicklinks.filter(\.takesQuery)) { Text($0.name).tag($0.id) }
                }
            }
        }
    }
}

struct CommandEntrySection: View {
    let entry: CbUserEntry
    let save: (CbUserEntry) -> Void
    let remove: () -> Void
    @State private var title = ""
    @State private var aliases = ""

    var body: some View {
        Section {
            TextField("Название", text: $title).onSubmit(commit)
            TextField("Другие имена", text: $aliases, prompt: Text("через запятую")).onSubmit(commit)
            Picker("Сочетание", selection: Binding(get: { entry.slot ?? 0 }, set: { v in var e = entry; e.slot = v == 0 ? nil : v; save(e) })) {
                Text("без сочетания").tag(0)
                ForEach(1...CommandBarSettings.slotCount, id: \.self) { Text("№\($0)").tag($0) }
            }
            Button("Убрать пункт", role: .destructive, action: remove)
        } header: {
            Label(CbEntriesProvider.detail(entry.target), systemImage: entry.target.defaultSymbol).lineLimit(1)
        }
        .onAppear { title = entry.title; aliases = entry.aliases.joined(separator: ", ") }
    }

    private func commit() {
        var e = entry
        e.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? entry.target.defaultTitle : title
        e.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        save(e)
    }
}
