import Foundation

public enum BrewKind: String, CaseIterable, Sendable {
    case formula, cask

    public var title: String { self == .formula ? "Формула" : "Cask" }
    public var flag: String { self == .formula ? "--formula" : "--cask" }
}

public struct BrewPackage: Identifiable, Equatable, Sendable {
    public var name: String
    public var fullName: String
    public var kind: BrewKind
    public var displayName: String
    public var desc: String
    public var homepage: String
    public var tap: String
    public var installedVersion: String?
    public var latestVersion: String
    public var installedOnRequest: Bool
    public var installedAsDependency: Bool
    public var pinned: Bool
    public var outdated: Bool
    public var autoUpdates: Bool
    public var deprecated: Bool
    public var disabled: Bool
    public var dependencies: [String]
    public var appNames: [String]

    public var id: String { kind.rawValue + ":" + fullName }
    public var isInstalled: Bool { installedVersion != nil }

    public init(name: String, fullName: String? = nil, kind: BrewKind, displayName: String = "", desc: String = "", homepage: String = "", tap: String = "",
                installedVersion: String? = nil, latestVersion: String = "", installedOnRequest: Bool = false, installedAsDependency: Bool = false,
                pinned: Bool = false, outdated: Bool = false, autoUpdates: Bool = false, deprecated: Bool = false, disabled: Bool = false,
                dependencies: [String] = [], appNames: [String] = []) {
        self.name = name
        self.fullName = fullName ?? name
        self.kind = kind
        self.displayName = displayName.isEmpty ? name : displayName
        self.desc = desc
        self.homepage = homepage
        self.tap = tap
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.installedOnRequest = installedOnRequest
        self.installedAsDependency = installedAsDependency
        self.pinned = pinned
        self.outdated = outdated
        self.autoUpdates = autoUpdates
        self.deprecated = deprecated
        self.disabled = disabled
        self.dependencies = dependencies
        self.appNames = appNames
    }
}

public struct BrewOutdatedItem: Identifiable, Equatable, Sendable {
    public var name: String
    public var kind: BrewKind
    public var installedVersions: [String]
    public var currentVersion: String
    public var pinned: Bool

    public var id: String { kind.rawValue + ":" + name }
    public var installedVersion: String { installedVersions.last ?? "" }

    public init(name: String, kind: BrewKind, installedVersions: [String], currentVersion: String, pinned: Bool = false) {
        self.name = name
        self.kind = kind
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.pinned = pinned
    }
}

public enum BrewServiceStatus: String, Sendable {
    case started, stopped, scheduled, error, none, unknown

    public var title: String {
        switch self {
        case .started: "Работает"
        case .stopped: "Остановлена"
        case .scheduled: "По расписанию"
        case .error: "Ошибка"
        case .none: "Не запускалась"
        case .unknown: "Неизвестно"
        }
    }

    public var isRunning: Bool { self == .started || self == .scheduled }
}

public struct BrewServiceInfo: Identifiable, Equatable, Sendable {
    public var name: String
    public var status: BrewServiceStatus
    public var user: String
    public var file: String
    public var exitCode: Int?

    public var id: String { name }

    public init(name: String, status: BrewServiceStatus, user: String = "", file: String = "", exitCode: Int? = nil) {
        self.name = name
        self.status = status
        self.user = user
        self.file = file
        self.exitCode = exitCode
    }
}

public struct BrewSearchResult: Identifiable, Equatable, Sendable {
    public var name: String
    public var kind: BrewKind?
    public var desc: String

    public var id: String { (kind?.rawValue ?? "any") + ":" + name }

    public init(name: String, kind: BrewKind?, desc: String = "") {
        self.name = name
        self.kind = kind
        self.desc = desc
    }
}

public struct BrewDepNode: Equatable, Sendable {
    public var name: String
    public var children: [BrewDepNode]

    public init(name: String, children: [BrewDepNode] = []) {
        self.name = name
        self.children = children
    }

    public var flattened: [String] { children.flatMap { [$0.name] + $0.flattened } }
    public var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
}

public struct BrewCleanupReport: Equatable, Sendable {
    public var items: [String]
    public var bytes: Int64
    public var isDryRun: Bool

    public init(items: [String] = [], bytes: Int64 = 0, isDryRun: Bool = true) {
        self.items = items
        self.bytes = bytes
        self.isDryRun = isDryRun
    }
}

public struct BrewSettings: Equatable, Sendable {
    public var includeGreedy = false
    public var autoUpdateIndex = true
    public var cleanupAfterUpgrade = false
    public var refreshOnOpen = true
    public var notifyOutdated = false
    public var preferTerminalForCasks = false
    public var searchWithDescriptions = true
    public var searchLimit = 40

    public static let searchLimitRange = 10...200

    public init() {}

    public var sanitized: BrewSettings {
        var s = self
        s.searchLimit = ToolsClamp.int(s.searchLimit, BrewSettings.searchLimitRange)
        return s
    }
}

public final class BrewSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> BrewSettings {
        var s = BrewSettings()
        let p = "homebrew."
        s.includeGreedy = a.bool(p + "greedy", s.includeGreedy)
        s.autoUpdateIndex = a.bool(p + "autoUpdate", s.autoUpdateIndex)
        s.cleanupAfterUpgrade = a.bool(p + "cleanupAfterUpgrade", s.cleanupAfterUpgrade)
        s.refreshOnOpen = a.bool(p + "refreshOnOpen", s.refreshOnOpen)
        s.notifyOutdated = a.bool(p + "notifyOutdated", s.notifyOutdated)
        s.preferTerminalForCasks = a.bool(p + "terminalForCasks", s.preferTerminalForCasks)
        s.searchWithDescriptions = a.bool(p + "searchDesc", s.searchWithDescriptions)
        s.searchLimit = a.int(p + "searchLimit", s.searchLimit)
        return s.sanitized
    }

    public func save(_ s: BrewSettings) {
        let b = BrewSettings()
        let v = s.sanitized
        let p = "homebrew."
        a.put(p + "greedy", v.includeGreedy, b.includeGreedy)
        a.put(p + "autoUpdate", v.autoUpdateIndex, b.autoUpdateIndex)
        a.put(p + "cleanupAfterUpgrade", v.cleanupAfterUpgrade, b.cleanupAfterUpgrade)
        a.put(p + "refreshOnOpen", v.refreshOnOpen, b.refreshOnOpen)
        a.put(p + "notifyOutdated", v.notifyOutdated, b.notifyOutdated)
        a.put(p + "terminalForCasks", v.preferTerminalForCasks, b.preferTerminalForCasks)
        a.put(p + "searchDesc", v.searchWithDescriptions, b.searchWithDescriptions)
        a.put(p + "searchLimit", v.searchLimit, b.searchLimit)
    }
}
