import Foundation

public enum ModuleFilter: String, CaseIterable, Identifiable, Sendable {
    case all, enabled, needsPermissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Все"
        case .enabled: "Включённые"
        case .needsPermissions: "Нужны права"
        }
    }
}

public struct ModuleListSection: Identifiable {
    public let group: ModuleGroup
    public let modules: [ModuleInfo]
    public var id: String { group.rawValue }
}

public enum ModuleList {
    public static func missingPermissions(_ info: ModuleInfo, status: (Permission) -> PermissionStatus) -> [Permission] {
        info.permissions.filter { let s = status($0); return s == .denied || s == .undetermined }
    }

    public static func matches(_ info: ModuleInfo, query: String, filter: ModuleFilter, enabled: Bool, status: (Permission) -> PermissionStatus) -> Bool {
        switch filter {
        case .all: break
        case .enabled: if !enabled { return false }
        case .needsPermissions: if !enabled || missingPermissions(info, status: status).isEmpty { return false }
        }
        if SettingsSearch.words(query).isEmpty { return true }
        let kw = info.summary + " " + info.group.title + " " + info.permissions.map(\.title).joined(separator: " ")
        return SettingsSearch.score(query: query, title: info.title, keywords: kw) != nil
    }

    public static func sections(query: String, filter: ModuleFilter, isEnabled: (ModuleID) -> Bool, status: (Permission) -> PermissionStatus) -> [ModuleListSection] {
        ModuleGroup.allCases.compactMap { g in
            let list = ModuleID.allCases.map(\.info).filter {
                $0.group == g && matches($0, query: query, filter: filter, enabled: isEnabled($0.id), status: status)
            }
            return list.isEmpty ? nil : ModuleListSection(group: g, modules: list)
        }
    }
}

public struct PermissionUsage: Equatable, Sendable {
    public let permission: Permission
    public let all: [String]
    public let enabled: [String]
}

public enum PermissionPortal {
    public static func purpose(_ p: Permission) -> String {
        switch p {
        case .accessibility: "Сочетания клавиш, окна, мышь и клавиатура"
        case .screenRecording: "Скриншоты, запись экрана, пипетка, текст с экрана"
        case .inputMonitoring: "Перехват клавиш и событий мыши"
        case .automation: "Управление Finder, Safari и другими программами. Из приложения не проверяется"
        case .notifications: "Предупреждения Сторожа, VPN и лимитов"
        case .fullDiskAccess: "Очистка диска и разбор"
        case .camera: "Зеркало камеры"
        case .microphone: "Запись звука, телевизор"
        case .calendars: "Календарь в Острове"
        case .bluetooth: "Bluetooth на время сна"
        case .systemAudio: "Микшер и звук системы при записи"
        case .appManagement: "Установка и обновление приложений"
        }
    }

    public static func usage(_ p: Permission, isEnabled: (ModuleID) -> Bool) -> PermissionUsage {
        let users = ModuleID.allCases.filter { $0.info.permissions.contains(p) }
        return PermissionUsage(permission: p, all: users.map { $0.info.title }, enabled: users.filter(isEnabled).map { $0.info.title })
    }

    public static func usages(isEnabled: (ModuleID) -> Bool) -> [PermissionUsage] {
        let u = Permission.allCases.map { usage($0, isEnabled: isEnabled) }
        return u.filter { !$0.enabled.isEmpty } + u.filter { $0.enabled.isEmpty }
    }

    public static func summary(_ u: PermissionUsage, maxNames: Int = 3) -> String {
        let names = u.enabled.isEmpty ? u.all : u.enabled
        if names.isEmpty { return "Пока ни один модуль не требует" }
        let head = names.prefix(maxNames).joined(separator: ", ")
        let rest = names.count - maxNames
        let tail = rest > 0 ? " и ещё \(rest)" : ""
        return (u.enabled.isEmpty ? "Нужно выключенным: " : "Нужно: ") + head + tail
    }

    public static func blockedModules(isEnabled: (ModuleID) -> Bool, status: (Permission) -> PermissionStatus) -> [ModuleInfo] {
        ModuleID.allCases.filter(isEnabled).map(\.info).filter { !ModuleList.missingPermissions($0, status: status).isEmpty }
    }
}
