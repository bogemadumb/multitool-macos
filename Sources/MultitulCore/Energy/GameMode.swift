import Foundation
import MultitulCtlCore

public struct GameModeAgent: Codable, Equatable, Hashable, Sendable {
    public var launchLabel: String
    public var processPattern: String
    public var relaunchPath: String

    public init(launchLabel: String, processPattern: String, relaunchPath: String) {
        self.launchLabel = launchLabel
        self.processPattern = processPattern
        self.relaunchPath = relaunchPath
    }

    public var title: String { processPattern.isEmpty ? launchLabel : processPattern }
    public var isValid: Bool {
        GameModeSafety.isIdentifier(launchLabel) && !processPattern.trimmingCharacters(in: .whitespaces).isEmpty && relaunchPath.hasPrefix("/")
    }

    public static let mouseFix = GameModeAgent(
        launchLabel: "com.nuebling.mac-mouse-fix.helper",
        processPattern: "Mac Mouse Fix Helper",
        relaunchPath: "/Applications/Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app")
}

public struct GameModeApp: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    public var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && GameModeSafety.isIdentifier(bundleID) }

    public static let atoll = GameModeApp(name: "Atoll", bundleID: "com.Ebullioscopic.Atoll")
}

public enum GameModeSafety {
    public static func isIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}

public struct GameModeSettings: Codable, Equatable, Sendable {
    public static let allCorners = ["tl", "tr", "bl", "br"]

    public var fnKeys = true
    public var disableCorners = true
    public var corners: [String] = GameModeSettings.allCorners
    public var agents: [GameModeAgent] = [.mouseFix]
    public var apps: [GameModeApp] = [.atoll]
    public var notify = true

    public init() {}

    enum CodingKeys: String, CodingKey { case fnKeys, disableCorners, corners, agents, apps, notify }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameModeSettings()
        fnKeys = try c.decodeIfPresent(Bool.self, forKey: .fnKeys) ?? d.fnKeys
        disableCorners = try c.decodeIfPresent(Bool.self, forKey: .disableCorners) ?? d.disableCorners
        corners = try c.decodeIfPresent([String].self, forKey: .corners) ?? d.corners
        agents = try c.decodeIfPresent([GameModeAgent].self, forKey: .agents) ?? d.agents
        apps = try c.decodeIfPresent([GameModeApp].self, forKey: .apps) ?? d.apps
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
    }

    public var sanitized: GameModeSettings {
        var s = self
        s.corners = Self.allCorners.filter { s.corners.contains($0) }
        s.agents = s.agents.filter(\.isValid)
        s.apps = s.apps.filter(\.isValid)
        return s
    }
}

public enum GameModeHotkeys {
    public static let toggle = HotkeySpec(id: "gameMode.toggle", title: "Игровой режим: включить / выключить", defaultCombo: .none)
}

public final class GameModeSettingsStore {
    static let key = "gameMode.settings"
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> GameModeSettings {
        guard let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(GameModeSettings.self, from: d) else { return GameModeSettings() }
        return s.sanitized
    }

    public func save(_ s: GameModeSettings) {
        if s.sanitized == GameModeSettings() { defaults.removeObject(forKey: Self.key); return }
        if let d = try? JSONEncoder().encode(s.sanitized) { defaults.set(d, forKey: Self.key) }
    }
}

public struct GameModeCorner: Codable, Equatable, Sendable {
    public var action: Int
    public var modifier: Int
    public init(action: Int, modifier: Int) {
        self.action = action
        self.modifier = modifier
    }
}

public struct GameModeState: Codable, Equatable, Sendable {
    public var active = false
    public var corners: [String: GameModeCorner] = [:]
    public var fnBefore: Bool?
    public var agents: [GameModeAgent] = []
    public var apps: [GameModeApp] = []
    public init() {}
}

public protocol GameModeStateStoring: AnyObject {
    func load() -> GameModeState
    func save(_ state: GameModeState)
}

public final class GameModeFileState: GameModeStateStoring {
    private let path: String

    public init(path: String = MultitulPaths.home + "/gamemode-state.json") { self.path = path }

    public func load() -> GameModeState {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(GameModeState.self, from: $0) } ?? GameModeState()
    }

    public func save(_ state: GameModeState) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(state) { FileManager.default.createFile(atPath: path, contents: d) }
    }
}

public enum GameModeLegacy {
    public static func isActive(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: home + "/Library/Application Support/gamemode/active")
    }
}

public enum GameModeResult: Equatable, Sendable {
    case turnedOn, turnedOff, alreadyOn, alreadyOff

    public var message: String {
        switch self {
        case .turnedOn: "Включён"
        case .turnedOff: "Выключен"
        case .alreadyOn: "Уже включён"
        case .alreadyOff: "Уже выключен"
        }
    }
}

public final class GameModeEngine {
    public static let defaults = "/usr/bin/defaults"
    public static let activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    private let runner: ProcessRunning
    private let store: GameModeStateStoring
    private let uid: uid_t
    private let settings: () -> GameModeSettings
    private let notify: (String) -> Void
    public private(set) var warnings: [String] = []

    public init(runner: ProcessRunning = SystemProcessRunner(), store: GameModeStateStoring = GameModeFileState(), uid: uid_t = getuid(),
                settings: @escaping () -> GameModeSettings, notify: @escaping (String) -> Void = { _ in }) {
        self.runner = runner
        self.store = store
        self.uid = uid
        self.settings = settings
        self.notify = notify
    }

    public var isOn: Bool { store.load().active }

    @discardableResult
    public func toggle() -> GameModeResult { isOn ? off() : on() }

    @discardableResult
    private func sh(_ exe: String, _ args: [String]) -> ProcessOutput {
        let r = runner.run(exe, args, timeout: 15)
        if r.status != 0 { Log.write("gameMode \(exe) \(args.joined(separator: " ")) -> \(r.status)") }
        return r
    }

    private func readInt(_ domain: String, _ key: String, fallback: Int) -> Int {
        let r = sh(Self.defaults, ["read", domain, key])
        return r.status == 0 ? Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback : fallback
    }

    private func readFn() -> Bool {
        let r = sh(Self.defaults, ["read", "-g", "com.apple.keyboard.fnState"])
        let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && (t == "1" || t.lowercased() == "true")
    }

    private func writeFn(_ on: Bool) {
        sh(Self.defaults, ["write", "-g", "com.apple.keyboard.fnState", "-bool", on ? "true" : "false"])
        sh(Self.activateSettings, ["-u"])
    }

    @discardableResult
    public func on() -> GameModeResult {
        var state = store.load()
        if state.active { return .alreadyOn }
        let s = settings().sanitized
        state = GameModeState()
        state.agents = s.agents
        state.apps = s.apps
        if s.disableCorners {
            for c in s.corners {
                state.corners[c] = GameModeCorner(action: readInt("com.apple.dock", "wvous-\(c)-corner", fallback: 1),
                                                  modifier: readInt("com.apple.dock", "wvous-\(c)-modifier", fallback: 0))
            }
        }
        if s.fnKeys { state.fnBefore = readFn() }
        state.active = true
        store.save(state)

        if !state.corners.isEmpty {
            for c in state.corners.keys.sorted() {
                sh(Self.defaults, ["write", "com.apple.dock", "wvous-\(c)-corner", "-int", "1"])
                sh(Self.defaults, ["write", "com.apple.dock", "wvous-\(c)-modifier", "-int", "0"])
            }
            sh("/usr/bin/killall", ["Dock"])
        }
        if s.fnKeys { writeFn(true) }
        for a in s.agents {
            sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(a.launchLabel)"])
            sh("/usr/bin/pkill", ["-f", a.processPattern])
        }
        for app in s.apps {
            sh("/usr/bin/osascript", ["-e", "quit app id \"\(app.bundleID)\""])
            sh("/usr/bin/pkill", ["-x", app.name])
        }
        if s.notify { notify("Включён") }
        return .turnedOn
    }

    @discardableResult
    public func off() -> GameModeResult {
        let state = store.load()
        if !state.active { return .alreadyOff }
        let s = settings()
        if !state.corners.isEmpty {
            for c in state.corners.keys.sorted() {
                let v = state.corners[c]!
                sh(Self.defaults, ["write", "com.apple.dock", "wvous-\(c)-corner", "-int", String(v.action)])
                sh(Self.defaults, ["write", "com.apple.dock", "wvous-\(c)-modifier", "-int", String(v.modifier)])
            }
            sh("/usr/bin/killall", ["Dock"])
        }
        if let before = state.fnBefore { writeFn(before) }
        for a in state.agents where a.isValid {
            if sh("/usr/bin/pgrep", ["-f", a.processPattern]).status != 0 { sh("/usr/bin/open", ["-g", a.relaunchPath]) }
        }
        for app in state.apps where app.isValid {
            if sh("/usr/bin/pgrep", ["-x", app.name]).status != 0 { sh("/usr/bin/open", ["-g", "-b", app.bundleID]) }
        }
        store.save(GameModeState())
        if s.notify { notify("Выключен") }
        return .turnedOff
    }
}

// Multitul --gamemode on|off|toggle|status  (replaces ~/bin/gamemode)
public enum GameModeCLI {
    public static func handles(_ args: [String]) -> Bool { args.contains("--gamemode") }

    public static func run(arguments a: [String], engine: GameModeEngine? = nil, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        guard let k = a.firstIndex(of: "--gamemode") else { return 2 }
        let word = a.count > k + 1 ? a[k + 1] : "toggle"
        let e = engine ?? GameModeEngine(settings: { GameModeSettingsStore().load() }, notify: { text in
            _ = SystemProcessRunner().run("/usr/bin/osascript", ["-e", "display notification \"\(text)\" with title \"Игровой режим\""], timeout: 10)
        })
        switch word {
        case "on": out(e.on() == .alreadyOn ? "already on" : "on")
        case "off": _ = e.off(); out("off")
        case "toggle": out(e.toggle() == .turnedOn ? "on" : "off")
        case "status": out(e.isOn ? "on" : "off")
        default:
            err("usage: Multitul --gamemode on|off|toggle|status")
            return 2
        }
        return 0
    }
}
