import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

private final class GMScriptedRunner: ProcessRunning, @unchecked Sendable {
    var calls: [String] = []
    var replies: [String: ProcessOutput] = [:]

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        let line = ([executable] + arguments).joined(separator: " ")
        calls.append(line)
        return replies[line] ?? ProcessOutput(status: 0)
    }
}

private final class GMMemoryState: GameModeStateStoring {
    var state = GameModeState()
    func load() -> GameModeState { state }
    func save(_ s: GameModeState) { state = s }
}

private func engine(_ runner: GMScriptedRunner, _ mem: GMMemoryState = GMMemoryState(), settings: GameModeSettings = GameModeSettings(),
                    notes: NoteBox = NoteBox()) -> GameModeEngine {
    GameModeEngine(runner: runner, store: mem, uid: 501, settings: { settings }, notify: { notes.items.append($0) })
}

private final class NoteBox { var items: [String] = [] }

private let defaults = "/usr/bin/defaults"

@Suite struct GameModeEngineTests {
    @Test func onRunsEveryStepInOrder() {
        let r = GMScriptedRunner()
        let notes = NoteBox()
        let result = engine(r, notes: notes).on()
        #expect(result == .turnedOn)
        let c = r.calls
        #expect(c.contains("\(defaults) write com.apple.dock wvous-tl-corner -int 1"))
        #expect(c.contains("\(defaults) write com.apple.dock wvous-br-modifier -int 0"))
        #expect(c.contains("/usr/bin/killall Dock"))
        #expect(c.contains("\(defaults) write -g com.apple.keyboard.fnState -bool true"))
        #expect(c.contains("\(GameModeEngine.activateSettings) -u"))
        #expect(c.contains("/bin/launchctl bootout gui/501/com.nuebling.mac-mouse-fix.helper"))
        #expect(c.contains("/usr/bin/pkill -f Mac Mouse Fix Helper"))
        #expect(c.contains("/usr/bin/osascript -e quit app id \"com.Ebullioscopic.Atoll\""))
        #expect(c.contains("/usr/bin/pkill -x Atoll"))
        let dock = c.firstIndex(of: "/usr/bin/killall Dock")!
        let fn = c.firstIndex(of: "\(defaults) write -g com.apple.keyboard.fnState -bool true")!
        let boot = c.firstIndex(of: "/bin/launchctl bootout gui/501/com.nuebling.mac-mouse-fix.helper")!
        #expect(dock < fn && fn < boot)
        #expect(notes.items == ["Включён"])
    }

    @Test func cornersAreReadBeforeAnythingIsChanged() {
        let r = GMScriptedRunner()
        r.replies["\(defaults) read com.apple.dock wvous-tr-corner"] = ProcessOutput(status: 0, stdout: "5\n")
        r.replies["\(defaults) read com.apple.dock wvous-tr-modifier"] = ProcessOutput(status: 0, stdout: "1048576\n")
        let mem = GMMemoryState()
        _ = engine(r, mem).on()
        #expect(mem.state.corners["tr"] == GameModeCorner(action: 5, modifier: 1048576))
        #expect(mem.state.corners["tl"] == GameModeCorner(action: 1, modifier: 0))
        let firstWrite = r.calls.firstIndex { $0.contains(" write ") }!
        let lastRead = r.calls.lastIndex { $0.contains(" read ") }!
        #expect(lastRead < firstWrite)
        #expect(mem.state.active)
    }

    @Test func offRestoresCornersFnAndPrograms() {
        let r = GMScriptedRunner()
        r.replies["\(defaults) read com.apple.dock wvous-bl-corner"] = ProcessOutput(status: 0, stdout: "2\n")
        r.replies["\(defaults) read -g com.apple.keyboard.fnState"] = ProcessOutput(status: 0, stdout: "1\n")
        let mem = GMMemoryState()
        let e = engine(r, mem)
        _ = e.on()
        r.calls = []
        r.replies["/usr/bin/pgrep -f Mac Mouse Fix Helper"] = ProcessOutput(status: 1)
        r.replies["/usr/bin/pgrep -x Atoll"] = ProcessOutput(status: 1)
        #expect(e.off() == .turnedOff)
        let c = r.calls
        #expect(c.contains("\(defaults) write com.apple.dock wvous-bl-corner -int 2"))
        #expect(c.contains("/usr/bin/killall Dock"))
        #expect(c.contains("\(defaults) write -g com.apple.keyboard.fnState -bool true"))
        #expect(c.contains("/usr/bin/open -g /Applications/Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app"))
        #expect(c.contains("/usr/bin/open -g -b com.Ebullioscopic.Atoll"))
        #expect(!mem.state.active)
    }

    @Test func offDoesNotRelaunchProgramsThatAreRunning() {
        let r = GMScriptedRunner()
        let e = engine(r)
        _ = e.on()
        r.calls = []
        _ = e.off()
        #expect(!r.calls.contains { $0.hasPrefix("/usr/bin/open") })
    }

    @Test func fnRestoredToPreviousValueNotAlwaysFalse() {
        let r = GMScriptedRunner()
        let e = engine(r)
        _ = e.on()
        r.calls = []
        _ = e.off()
        #expect(r.calls.contains("\(defaults) write -g com.apple.keyboard.fnState -bool false"))
    }

    @Test func idempotent() {
        let r = GMScriptedRunner()
        let e = engine(r)
        #expect(e.off() == .alreadyOff)
        #expect(r.calls.isEmpty)
        _ = e.on()
        let n = r.calls.count
        #expect(e.on() == .alreadyOn)
        #expect(r.calls.count == n)
    }

    @Test func toggleFlips() {
        let r = GMScriptedRunner()
        let e = engine(r)
        #expect(e.toggle() == .turnedOn)
        #expect(e.isOn)
        #expect(e.toggle() == .turnedOff)
        #expect(!e.isOn)
    }

    @Test func disabledPartsAreSkipped() {
        var s = GameModeSettings()
        s.fnKeys = false
        s.disableCorners = false
        s.agents = []
        s.apps = []
        let r = GMScriptedRunner()
        let e = engine(r, settings: s)
        _ = e.on()
        #expect(r.calls.isEmpty)
        _ = e.off()
        #expect(r.calls.isEmpty)
    }

    @Test func onlySelectedCornersTouched() {
        var s = GameModeSettings()
        s.corners = ["tl", "br"]
        let r = GMScriptedRunner()
        _ = engine(r, settings: s).on()
        #expect(r.calls.contains("\(defaults) write com.apple.dock wvous-tl-corner -int 1"))
        #expect(!r.calls.contains { $0.contains("wvous-tr-") })
    }

    @Test func notificationsCanBeSilenced() {
        var s = GameModeSettings()
        s.notify = false
        let notes = NoteBox()
        let e = engine(GMScriptedRunner(), settings: s, notes: notes)
        _ = e.on()
        _ = e.off()
        #expect(notes.items.isEmpty)
    }

    @Test func stateSurvivesRestartOfEngine() {
        let mem = GMMemoryState()
        _ = engine(GMScriptedRunner(), mem).on()
        let r2 = GMScriptedRunner()
        let e2 = engine(r2, mem)
        #expect(e2.isOn)
        #expect(e2.off() == .turnedOff)
    }
}

@Suite struct GameModeSettingsTests {
    @Test func defaultsMatchOldScript() {
        let s = GameModeSettings()
        #expect(s.corners == ["tl", "tr", "bl", "br"])
        #expect(s.agents == [.mouseFix])
        #expect(s.apps == [.atoll])
        #expect(s.fnKeys && s.disableCorners)
    }

    @Test func dangerousValuesAreDropped() {
        var s = GameModeSettings()
        s.apps = [GameModeApp(name: "X", bundleID: "com.x\" & (do shell script \"rm\")"), GameModeApp(name: "", bundleID: "com.ok"), GameModeApp(name: "Ok", bundleID: "com.ok")]
        s.agents = [GameModeAgent(launchLabel: "a b", processPattern: "x", relaunchPath: "/x"),
                    GameModeAgent(launchLabel: "ok.label", processPattern: "  ", relaunchPath: "/x"),
                    GameModeAgent(launchLabel: "ok.label", processPattern: "P", relaunchPath: "relative"),
                    GameModeAgent(launchLabel: "ok.label", processPattern: "P", relaunchPath: "/x")]
        let c = s.sanitized
        #expect(c.apps == [GameModeApp(name: "Ok", bundleID: "com.ok")])
        #expect(c.agents.count == 1)
    }

    @Test func emptyPatternNeverReachesPkill() {
        var s = GameModeSettings()
        s.agents = [GameModeAgent(launchLabel: "x.y", processPattern: "", relaunchPath: "/x")]
        s.apps = []
        let r = GMScriptedRunner()
        _ = engine(r, settings: s).on()
        #expect(!r.calls.contains { $0.hasPrefix("/usr/bin/pkill") })
    }

    @Test func storeRoundtripAndPartialJson() {
        let suite = "multitul-gm-\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let store = GameModeSettingsStore(defaults: d)
        #expect(store.load() == GameModeSettings())
        var s = GameModeSettings()
        s.apps.append(GameModeApp(name: "Notion", bundleID: "notion.id"))
        s.corners = ["tl"]
        s.fnKeys = false
        store.save(s)
        #expect(store.load() == s)
        d.set(Data(#"{"notify":false}"#.utf8), forKey: "gameMode.settings")
        let partial = store.load()
        #expect(!partial.notify && partial.fnKeys && partial.apps == [.atoll])
        store.save(GameModeSettings())
        #expect(d.data(forKey: "gameMode.settings") == nil)
    }

    @Test func fileStateRoundtrip() {
        let dir = "/private/tmp/claude-501/multitul-gm-\(UUID().uuidString)"
        let f = GameModeFileState(path: dir + "/state.json")
        #expect(!f.load().active)
        var st = GameModeState()
        st.active = true
        st.fnBefore = true
        st.corners["tl"] = GameModeCorner(action: 4, modifier: 0)
        st.apps = [.atoll]
        f.save(st)
        #expect(f.load() == st)
    }

    @Test func legacyFlagDetection() {
        let home = "/private/tmp/claude-501/multitul-gm-home-\(UUID().uuidString)"
        let dir = home + "/Library/Application Support/gamemode"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(!GameModeLegacy.isActive(home: home))
        FileManager.default.createFile(atPath: dir + "/active", contents: Data())
        #expect(GameModeLegacy.isActive(home: home))
    }
}

@Suite struct GameModeCLITests {
    private func run(_ args: [String], _ e: GameModeEngine) -> (Int32, [String], [String]) {
        var out: [String] = [], err: [String] = []
        let code = GameModeCLI.run(arguments: args, engine: e, out: { out.append($0) }, err: { err.append($0) })
        return (code, out, err)
    }

    @Test func statusOnOffToggle() {
        let e = engine(GMScriptedRunner())
        #expect(run(["x", "--gamemode", "status"], e).1 == ["off"])
        #expect(run(["x", "--gamemode", "on"], e).1 == ["on"])
        #expect(run(["x", "--gamemode", "on"], e).1 == ["already on"])
        #expect(run(["x", "--gamemode", "status"], e).1 == ["on"])
        #expect(run(["x", "--gamemode", "toggle"], e).1 == ["off"])
        #expect(run(["x", "--gamemode"], e).1 == ["on"])
    }

    @Test func unknownWordIsUsageError() {
        let r = GMScriptedRunner()
        let (code, out, err) = run(["x", "--gamemode", "reboot"], engine(r))
        #expect(code == 2 && out.isEmpty && err.count == 1)
        #expect(r.calls.isEmpty)
        #expect(GameModeCLI.handles(["a", "--gamemode"]) && !GameModeCLI.handles(["a", "--monitor"]))
    }
}
