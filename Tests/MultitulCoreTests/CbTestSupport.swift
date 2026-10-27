import Foundation
import CoreGraphics
@testable import MultitulCore

final class CbFakeApps: CbAppSource {
    var list: [CbAppInfo]
    init(_ l: [CbAppInfo] = []) { list = l }
    func apps() -> [CbAppInfo] { list }
}

final class CbFakeWindows: CbWindowSource {
    var list: [SwitchEntry] = []
    func windows() -> [SwitchEntry] { list }
}

final class CbFakeClip: CbClipSource {
    var items: [ClipItem] = []
    var searches: [String] = []
    func recent(limit: Int) -> [ClipItem] { Array(items.prefix(limit)) }
    func search(_ text: String, limit: Int) -> [ClipItem] {
        searches.append(text)
        return Array(items.filter { $0.title.lowercased().contains(text.lowercased()) }.prefix(limit))
    }
}

final class CbFakeFiles: CbFileSearching {
    var calls: [(text: String, folders: [String], limit: Int)] = []
    var cancelled = 0
    private var deliver: ((String, [CbFileHit]) -> Void)?

    func search(_ text: String, folders: [String], limit: Int, deliver: @escaping (String, [CbFileHit]) -> Void) {
        calls.append((text, folders, limit))
        self.deliver = deliver
    }

    func cancel() { cancelled += 1 }

    func answer(_ hits: [CbFileHit]) { deliver?(calls.last?.text ?? "", hits) }
}

final class CbFakeMenu: CbMenuSource {
    var snap: CbMenuSnapshot?
    func snapshot() -> CbMenuSnapshot? { snap }
}

final class CbFakeSnippets: CbSnippetSource {
    var list: [Snippet] = []
    var used: [Int64] = []
    func snippets() -> [Snippet] { list }
    func markUsed(id: Int64) { used.append(id) }
}

final class CbFakeProcs: CbProcessSource {
    var list: [CatalogProcess] = []
    func processes() -> [CatalogProcess] { list }
}

final class CbFakeScripts: CbScriptSource {
    var files: [String] = []
    var asked: [String] = []
    func scripts(in folder: String) -> [String] { asked.append(folder); return files }
}

final class CbFakeLauncherItems: CbLauncherSource {
    var list: [LauncherItem] = []
    func items() -> [LauncherItem] { list }
}

final class CbFakeFS: LauncherFileChecking {
    var files: Set<String> = []
    var executables: Set<String> = []
    var bundles: [String: String] = [:]
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func appPath(forBundleID id: String) -> String? { bundles[id] }
}

final class CbFakeExec: LauncherExecuting {
    var commands: [LauncherCommand] = []
    var result = LauncherExecResult.ok
    func execute(_ command: LauncherCommand) -> LauncherExecResult { commands.append(command); return result }
}

final class CbFakeHost: CbHost {
    var log: [String] = []
    var focusOK = true
    var openOK = true
    var pasteClipOK = true
    var menuOK = true
    var systemOK = true
    var terminateError: String?
    var uninstallOK = true
    var shelfOK = true
    var pasteTextOK = true
    var clipboard: String? = "clip"

    func focusWindow(key: Int, pid: Int32) -> Bool { log.append("focus \(pid):\(key)"); return focusOK }
    func open(path: String) -> Bool { log.append("open \(path)"); return openOK }
    func reveal(path: String) { log.append("reveal \(path)") }
    func paste(clipID: Int64, copyOnly: Bool) -> Bool { log.append("clip \(clipID) copyOnly=\(copyOnly)"); return pasteClipOK }
    func copy(_ text: String) { log.append("copy \(text)") }
    func paste(_ text: String) -> Bool { log.append("paste \(text)"); return pasteTextOK }
    func pressMenu(pid: Int32, path: [String]) -> Bool { log.append("menu \(pid) \(path.joined(separator: "/"))"); return menuOK }
    func run(_ command: CbSystemCommand) -> Bool { log.append("system \(command.rawValue)"); return systemOK }
    func terminate(pid: Int32, name: String, tree: Bool) -> String? { log.append("terminate \(pid) \(name) tree=\(tree)"); return terminateError }
    func quit(pid: Int32) { log.append("quit \(pid)") }
    func uninstall(appPath: String) -> Bool { log.append("uninstall \(appPath)"); return uninstallOK }
    func openSection(_ id: String) { log.append("section \(id)") }
    func refreshRates() { log.append("rates") }
    func shelfAdd(path: String) -> Bool { log.append("shelf \(path)"); return shelfOK }
    func clipboardText() -> String? { clipboard }
}

enum CbFix {
    static func app(_ name: String, bundle: String = "", running: Bool = false, pid: Int32 = 0, dir: String = "/Applications") -> CbAppInfo {
        CbAppInfo(name: name, path: "\(dir)/\(name).app", bundleID: bundle.isEmpty ? "com.test.\(name.replacingOccurrences(of: " ", with: ""))" : bundle, isRunning: running, pid: pid)
    }

    static func window(_ key: Int, app: String, title: String, pid: Int32 = 10, minimized: Bool = false) -> SwitchEntry {
        SwitchEntry(window: SwitchWindow(key: key, windowID: UInt32(key + 100), pid: pid, bundleID: "com.test.\(app)", appName: app, title: title, isMinimized: minimized))
    }

    static func clip(_ id: Int64, _ title: String, kind: ClipKind = .text, pinned: Bool = false, source: String? = nil, age: TimeInterval = 120) -> ClipItem {
        ClipItem(id: id, kind: kind, hash: "h\(id)", title: title, created: Date(timeIntervalSince1970: 1_000_000 - age), used: Date(timeIntervalSince1970: 1_000_000 - age), pinned: pinned, sourceName: source)
    }

    static func proc(_ pid: Int32, _ name: String, ppid: Int32 = 1, uid: UInt32 = 501, rssMB: Int64 = 100, path: String? = nil) -> CatalogProcess {
        CatalogProcess(pid: pid, ppid: ppid, uid: uid, cpu: 1, rssBytes: rssMB * 1_048_576, name: name, path: path ?? "/usr/bin/\(name)")
    }

    static let now = Date(timeIntervalSince1970: 1_000_000)
}

struct CbRig {
    var settings: CommandBarSettings
    var enabled: Set<ModuleID>
    var rates: CurrencyRateTable?
    let apps = CbFakeApps()
    let windows = CbFakeWindows()
    let clip = CbFakeClip()
    let files = CbFakeFiles()
    let menu = CbFakeMenu()
    let snippets = CbFakeSnippets()
    let procs = CbFakeProcs()
    let scripts = CbFakeScripts()
    let launcher = CbFakeLauncherItems()
    let frecencyStore = MemoryFrecencyStore()
    let clock = WndBox(CbFix.now)

    init(settings: CommandBarSettings = CommandBarSettings(), enabled: Set<ModuleID> = [.quickToggles, .scratchpad, .colorPicker, .killProcess, .uninstaller, .shelf]) {
        self.settings = settings
        self.enabled = enabled
    }
}

final class CbWorld {
    var rig: CbRig
    let box: WndBox<CommandBarSettings>
    let ctx: CbContext
    let filesProvider: CbFilesProvider
    let frecency: FrecencyIndex
    let engine: CbEngine

    init(_ rig: CbRig = CbRig()) {
        self.rig = rig
        box = WndBox(rig.settings)
        let b = box
        let enabled = rig.enabled
        let rates = rig.rates
        ctx = CbContext(settings: { b.value }, isModuleEnabled: { enabled.contains($0) }, rates: { rates }, now: { CbFix.now })
        filesProvider = CbFilesProvider(source: rig.files, ctx: ctx)
        let clockBox = rig.clock
        frecency = FrecencyIndex(store: rig.frecencyStore) { clockBox.value }
        let providers: [CbProvider] = [
            CbCalculatorProvider(ctx: ctx), CbUnitsProvider(ctx: ctx), CbAppsProvider(source: rig.apps, ctx: ctx), CbEntriesProvider(ctx: ctx, launcher: rig.launcher),
            CbCommandsProvider(ctx: ctx), CbWindowsProvider(source: rig.windows), CbQuicklinksProvider(ctx: ctx), CbScriptsProvider(source: rig.scripts, ctx: ctx),
            CbSnippetsProvider(source: rig.snippets), CbMenuProvider(source: rig.menu), filesProvider, CbClipboardProvider(source: rig.clip, ctx: ctx),
            CbEmojiProvider(ctx: ctx), CbProcessesProvider(source: rig.procs, ctx: ctx), CbUninstallProvider(source: rig.apps, ctx: ctx), CbWebProvider(ctx: ctx)
        ]
        engine = CbEngine(providers: providers, frecency: frecency) { b.value }
    }

    func search(_ q: String) -> [CbResult] { engine.search(q).results }
    func titles(_ q: String) -> [String] { search(q).map(\.title) }
}
