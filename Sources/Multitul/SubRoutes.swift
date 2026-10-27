import SwiftUI
import MultitulCore

enum VpnSub: Hashable { case connections, rules, keys, journal, diagnostics }
enum SystemRoute: Hashable { case processes, history, energy, fans, kill, ports }
enum CleanRoute: Hashable { case cleaner, disk, razbor, uninstall, ram }
enum StorozhRoute: Hashable { case sessions }
enum DisplaysRoute: Hashable { case staticWallpaper, tv }
enum WindowsRoute: Hashable { case shortcuts, customLayouts, snapZones, switcherRules }
enum InputRoute: Hashable { case mouseButtons, buttonActions, snippets }
enum ClipRoute: Hashable { case ignoredApps, urlManual, urlRules }
enum IslandRoute: Hashable { case sections, shortcuts, extensions }
enum ToolRoute: Hashable {
    case shotLink, shotWatermark, shotPins, recorderEditor
    case launcherItems, launcherSlots
    case commandFiles, commandEntries, commandSlots, commandQuicklinks
    case radialItems
    case colorConverter, colorContrast
    case homebrew, appUpdates, appUpdateSettings, mediaSettings
}

struct SubpageTarget {
    let module: ModuleID?
    let push: (inout NavigationPath) -> Void

    init<R: Hashable>(_ module: ModuleID?, _ route: R) {
        self.module = module
        push = { $0.append(route) }
    }
}

enum SubpageTable {
    static func anchor(section: String, subpage: String) -> String? {
        switch section + "|" + subpage {
        case "shots|История": "shots.history"
        default: nil
        }
    }

    static func target(section: String, subpage: String) -> SubpageTarget? {
        switch section + "|" + subpage {
        case "net|Соединения": SubpageTarget(.vpn, VpnSub.connections)
        case "net|Правила": SubpageTarget(.vpn, VpnSub.rules)
        case "net|Ключи": SubpageTarget(.vpn, VpnSub.keys)
        case "net|Журнал": SubpageTarget(.vpn, VpnSub.journal)
        case "net|Скорость": SubpageTarget(.vpn, VpnSub.diagnostics)
        case "system|Процессы": SubpageTarget(nil, SystemRoute.processes)
        case "system|История": SubpageTarget(nil, SystemRoute.history)
        case "system|Энергия": SubpageTarget(nil, SystemRoute.energy)
        case "system|Вентиляторы": SubpageTarget(.fanControl, SystemRoute.fans)
        case "system|Завершение процессов": SubpageTarget(.killProcess, SystemRoute.kill)
        case "system|Порты": SubpageTarget(.portManager, SystemRoute.ports)
        case "storage|Очистка Мака": SubpageTarget(.cleaner, CleanRoute.cleaner)
        case "storage|Очистка диска": SubpageTarget(.diskClean, CleanRoute.disk)
        case "storage|Разбор": SubpageTarget(.razbor, CleanRoute.razbor)
        case "storage|Удаление приложений": SubpageTarget(.uninstaller, CleanRoute.uninstall)
        case "storage|Оперативная память": SubpageTarget(.ramClean, CleanRoute.ram)
        case "guard|Сессии": SubpageTarget(.storozh, StorozhRoute.sessions)
        case "displays|Статичные обои": SubpageTarget(.staticWallpaper, DisplaysRoute.staticWallpaper)
        case "displays|Телевизор": SubpageTarget(.tvScreen, DisplaysRoute.tv)
        case "windows|Сочетания": SubpageTarget(.windowLayout, WindowsRoute.shortcuts)
        case "windows|Свои макеты": SubpageTarget(.windowLayout, WindowsRoute.customLayouts)
        case "windows|Зоны краёв": SubpageTarget(.windowLayout, WindowsRoute.snapZones)
        case "windows|Правила": SubpageTarget(.windowSwitcher, WindowsRoute.switcherRules)
        case "input|Боковые кнопки": SubpageTarget(.mouseNavigation, InputRoute.mouseButtons)
        case "input|Действия": SubpageTarget(.mouseButtonShortcuts, InputRoute.buttonActions)
        case "input|Библиотека": SubpageTarget(.textSnippets, InputRoute.snippets)
        case "clip|Игнорируемые приложения": SubpageTarget(.clipboardHistory, ClipRoute.ignoredApps)
        case "clip|Очистить вручную": SubpageTarget(.urlCleaner, ClipRoute.urlManual)
        case "clip|Правила сайтов": SubpageTarget(.urlCleaner, ClipRoute.urlRules)
        case "island|Разделы": SubpageTarget(.notch, IslandRoute.sections)
        case "island|Ярлыки": SubpageTarget(.notch, IslandRoute.shortcuts)
        case "island|Расширения": SubpageTarget(.notch, IslandRoute.extensions)
        case "shots|Ссылка на снимок": SubpageTarget(.screenshot, ToolRoute.shotLink)
        case "shots|Водяной знак": SubpageTarget(.screenshot, ToolRoute.shotWatermark)
        case "shots|Закреплённые снимки": SubpageTarget(.screenshot, ToolRoute.shotPins)
        case "shots|Редактор записи": SubpageTarget(.screenRecorder, ToolRoute.recorderEditor)
        case "cmd|Пункты палитры": SubpageTarget(.quickLauncher, ToolRoute.launcherItems)
        case "cmd|Сочетания палитры": SubpageTarget(.quickLauncher, ToolRoute.launcherSlots)
        case "cmd|Файлы и скрипты": SubpageTarget(.commandBar, ToolRoute.commandFiles)
        case "cmd|Мои пункты": SubpageTarget(.commandBar, ToolRoute.commandEntries)
        case "cmd|Сочетания для пунктов": SubpageTarget(.commandBar, ToolRoute.commandSlots)
        case "cmd|Быстрые ссылки": SubpageTarget(.commandBar, ToolRoute.commandQuicklinks)
        case "cmd|Пункты колеса": SubpageTarget(.radialMenu, ToolRoute.radialItems)
        case "ocr|Конвертер и палитра": SubpageTarget(.colorPicker, ToolRoute.colorConverter)
        case "ocr|Контраст WCAG": SubpageTarget(.colorPicker, ToolRoute.colorContrast)
        case "brew|Homebrew": SubpageTarget(.homebrewManager, ToolRoute.homebrew)
        case "brew|Обновления приложений": SubpageTarget(.appUpdates, ToolRoute.appUpdates)
        case "brew|Настройки обновлений": SubpageTarget(.appUpdates, ToolRoute.appUpdateSettings)
        case "brew|Параметры медиа": SubpageTarget(.mediaTools, ToolRoute.mediaSettings)
        default: nil
        }
    }
}
