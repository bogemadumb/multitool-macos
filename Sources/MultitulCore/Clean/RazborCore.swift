import Foundation

public enum Reco: String, Codable, Sendable { case keep, can, check }

public enum RemoteState: String, Codable, Sendable { case none, copy, noCopy, unreachable }

public struct HeavyEntry: Codable, Sendable, Equatable {
    public var name: String
    public var bytes: Int64
}

public struct AnalysisItem: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var path = ""
    public var paths: [String] = []
    public var bytes: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var files = 0
    public var ageDays = 0
    public var reco = Reco.keep
    public var reason = ""
    public var inUseBy: [String] = []
    public var symlinks: [String] = []
    public var heavy: [HeavyEntry] = []
    public var composition: [String: Int64] = [:]
    public var remote = RemoteState.none
    public var remoteNote = ""
    public var note = ""
    public var children: [AnalysisItem] = []

    public init(id: String, kind: String, title: String, path: String = "", paths: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.paths = paths
    }

    public var selectable: Bool { reco != .keep }
    public var inUse: Bool { !inUseBy.isEmpty }
}

public struct AnalysisResult: Codable, Sendable {
    public var stamp = 0.0
    public var seconds = 0.0
    public var roots: [String] = []
    public var orphans: [AnalysisItem] = []
    public var folders: [AnalysisItem] = []
    public var envs: [AnalysisItem] = []
    public var models: [AnalysisItem] = []
    public var uv: AnalysisItem?
    public var notes: [String] = []
    public var remoteChecked = false
    public var cancelled = false

    public var allItems: [AnalysisItem] {
        var out = orphans
        for f in folders { out.append(f); out += f.children }
        out += envs
        out += models
        if let uv { out.append(uv) }
        return out
    }
}

public protocol RemoteChecking: Sendable {
    // Raw result of the remote `find ... du` run; status 255/15/-1 mean "unreachable". Never called from tests against a real host.
    func find(name: String) -> (status: Int32, out: String)?
}

public struct SshRemoteChecker: RemoteChecking {
    let exec: CleanExec
    let allowed: Bool
    public init(exec: @escaping CleanExec, allowed: Bool) {
        self.exec = exec
        self.allowed = allowed
    }

    public func find(name: String) -> (status: Int32, out: String)? {
        guard allowed else { return nil }
        return exec("/usr/bin/ssh", remoteArgs(name: name), 30)
    }
}

public struct AnalysisEnv: Sendable {
    public var clean: CleanEnv
    public var roots = ["Documents/Scratch"]
    public var envRoots = ["Documents", "Code"]
    public var appsDirs = ["/Applications"]
    public var stateDir: String
    public var checkRemote = true
    public var remote: RemoteChecking
    public var cwdBlob = ""
    public var envMaxAgeDays = 14
    public var cancelled: @Sendable () -> Bool = { false }
    public var progress: @Sendable (Double, String) -> Void = { _, _ in }

    public init(clean: CleanEnv, stateDir: String = MultitulPaths.home) {
        self.clean = clean
        self.stateDir = stateDir
        self.remote = SshRemoteChecker(exec: clean.exec, allowed: clean.allowExec)
    }

    public var home: String { clean.home }
    public var now: Date { clean.now }
    public var rootsAbs: [String] { roots.map { home + "/" + $0 } }

    func run(_ path: String, _ args: [String], timeout: Double) -> (status: Int32, out: String)? {
        guard clean.allowExec else { return nil }
        return clean.exec(path, args, timeout)
    }

    public static let rootsKey = "razbor.roots"

    public static func configuredRoots(_ d: KeyValueStoring = UserDefaults.standard) -> [String] {
        let v = d.stringArray(forKey: rootsKey) ?? []
        return v.isEmpty ? ["Documents/Scratch"] : v
    }

    public static func live(home: String = NSHomeDirectory(), roots: [String]? = nil, clean: CleanEnv? = nil, stateDir: String? = nil) -> AnalysisEnv {
        let c = clean ?? CleanEnv.live(home: home)
        var e = AnalysisEnv(clean: c, stateDir: stateDir ?? MultitulPaths.home)
        e.roots = roots ?? (home == NSHomeDirectory() ? configuredRoots() : e.roots)
        if c.allowExec { e.cwdBlob = readCwdBlob() }
        return e
    }
}

func readCwdBlob() -> String {
    let out = runCleanTool("/usr/sbin/lsof", ["-nP", "-a", "-d", "cwd", "-Fn"], timeout: 15).out
    return out.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }.joined(separator: "\n")
}

// MARK: file info

struct FileInfo {
    var mode: mode_t
    var blocks: Int64
    var size: Int64
    var mtime: Double
    var atime: Double
    var dev: Int32
    var ino: UInt64
    var nlink: Int
    var isDir: Bool { (mode & S_IFMT) == S_IFDIR }
    var isLink: Bool { (mode & S_IFMT) == S_IFLNK }
    var alloc: Int64 { blocks * 512 }
}

private func tsec(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }

private func info(_ st: stat) -> FileInfo {
    FileInfo(mode: st.st_mode, blocks: Int64(st.st_blocks), size: Int64(st.st_size), mtime: tsec(st.st_mtimespec),
             atime: tsec(st.st_atimespec), dev: st.st_dev, ino: st.st_ino, nlink: Int(st.st_nlink))
}

func lstatInfo(_ p: String) -> FileInfo? {
    var st = stat()
    return lstat(p, &st) == 0 ? info(st) : nil
}

func statInfo(_ p: String) -> FileInfo? {
    var st = stat()
    return stat(p, &st) == 0 ? info(st) : nil
}

// MARK: in-use index

public struct InUseSource: Sendable {
    public var name: String
    public var text: String
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

func containsPath(_ text: String, _ p: String) -> Bool {
    guard !p.isEmpty else { return false }
    var from = text.startIndex
    while let r = text.range(of: p, range: from..<text.endIndex) {
        if r.upperBound == text.endIndex { return true }
        let c = text[r.upperBound]
        if !(c.isLetter || c.isNumber || c == "_" || c == "-") { return true }
        from = r.upperBound
    }
    return false
}

public struct InUseIndex: Sendable {
    public var sources: [InUseSource] = []
    public init(sources: [InUseSource] = []) { self.sources = sources }

    public func users(of path: String) -> [String] {
        let np = norm(path)
        var out: [String] = []
        for s in sources where containsPath(s.text, np) && !out.contains(s.name) { out.append(s.name) }
        return out
    }

    private static let scriptExt: Set<String> = ["sh", "py", "js", "mjs", "zsh", "bash", "rb", "pl", "command", "ts"]

    public static func build(_ env: AnalysisEnv) -> InUseIndex {
        var idx = InUseIndex()
        let dir = env.home + "/Library/LaunchAgents"
        for n in childNames(dir) where n.hasSuffix(".plist") {
            let p = dir + "/" + n
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            let label = String(n.dropLast(6))
            var text = String(decoding: data, as: UTF8.self)
            let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            if data.starts(with: Array("bplist".utf8)), let obj,
               let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                text = String(decoding: xml, as: UTF8.self)
            }
            if let d = obj as? [String: Any] {
                var args = d["ProgramArguments"] as? [String] ?? []
                if let prog = d["Program"] as? String { args.append(prog) }
                for a in args where a.hasPrefix("/") {
                    let ext = (a as NSString).pathExtension.lowercased()
                    guard ext.isEmpty || scriptExt.contains(ext), let fi = statInfo(a), !fi.isDir, fi.size > 0, fi.size < 512_000,
                          let sd = FileManager.default.contents(atPath: a), !sd.contains(0) else { continue }
                    text += "\n" + String(decoding: sd, as: UTF8.self)
                }
            }
            idx.sources.append(InUseSource(name: label, text: norm(text)))
        }
        if !env.clean.processBlob.isEmpty { idx.sources.append(InUseSource(name: "ps", text: norm(env.clean.processBlob))) }
        if !env.cwdBlob.isEmpty { idx.sources.append(InUseSource(name: "cwd", text: norm(env.cwdBlob))) }
        if let cr = env.run("/usr/bin/crontab", ["-l"], timeout: 5), cr.status == 0, !cr.out.isEmpty {
            idx.sources.append(InUseSource(name: "cron", text: norm(cr.out)))
        }
        return idx
    }
}

// MARK: tree walk

struct SpecialDir: Sendable {
    var path: String
    var kind: String
    var bytes: Int64
}

let regenKinds: Set<String> = ["venv", "nodemodules", "pycache"]

let dumpMinBytes: Int64 = 100_000

func fileBucket(_ name: String, size: Int64 = .max) -> String? {
    let l = name.lowercased()
    if l.hasSuffix(".dump") || l.hasSuffix(".sql") || l.hasSuffix(".dump.enc") || l.hasSuffix(".bak") { return size >= dumpMinBytes ? "dumps" : nil }
    switch (l as NSString).pathExtension {
    case "mp4", "mov", "webm", "mkv", "m4v", "avi": return "video"
    case "png", "jpg", "jpeg", "gif", "webp", "heic": return "images"
    case "zip", "gz", "tgz", "7z", "tar", "rar", "xz", "bz2": return "archives"
    case "safetensors", "bin", "gguf", "onnx", "pt", "pth", "ckpt": return "models"
    default: return nil
    }
}

final class TreeWalker {
    var bytes: Int64 = 0
    var logical: Int64 = 0
    var files = 0
    var newest = 0.0
    var newestOutside = 0.0
    var newestAccess = 0.0
    var buckets: [String: Int64] = [:]
    var specials: [SpecialDir] = []
    var links: [(path: String, target: String)] = []
    var dumps: [String] = []
    var childBytes: [String: Int64] = [:]
    var stopped = false
    private var seen = Set<UInt64>()
    private var rootDev: Int32 = 0
    private let cancel: @Sendable () -> Bool

    init(cancel: @escaping @Sendable () -> Bool = { false }) { self.cancel = cancel }

    func run(_ root: String) {
        guard let st = lstatInfo(root), st.isDir else { return }
        rootDev = st.dev
        bytes += st.alloc
        walkDir(root, bucket: nil, top: nil)
    }

    private func specialKind(_ dir: String, _ names: [String]) -> String? {
        if names.contains("pyvenv.cfg") { return "venv" }
        let base = (dir as NSString).lastPathComponent
        if base == "node_modules" { return "nodemodules" }
        if base == "__pycache__" { return "pycache" }
        if names.contains("RunningChromeVersion") || (names.contains("Default") && exists(dir + "/Default/Preferences")) { return "browser" }
        return nil
    }

    private func walkDir(_ dir: String, bucket inherited: String?, top: String?) {
        if stopped { return }
        if cancel() { stopped = true; return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        var bucket = inherited
        var kind: String?
        let start = bytes
        if bucket == nil, let k = specialKind(dir, names) { kind = k; bucket = k }
        for n in names {
            if stopped { return }
            let p = dir + "/" + n
            guard let st = lstatInfo(p) else { continue }
            let t = top ?? n
            if st.isLink {
                bytes += st.alloc
                childBytes[t, default: 0] += st.alloc
                if bucket == nil, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p) { links.append((p, dest)) }
                continue
            }
            if st.isDir {
                if st.dev != rootDev { continue }
                bytes += st.alloc
                childBytes[t, default: 0] += st.alloc
                walkDir(p, bucket: bucket, top: t)
                continue
            }
            var counted = true
            if st.nlink > 1 { counted = seen.insert(st.ino).inserted }
            if counted {
                bytes += st.alloc
                childBytes[t, default: 0] += st.alloc
            }
            logical += st.size
            files += 1
            newest = max(newest, st.mtime)
            newestAccess = max(newestAccess, st.atime, st.mtime)
            if bucket == nil {
                newestOutside = max(newestOutside, st.mtime)
                if let b = fileBucket(n, size: st.size) {
                    if counted { buckets[b, default: 0] += st.alloc }
                    if b == "dumps" && dumps.count < 5 { dumps.append(n) }
                }
            }
        }
        if let k = kind {
            let size = bytes - start
            buckets[k, default: 0] += size
            if regenKinds.contains(k) { specials.append(SpecialDir(path: dir, kind: k, bytes: size)) }
        }
    }
}

// MARK: recommendation

public struct RecoInput {
    var name: String
    var inUse: Bool
    var hasDumps: Bool
    var ageDays: Int
    var bytes: Int64
    var buckets: [String: Int64]
}

public func recommend(_ r: RecoInput) -> (Reco, String) {
    if r.inUse { return (.keep, "работает, не трогать") }
    if r.hasDumps { return (.keep, "есть дампы или бэкапы") }
    let l = r.name.lowercased()
    if l.contains("kontakt") || l.contains("contact") || l.contains("контакт") { return (.keep, "контакты") }
    if r.ageDays < 2 { return (.keep, "свежее, трогали меньше 2 дней назад") }
    let regen = (r.buckets["venv"] ?? 0) + (r.buckets["nodemodules"] ?? 0) + (r.buckets["pycache"] ?? 0)
    if r.bytes > 0 && Double(regen) >= Double(r.bytes) * 0.9 { return (.can, "почти всё пересоздаётся") }
    let video = r.buckets["video"] ?? 0
    if video * 2 >= r.bytes && video > 0 || video >= 200_000_000 || l.contains("render") { return (.check, "видео и рендеры, проверь") }
    if r.ageDays >= 21 { return (.check, "не трогали \(r.ageDays) дн.") }
    return (.keep, "недавнее, \(r.ageDays) дн.")
}

// MARK: analysis-specific denylist

let analysisAllowedPrefixes = [".colima/_lima/_disks/", ".lima/_disks/", "library/containers/com.docker.docker/data/vms/",
                               "library/containers/com.utmapp.utm/data/documents/", ".cache/huggingface/hub/models--"]

func isEnvDir(_ p: String) -> Bool {
    let base = (p as NSString).lastPathComponent
    return base == "node_modules" || base == "__pycache__" || exists(p + "/pyvenv.cfg")
}

func deniedAnalysisCanonical(_ p: String, home h: String, roots: [String]) -> Bool {
    guard p.hasPrefix(h + "/") else { return true }
    let rel = norm(String(p.dropFirst(h.count + 1)))
    if !rel.contains("/") { return true }
    if protectedRoots.contains(rel) { return true }
    for d in neverPrefixes where rel == d || rel.hasPrefix(d + "/") { return true }
    for r in roots {
        let c = canonicalPath(r)
        guard c.hasPrefix(h + "/") else { continue }
        if rel.hasPrefix(norm(String(c.dropFirst(h.count + 1))) + "/") { return false }
    }
    for pre in analysisAllowedPrefixes where rel.hasPrefix(pre) { return false }
    let parts = rel.split(separator: "/")
    if parts.count >= 3, parts[0] == "documents" || parts[0] == "code", isEnvDir(p) { return false }
    return true
}

public func isDeniedAnalysis(_ path: String, home: String, roots: [String]) -> Bool {
    let h = canonicalPath(home)
    let lexical = URL(fileURLWithPath: path).standardized.path
    let lexHome = URL(fileURLWithPath: home).standardized.path
    var lex = lexical
    if lex.hasPrefix(lexHome + "/") { lex = h + String(lex.dropFirst(lexHome.count)) }
    return deniedAnalysisCanonical(lex, home: h, roots: roots) || deniedAnalysisCanonical(canonicalPath(path), home: h, roots: roots)
}

func relToHome(_ p: String, _ home: String) -> String {
    p.hasPrefix(home + "/") ? String(p.dropFirst(home.count + 1)) : p
}
