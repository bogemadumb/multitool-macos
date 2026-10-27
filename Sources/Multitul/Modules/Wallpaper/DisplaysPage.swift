import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct DisplaysPage: View {
    var enabled: Set<ModuleID> = []

    var body: some View {
        SettingsPage {
            if enabled.contains(.liveWallpaper) { LiveWallpaperView() }
            if enabled.contains(.staticWallpaper) {
                Section {
                    NavigationLink(value: DisplaysRoute.staticWallpaper) {
                        SettingLabel("Статичные обои", "Картинки и папки, назначение на выбранный экран")
                    }
                } header: { if !enabled.contains(.liveWallpaper) { Text("Обои") } }
            }
            if enabled.contains(.monitorToggle) { MonitorToggleView() }
            if enabled.contains(.brightness) || enabled.contains(.extraBrightness) {
                BrightnessView(showMain: enabled.contains(.brightness), showExtra: enabled.contains(.extraBrightness), canToggleMonitor: enabled.contains(.monitorToggle))
            }
            if enabled.contains(.tvScreen) {
                Section {
                    NavigationLink(value: DisplaysRoute.tv) { TvLinkLabel() }
                } header: { Text("Телевизор") }
            }
        }
        .navigationDestination(for: DisplaysRoute.self) { route in
            switch route {
            case .staticWallpaper: StaticWallpaperView().navigationTitle("Статичные обои")
            case .tv: TvScreenView().navigationTitle("Телевизор")
            }
        }
    }
}

private struct TvLinkLabel: View {
    @ObservedObject private var c = TvScreenController.shared

    var body: some View {
        LabeledContent("Трансляция на телевизор") {
            switch c.state {
            case .running: StatusLabel("идёт", color: .green)
            case .failed: StatusLabel("ошибка", color: .orange)
            default: Text("выключена").foregroundStyle(.secondary)
            }
        }
    }
}

struct LiveWallpaperView: View {
    @ObservedObject private var c = LiveWallpaperController.shared
    @State private var migration: WallpaperMigrationPlan?
    @State private var migrationNote: String?
    @State private var confirmMigrate = false

    var body: some View {
        statusSection
        looksSection
        screensSection
        lockscreenSection
        filesSection
            .onAppear { migration = WallpaperMigration.plan(freeBytes: WallpaperMigration.freeBytes(at: WallpaperFiles.dir)) }
    }

    private var statusSection: some View {
        Section {
            LabeledContent {
                if let r = c.status.pauseReason {
                    StatusLabel("пауза: \(pauseReasonText(r))", color: .orange)
                } else if c.status.screens == 0 {
                    Text("не запущено").foregroundStyle(.secondary)
                } else {
                    StatusLabel("играет на \(c.status.playing) из \(c.status.screens)", color: c.status.playing > 0 ? .green : .secondary)
                }
            } label: {
                let titles = WallpaperFiles.loadTitles()
                Label {
                    SettingLabel(c.status.videoName.map { titles[$0] ?? $0 } ?? "Нет роликов",
                                 c.status.isStandard || c.status.videoName == nil ? (c.status.isDay ? "день" : "ночь") : "не стандартный ролик: первый по имени")
                } icon: { Image(systemName: c.status.isDay ? "sun.max" : "moon") }
            }
            Button(c.manualPause ? "Продолжить" : "Пауза") { c.togglePause() }
        } header: { Text("Живые обои") } footer: {
            if c.dayMode == .auto {
                let s = SunCalc.spb
                if let e = s.events(on: Date()) {
                    SectionFooter("Санкт-Петербург: рассвет \(s.hhmm(e.rise)), закат \(s.hhmm(e.set))" + (c.status.nextSwitch.map { ", следующая смена в \(s.hhmm($0))" } ?? ""))
                } else {
                    SectionFooter(s.polarState(on: Date()) == .midnightSun ? "Солнце не заходит: считается днём" : "Солнце не встаёт: считается ночью")
                }
            }
        }
    }

    private var looksSection: some View {
        Section {
            Picker(selection: Binding(get: { c.color }, set: { c.setColor($0) })) {
                ForEach(WallpaperColor.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { Label("Цвет", systemImage: "circle.lefthalf.filled") }
            .pickerStyle(.segmented)
            Picker(selection: Binding(get: { c.dayMode }, set: { c.setDayMode($0) })) {
                ForEach(DayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { SettingLabel("Время суток", "Авто считает восход и закат по солнцу, без сети") }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { c.pauseOnBattery }, set: { c.setPauseOnBattery($0) })) {
                SettingLabel("Пауза от батареи", "Работа от аккумулятора ставит видео на паузу. Пауза также при блокировке, сне и когда окна закрывают экран целиком.")
            }
        }
    }

    private var screensSection: some View {
        Section {
            ForEach(c.screens) { s in
                Toggle(s.name, isOn: Binding(get: { !c.excluded.contains(s.id) }, set: { c.setScreen(s.id, enabled: $0) }))
            }
        } header: { Text("Экраны") } footer: { SectionFooter("На выключенном экране можно ставить статичные обои.") }
    }

    private var lockscreenSection: some View {
        Section {
            Toggle(isOn: Binding(get: { c.lockFollows }, set: { c.setLockFollows($0) })) {
                SettingLabel("Экран блокировки следует за обоями", "Подменяет файл Aerial «Tahoe Day» и перезапускает WallpaperAgent. Нужна копия оригинала в wallpapers/aerial-original и клипы в wallpapers/aerial. В Настройках → Обои должен быть выбран «Тахо днём».")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if c.status.lockBusy { ProgressView().controlSize(.small) }
                    Button("Вернуть оригинальный Aerial") { c.restoreOriginalAerial() }.disabled(c.status.lockBusy)
                }
            } label: { SettingLabel("На экране блокировки", c.lockVideo ?? "оригинал") }
            if let e = c.status.lockError { ToolWarning(text: e) }
        } header: { Text("Экран блокировки") }
    }

    private var filesSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Открыть") { c.openFolder() }
                    Button("Обновить") { c.refreshNow() }
                }
            } label: { SettingLabel("Папка с роликами", "Роликов: \(c.status.videoCount)") }
            .help("\(WallpaperFiles.dir). Имена: cls-white-night, cls-black-night, cls-white-day, cls-black-day.")
            if let m = migration, !m.missingSource, !m.toCopy.isEmpty {
                LabeledContent {
                    Button("Скопировать") { confirmMigrate = true }.disabled(!m.enoughSpace)
                } label: {
                    SettingLabel("Найдена папка старого LiveWallpaper", "Скопировать \(m.toCopy.count) файлов (\(ByteCountFormatter.string(fromByteCount: m.copyBytes, countStyle: .file))). Исходные файлы не трогаются.")
                }
                if !m.enoughSpace { ToolWarning(text: "Не хватает свободного места.") }
            }
            if let n = migrationNote { Text(n).foregroundStyle(.secondary) }
        } header: { Text("Ролики") }
        .confirmationDialog("Скопировать ролики из старой папки LiveWallpaper?", isPresented: $confirmMigrate) {
            Button("Скопировать") { runMigration() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func runMigration() {
        guard let plan = migration else { return }
        migrationNote = "Копирую…"
        Task {
            let r = await Task.detached { WallpaperMigration.execute(plan) }.value
            migrationNote = r.failed.isEmpty ? "Скопировано файлов: \(r.copied.count)" : "Ошибки: " + r.failed.joined(separator: "; ")
            migration = WallpaperMigration.plan(freeBytes: WallpaperMigration.freeBytes(at: WallpaperFiles.dir))
            c.refreshNow()
        }
    }
}
