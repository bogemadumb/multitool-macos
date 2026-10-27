import SwiftUI
import MultitulCore
import MultitulUI

enum ToolPageKind {
    case shots, command, ocr, pad, tidy, brew, pip
}

struct ToolPage: View {
    let kind: ToolPageKind
    var enabled: Set<ModuleID>
    var extras: [Module] = []
    var openModules: () -> Void

    private func on(_ ids: ModuleID...) -> Bool { ids.contains { enabled.contains($0) } }

    var body: some View {
        content
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case .shotLink: ScreenshotLinkPage().navigationTitle("Ссылка на снимок")
                case .shotWatermark: ScreenshotWatermarkPage().navigationTitle("Водяной знак")
                case .shotPins: ScreenshotPinsPage().navigationTitle("Закреплённые снимки")
                case .recorderEditor: RecorderEditorDefaultsPage().navigationTitle("Редактор записи")
                case .launcherItems: LauncherItemsPage().navigationTitle("Пункты палитры")
                case .launcherSlots: LauncherSlotsPage().navigationTitle("Сочетания для пунктов")
                case .commandFiles: CommandFilesPage().navigationTitle("Файлы и скрипты")
                case .commandEntries: CommandEntriesPage().navigationTitle("Мои пункты")
                case .commandSlots: CommandSlotsPage().navigationTitle("Сочетания для пунктов")
                case .commandQuicklinks: CommandQuicklinksPage().navigationTitle("Быстрые ссылки и поиск в сети")
                case .radialItems: RadialItemsPage().navigationTitle("Пункты колеса")
                case .colorConverter: ColorConverterPage().navigationTitle("Конвертер и палитра")
                case .colorContrast: ColorContrastPage().navigationTitle("Контраст WCAG")
                case .homebrew: HomebrewPage().navigationTitle("Homebrew")
                case .appUpdates: AppUpdatesPage().navigationTitle("Обновления приложений")
                case .appUpdateSettings: AppUpdatesSettingsPage().navigationTitle("Настройки обновлений")
                case .mediaSettings: MediaSettingsPage().navigationTitle("Параметры медиа")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .shots:
            if on(.screenshot, .screenRecorder) {
                SettingsPage {
                    if enabled.contains(.screenshot) { ScreenshotSections() }
                    if enabled.contains(.screenRecorder) { RecorderSections() }
                }
            } else { ToolDisabledState(title: "Скриншоты и запись", symbol: "camera.fill", openModules: openModules) }
        case .command:
            if on(.quickLauncher, .commandBar, .radialMenu, .quickToggles) {
                SettingsPage {
                    if enabled.contains(.quickLauncher) { QuickLauncherSections() }
                    if enabled.contains(.commandBar) { CommandBarSections() }
                    if enabled.contains(.radialMenu) { RadialMenuSections() }
                    if enabled.contains(.quickToggles) { QuickTogglesSections() }
                }
            } else { ToolDisabledState(title: "Палитра и командная строка", symbol: "command", openModules: openModules) }
        case .ocr:
            if on(.screenOcr, .colorPicker) {
                SettingsPage {
                    if enabled.contains(.screenOcr) { ScreenOcrSections() }
                    if enabled.contains(.colorPicker) { ColorPickerSections() }
                }
            } else { ToolDisabledState(title: "Текст с экрана и пипетка", symbol: "text.viewfinder", openModules: openModules) }
        case .pad:
            if on(.scratchpad) || !extras.isEmpty {
                SettingsPage {
                    if enabled.contains(.scratchpad) { ScratchpadSections() }
                    ForEach(extras, id: \.info.id) { m in
                        Section(m.info.title) { m.settingsView }
                    }
                }
            } else { ToolDisabledState(title: "Блокнот", symbol: "note.text", openModules: openModules) }
        case .tidy:
            if on(.cleaningMode, .cameraPreview) {
                SettingsPage {
                    if enabled.contains(.cleaningMode) { CleaningModeSections() }
                    if enabled.contains(.cameraPreview) { CameraPreviewSections() }
                }
            } else { ToolDisabledState(title: "Уборка и камера", symbol: "paintbrush.fill", openModules: openModules) }
        case .brew:
            if on(.mediaTools, .homebrewManager, .appUpdates) {
                SettingsPage {
                    if enabled.contains(.mediaTools) { MediaToolsSections() }
                    if on(.homebrewManager, .appUpdates) {
                        Section {
                            if enabled.contains(.homebrewManager) { HomebrewLink() }
                            if enabled.contains(.appUpdates) {
                                NavigationLink(value: ToolRoute.appUpdates) { AppUpdatesLinkLabel() }
                                NavigationLink(value: ToolRoute.appUpdateSettings) { Text("Настройки обновлений") }
                            }
                        } header: { Text("Менеджеры") }
                    }
                }
            } else { ToolDisabledState(title: "Медиа, Homebrew, обновления", symbol: "shippingbox.fill", openModules: openModules) }
        case .pip:
            if enabled.contains(.autoPip) {
                SettingsPage { AutoPipSections() }
            } else { ToolDisabledState(title: "Авто-PiP", symbol: "pip.fill", openModules: openModules) }
        }
    }
}

private struct HomebrewLink: View {
    @ObservedObject private var c = HomebrewController.shared

    var body: some View {
        let _ = c.revision
        NavigationLink(value: ToolRoute.homebrew) {
            LabeledContent("Менеджер Homebrew", value: c.manager.availability.path == nil ? "не найден" : (c.snapshot.outdatedCount > 0 ? "обновлений: \(c.snapshot.outdatedCount)" : "актуально"))
        }
    }
}

private struct AppUpdatesLinkLabel: View {
    @ObservedObject private var c = AppUpdatesController.shared

    var body: some View {
        let _ = c.revision
        LabeledContent("Обновления приложений", value: c.service.isChecking ? "проверяю" : (c.updates.isEmpty ? "всё свежее" : "обновлений: \(c.updates.count)"))
    }
}
