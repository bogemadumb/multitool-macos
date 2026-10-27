import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MultitulCore
import MultitulUI

struct CleanPage: View {
    var enabled: Set<ModuleID> = []
    @StateObject private var disk = CategoryCleanModel(defs: cleanDefs)
    @StateObject private var cleaner = CategoryCleanModel(defs: cleanerDefs, customize: { CleanEnvSettings.apply(to: &$0) })
    @StateObject private var ram = RamModel()
    @StateObject private var razbor = RazborModel()
    @StateObject private var uninstall = UninstallModel()
    @ObservedObject private var router = UninstallRouter.shared
    @State private var showUninstall = false

    private func consumePending() {
        guard let path = router.pending else { return }
        router.pending = nil
        guard enabled.contains(.uninstaller) else { return }
        uninstall.choose(path: path)
        showUninstall = true
    }

    private var volume: (free: Int64, total: Int64)? {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return (free, Int64(total))
    }

    var body: some View {
        SettingsPage {
            if let v = volume {
                let used = 1 - Double(v.free) / Double(v.total)
                Section {
                    LabeledContent("Свободно", value: "\(fmtBytes(v.free)) из \(fmtBytes(v.total))")
                    ProgressView(value: min(max(used, 0), 1)).tint(used > 0.9 ? Color.red : (used > 0.8 ? Color.orange : Color.accentColor))
                } header: { Text("Диск") } footer: {
                    SectionFooter(used > 0.9 ? "Места мало: пора чистить." : "Всё, что чистится отсюда, уходит в Корзину и проверяется перед удалением.")
                }
            }
            Section {
                if enabled.contains(.cleaner) {
                    NavigationLink(value: CleanRoute.cleaner) { SettingLabel("Очистка Мака", "Кэши, старые файлы, скриншоты, WhatsApp, бэкапы iOS") }
                }
                if enabled.contains(.diskClean) {
                    NavigationLink(value: CleanRoute.disk) { SettingLabel("Очистка диска", "Категории по уровню риска: безопасно, проверь, никогда") }
                }
                if enabled.contains(.razbor) {
                    NavigationLink(value: CleanRoute.razbor) {
                        SettingLabel("Разбор", "Брошенные диски VM, рабочие папки, venv, модели, кэш uv")
                    }
                }
                if enabled.contains(.uninstaller) {
                    NavigationLink(value: CleanRoute.uninstall) {
                        SettingLabel("Удаление приложений", "Приложение вместе с хвостами в Библиотеке")
                    }
                }
                if enabled.contains(.ramClean) {
                    NavigationLink(value: CleanRoute.ram) {
                        SettingLabel("Оперативная память", "Брошенные dev-серверы, простаивающие сессии, тяжёлые фоновые приложения")
                    }
                }
            } header: { Text("Инструменты") }
        }
        .navigationDestination(for: CleanRoute.self) { route in
            switch route {
            case .cleaner:
                CategoryCleanView(model: cleaner, hint: "Сначала список, потом Корзина. Из Корзины ничего не удаляется само, кроме строки «Корзина».") { CleanerSettingsSections() }
                    .navigationTitle("Очистка Мака")
            case .disk:
                CategoryCleanView(model: disk, hint: "Всё идёт через Корзину. После переноса проверяются службы dev.multitool.*: если одна упала, Корзина не очищается.")
                    .navigationTitle("Очистка диска")
            case .razbor: RazborView(model: razbor).navigationTitle("Разбор")
            case .uninstall: UninstallView(model: uninstall).navigationTitle("Удаление приложений")
            case .ram: RamCleanView(model: ram).navigationTitle("Оперативная память")
            }
        }
        .navigationDestination(isPresented: $showUninstall) { UninstallView(model: uninstall).navigationTitle("Удаление приложений") }
        .onAppear { consumePending() }
        .onChange(of: router.pending) { _, _ in consumePending() }
    }
}

// MARK: categories

struct CategoryCleanView<Extra: View>: View {
    @ObservedObject var model: CategoryCleanModel
    var hint: String
    @ViewBuilder var extra: () -> Extra
    @State private var confirm = false
    @State private var expanded = Set<String>()

    init(model: CategoryCleanModel, hint: String, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.model = model
        self.hint = hint
        self.extra = extra
    }

    var body: some View {
        SettingsPage {
            controls
            if model.total > 0 { spaceSection }
            if !model.report.isEmpty {
                Section("Результат") { ForEach(Array(model.report.enumerated()), id: \.offset) { _, l in Text(l) } }
            }
            if !model.scanned && !model.scanning {
                Section {
                    ContentUnavailableView("Ещё не сканировали", systemImage: "magnifyingglass", description: Text("Нажми «Сканировать»: ничего не удаляется, пока ты не выберешь и не подтвердишь."))
                }
            }
            ForEach(CleanLevel.allCases, id: \.self) { level in
                let cats = model.categories.filter { $0.level == level }
                if !cats.isEmpty { levelSection(level, cats) }
            }
            extra()
            Section { EmptyView() } footer: { SectionFooter(hint) }
        }
        .onAppear { if !model.scanned { model.scan() } }
        .confirmationDialog("Убрать выбранное (\(fmtBytes(model.pickedBytes)))?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { model.clean() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Файлы уйдут в Корзину. Строка «Корзина» удаляется насовсем.")
        }
    }

    private var controls: some View {
        Section {
            Button { model.scan() } label: { Label(model.scanning ? "Сканирую…" : "Сканировать", systemImage: "magnifyingglass") }
                .disabled(model.scanning || model.cleaning)
            if model.scanning || model.cleaning || !model.progress.isEmpty {
                HStack(spacing: 8) {
                    if model.scanning || model.cleaning { ProgressView().controlSize(.small) }
                    if !model.progress.isEmpty { Text(model.progress).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Button(role: .destructive) { confirm = true } label: { Label("Очистить выбранное · \(fmtBytes(model.pickedBytes))", systemImage: "trash") }
                .disabled(!model.hasPicked || model.cleaning || model.scanning)
        }
    }

    private var spaceSection: some View {
        let used = 1 - Double(model.free) / Double(max(model.total, 1))
        return Section {
            LabeledContent("Свободно на диске", value: "\(fmtBytes(model.free)) из \(fmtBytes(model.total))")
            ProgressView(value: min(max(used, 0), 1)).tint(used > 0.9 ? Color.red : (used > 0.8 ? Color.orange : Color.accentColor))
        }
    }

    private func levelSection(_ level: CleanLevel, _ cats: [CleanCategory]) -> some View {
        let total = fmtBytes(cats.reduce(0) { $0 + $1.bytes + (level == .never ? $1.blockedBytes : 0) })
        return Section {
            ForEach(cats) { c in categoryRow(c) }
        } header: { Text("\(level.title), \(total)") }
    }

    private func categoryRow(_ c: CleanCategory) -> some View {
        let selectable = c.level != .never
        let free = c.items.filter { $0.blocked == nil }
        let allOn = !free.isEmpty && free.allSatisfy { model.picked.contains($0.id) }
        let open = Binding(get: { expanded.contains(c.id) }, set: { on in if on { expanded.insert(c.id) } else { expanded.remove(c.id) } })
        let head = HStack(spacing: 8) {
            if selectable {
                Toggle(c.title, isOn: Binding(get: { allOn }, set: { model.setCategory(c, on: $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(free.isEmpty)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18)
            }
            SettingLabel(c.title, c.note ?? c.subtitle)
            Spacer()
            Text(fmtBytes(c.level == .never ? c.blockedBytes : c.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        return Group {
            if c.items.isEmpty {
                head
            } else {
                DisclosureGroup(isExpanded: open) {
                    ForEach(c.items.prefix(60)) { item in
                        HStack(spacing: 8) {
                            Toggle(item.title, isOn: Binding(get: { model.picked.contains(item.id) }, set: { _ in model.toggle(item) }))
                                .toggleStyle(.checkbox).labelsHidden().disabled(item.blocked != nil || !selectable)
                            SettingLabel(item.title, item.subtitle.isEmpty ? nil : item.subtitle).lineLimit(2)
                            Spacer()
                            if let b = item.blocked { StatusLabel(b, color: .orange).font(.caption) }
                            Text(fmtBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if c.items.count > 60 { Text("…и ещё \(c.items.count - 60)").font(.caption).foregroundStyle(.secondary) }
                } label: { head }
            }
        }
    }
}

struct WhatsAppDaysRow: View {
    let kind: WhatsAppKind
    @State private var days = 0

    var body: some View {
        Stepper("\(kind.title): \(days == 0 ? "не трогать" : "старше \(days) дн.")", value: Binding(get: { days }, set: { v in
            days = v
            UserDefaults.standard.set(v, forKey: kind.defaultsKey)
        }), in: WhatsAppRules.daysRange, step: kind == .document ? 30 : 5)
        .onAppear { days = WhatsAppRules.load().days(kind) }
    }
}

struct CleanerSettingsSections: View {
    @AppStorage(CleanDefaultsKeys.screenshotDays) private var shotDays = 30
    @AppStorage(CleanDefaultsKeys.iosDays) private var iosDays = 90
    @AppStorage(CleanDefaultsKeys.waDownloads) private var waDownloads = true
    @AppStorage(CleanDefaultsKeys.waContainer) private var waContainer = true
    @AppStorage(CleanerSchedule.enabledKey) private var autoOn = false
    @AppStorage(CleanerSchedule.intervalKey) private var interval = 7
    @AppStorage(CleanerSchedule.lastRunKey) private var lastRun = 0.0

    var body: some View {
        Section {
            DisclosureGroup("Параметры очистки") {
                StepperSetting("Скриншоты", "Не открывали дольше этого срока", value: $shotDays, in: 1...365, step: 5, unit: " дн.")
                StepperSetting("Бэкапы iPhone и iPad", "Старше этого срока", value: $iosDays, in: 7...730, step: 15, unit: " дн.")
                Text("WhatsApp: сколько дней хранить скачанное (0: не трогать этот тип)").font(.subheadline).foregroundStyle(.secondary)
                ForEach(WhatsAppKind.allCases, id: \.self) { WhatsAppDaysRow(kind: $0) }
                Toggle(isOn: $waDownloads) { SettingLabel("Искать в Загрузках", "WhatsApp Image, Video, Audio, IMG-…-WA…") }
                Toggle(isOn: $waContainer) { SettingLabel("Искать в медиа приложения WhatsApp", "Нужен полный доступ к диску") }
            }
        }
        Section {
            Toggle(isOn: $autoOn) { SettingLabel("Безопасная автоочистка", "Кэши, старые логи, мусор Xcode: в Корзину, с уведомлением") }
            if autoOn {
                StepperSetting("Периодичность", value: $interval, in: 1...60, unit: " дн.")
            }
        } header: { Text("Автоочистка") } footer: {
            if autoOn { SectionFooter(lastRun > 0 ? "Последний запуск: \(SnapshotWriter.formatTime(Int64(lastRun), "d MMM HH:mm"))" : "Ещё не запускалась") }
        }
    }
}

// MARK: RAM

struct RamCleanView: View {
    @ObservedObject var model: RamModel
    @State private var confirm = false

    var body: some View {
        SettingsPage {
            Section {
                Button { model.refresh() } label: { Label(model.scanning ? "Сканирую…" : "Обновить", systemImage: "arrow.clockwise") }.disabled(model.scanning || model.cleaning)
                Button(role: .destructive) { confirm = true } label: { Label("Освободить", systemImage: "memorychip") }.disabled(!model.hasWork || model.cleaning || model.scanning)
                if model.cleaning { ProgressView().controlSize(.small) }
                if let s = model.scan { LabeledContent("Свободно", value: "\(s.freeMb) МБ") }
                if let r = model.result { Text(r) }
            }
            Section {
                Toggle(isOn: $model.purge) { SettingLabel("purge: сбросить кэш файловой системы", "Через multitul-ctl; нужен установленный multitul-ctl и правило sudo, без них шаг пропустится") }
            }
            section("Брошенные dev-серверы", rows: model.scan?.orphans.map { o in
                RamRow(id: o.id, title: "\(o.info.name) · \(o.info.pid)", detail: String(o.info.args.prefix(90)), mb: o.rssMb) } ?? [], selection: $model.orphans)
            section("Простаивающие сессии Claude (2 часа без работы)", rows: model.scan?.sessions.map { s in
                RamRow(id: s.id, title: "\(s.name) · \(s.pid)", detail: s.cwd ?? "", mb: s.rssMb) } ?? [], selection: $model.sessions)
            section("Тяжёлые приложения в фоне (больше 1 ГБ)", rows: model.scan?.heavy.map { a in
                RamRow(id: a.id, title: "\(a.name) · \(a.pid)", detail: "закроется штатно, как Cmd+Q", mb: a.rssMb) } ?? [], selection: $model.apps)
            Section { EmptyView() } footer: {
                SectionFooter("Остановка идёт через защиту: sing-box, xray, VPNMonitor, Мультитул и службы dev.multitool.* не трогаются. Сессии Claude закрываются только отмеченные.")
            }
        }
        .onAppear { if model.scan == nil { model.refresh() } }
        .confirmationDialog("Освободить оперативку?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Освободить", role: .destructive) { model.run() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Отмеченные процессы будут остановлены.")
        }
    }

    struct RamRow: Identifiable {
        var id: Int32
        var title: String
        var detail: String
        var mb: Int
    }

    private func section(_ title: String, rows: [RamRow], selection: Binding<Set<Int32>>) -> some View {
        Section {
            if rows.isEmpty { EmptyHint(text: "Нет", symbol: "checkmark.circle") }
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Toggle(r.title, isOn: Binding(get: { selection.wrappedValue.contains(r.id) },
                                                  set: { on in if on { selection.wrappedValue.insert(r.id) } else { selection.wrappedValue.remove(r.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    SettingLabel(r.title, r.detail.isEmpty ? nil : r.detail).lineLimit(2)
                    Spacer()
                    Text("\(r.mb) МБ").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } header: { Text(title) }
    }
}

// MARK: uninstaller

extension InstalledApp {
    var protectionText: String { protection ?? "" }
}

extension Leftover {
    var kindTitle: String { kind.title }
}

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @State private var confirm = false
    @State private var dropping = false
    @State private var appSort = [KeyPathComparator(\InstalledApp.name)]
    @State private var leftSort = [KeyPathComparator(\Leftover.bytes, order: .reverse)]
    @State private var appPick: InstalledApp.ID?

    var body: some View {
        Group {
            if let app = model.selected { relatedView(app) } else { appList }
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.choose(path: url.path) }
            }
            return true
        }
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
        .confirmationDialog("Убрать в Корзину (\(fmtBytes(model.pickedBytes)))?", isPresented: $confirm, titleVisibility: .visible) {
            Button("В Корзину", role: .destructive) { model.uninstall() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ничего не удаляется навсегда: всё можно достать из Корзины.")
        }
    }

    private var appList: some View {
        Table(model.filtered.sorted(using: appSort), selection: $appPick, sortOrder: $appSort) {
            TableColumn("Приложение", value: \.name) { a in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name)
                        Text(a.bundleId).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Защита", value: \.protectionText) { a in Text(a.protectionText).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 130)
            TableColumn("Версия", value: \.version) { a in Text(a.version).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
            if let id = ids.first, let a = model.apps.first(where: { $0.id == id }) { Button("Найти хвосты") { model.choose(a) } }
        } primaryAction: { ids in
            if let id = ids.first, let a = model.apps.first(where: { $0.id == id }) { model.choose(a) }
        }
        .overlay {
            if model.loading && model.apps.isEmpty { ProgressView("Читаю список приложений…") }
            else if model.filtered.isEmpty { ContentUnavailableView("Приложений не найдено", systemImage: "app.dashed") }
        }
        .searchable(text: $model.query, prompt: "Поиск")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.report.enumerated()), id: \.offset) { _, l in Text(l) }
                Text("Перетащи .app в окно или дважды щёлкни по приложению в списке.").foregroundStyle(.secondary)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func relatedView(_ app: InstalledApp) -> some View {
        Table(model.related.sorted(using: leftSort), sortOrder: $leftSort) {
            TableColumn("") { l in
                Toggle(l.title, isOn: Binding(get: { model.picked.contains(l.id) }, set: { _ in model.toggle(l) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(l.blocked != nil)
            }
            .width(24)
            TableColumn("Что", value: \.title) { l in
                VStack(alignment: .leading, spacing: 0) {
                    Text(l.title).lineLimit(1).truncationMode(.middle)
                    Text(l.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            TableColumn("Тип", value: \.kindTitle) { l in
                HStack(spacing: 6) {
                    Text(l.kindTitle)
                    if let b = l.blocked { StatusLabel(b, color: .orange) }
                }
            }
            .width(min: 90, ideal: 150)
            TableColumn("Размер", value: \.bytes) { l in Text(fmtBytes(l.bytes)).monospacedDigit() }
                .width(min: 70, ideal: 90)
        }
        .overlay {
            if model.related.isEmpty && !model.loading { ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass") }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.loading || model.working { ProgressView().controlSize(.small) }
                Button("К списку") { model.clearSelection() }
                Button(role: .destructive) { confirm = true } label: { Label("В Корзину · \(fmtBytes(model.pickedBytes))", systemImage: "trash") }
                    .disabled(model.picked.isEmpty || model.working)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                    Text(app.name).fontWeight(.semibold)
                    Text(app.bundleId).foregroundStyle(.secondary)
                }
                ForEach(Array(model.report.enumerated()), id: \.offset) { _, l in Text(l) }
                Text("Apple и системные приложения защищены. Запущенное приложение сначала закрой. Системные папки (/Library) показаны, но убираются вручную: нужен администратор.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
