import Foundation

public enum BrewName {
    // Formula/cask names and tap paths: letters, digits and @ . _ + - /; never a leading dash, so a name cannot become an option.
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 200, !s.hasPrefix("-"), !s.hasPrefix("/"), !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy { u in
            u.isASCII && (CharacterSet.alphanumerics.contains(u) || "@._+-/".unicodeScalars.contains(u))
        }
    }
}

public extension BrewName {
    static func isValidQuery(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
    }
}

public enum BrewCommandError: Error, Equatable, Sendable {
    case invalidName(String)
    case emptySelection
}

public enum BrewServiceAction: String, CaseIterable, Sendable {
    case start, stop, restart, run

    public var title: String {
        switch self {
        case .start: "Запустить"
        case .stop: "Остановить"
        case .restart: "Перезапустить"
        case .run: "Запустить без автозапуска"
        }
    }
}

public struct BrewCommands {
    public var brewPath: String
    public var autoUpdate: Bool

    public static let installCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    public init(brewPath: String, autoUpdate: Bool = true) {
        self.brewPath = brewPath
        self.autoUpdate = autoUpdate
    }

    public static let baseEnvironment: [String: String] = [
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_EMOJI": "1",
        "HOMEBREW_NO_COLOR": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "NONINTERACTIVE": "1"
    ]

    private func env(readOnly: Bool) -> [String: String] {
        var e = Self.baseEnvironment
        if readOnly || !autoUpdate { e["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        return e
    }

    private func cmd(_ args: [String], timeout: TimeInterval = 60, readOnly: Bool = true) -> ManagerCommand {
        ManagerCommand(brewPath, args, environment: env(readOnly: readOnly), timeout: timeout)
    }

    private func checked(_ names: [String]) throws {
        for n in names where !BrewName.isValid(n) { throw BrewCommandError.invalidName(n) }
    }

    public func installedInfo() -> ManagerCommand { cmd(["info", "--json=v2", "--installed"], timeout: 120) }

    public func info(_ name: String, kind: BrewKind? = nil) throws -> ManagerCommand {
        try checked([name])
        return cmd(["info", "--json=v2"] + (kind.map { [$0.flag] } ?? []) + [name])
    }

    public func outdated(greedy: Bool) -> ManagerCommand {
        cmd(["outdated", "--json=v2"] + (greedy ? ["--greedy"] : []), timeout: 120)
    }

    public func search(_ query: String, kind: BrewKind? = nil, descriptions: Bool = false) throws -> ManagerCommand {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrewName.isValidQuery(q) else { throw BrewCommandError.invalidName(q) }
        var args = ["search"]
        if let kind { args.append(kind.flag) }
        if descriptions { args.append("--desc") }
        args.append(q)
        return cmd(args, timeout: 90)
    }

    public func leaves() -> ManagerCommand { cmd(["leaves"]) }

    public func depsTree(_ name: String) throws -> ManagerCommand {
        try checked([name])
        return cmd(["deps", "--tree", name])
    }

    public func uses(_ name: String) throws -> ManagerCommand {
        try checked([name])
        return cmd(["uses", "--installed", name], timeout: 90)
    }

    public func servicesList() -> ManagerCommand { cmd(["services", "list", "--json"]) }

    public func service(_ action: BrewServiceAction, name: String) throws -> ManagerCommand {
        try checked([name])
        return cmd(["services", action.rawValue, name], timeout: 120, readOnly: false)
    }

    public func servicesCleanup() -> ManagerCommand { cmd(["services", "cleanup"], timeout: 120, readOnly: false) }

    public func update() -> ManagerCommand {
        ManagerCommand(brewPath, ["update"], environment: Self.baseEnvironment, timeout: 600)
    }

    public func install(_ name: String, kind: BrewKind) throws -> ManagerCommand {
        try checked([name])
        return cmd(["install", kind.flag, name], timeout: 3600, readOnly: false)
    }

    public func uninstall(_ name: String, kind: BrewKind, zap: Bool = false, ignoreDependencies: Bool = false) throws -> ManagerCommand {
        try checked([name])
        var args = ["uninstall", kind.flag]
        if zap && kind == .cask { args.append("--zap") }
        if ignoreDependencies && kind == .formula { args.append("--ignore-dependencies") }
        args.append(name)
        return cmd(args, timeout: 900, readOnly: false)
    }

    public func upgrade(_ names: [String], kind: BrewKind, greedy: Bool = false) throws -> ManagerCommand {
        guard !names.isEmpty else { throw BrewCommandError.emptySelection }
        try checked(names)
        return cmd(["upgrade", kind.flag] + (greedy && kind == .cask ? ["--greedy"] : []) + names, timeout: 3600, readOnly: false)
    }

    public func upgradeAll(greedy: Bool) -> ManagerCommand {
        cmd(["upgrade"] + (greedy ? ["--greedy"] : []), timeout: 7200, readOnly: false)
    }

    public func pin(_ name: String, pinned: Bool) throws -> ManagerCommand {
        try checked([name])
        return cmd([pinned ? "pin" : "unpin", name], readOnly: false)
    }

    public func cleanup(dryRun: Bool, pruneAll: Bool = false) -> ManagerCommand {
        var args = ["cleanup"]
        if dryRun { args.append("--dry-run") }
        if pruneAll { args.append("--prune=all") }
        return cmd(args, timeout: 600, readOnly: dryRun)
    }

    public func autoremove(dryRun: Bool) -> ManagerCommand {
        cmd(["autoremove"] + (dryRun ? ["--dry-run"] : []), timeout: 600, readOnly: dryRun)
    }

    public func doctor() -> ManagerCommand { cmd(["doctor"], timeout: 180) }

    // The text shown to the user when a step needs a password: the same command, ready to paste into Terminal.
    public func terminalLine(_ command: ManagerCommand) -> String {
        ShellQuote.line([command.executable] + command.arguments)
    }
}
