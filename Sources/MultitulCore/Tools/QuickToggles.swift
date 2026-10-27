import Foundation

public enum QuickToggleID: String, CaseIterable, Identifiable, Sendable {
    case darkMode, desktopIcons, ejectDisks, emptyTrash, restartFinder, lockScreen, displaySleep, screenSaver

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .darkMode: "Тёмная тема"
        case .desktopIcons: "Иконки рабочего стола"
        case .ejectDisks: "Извлечь диски"
        case .emptyTrash: "Очистить Корзину"
        case .restartFinder: "Перезапустить Finder"
        case .lockScreen: "Заблокировать экран"
        case .displaySleep: "Выключить дисплей"
        case .screenSaver: "Заставка"
        }
    }

    public var caption: String {
        switch self {
        case .darkMode: "Тёмная"
        case .desktopIcons: "Иконки"
        case .ejectDisks: "Диски"
        case .emptyTrash: "Корзина"
        case .restartFinder: "Finder"
        case .lockScreen: "Блокировка"
        case .displaySleep: "Дисплей"
        case .screenSaver: "Заставка"
        }
    }

    public var symbol: String {
        switch self {
        case .darkMode: "circle.lefthalf.filled"
        case .desktopIcons: "menubar.dock.rectangle"
        case .ejectDisks: "eject"
        case .emptyTrash: "trash"
        case .restartFinder: "arrow.clockwise"
        case .lockScreen: "lock.fill"
        case .displaySleep: "display"
        case .screenSaver: "moon.stars"
        }
    }

    public var summary: String {
        switch self {
        case .darkMode: "Переключает светлую и тёмную тему системы"
        case .desktopIcons: "Прячет и возвращает значки на рабочем столе (Finder перезапускается)"
        case .ejectDisks: "Размонтирует и извлекает все внешние диски и образы"
        case .emptyTrash: "Удаляет всё из Корзины; по умолчанию с подтверждением"
        case .restartFinder: "Перезапускает Finder, если он завис"
        case .lockScreen: "Блокирует экран, как «Заблокировать экран» в меню Apple"
        case .displaySleep: "Выключает дисплей, не усыпляя Мак"
        case .screenSaver: "Запускает заставку"
        }
    }

    public var isSwitch: Bool { self == .darkMode || self == .desktopIcons }

    public var needsConfirmation: Bool { self == .emptyTrash }

    public var permission: Permission? { self == .emptyTrash ? .automation : nil }
}

public struct VolumeInfo: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isInternal: Bool
    public var isEjectable: Bool
    public var isRemovable: Bool
    public var isLocal: Bool

    public init(name: String, path: String, isInternal: Bool = false, isEjectable: Bool = true, isRemovable: Bool = false, isLocal: Bool = true) {
        self.name = name
        self.path = path
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.isLocal = isLocal
    }
}

public enum EjectPolicy {
    public static func targets(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.filter { v in
            guard v.path != "/", !v.path.hasPrefix("/System/"), !v.path.hasPrefix("/private/"), v.isLocal else { return false }
            return !v.isInternal && (v.isEjectable || v.isRemovable)
        }
    }
}

public protocol QuickToggleDriving: AnyObject {
    func isDarkMode() -> Bool
    func setDarkMode(_ on: Bool) -> Bool
    func desktopIconsHidden() -> Bool
    func setDesktopIconsHidden(_ hidden: Bool) -> Bool
    func volumes() -> [VolumeInfo]
    func eject(_ volume: VolumeInfo) -> Bool
    func trashItemCount() -> Int?
    func emptyTrash() -> Bool
    func restartFinder() -> Bool
    func lockScreen() -> Bool
    func sleepDisplays() -> Bool
    func startScreenSaver() -> Bool
}

public struct QuickToggleSettings: Equatable, Sendable {
    public var enabled = QuickToggleID.allCases
    public var confirmTrash = true
    public var showHud = true

    public init() {}

    public var sanitized: QuickToggleSettings {
        var s = self
        var seen = Set<QuickToggleID>()
        s.enabled = enabled.filter { seen.insert($0).inserted }
        return s
    }
}

public final class QuickToggleSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> QuickToggleSettings {
        var s = QuickToggleSettings()
        let p = "quickToggles."
        if let raw = a.string(p + "enabled") {
            s.enabled = raw.split(separator: ",").compactMap { QuickToggleID(rawValue: String($0)) }
        }
        s.confirmTrash = a.bool(p + "confirmTrash", s.confirmTrash)
        s.showHud = a.bool(p + "showHud", s.showHud)
        return s.sanitized
    }

    public func save(_ settings: QuickToggleSettings) {
        let s = settings.sanitized
        let b = QuickToggleSettings()
        let p = "quickToggles."
        a.put(p + "enabled", s.enabled.map(\.rawValue).joined(separator: ","), b.enabled.map(\.rawValue).joined(separator: ","))
        a.put(p + "confirmTrash", s.confirmTrash, b.confirmTrash)
        a.put(p + "showHud", s.showHud, b.showHud)
    }
}

public enum QuickToggleResult: Equatable, Sendable {
    case done(message: String, state: Bool?)
    case needsConfirmation(prompt: String)
    case nothingToDo(message: String)
    case failed(message: String)

    public var message: String {
        switch self {
        case .done(let m, _), .nothingToDo(let m), .failed(let m), .needsConfirmation(let m): m
        }
    }
}

public final class QuickToggleRegistry: @unchecked Sendable {
    public var settings: QuickToggleSettings
    private let driver: QuickToggleDriving

    public init(driver: QuickToggleDriving, settings: QuickToggleSettings = QuickToggleSettings()) {
        self.driver = driver
        self.settings = settings.sanitized
    }

    public var visible: [QuickToggleID] { settings.enabled }

    public func state(of id: QuickToggleID) -> Bool? {
        switch id {
        case .darkMode: driver.isDarkMode()
        case .desktopIcons: driver.desktopIconsHidden()
        default: nil
        }
    }

    public func perform(_ id: QuickToggleID, confirmed: Bool = false) -> QuickToggleResult {
        switch id {
        case .darkMode:
            let target = !driver.isDarkMode()
            return driver.setDarkMode(target)
                ? .done(message: target ? "Тёмная тема включена" : "Светлая тема включена", state: target)
                : .failed(message: "Не удалось переключить тему")
        case .desktopIcons:
            let target = !driver.desktopIconsHidden()
            return driver.setDesktopIconsHidden(target)
                ? .done(message: target ? "Иконки рабочего стола скрыты" : "Иконки рабочего стола вернулись", state: target)
                : .failed(message: "Не удалось изменить иконки рабочего стола")
        case .ejectDisks:
            let targets = EjectPolicy.targets(driver.volumes())
            guard !targets.isEmpty else { return .nothingToDo(message: "Внешних дисков нет") }
            var failed: [String] = []
            for v in targets where !driver.eject(v) { failed.append(v.name) }
            let ok = targets.count - failed.count
            if failed.isEmpty { return .done(message: "Извлечено дисков: \(ok)", state: nil) }
            return ok > 0 ? .done(message: "Извлечено: \(ok), не вышло: \(failed.joined(separator: ", "))", state: nil)
                          : .failed(message: "Не удалось извлечь: \(failed.joined(separator: ", "))")
        case .emptyTrash:
            let count = driver.trashItemCount()
            if count == 0 { return .nothingToDo(message: "Корзина уже пуста") }
            if settings.confirmTrash && !confirmed {
                return .needsConfirmation(prompt: count.map { "Очистить Корзину? Элементов: \($0). Это нельзя отменить." } ?? "Очистить Корзину? Это нельзя отменить.")
            }
            return driver.emptyTrash() ? .done(message: "Корзина очищена", state: nil) : .failed(message: "Не удалось очистить Корзину. Проверь доступ к автоматизации Finder")
        case .restartFinder:
            return driver.restartFinder() ? .done(message: "Finder перезапущен", state: nil) : .failed(message: "Не удалось перезапустить Finder")
        case .lockScreen:
            return driver.lockScreen() ? .done(message: "Экран заблокирован", state: nil) : .failed(message: "Не удалось заблокировать экран")
        case .displaySleep:
            return driver.sleepDisplays() ? .done(message: "Дисплей выключен", state: nil) : .failed(message: "Не удалось выключить дисплей")
        case .screenSaver:
            return driver.startScreenSaver() ? .done(message: "Заставка запущена", state: nil) : .failed(message: "Не удалось запустить заставку")
        }
    }
}
