import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct ClipPage: View {
    var enabled: Set<ModuleID> = []

    var body: some View {
        SettingsPage {
            if enabled.contains(.clipboardHistory) { ClipHistorySections() }
            if enabled.contains(.pastePlain) { PastePlainSections() }
            if enabled.contains(.urlCleaner) { UrlCleanerSections() }
            if enabled.contains(.shelf) { ShelfSections() }
            if enabled.contains(.dmgInstaller) { DmgSections() }
            if enabled.contains(.finderCutPaste) || enabled.contains(.finderRename) { FinderSections(enabled: enabled) }
        }
        .navigationDestination(for: ClipRoute.self) { route in
            switch route {
            case .ignoredApps: ClipIgnoredAppsPage().navigationTitle("Игнорируемые приложения")
            case .urlManual: UrlManualPage().navigationTitle("Очистить вручную")
            case .urlRules: UrlRulesPage().navigationTitle("Правила для сайтов")
            }
        }
    }
}

private struct ClipIgnoredAppsPage: View {
    @ObservedObject private var c = ClipboardController.shared

    var body: some View {
        BundleListPage(footer: "Копирование из этих приложений не попадает в историю.", apps: Binding(get: { c.settings.ignoredApps }, set: { v in var s = c.settings; s.ignoredApps = v; c.update(s) }))
    }
}

private func sizeText(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

private func appName(_ bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

struct BundleListPage: View {
    var footer: String
    @Binding var apps: [String]
    @State private var newApp = ""

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
    }

    var body: some View {
        SettingsPage {
            Section {
                if apps.isEmpty { Text("Список пуст").foregroundStyle(.secondary) }
                ForEach(apps, id: \.self) { b in
                    LabeledContent {
                        Button("Убрать") { apps.removeAll { $0 == b } }
                    } label: {
                        SettingLabel(appName(b) ?? b, appName(b) == nil ? nil : b)
                    }
                }
            } header: { Text("Приложения") } footer: { SectionFooter(footer) }
            Section("Добавить") {
                TextField("Bundle ID", text: $newApp, prompt: Text("com.example.app"))
                Menu("Выбрать из запущенных") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "?") { newApp = app.bundleIdentifier ?? "" }
                    }
                }
                Button("Добавить") {
                    let b = newApp.trimmingCharacters(in: .whitespaces)
                    guard !b.isEmpty, !apps.contains(b) else { return }
                    apps.append(b)
                    newApp = ""
                }
                .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct ClipHistorySections: View {
    @ObservedObject private var c = ClipboardController.shared
    @State private var confirmClear = false

    private func binding<T>(_ kp: WritableKeyPath<ClipSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        Section {
            LabeledContent("Записей", value: "\(c.count) · \(sizeText(c.totalBytes))")
            LabeledContent("Показать историю") {
                HStack(spacing: 12) {
                    Button("Открыть") { c.picker.toggle() }
                    HotkeyRecorder(spec: c.spec, titles: [:])
                }
            }
            Picker(selection: binding(\.maxItems)) {
                ForEach(ClipSettings.countChoices + (ClipSettings.countChoices.contains(c.settings.maxItems) ? [] : [c.settings.maxItems]), id: \.self) { Text("\($0)").tag($0) }
            } label: { SettingLabel("Сколько записей хранить", "Закреплённые не считаются") }
            Picker(selection: binding(\.maxAgeDays)) {
                ForEach(ClipSettings.ageChoices + (ClipSettings.ageChoices.contains(c.settings.maxAgeDays) ? [] : [c.settings.maxAgeDays]), id: \.self) { Text($0 == 0 ? "бессрочно" : "\($0) дн.").tag($0) }
            } label: { SettingLabel("Срок хранения", "Старше удаляется, закреплённые остаются") }
            Picker(selection: binding(\.maxItemKB)) {
                ForEach([1024, 4096, 8192, 32768, 131_072], id: \.self) { Text(sizeText($0 * 1024)).tag($0) }
            } label: { SettingLabel("Максимальный размер записи", "Крупнее не сохраняется") }
            Picker(selection: binding(\.maxTotalMB)) {
                ForEach([64, 256, 1024, 4096], id: \.self) { Text(sizeText($0 * 1024 * 1024)).tag($0) }
            } label: { SettingLabel("Общий размер истории", "Лишнее убирается с самых старых") }
        } header: { Text("История буфера") } footer: {
            SectionFooter(c.storeError.map { "Хранилище недоступно: \($0)" } ?? "Хранится локально в базе Мультитула; закреплённые не удаляются лимитами.")
        }
        Section("Что запоминать") {
            Toggle(isOn: binding(\.keepRich)) { SettingLabel("Форматированный текст", "RTF и HTML рядом с обычным текстом; выключено — только текст") }
            Toggle(isOn: binding(\.keepImages)) { SettingLabel("Картинки", "Хранятся в базе целиком, до лимита размера записи") }
            Toggle(isOn: binding(\.keepFiles)) { SettingLabel("Файлы", "Только ссылки на место файла, сами файлы не копируются") }
            Toggle(isOn: binding(\.keepColors)) { SettingLabel("Цвета", "Цвета из палитр и пипеток") }
        }
        Section("Что не запоминать") {
            Toggle(isOn: binding(\.skipSensitive)) { SettingLabel("Пароли и токены", "Одиночные строки, похожие на пароль, ключ API, JWT или закрытый ключ") }
            Toggle(isOn: binding(\.skipConcealed)) { SettingLabel("Секретные копии менеджеров паролей", "Пометка ConcealedType: 1Password, KeePassXC и другие") }
            Toggle(isOn: binding(\.skipTransient)) { SettingLabel("Временные и автоматические копии", "Пометки TransientType и AutoGeneratedType") }
            NavigationLink(value: ClipRoute.ignoredApps) {
                LabeledContent("Игнорируемые приложения", value: "\(c.settings.ignoredApps.count)")
            }
        }
        Section("Выбор записи") {
            Toggle(isOn: binding(\.pasteOnPick)) { SettingLabel("Вставлять сразу при выборе", "Выключено: выбор только копирует запись в буфер") }
            Toggle(isOn: binding(\.menuBarPreview)) { SettingLabel("Последнее скопированное в строке меню", "Короткий текст рядом с иконкой; клик открывает историю") }
        }
        Section {
            Picker(selection: binding(\.autoClearSeconds)) {
                ForEach(ClipSettings.clearChoices, id: \.self) { Text($0 == 0 ? "не очищать" : ($0 >= 60 ? "\($0 / 60) мин" : "\($0) с")).tag($0) }
            } label: { SettingLabel("Очищать системный буфер через", "История не затрагивается; очищается, только если там всё ещё то же самое") }
            Toggle("При засыпании", isOn: binding(\.clearOnSleep))
            Toggle("При блокировке экрана", isOn: binding(\.clearOnLock))
            Button("Очистить системный буфер сейчас") { c.clearSystemClipboard() }
        } header: { Text("Системный буфер") }
        Section {
            Button("Очистить историю, закреплённые останутся") { c.clearHistory(keepPinned: true) }
            Button("Очистить всё…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Удалить всю историю, включая закреплённое?", isPresented: $confirmClear) {
                    Button("Удалить всё", role: .destructive) { c.clearHistory(keepPinned: false) }
                }
        }
    }
}

struct PastePlainSections: View {
    @ObservedObject private var c = PastePlainController.shared

    var body: some View {
        Section {
            LabeledContent("Вставить без форматирования") {
                HStack(spacing: 12) {
                    Button("Вставить сейчас") { c.run() }
                    HotkeyRecorder(spec: c.spec, titles: [:])
                }
            }
            Toggle("Обрезать пробелы и переводы строк по краям", isOn: Binding(get: { c.settings.trimEdges }, set: { v in var s = c.settings; s.trimEdges = v; c.update(s) }))
        } header: { Text("Вставка без форматирования") } footer: {
            if c.lastOutcome == .needsAccessibility {
                SectionFooter("Для вставки нужен Универсальный доступ: выдай его на странице «Модули».", color: .orange)
            } else {
                SectionFooter("Вставляет текст из буфера без шрифтов и цветов; через долю секунды оригинал с форматированием возвращается в буфер.")
            }
        }
    }
}

struct UrlCleanerSections: View {
    @ObservedObject private var c = UrlCleanerController.shared

    private func edit(_ f: (inout UrlCleanerSettings) -> Void) { var s = c.settings; f(&s); c.update(s) }

    var body: some View {
        Section {
            LabeledContent("Очищено ссылок", value: "\(c.cleaned)")
            LabeledContent("Очистить ссылку в буфере") {
                HStack(spacing: 12) {
                    Button("Очистить") { c.cleanNow() }
                    HotkeyRecorder(spec: c.spec, titles: [:])
                }
            }
            Toggle(isOn: Binding(get: { c.settings.cleanOnCopy }, set: { v in edit { $0.cleanOnCopy = v } })) { SettingLabel("Очищать сразу при копировании", "Работает с одиночной ссылкой http/https в тексте буфера") }
            Toggle("Показывать плашку", isOn: Binding(get: { c.settings.showHud }, set: { v in edit { $0.showHud = v } }))
            Toggle(isOn: Binding(get: { c.settings.rules.unwrapRedirects }, set: { v in edit { $0.rules.unwrapRedirects = v } })) { SettingLabel("Раскрывать ссылки-переходники", "Google /url, VK away.php, переходы Facebook, YouTube, Instagram, Steam и Slack: остаётся конечный адрес") }
            NavigationLink(value: ClipRoute.urlManual) { Text("Очистить вручную") }
            NavigationLink(value: ClipRoute.urlRules) {
                LabeledContent("Правила для сайтов", value: "\(UrlCleaner.hostRules.count + c.settings.rules.added.values.reduce(0) { $0 + $1.count })")
            }
        } header: { Text("Очистка ссылок") } footer: {
            SectionFooter(c.lastRemoved.isEmpty ? "Всё локально, без сети." : "Последний раз убрано: \(c.lastRemoved.joined(separator: ", ")).")
        }
    }
}

struct UrlManualPage: View {
    @ObservedObject private var c = UrlCleanerController.shared
    @State private var input = ""

    private var result: UrlCleanResult? { UrlCleaner.clean(input, rules: c.settings.rules) }

    var body: some View {
        SettingsPage {
            Section("Ссылка") {
                TextField("Ссылка", text: $input, prompt: Text("Вставьте ссылку"))
                Button("Взять из буфера") { input = NSPasteboard.general.string(forType: .string) ?? "" }
            }
            Section("Результат") {
                switch UrlCleaner.outcome(for: result) {
                case .notAUrl:
                    Text(input.isEmpty ? "Введите ссылку" : "Это не ссылка http/https").foregroundStyle(.secondary)
                case .unchanged:
                    Text("Нечего убирать").foregroundStyle(.secondary)
                case .cleaned(let removed, _):
                    Text(result?.url ?? "").monospaced().textSelection(.enabled)
                    LabeledContent("Убрано", value: removed.joined(separator: ", "))
                    Button("Скопировать") {
                        if let u = result?.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
                    }
                }
            }
        }
    }
}

struct UrlRulesPage: View {
    @ObservedObject private var c = UrlCleanerController.shared
    @State private var newSite = ""
    @State private var newName = ""

    private func edit(_ f: (inout UrlCleanerSettings) -> Void) { var s = c.settings; f(&s); c.update(s) }

    var body: some View {
        SettingsPage {
            Section {
                ForEach(UrlCleaner.hostRules.keys.sorted(), id: \.self) { site in
                    Toggle(isOn: Binding(get: { !c.settings.rules.disabledSites.contains(site) },
                                         set: { on in edit { if on { $0.rules.disabledSites.remove(site) } else { $0.rules.disabledSites.insert(site) } } })) {
                        SettingLabel(site, (UrlCleaner.hostRules[site] ?? []).sorted().joined(separator: ", "))
                    }
                }
            } header: { Text("Правила сайтов") } footer: {
                SectionFooter("Для всех сайтов убирается: utm_*, \(UrlCleaner.globalNames.count) известных меток. Правила сайтов нужны там, где одно имя бывает и меткой, и настоящим параметром (например, si у YouTube, t у X).")
            }
            Section("Свои правила") {
                ForEach(c.settings.rules.added.keys.sorted(), id: \.self) { site in
                    ForEach((c.settings.rules.added[site] ?? []).sorted(), id: \.self) { name in
                        LabeledContent {
                            HStack(spacing: 12) {
                                Text(name).monospaced()
                                Button("Убрать") { edit { $0.rules.added[site]?.remove(name); if $0.rules.added[site]?.isEmpty == true { $0.rules.added[site] = nil } } }
                            }
                        } label: { Text(site.isEmpty ? "все сайты" : site) }
                    }
                }
                TextField("Сайт", text: $newSite, prompt: Text("пусто — все сайты"))
                TextField("Параметр", text: $newName, prompt: Text("имя параметра, можно с *"))
                Button("Добавить") {
                    let name = newName.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !name.isEmpty else { return }
                    let site = newSite.trimmingCharacters(in: .whitespaces).lowercased()
                    edit { $0.rules.added[site, default: []].insert(name) }
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct DmgSections: View {
    @ObservedObject private var c = DmgController.shared

    private func edit(_ f: (inout DmgSettings) -> Void) { var s = c.settings; f(&s); c.update(s) }

    var body: some View {
        Section {
            LabeledContent("Установлено из образов", value: "\(c.installed)")
            Picker(selection: Binding(get: { c.settings.destination }, set: { v in edit { $0.destination = v } })) {
                ForEach(DmgDestination.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Куда устанавливать", "Для папки «Программы» может понадобиться право «Управление приложениями»") }
            Toggle(isOn: Binding(get: { c.settings.askFirst }, set: { v in edit { $0.askFirst = v } })) { SettingLabel("Спрашивать перед установкой", "Уведомление с кнопкой «Установить»; выключено — ставит сразу") }
            Toggle("Извлекать образ после установки", isOn: Binding(get: { c.settings.ejectAfter }, set: { v in edit { $0.ejectAfter = v } }))
            Toggle(isOn: Binding(get: { c.settings.trashDmg }, set: { v in edit { $0.trashDmg = v } })) { SettingLabel("Убирать dmg в Корзину", "Только после успешной установки и извлечения образа") }
            Toggle("Показывать установленное в Finder", isOn: Binding(get: { c.settings.reveal }, set: { v in edit { $0.reveal = v } }))
            Toggle(isOn: Binding(get: { c.settings.requireValidSignature }, set: { v in edit { $0.requireValidSignature = v } })) { SettingLabel("Требовать действующую подпись", "Без подписи или с нарушенной установка отменяется, образ остаётся смонтированным") }
            Toggle(isOn: Binding(get: { c.settings.reinstallSameVersion }, set: { v in edit { $0.reinstallSameVersion = v } })) { SettingLabel("Ставить поверх той же версии", "Выключено: если такая версия уже стоит, предложения не будет") }
            Toggle(isOn: Binding(get: { c.settings.watchDownloads }, set: { v in edit { $0.watchDownloads = v } })) { SettingLabel("Следить за папкой «Загрузки»", "Новый скачанный dmg монтируется сам (скрыто от Finder) и проверяется; macOS спросит доступ к «Загрузкам»") }
        } header: { Text("Образы dmg") } footer: {
            SectionFooter("\(c.lastLine). Образы с несколькими приложениями или только с установщиком .pkg пропускаются без уведомления.")
        }
    }
}

struct FinderSections: View {
    var enabled: Set<ModuleID>
    @ObservedObject private var cut = FinderCutController.shared
    @ObservedObject private var rename = FinderRenameController.shared

    var body: some View {
        if enabled.contains(.finderCutPaste) {
            Section {
                LabeledContent("Перехват ⌘X и ⌘V") {
                    Text(cut.tapActive ? "работает" : "нет перехвата").foregroundStyle(cut.tapActive ? Color.green : Color.orange)
                }
                if let c = cut.cut {
                    LabeledContent("Вырезано: \(c.paths.count)") { Button("Отменить") { cut.cancel() } }
                }
                Toggle(isOn: Binding(get: { cut.settings.pasteImage }, set: { v in var s = cut.settings; s.pasteImage = v; cut.update(s) })) { SettingLabel("⌘V с картинкой сохраняет PNG в открытую папку", "Только когда в буфере картинка, а не файлы") }
                Toggle(isOn: Binding(get: { cut.settings.indicator }, set: { v in var s = cut.settings; s.indicator = v; cut.update(s) })) { SettingLabel("Плавающий индикатор вырезанного", "Виден, пока Finder на переднем плане; крестик отменяет вырезание") }
            } header: { Text("Finder: вырезать и вставить") } footer: {
                SectionFooter("⌘X запоминает выделенное, ⌘V в нужной папке перемещает. В текстовых полях и при переименовании клавиши обычные. Файлы кладутся и в буфер, так что ⌘V в другом приложении вставит копию.")
            }
        }
        if enabled.contains(.finderRename) {
            Section {
                LabeledContent("Перехват клавиши") {
                    Text(rename.tapActive ? "работает" : "нет перехвата").foregroundStyle(rename.tapActive ? Color.green : Color.orange)
                }
                LabeledContent("Клавиша переименования") { HotkeyRecorder(spec: rename.spec, titles: [:]) }
                LabeledContent("Сработало раз", value: "\(rename.fired)")
            } header: { Text("Finder: переименование") } footer: {
                SectionFooter("Нажатие записанной клавиши в Finder открывает переименование выделенного файла. Работает только в Finder и не мешает текстовым полям. На клавиатурах, где F2 — яркость, нужен Fn-F2.")
            }
        }
    }
}
