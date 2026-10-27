import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct BrewDetail: Equatable {
    var package: BrewPackage
    var tree: BrewDepNode?
    var dependents: [String]
    var loading: Bool
}

@MainActor
final class HomebrewController: ObservableObject {
    static let shared = HomebrewController()

    @Published private(set) var revision = 0
    @Published private(set) var settings = BrewSettings()
    @Published private(set) var detail: BrewDetail?
    @Published private(set) var cleanupBusy = false
    let manager: BrewManager

    private let store = BrewSettingsStore()
    private let opener = TerminalAppleScriptOpener()
    private var running = false
    private var lastNotifiedCount = 0

    private init() {
        manager = BrewManager(runner: SystemManagerRunner(), locator: ToolLocator(files: FileSystemLauncherChecker()))
        manager.terminal = opener
        manager.onChange = { [weak self] in self?.revision += 1 }
    }

    var snapshot: BrewSnapshot { manager.snapshot }
    var jobs: [JobSnapshot] { manager.queue.jobs }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        manager.settings = settings
        manager.detect()
        if settings.refreshOnOpen { refresh() }
        revision += 1
    }

    func stop() {
        guard running else { return }
        running = false
        manager.queue.cancelAll()
    }

    func update(_ s: BrewSettings) {
        settings = s.sanitized
        store.save(settings)
        manager.settings = settings
        revision += 1
    }

    func refresh() {
        Task {
            manager.detect()
            await manager.refresh()
            notifyOutdated()
            revision += 1
        }
    }

    private func notifyOutdated() {
        let n = manager.snapshot.outdatedCount
        guard settings.notifyOutdated, n > 0, n != lastNotifiedCount else { lastNotifiedCount = n; return }
        lastNotifiedCount = n
        Notifier.shared.post(title: "Homebrew", body: "Есть обновления: \(n)", id: "homebrew-outdated")
    }

    func search(_ q: String) { Task { await manager.search(q); revision += 1 } }

    func showDetail(_ p: BrewPackage) {
        detail = BrewDetail(package: p, tree: nil, dependents: [], loading: true)
        Task {
            let full = await manager.details(of: p.name, kind: p.kind) ?? p
            var merged = full
            merged.installedVersion = p.installedVersion ?? full.installedVersion
            merged.pinned = p.pinned || full.pinned
            merged.outdated = p.outdated
            let tree = p.kind == .formula ? await manager.dependencyTree(of: p.name) : nil
            let uses = p.kind == .formula ? await manager.dependents(of: p.name) : []
            detail = BrewDetail(package: merged, tree: tree, dependents: uses, loading: false)
        }
    }

    func closeDetail() { detail = nil }

    func previewCleanup() { cleanupBusy = true; Task { await manager.previewCleanup(); cleanupBusy = false; revision += 1 } }
    func previewOrphans() { cleanupBusy = true; Task { await manager.previewOrphans(); cleanupBusy = false; revision += 1 } }

    func openTerminalFor(job id: Int) {
        if !manager.openInTerminal(job: id) { HUD.show("Не удалось открыть Terminal") }
    }

    func install(_ name: String, _ kind: BrewKind) { manager.install(name, kind: kind); revision += 1 }
    func upgrade(_ name: String, _ kind: BrewKind) { manager.upgrade(name, kind: kind); revision += 1 }
    func upgradeAll() { manager.upgradeAll(); revision += 1 }
    func updateIndex() { manager.updateIndex(); revision += 1 }
    func setPinned(_ name: String, _ pinned: Bool) { manager.setPinned(name, pinned: pinned); revision += 1 }
    func service(_ a: BrewServiceAction, _ name: String) { manager.service(a, name: name); revision += 1 }
    func cleanup() { manager.cleanup(); revision += 1 }
    func removeOrphans() { manager.removeOrphans(); revision += 1 }

    func uninstall(_ p: BrewPackage) {
        let hasDependents = p.kind == .formula
        let choice = confirmAlert("Удалить \(p.name)?", hasDependents ? "Если от пакета зависят другие, brew откажется удалять." : "Приложение уйдёт из Программ.",
                                  ok: "Удалить", extraButton: p.kind == .cask ? "Удалить с данными (zap)" : nil)
        guard choice > 0 else { return }
        manager.uninstall(p.name, kind: p.kind, zap: choice == 2)
        revision += 1
    }
}

@MainActor
final class HomebrewModule: Module {
    let info = ModuleID.homebrewManager.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { HomebrewController.shared.start(); Log.write("module homebrewManager start") }
    func stop() { HomebrewController.shared.stop(); Log.write("module homebrewManager stop") }
}

private enum InstalledFilter: Int, CaseIterable {
    case all, formulae, casks, leaves, dependencies, pinned

    var title: String {
        switch self {
        case .all: "Все"
        case .formulae: "Формулы"
        case .casks: "Casks"
        case .leaves: "Листья"
        case .dependencies: "Зависимости"
        case .pinned: "Закреплённые"
        }
    }
}

private struct BrewJobsForm: View {
    @ObservedObject var c: HomebrewController

    var body: some View {
        JobsSection(jobs: c.jobs, onCancel: { c.manager.queue.cancel($0) }, onClear: { c.manager.queue.clearFinished(); c.refresh() }) { job in
            c.manager.terminalLines[job.id] == nil ? nil : ("В Terminal", { c.openTerminalFor(job: job.id) })
        }
    }
}

private struct BrewJobsBar: View {
    @ObservedObject var c: HomebrewController

    var body: some View {
        if !c.jobs.isEmpty {
            Form { BrewJobsForm(c: c) }
                .formStyle(.grouped)
                .frame(height: 190)
        }
    }
}

struct HomebrewPage: View {
    @ObservedObject private var c = HomebrewController.shared

    private var statusText: String {
        guard let p = c.manager.availability.path else { return "не найден" }
        let when = c.snapshot.loadedAt.map { "обновлено " + $0.formatted(date: .omitted, time: .shortened) } ?? (c.manager.isRefreshing ? "читаю…" : "ещё не читал")
        return "\(p) · \(when)"
    }

    var body: some View {
        let _ = c.revision
        SettingsPage {
            Section {
                LabeledContent("Homebrew", value: statusText)
                if c.manager.availability.path != nil {
                    LabeledContent("Пакеты", value: "\(c.snapshot.formulae.count) формул, \(c.snapshot.casks.count) casks")
                    LabeledContent("Обновления", value: c.snapshot.outdatedCount > 0 ? "\(c.snapshot.outdatedCount)" : "всё актуально")
                }
            } header: { Text("Менеджер Homebrew") } footer: {
                if c.manager.availability.path == nil { SectionFooter("Нужен Homebrew (brew.sh).") }
            }
            if c.manager.availability.path == nil {
                Section {
                    Text("brew не найден в /opt/homebrew/bin и /usr/local/bin")
                    CommandBox(command: BrewCommands.installCommand) { _ = c.manager.openInstallerInTerminal() }
                    Button("Проверить ещё раз") { c.refresh() }
                } footer: {
                    SectionFooter("Установщик спросит пароль администратора, поэтому команда открывается в Terminal; Мультитул пароль не собирает.")
                }
            } else {
                if let f = c.manager.lastFailure {
                    Section {
                        ToolWarning(text: f.kind.title)
                        if !f.kind.hint.isEmpty { Text(f.kind.hint).foregroundStyle(.secondary) }
                        if !f.message.isEmpty { Text(f.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Section {
                    Button("Обновить всё") { c.upgradeAll() }.disabled(c.snapshot.outdated.isEmpty)
                    Button("Обновить список пакетов") { c.updateIndex() }
                    Button("Перечитать") { c.refresh() }.disabled(c.manager.isRefreshing)
                } header: { Text("Действия") }
                Section {
                    NavigationLink { BrewUpdatesPage().navigationTitle("Обновления Homebrew") } label: {
                        LabeledContent("Обновления", value: "\(c.snapshot.outdated.count)")
                    }
                    NavigationLink { BrewInstalledPage().navigationTitle("Установленные пакеты") } label: {
                        LabeledContent("Установленные пакеты", value: "\(c.snapshot.packages.count)")
                    }
                    NavigationLink { BrewSearchPage().navigationTitle("Поиск пакетов") } label: { Text("Поиск и установка") }
                    NavigationLink { BrewServicesPage().navigationTitle("Службы Homebrew") } label: {
                        LabeledContent("Службы", value: "\(c.snapshot.services.count)")
                    }
                    NavigationLink { BrewUpkeepPage().navigationTitle("Уборка Homebrew") } label: { Text("Уборка") }
                    NavigationLink { BrewSettingsPage().navigationTitle("Настройки Homebrew") } label: { Text("Настройки") }
                } header: { Text("Разделы") }
            }
            BrewJobsForm(c: c)
        }
        .onAppear { if c.manager.snapshot.loadedAt == nil && c.manager.availability.path != nil { c.refresh() } }
    }
}

struct BrewUpdatesPage: View {
    @ObservedObject private var c = HomebrewController.shared

    var body: some View {
        let _ = c.revision
        Group {
            if c.snapshot.outdated.isEmpty {
                ContentUnavailableView("Всё свежее", systemImage: "checkmark.circle", description: Text("Обновлений Homebrew нет"))
            } else {
                Table(c.snapshot.outdated) {
                    TableColumn("Пакет", value: \.name)
                    TableColumn("Тип") { o in Text(o.kind.title) }.width(70)
                    TableColumn("Версия") { o in Text("\(o.installedVersion) → \(o.currentVersion)").monospacedDigit() }
                    TableColumn("Статус") { o in Text(o.pinned ? "закреплён" : "").foregroundStyle(.secondary) }.width(90)
                    TableColumn("") { o in Button("Обновить") { c.upgrade(o.name, o.kind) }.disabled(o.pinned) }.width(90)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if c.manager.isRefreshing { ProgressView().controlSize(.small) }
                Button("Обновить всё") { c.upgradeAll() }.disabled(c.snapshot.outdated.isEmpty)
                Button("Обновить список пакетов") { c.updateIndex() }
                Button("Перечитать") { c.refresh() }.disabled(c.manager.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) { BrewJobsBar(c: c) }
    }
}

struct BrewInstalledPage: View {
    @ObservedObject private var c = HomebrewController.shared
    @State private var filter = InstalledFilter.all.rawValue
    @State private var filterText = ""
    @State private var sortOrder = [KeyPathComparator(\BrewPackage.name)]

    private func filtered() -> [BrewPackage] {
        let s = c.snapshot
        var list: [BrewPackage]
        switch InstalledFilter(rawValue: filter) ?? .all {
        case .all: list = s.packages
        case .formulae: list = s.formulae
        case .casks: list = s.casks
        case .leaves: list = s.leafPackages
        case .dependencies: list = s.dependencyPackages
        case .pinned: list = s.pinnedPackages
        }
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || $0.displayName.lowercased().contains(q) } }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        let _ = c.revision
        let list = filtered()
        VStack(spacing: 0) {
            if let d = c.detail {
                Form { BrewDetailSection(detail: d) { c.closeDetail() } }
                    .formStyle(.grouped)
                    .frame(height: 240)
            }
            Table(list, sortOrder: $sortOrder) {
                TableColumn("Пакет", value: \.name) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).lineLimit(1)
                        Text(p.desc.isEmpty ? p.kind.title : p.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TableColumn("Версия") { p in Text(p.installedVersion ?? "").monospacedDigit() }.width(90)
                TableColumn("Статус") { p in
                    Text([p.pinned ? "закреплён" : nil, p.outdated ? "есть новая" : nil].compactMap { $0 }.joined(separator: ", "))
                        .foregroundStyle(p.outdated ? Color.orange : Color.secondary)
                }.width(120)
                TableColumn("") { p in
                    Menu {
                        Button("Подробности") { c.showDetail(p) }
                        if p.outdated { Button("Обновить") { c.upgrade(p.name, p.kind) } }
                        if p.kind == .formula { Button(p.pinned ? "Открепить" : "Закрепить") { c.setPinned(p.name, !p.pinned) } }
                        Divider()
                        Button("Удалить…", role: .destructive) { c.uninstall(p) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                }.width(40)
            }
        }
        .searchable(text: $filterText, prompt: "Фильтр")
        .toolbar {
            ToolbarItem {
                Picker("Показать", selection: $filter) { ForEach(InstalledFilter.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
            }
        }
        .safeAreaInset(edge: .bottom) { BrewJobsBar(c: c) }
    }
}

private struct BrewDetailSection: View {
    let detail: BrewDetail
    var close: () -> Void

    var body: some View {
        let d = detail
        Section {
            LabeledContent {
                Button("Закрыть", action: close)
            } label: { Text("\(d.package.name) · \(d.package.kind.title)").font(.headline) }
            if !d.package.desc.isEmpty { Text(d.package.desc) }
            LabeledContent("Установлено", value: d.package.installedVersion ?? "нет")
            LabeledContent("Последняя", value: d.package.latestVersion.isEmpty ? "?" : d.package.latestVersion)
            LabeledContent("Tap", value: d.package.tap)
            if let url = URL(string: d.package.homepage), !d.package.homepage.isEmpty { Link(d.package.homepage, destination: url) }
            if d.loading { ProgressView().controlSize(.small) }
            if !d.package.dependencies.isEmpty { LabeledContent("Зависимости", value: d.package.dependencies.joined(separator: ", ")) }
            if let t = d.tree, !t.children.isEmpty { LabeledContent("Дерево", value: "\(t.flattened.count) пакетов, глубина \(t.depth - 1)") }
            if !d.dependents.isEmpty { LabeledContent("Нужен для", value: d.dependents.joined(separator: ", ")) }
        }
    }
}

struct BrewSearchPage: View {
    @ObservedObject private var c = HomebrewController.shared
    @State private var query = ""

    var body: some View {
        let _ = c.revision
        Group {
            if c.manager.searchResults.isEmpty {
                ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass", description: Text("Введите название формулы или cask и нажмите Return"))
            } else {
                Table(c.manager.searchResults) {
                    TableColumn("Пакет") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name)
                            if !r.desc.isEmpty { Text(r.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    TableColumn("Тип") { r in Text(r.kind?.title ?? "") }.width(70)
                    TableColumn("") { r in
                        if c.snapshot.packages.contains(where: { $0.name == r.name }) {
                            Text("установлено").foregroundStyle(.green)
                        } else {
                            Button("Установить") { c.install(r.name, r.kind ?? .formula) }
                        }
                    }.width(100)
                }
            }
        }
        .searchable(text: $query, prompt: "Название формулы или cask")
        .onSubmit(of: .search) { c.search(query) }
        .safeAreaInset(edge: .bottom) { BrewJobsBar(c: c) }
    }
}

struct BrewServicesPage: View {
    @ObservedObject private var c = HomebrewController.shared

    var body: some View {
        let _ = c.revision
        Group {
            if c.snapshot.services.isEmpty {
                ContentUnavailableView("Служб нет", systemImage: "gearshape.2", description: Text("Службы появляются, когда установлены пакеты с демонами"))
            } else {
                Table(c.snapshot.services) {
                    TableColumn("Служба", value: \.name)
                    TableColumn("Состояние") { s in
                        Text(s.status.title).foregroundStyle(s.status.isRunning ? Color.green : (s.status == .error ? Color.orange : Color.secondary))
                    }.width(120)
                    TableColumn("") { s in
                        HStack {
                            if s.status.isRunning {
                                Button("Перезапустить") { c.service(.restart, s.name) }
                                Button("Остановить") { c.service(.stop, s.name) }
                            } else {
                                Button("Запустить") { c.service(.start, s.name) }
                            }
                        }
                    }.width(200)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { BrewJobsBar(c: c) }
    }
}

struct BrewUpkeepPage: View {
    @ObservedObject private var c = HomebrewController.shared

    var body: some View {
        let _ = c.revision
        SettingsPage {
            Section {
                if let r = c.snapshot.cleanup {
                    Text(r.items.isEmpty ? "Убирать нечего" : "Можно освободить \(ManagerBytes.format(r.bytes)), объектов: \(r.items.count)")
                }
                Button("Проверить") { c.previewCleanup() }.disabled(c.cleanupBusy)
                Button("Очистить") { c.cleanup() }
                if c.cleanupBusy { ProgressView().controlSize(.small) }
            } header: { Text("Кэш и старые версии") }
            Section {
                if !c.snapshot.orphans.isEmpty { Text(c.snapshot.orphans.joined(separator: ", ")).textSelection(.enabled) }
                Button("Проверить") { c.previewOrphans() }.disabled(c.cleanupBusy)
                Button("Удалить лишние", role: .destructive) {
                    if confirmAlert("Удалить лишние зависимости?", c.snapshot.orphans.isEmpty ? "Список ещё не проверялся." : c.snapshot.orphans.joined(separator: ", "), ok: "Удалить") == 1 { c.removeOrphans() }
                }
            } header: { Text("Лишние зависимости") } footer: {
                SectionFooter("Пакеты, поставленные как зависимости, которые больше никому не нужны. Листьев (поставлено явно): \(c.snapshot.leaves.count).")
            }
            BrewJobsForm(c: c)
        }
    }
}

struct BrewSettingsPage: View {
    @ObservedObject private var c = HomebrewController.shared

    private func binding<T>(_ kp: WritableKeyPath<BrewSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: binding(\.refreshOnOpen)) { SettingLabel("Читать список при открытии", "Установленное, обновления и службы запрашиваются при включении модуля") }
                Toggle(isOn: binding(\.autoUpdateIndex)) { SettingLabel("Обновлять список пакетов перед установкой", "Выключено: brew не ходит в сеть за индексом сам (HOMEBREW_NO_AUTO_UPDATE)") }
                Toggle(isOn: binding(\.includeGreedy)) { SettingLabel("Включать приложения с автообновлением", "Ключ --greedy: casks, которые обновляют себя сами, тоже попадают в список") }
                Toggle(isOn: binding(\.cleanupAfterUpgrade)) { SettingLabel("Чистить кэш после обновления", "brew cleanup запускается, когда очередь опустела") }
                Toggle(isOn: binding(\.preferTerminalForCasks)) { SettingLabel("Casks сразу открывать в Terminal", "Установка приложений часто просит пароль администратора; Мультитул пароль не собирает") }
                Toggle(isOn: binding(\.notifyOutdated)) { SettingLabel("Уведомлять об обновлениях", "При чтении списка, если число обновлений изменилось") }
                Toggle(isOn: binding(\.searchWithDescriptions)) { SettingLabel("Описания в поиске", "brew search --desc: медленнее, зато видно, что это за пакет") }
            }
        }
    }
}
