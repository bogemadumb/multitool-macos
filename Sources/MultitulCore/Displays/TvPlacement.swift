import Foundation

public struct PlacerDisplay: Equatable, Sendable {
    public var id: String
    public var ctx: String
    public var type: String
    public var res: String

    public init(id: String, ctx: String = "", type: String = "", res: String = "") {
        self.id = id
        self.ctx = ctx
        self.type = type
        self.res = res
    }

    public var isBuiltin: Bool { type.contains("built in") }
}

public enum DisplayplacerParser {
    public static func parse(_ output: String) -> [PlacerDisplay] {
        var items: [PlacerDisplay] = []
        var cur: PlacerDisplay?
        func value(_ line: String) -> String { line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Persistent screen id:") {
                if let c = cur { items.append(c) }
                cur = PlacerDisplay(id: value(line))
            } else if line.hasPrefix("Contextual screen id:") {
                cur?.ctx = value(line)
            } else if line.hasPrefix("Type:") {
                cur?.type = value(line)
            } else if line.hasPrefix("Resolution:") {
                cur?.res = value(line)
            }
        }
        if let c = cur { items.append(c) }
        return items
    }

    // Built-in screen is found by type, the virtual one is the first non-built-in; settings can pin either by persistent or contextual id.
    public static func findScreens(_ list: [PlacerDisplay], mainId: String = "", virtualId: String = "") -> (built: PlacerDisplay?, virt: PlacerDisplay?) {
        func pinned(_ id: String) -> PlacerDisplay? { id.isEmpty ? nil : list.first { $0.id == id || $0.ctx == id } }
        let built = pinned(mainId) ?? list.first { $0.isBuiltin }
        let virt = pinned(virtualId) ?? list.first { !$0.isBuiltin && $0.id != built?.id }
        return (built, virt)
    }
}

public enum TvPlacement {
    public static func arrangeArgs(builtID: String, virtualID: String, config c: TvConfig) -> [String] {
        [
            "id:\(builtID) res:\(c.mainRes) hz:\(c.mainHz) color_depth:\(c.mainColorDepth) scaling:on origin:(0,0) degree:0",
            "id:\(virtualID) res:\(c.width)x\(c.height) hz:\(c.virtualHz) color_depth:\(c.virtualColorDepth) scaling:off origin:(\(c.mainWidth),0) degree:0"
        ]
    }

    public static func restoreArgs(builtID: String, config c: TvConfig) -> [String] {
        ["id:\(builtID) res:\(c.mainRes) hz:\(c.mainHz) color_depth:\(c.mainColorDepth) scaling:on origin:(0,0) degree:0"]
    }
}

public enum TvAudio {
    public static func setArgs(_ device: String) -> [String] { ["-s", device] }
    public static let currentArgs = ["-c"]
    public static let listArgs = ["-a", "-t", "output"]

    public static func parseDevices(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespaces)
            for suffix in [" (output)", " (input)", " (system)", " (aggregate)"] where s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
            }
            return s.isEmpty ? nil : s
        }
    }

    public static func parseCurrent(_ output: String) -> String? {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

public enum TvCommands {
    public static var toolEnvironment: [String: String] {
        let home = NSHomeDirectory()
        return [
            "PATH": "/Library/Frameworks/Python.framework/Versions/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8", "PYTHONIOENCODING": "utf-8"
        ]
    }

    public static func remote(_ action: String, config c: TvConfig) -> (exe: String, args: [String]) {
        if c.remotePython.contains("/") { return (c.remotePython, [c.resolvedRemoteScript, action]) }
        return ("/usr/bin/env", [c.remotePython, c.resolvedRemoteScript, action])
    }
}

public struct TvDependency: Equatable, Sendable {
    public let id: String
    public let title: String
    public let brewName: String
    public let isCask: Bool
    public let probePaths: [String]
    public let purpose: String
}

public enum DependencyStatus: Equatable, Sendable {
    case present(String)
    case missing
    public var isPresent: Bool { if case .present = self { true } else { false } }
}

public struct DependencyReport: Equatable, Sendable {
    public var items: [(dep: TvDependency, status: DependencyStatus)]
    public var brewAvailable: Bool

    public static func == (a: DependencyReport, b: DependencyReport) -> Bool {
        a.brewAvailable == b.brewAvailable && a.items.count == b.items.count
            && zip(a.items, b.items).allSatisfy { $0.dep == $1.dep && $0.status == $1.status }
    }

    public var missing: [TvDependency] { items.filter { !$0.status.isPresent }.map(\.dep) }
    public var allPresent: Bool { missing.isEmpty }
}

public enum TvDependencies {
    public static func list(_ c: TvConfig) -> [TvDependency] {
        [
            TvDependency(id: "deskpad", title: "DeskPad", brewName: "deskpad", isCask: true,
                         probePaths: ["/Applications/\(c.deskpadName).app", NSHomeDirectory() + "/Applications/\(c.deskpadName).app"],
                         purpose: "виртуальный экран"),
            TvDependency(id: "displayplacer", title: "displayplacer", brewName: "displayplacer", isCask: false,
                         probePaths: [c.displayplacerPath, "/usr/local/bin/displayplacer"],
                         purpose: "раскладка экранов"),
            TvDependency(id: "blackhole", title: "BlackHole 2ch", brewName: "blackhole-2ch", isCask: true,
                         probePaths: ["/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"],
                         purpose: "виртуальная звуковая карта"),
            TvDependency(id: "switchaudio", title: "switchaudio-osx", brewName: "switchaudio-osx", isCask: false,
                         probePaths: [c.switchAudioPath, "/usr/local/bin/SwitchAudioSource"],
                         purpose: "переключение вывода звука")
        ]
    }

    // `brew list -1` prints one name per line; `--versions` appends versions; tapped casks come as user/tap/name.
    public static func parseBrewList(_ output: String) -> Set<String> {
        var out = Set<String>()
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("==") { continue }
            guard let first = line.split(separator: " ").first else { continue }
            out.insert(String(first.split(separator: "/").last ?? first))
        }
        return out
    }

    public static func evaluate(config c: TvConfig, formulae: Set<String>, casks: Set<String>, brewAvailable: Bool, exists: (String) -> Bool) -> DependencyReport {
        let items = list(c).map { dep -> (dep: TvDependency, status: DependencyStatus) in
            if let p = dep.probePaths.first(where: exists) { return (dep, .present(p)) }
            if (dep.isCask ? casks : formulae).contains(dep.brewName) { return (dep, .present("brew")) }
            return (dep, .missing)
        }
        return DependencyReport(items: items, brewAvailable: brewAvailable)
    }

    public static func installHint(_ r: DependencyReport) -> String {
        guard !r.missing.isEmpty else { return "" }
        var lines: [String] = []
        if !r.brewAvailable { lines.append("Сначала поставь Homebrew: https://brew.sh") }
        let f = r.missing.filter { !$0.isCask }.map(\.brewName)
        let c = r.missing.filter(\.isCask).map(\.brewName)
        if !f.isEmpty { lines.append("brew install " + f.joined(separator: " ")) }
        if !c.isEmpty { lines.append("brew install --cask " + c.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}
