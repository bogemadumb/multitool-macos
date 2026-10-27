import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class AppUpdatesController: ObservableObject, UpdateInstalling {
    static let shared = AppUpdatesController()

    @Published private(set) var revision = 0
    @Published private(set) var settings = AppUpdateSettings()
    let service: AppUpdateService

    private let store = AppUpdateStore()
    private var running = false
    private var timer: Timer?
    private let folderHolder: FolderHolder

    private init() {
        let locator = ToolLocator(files: FileSystemLauncherChecker())
        let brew = HomebrewController.shared.manager
        let holder = FolderHolder()
        folderHolder = holder
        service = AppUpdateService(catalog: SystemAppCatalog(extraFolders: { holder.folders }), http: URLSessionFetcher(), runner: SystemManagerRunner(), locator: locator,
                                   casks: brew, store: store)
        service.installer = self
        service.onChange = { [weak self] in self?.revision += 1 }
        service.queue.onChange = { [weak self] in self?.revision += 1 }
    }

    var updates: [AppUpdate] { service.visibleUpdates }
    var jobs: [JobSnapshot] { service.queue.jobs }

    func start() {
        guard !running else { return }
        running = true
        settings = store.loadSettings()
        service.settings = settings
        folderHolder.folders = settings.folders
        HomebrewController.shared.manager.detect()
        if service.isDue { check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.service.isDue == true { self?.check() } }
        }
        revision += 1
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        service.queue.cancelAll()
    }

    func update(_ s: AppUpdateSettings) {
        settings = s.sanitized
        service.settings = settings
        service.saveSettings()
        folderHolder.folders = settings.folders
        revision += 1
    }

    func check() {
        Task {
            await service.check()
            let fresh = service.unreportedForNotification()
            if let text = AppUpdateService.notificationText(for: fresh) {
                Notifier.shared.post(title: text.title, body: text.body, id: "appupdates")
                service.markNotified(fresh)
            }
            revision += 1
        }
    }

    func install(_ u: AppUpdate) {
        let r = service.install(u)
        if case .unavailable(let m) = r { HUD.show(m) }
        revision += 1
    }

    func upgradeCask(token: String) -> Int? {
        let brew = HomebrewController.shared.manager
        if brew.availability.path == nil { brew.detect() }
        return brew.upgrade(token, kind: .cask)
    }

    func openApp(path: String) { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in } }
    func openURL(_ url: URL) { NSWorkspace.shared.open(url) }
}

private final class FolderHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var folders: [String] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
final class AppUpdatesModule: Module {
    let info = ModuleID.appUpdates.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() { AppUpdatesController.shared.start(); Log.write("module appUpdates start") }
    func stop() { AppUpdatesController.shared.stop(); Log.write("module appUpdates stop") }
}

struct AppUpdatesPage: View {
    @ObservedObject private var c = AppUpdatesController.shared

    private func primaryTitle(_ u: AppUpdate) -> String {
        switch u.action {
        case .brewCask: "Обновить через Homebrew"
        case .appStore: "Обновить в App Store"
        case .sparkle(_, let d): d == nil ? "Открыть приложение" : "Скачать"
        }
    }

    var body: some View {
        let _ = c.revision
        let ups = c.updates
        Group {
            if ups.isEmpty {
                ContentUnavailableView(c.service.report.finishedAt == nil ? "Ещё не проверял" : "Все приложения актуальны", systemImage: c.service.isChecking ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                                       description: Text(summary))
            } else {
                Table(ups) {
                    TableColumn("Приложение") { u in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.app.name).lineLimit(1)
                            if let m = u.minimumOS { Text("Нужна macOS \(m)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Источник") { u in Text(u.source.title + (u.critical ? " · важное" : "")).foregroundStyle(u.critical ? Color.orange : Color.secondary) }.width(120)
                    TableColumn("Версия") { u in Text("\(u.installedVersion) → \(u.newVersion)").monospacedDigit() }
                    TableColumn("") { u in
                        HStack(spacing: 8) {
                            Button(primaryTitle(u)) { c.install(u) }
                            Menu {
                                if case .sparkle = u.action { Button("Открыть приложение") { c.service.openInOwnUpdater(u) } }
                                if let n = u.notesURL { Button("Что нового") { NSWorkspace.shared.open(n) } }
                                Divider()
                                Button("Пропустить версию") { c.service.skip(u) }
                                Button("Не следить") { c.service.ignoreApp(u.app.bundleId) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                        }
                    }.width(230)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if c.service.isChecking { ProgressView().controlSize(.small) }
                Button("Проверить сейчас") { c.check() }.disabled(c.service.isChecking)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !c.jobs.isEmpty || !c.service.report.failures.isEmpty {
                Form {
                    if !c.service.report.failures.isEmpty {
                        Section { Text("Не удалось проверить: \(c.service.report.failures.count) (недоступны сервера обновлений)").foregroundStyle(.secondary) }
                    }
                    JobsSection(jobs: c.jobs, onCancel: { c.service.queue.cancel($0) }, onClear: { c.service.queue.clearFinished() }, extra: nil)
                }
                .formStyle(.grouped)
                .frame(height: c.jobs.isEmpty ? 90 : 220)
            }
        }
    }

    private var summary: String {
        let r = c.service.report
        guard let t = r.finishedAt else { return "Сайты разработчиков, App Store и Homebrew" }
        return "Проверено \(r.checked) приложений, \(t.formatted(date: .omitted, time: .shortened)); без источника: \(r.withoutSource)"
    }
}

struct AppUpdatesSettingsPage: View {
    @ObservedObject private var c = AppUpdatesController.shared

    private func binding<T>(_ kp: WritableKeyPath<AppUpdateSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        let _ = c.revision
        SettingsPage {
            Section("Источники") {
                Toggle(isOn: binding(\.includeAppStore)) { SettingLabel("Приложения из App Store", c.service.masPath == nil ? "Через публичный каталог Apple; с mas (brew install mas) точнее" : "Через mas") }
                Toggle(isOn: binding(\.includeBrewCasks)) { SettingLabel("Установленные через Homebrew", "Casks из brew outdated") }
                Toggle(isOn: binding(\.includeOther)) { SettingLabel("Остальные установленные", "Приложения с каналом обновлений Sparkle (SUFeedURL)") }
                Toggle(isOn: binding(\.includePrerelease)) { SettingLabel("Предрелизные версии", "Альфы, беты и RC тоже считаются обновлением") }
            }
            Section("Проверка") {
                Toggle(isOn: binding(\.notifyNew)) { SettingLabel("Уведомлять о новых", "Одно уведомление на каждую версию") }
                StepperSetting("Проверять раз в", value: binding(\.checkIntervalHours), in: AppUpdateSettings.intervalRange, step: 6, unit: " ч", zeroText: "только вручную")
                StepperSetting("Параллельных проверок", value: binding(\.maxConcurrent), in: AppUpdateSettings.concurrentRange)
            }
            if !c.service.ignoredBundleIds.isEmpty {
                Section {
                    ForEach(c.service.ignoredBundleIds, id: \.self) { id in
                        LabeledContent {
                            Button("Вернуть") { c.service.unignoreApp(id) }
                        } label: { Text(id) }
                    }
                    Button("Вернуть все") { for id in c.service.ignoredBundleIds { c.service.unignoreApp(id) } }
                } header: { Text("Не отслеживаются") }
            }
        }
    }
}
