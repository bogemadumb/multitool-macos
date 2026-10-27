import Foundation

public struct NavCatalogEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let header: String?
}

public enum NavCatalog {
    public static let defaultID = "today"
    public static let modulesID = "modules"

    private static func e(_ id: String, _ title: String, _ header: String?) -> NavCatalogEntry {
        NavCatalogEntry(id: id, title: title, header: header)
    }

    public static let entries: [NavCatalogEntry] = [
        e("today", "Сегодня", nil),
        e("net", "Сеть", "Сеть и система"),
        e("system", "Система", "Сеть и система"),
        e("guard", "Сторож", "Сеть и система"),
        e("storage", "Хранилище и очистка", "Сеть и система"),
        e("displays", "Экраны и обои", "Рабочее место"),
        e("windows", "Окна и Dock", "Рабочее место"),
        e("input", "Клавиатура и мышь", "Рабочее место"),
        e("sound", "Звук", "Рабочее место"),
        e("clip", "Буфер и файлы", "Рабочее место"),
        e("energy", "Энергия", "Рабочее место"),
        e("shots", "Скриншоты и запись", "Инструменты"),
        e("cmd", "Палитра и командная строка", "Инструменты"),
        e("ocr", "Текст с экрана и пипетка", "Инструменты"),
        e("pad", "Блокнот", "Инструменты"),
        e("tidy", "Уборка и камера", "Инструменты"),
        e("brew", "Медиа, Homebrew, обновления", "Инструменты"),
        e("pip", "Авто-PiP", "Инструменты"),
        e("island", "Остров", "Инструменты"),
        e("keys", "Горячие клавиши", "Приложение"),
        e("modules", "Модули", "Приложение"),
        e("perm", "Права", "Приложение"),
        e("general", "Основные", "Приложение")
    ]

    public static func title(of id: String) -> String? { entries.first { $0.id == id }?.title }

    public static func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

    private static let legacy: [String: String] = [
        "clean": "storage", "tools": "shots",
        "permissions": "perm", "rights": "perm",
        "hotkeys": "keys", "shortcuts": "keys",
        "settings": "general", "autostart": "general", "about": "general",
        "modules-and-permissions": "modules"
    ]

    public static func sidebarID(forSection raw: String) -> String {
        if contains(raw) { return raw }
        return legacy[raw] ?? defaultID
    }

    public static func sidebarID(for module: ModuleID) -> String {
        switch module {
        case .storozh: "guard"
        case .screenshot, .screenRecorder: "shots"
        case .quickLauncher, .commandBar, .radialMenu, .quickToggles: "cmd"
        case .screenOcr, .colorPicker: "ocr"
        case .scratchpad, .demoClock: "pad"
        case .cleaningMode, .cameraPreview: "tidy"
        case .mediaTools, .homebrewManager, .appUpdates: "brew"
        case .autoPip: "pip"
        default: sidebarID(forSection: module.info.group.rawValue)
        }
    }
}
