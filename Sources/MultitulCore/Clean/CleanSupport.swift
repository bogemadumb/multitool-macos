import Foundation
import AppKit
import CoreServices

public struct RunningApp: Sendable, Equatable {
    public var bundleId: String
    public var name: String
    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

public typealias CleanExec = @Sendable (String, [String], Double) -> (status: Int32, out: String)

// Everything a scan or a clean touches from the outside world goes through this struct, so tests run on a fixture home.
public struct CleanEnv: Sendable {
    public var home: String
    public var now = Date()
    public var running: [RunningApp] = []
    public var toolDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    public var processBlob = ""
    public var allowExec = true
    public var exec: CleanExec = { runCleanTool($0, $1, timeout: $2) }
    // Moves a path to the Trash and returns where it landed, nil on failure.
    public var trasher: @Sendable (String) -> String? = { p in
        var out: NSURL?
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out) } catch { return nil }
        return out?.path
    }
    // Permanent removal of something that already sits in the Trash.
    public var purger: @Sendable (String) -> Bool = { p in (try? FileManager.default.removeItem(atPath: p)) != nil }
    public var finderEmptyTrash: @Sendable () -> Bool = {
        runCleanTool("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 120).status == 0
    }
    public var launchctlList: @Sendable () -> String = { runCleanTool("/bin/launchctl", ["list"], timeout: 10).out }
    public var settle = 3.0
    public var sleeper: @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    public var appDirs: [String]
    public var screenshotDirs: [String]
    public var screenshotDays = 30
    public var iosBackupDays = 90
    public var leftoverMinAgeDays = 7
    public var whatsapp = WhatsAppRules()
    // Last time the user opened a file (Spotlight kMDItemLastUsedDate); nil when unknown.
    public var lastOpened: @Sendable (String) -> Date? = { p in
        guard let item = MDItemCreate(kCFAllocatorDefault, p as CFString),
              let v = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { return nil }
        return v
    }

    public init(home: String) {
        self.home = home
        self.appDirs = ["/Applications", "/Applications/Utilities", home + "/Applications", "/System/Applications", "/System/Applications/Utilities"]
        self.screenshotDirs = [home + "/Desktop"]
    }

    public func path(_ rel: String) -> String { home + "/" + rel }

    public func findTool(_ name: String) -> String? {
        toolDirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func appRunning(_ key: String) -> Bool {
        let k = key.lowercased()
        return running.contains { $0.bundleId.lowercased().contains(k) || $0.name.lowercased() == k }
    }

    public func cacheOwnerRunning(_ folder: String) -> Bool {
        let f = folder.lowercased()
        return running.contains { a in
            let b = a.bundleId.lowercased()
            return b == f || (f.count >= 4 && (b.contains(f) || f.contains(b)))
                || (!a.name.isEmpty && a.name.lowercased() == f)
        }
    }

    public var trashDir: String { home + "/.Trash" }

    public static func live(home: String = NSHomeDirectory()) -> CleanEnv {
        var e = CleanEnv(home: home)
        e.running = NSWorkspace.shared.runningApplications.compactMap { a in
            guard let b = a.bundleIdentifier else { return nil }
            return RunningApp(bundleId: b, name: a.localizedName ?? "")
        }
        e.processBlob = ToolRunner.run("/bin/ps", ["-axww", "-o", "args="])
        e.allowExec = home == NSHomeDirectory()
        if home == NSHomeDirectory(), let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            e.screenshotDirs = [(loc as NSString).expandingTildeInPath]
        }
        return e
    }
}

public func runCleanTool(_ path: String, _ args: [String], timeout: Double) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LC_ALL": "en_US.UTF-8"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { if p.isRunning { p.terminate() } }
    timer.resume()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    public init(_ v: T) { self.v = v }
    public var value: T { lock.lock(); defer { lock.unlock() }; return v }
    public func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

// MARK: denylist

func canonicalPath(_ p: String) -> String {
    let std = URL(fileURLWithPath: p).standardized.path
    var head = std
    var tail: [String] = []
    while head != "/" && !head.isEmpty {
        if let r = realpath(head, nil) {
            defer { free(r) }
            let base = String(cString: r)
            return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
        }
        tail.append((head as NSString).lastPathComponent)
        head = (head as NSString).deletingLastPathComponent
    }
    return std
}

func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

// Paths under these prefixes are never removed by any cleaning tool (uv: uvx environments link into archive-v0).
let neverPrefixes = [".cache/uv", "Documents/Система", ".claude", "Library/Mail", ".ssh", "Library/Keychains",
                     "Library/Mobile Documents", ".local/bin"].map(norm)
let protectedRoots = ["Library", "Library/Caches", "Library/Logs", "Library/Application Support",
                      "Library/Group Containers", "Library/Containers", "Library/Preferences", "Library/LaunchAgents",
                      ".cache", ".cache/huggingface", ".cache/huggingface/hub",
                      ".local", ".local/share", ".local/bin", ".local/share/claude", ".local/share/claude/versions",
                      ".Trash", "Downloads", "Documents", "Documents/Scratch", "Desktop",
                      "Library/Caches/ms-playwright", "Library/Developer", "Library/Developer/Xcode"].map(norm)

func isDeniedCanonical(_ p: String, home h: String) -> Bool {
    guard p.hasPrefix(h + "/") else { return true }
    let rel = norm(String(p.dropFirst(h.count + 1)))
    if !rel.contains("/") { return true }
    if protectedRoots.contains(rel) { return true }
    for d in neverPrefixes where rel == d || rel.hasPrefix(d + "/") { return true }
    if rel.hasPrefix("documents/") {
        let parts = rel.split(separator: "/")
        if parts.count >= 3 && parts[1] == "scratch" { return false }
        return true
    }
    return false
}

public func isDeniedPath(_ path: String, home: String) -> Bool {
    let h = canonicalPath(home)
    let lexical = URL(fileURLWithPath: path).standardized.path
    let lexHome = URL(fileURLWithPath: home).standardized.path
    var lex = lexical
    if lex.hasPrefix(lexHome + "/") { lex = h + String(lex.dropFirst(lexHome.count)) }
    return isDeniedCanonical(lex, home: h) || isDeniedCanonical(canonicalPath(path), home: h)
}

// MARK: sizes and files

public struct TreeStat: Sendable {
    public var bytes: Int64 = 0
    public var newestFile = Date.distantPast
    public var newestAccess = Date.distantPast
    public var files = 0
}

public func scanTree(_ path: String) -> TreeStat {
    var st = TreeStat()
    let fm = FileManager.default
    let root = URL(fileURLWithPath: path)
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
                                  .contentModificationDateKey, .contentAccessDateKey, .volumeIdentifierKey, .linkCountKey, .fileResourceIdentifierKey]
    guard let rv = try? root.resourceValues(forKeys: Set(keys)) else { return st }
    if rv.isSymbolicLink == true {
        st.bytes = Int64(rv.fileAllocatedSize ?? 0)
        st.newestFile = rv.contentModificationDate ?? .distantPast
        return st
    }
    guard rv.isDirectory == true else {
        st.bytes = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
        st.newestFile = rv.contentModificationDate ?? .distantPast
        st.newestAccess = max(rv.contentAccessDate ?? .distantPast, st.newestFile)
        st.files = 1
        return st
    }
    let rootVol = rv.volumeIdentifier as? NSObject
    st.newestFile = rv.contentModificationDate ?? .distantPast
    var sawFile = false
    var seenLinks = Set<AnyHashable>()
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return st }
    for case let url as URL in en {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isSymbolicLink == true {
            st.bytes += Int64(v.fileAllocatedSize ?? 0)
            continue
        }
        if v.isDirectory == true {
            if let rootVol, let vol = v.volumeIdentifier as? NSObject, !vol.isEqual(rootVol) { en.skipDescendants(); continue }
            st.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            continue
        }
        var counted = true
        if (v.linkCount ?? 1) > 1, let rid = v.fileResourceIdentifier as? AnyHashable { counted = seenLinks.insert(rid).inserted }
        if counted { st.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        st.files += 1
        let m = v.contentModificationDate ?? .distantPast
        if !sawFile || m > st.newestFile { st.newestFile = m; sawFile = true }
        st.newestAccess = max(st.newestAccess, v.contentAccessDate ?? .distantPast, m)
    }
    return st
}

func childNames(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
}

func exists(_ p: String) -> Bool {
    var st = stat()
    return lstat(p, &st) == 0
}

func isRealDir(_ p: String) -> Bool {
    var st = stat()
    return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

func days(_ from: Date, _ to: Date) -> Int { max(Int(to.timeIntervalSince(from) / 86400), 0) }

public func fmtBytes(_ b: Int64) -> String { SysFormat.bytes(Double(b)) }

func parseDockerSize(_ s: String) -> Int64 {
    let head = s.split(separator: " ").first.map(String.init) ?? s
    let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
    for (u, m) in units where head.hasSuffix(u) {
        if let v = Double(head.dropLast(u.count)) { return Int64(v * m) }
    }
    return 0
}

public func freeSpaceBytes(_ path: String) -> Int64 {
    let a = try? FileManager.default.attributesOfFileSystem(forPath: path)
    return (a?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
}

public func totalSpaceBytes(_ path: String) -> Int64 {
    let a = try? FileManager.default.attributesOfFileSystem(forPath: path)
    return (a?[.systemSize] as? NSNumber)?.int64Value ?? 0
}

// MARK: services guard

public struct ServiceState: Equatable, Sendable {
    public var pid: Int?
    public var status: Int
}

public func parseLaunchctl(_ out: String) -> [String: ServiceState] {
    var m: [String: ServiceState] = [:]
    for line in out.split(separator: "\n") {
        let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard c.count >= 3, c[2].hasPrefix("dev.multitool.") else { continue }
        m[c[2]] = ServiceState(pid: Int(c[0]), status: Int(c[1]) ?? 0)
    }
    return m
}

public func diedServices(before: [String: ServiceState], after: [String: ServiceState]) -> [String] {
    before.filter { $0.value.pid != nil }.keys.sorted().filter { label in
        guard let a = after[label] else { return true }
        return a.pid == nil && a.status != 0
    }
}

// MARK: Trash flow

public struct TrashedItem: Sendable {
    public var src: String
    public var dst: String
    public var id: String
}

public struct TrashMoveResult: Sendable {
    public var moved: [TrashedItem] = []
    public var failed: [String] = []
    public var failedIds = Set<String>()
    public var denied: [String] = []
}

// Moves every path to the Trash. `isDenied` is checked again right before the move.
func moveToTrash(_ items: [(path: String, id: String)], env: CleanEnv, isDenied: (String) -> Bool,
                 progress: (Int, Int, String) -> Void = { _, _, _ in }) -> TrashMoveResult {
    var r = TrashMoveResult()
    for (i, it) in items.enumerated() {
        progress(i, items.count, (it.path as NSString).lastPathComponent)
        if isDenied(it.path) {
            r.denied.append(it.path)
            r.failedIds.insert(it.id)
            continue
        }
        if !exists(it.path) { continue }
        if let dst = env.trasher(it.path) {
            r.moved.append(TrashedItem(src: it.path, dst: dst, id: it.id))
            Log.write("clean trash \(it.path) -> \(dst)")
        } else {
            r.failed.append("\(it.path): не ушло в Корзину")
            r.failedIds.insert(it.id)
        }
    }
    return r
}

public struct ServiceVerdict: Sendable {
    public var died: [String] = []
    public var checked = false
}

// The services listed by launchctl before the move must still run after it. Two looks with a pause between them.
func verifyServices(before: [String: ServiceState], env: CleanEnv) -> ServiceVerdict {
    guard !before.isEmpty else { return ServiceVerdict() }
    var v = ServiceVerdict(died: [], checked: true)
    for _ in 0..<2 {
        if env.settle > 0 { env.sleeper(env.settle) }
        v.died = diedServices(before: before, after: parseLaunchctl(env.launchctlList()))
        if !v.died.isEmpty { break }
    }
    return v
}

// Permanent removal, allowed only for something that really sits inside this home's Trash.
func purgeFromTrash(_ item: TrashedItem, env: CleanEnv) -> String? {
    let trashRoot = canonicalPath(env.trashDir)
    let c = canonicalPath(item.dst)
    guard c.hasPrefix(trashRoot + "/"), c != trashRoot else { return "\(item.dst): не в Корзине, не трогаю" }
    return env.purger(item.dst) ? nil : "\(item.dst): не удалилось из Корзины"
}
