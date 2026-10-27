import Foundation
@testable import MultitulCore

final class MgrRunner: ManagerRunning, @unchecked Sendable {
    struct Rule {
        var match: @Sendable ([String]) -> Bool
        var result: ManagerResult
        var lines: [ManagerLine]
        var hang: Bool
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var log: [ManagerCommand] = []
    var fallback = ManagerResult(status: 1, stderr: "Error: unscripted command")
    var hook: (@Sendable (ManagerCommand) -> Void)?

    var calls: [ManagerCommand] { lock.lock(); defer { lock.unlock() }; return log }
    var argLines: [String] { calls.map { $0.arguments.joined(separator: " ") } }

    func on(_ prefix: String, status: Int32 = 0, out: String = "", lines: [ManagerLine] = [], err: String = "", hang: Bool = false, timedOut: Bool = false) {
        let rule = Rule(match: { $0.joined(separator: " ").hasPrefix(prefix) }, result: ManagerResult(status: status, stdout: out, stderr: err, timedOut: timedOut), lines: lines, hang: hang)
        lock.lock(); rules.insert(rule, at: 0); lock.unlock()
    }

    private func find(_ c: ManagerCommand) -> Rule? {
        lock.lock(); defer { lock.unlock() }
        log.append(c)
        return rules.first { $0.match(c.arguments) }
    }

    func run(_ command: ManagerCommand) async -> ManagerResult {
        await stream(command, onLine: { _ in })
    }

    func stream(_ command: ManagerCommand, onLine: @escaping @Sendable (ManagerLine) -> Void) async -> ManagerResult {
        let rule = find(command)
        hook?(command)
        guard let rule else { return fallback }
        for l in rule.lines {
            if Task.isCancelled { return ManagerResult(status: 130, cancelled: true) }
            onLine(l)
        }
        if rule.hang {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return ManagerResult(status: 130, cancelled: true)
        }
        return rule.result
    }
}

final class MgrFiles: MediaFileOps, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int64] = [:]
    private(set) var moves: [(String, String)] = []
    private(set) var removed: [String] = []
    private(set) var directories: [String] = []
    var failMove = false

    init(_ initial: [String: Int64] = [:]) { paths = initial }

    func put(_ p: String, _ size: Int64 = 1000) { lock.lock(); paths[p] = size; lock.unlock() }
    func exists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return paths[path] != nil }
    func size(_ path: String) -> Int64? { lock.lock(); defer { lock.unlock() }; return paths[path] }
    func move(_ from: String, to: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failMove { throw TlsError() }
        paths[to] = paths[from]
        paths[from] = nil
        moves.append((from, to))
    }
    func remove(_ path: String) { lock.lock(); paths[path] = nil; removed.append(path); lock.unlock() }
    func makeDirectory(_ path: String) throws { lock.lock(); directories.append(path); lock.unlock() }
}

final class MgrImages: ImageConverting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var conversions: [(String, String, ImageConvertOptions)] = []
    var fail = false
    let files: MgrFiles

    init(files: MgrFiles) { self.files = files }

    func convert(input: String, output: String, options: ImageConvertOptions) throws {
        if fail { throw ImageIOConvertError.unreadable }
        lock.lock(); conversions.append((input, output, options)); lock.unlock()
        files.put(output, 500)
    }
}

final class MgrOcr: MediaTextExtracting, @unchecked Sendable {
    var text = "Привет"
    var paths: [String] = []
    func extractText(imagePath: String) throws -> String { paths.append(imagePath); return text }
}

final class MgrHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Data, Int)] = [:]
    private(set) var requested: [String] = []
    var failing: Set<String> = []

    func set(_ url: String, _ body: String, status: Int = 200) { lock.lock(); responses[url] = (Data(body.utf8), status); lock.unlock() }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        lock.lock()
        requested.append(url.absoluteString)
        let r = responses[url.absoluteString]
        let fails = failing.contains(url.absoluteString)
        lock.unlock()
        if fails { throw TlsError() }
        guard let r else { return (Data(), 404) }
        return r
    }
}

final class MgrCatalog: AppCataloging {
    var apps: [UpdateAppBundle] = []
    func installedApps() -> [UpdateAppBundle] { apps }
}

@MainActor
final class MgrCasks: CaskInfoProviding {
    var installed: [BrewPackage] = []
    var outdated: [BrewOutdatedItem] = []
    var calls = 0
    func caskData() async -> (installed: [BrewPackage], outdated: [BrewOutdatedItem]) { calls += 1; return (installed, outdated) }
}

@MainActor
final class MgrInstaller: UpdateInstalling {
    var casks: [String] = []
    var opened: [String] = []
    var urls: [URL] = []
    var jobId: Int? = 7
    func upgradeCask(token: String) -> Int? { casks.append(token); return jobId }
    func openApp(path: String) { opened.append(path) }
    func openURL(_ url: URL) { urls.append(url) }
}

final class MgrTerminal: TerminalOpening {
    var commands: [String] = []
    var ok = true
    func open(command: String) -> Bool { commands.append(command); return ok }
}

func mgrFiles(executables: [String] = []) -> TlsFiles {
    let f = TlsFiles()
    f.executables = Set(executables)
    return f
}

func mgrApp(_ name: String, id: String? = nil, short: String = "1.0", build: String = "100", feed: String? = nil, receipt: Bool = false, dir: String = "/Applications") -> UpdateAppBundle {
    UpdateAppBundle(path: "\(dir)/\(name).app", bundleId: id ?? "org.test.\(name.lowercased())", name: name, shortVersion: short, build: build, feedURL: feed, hasStoreReceipt: receipt)
}

func mgrAppcast(_ items: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel><title>App</title>\(items)</channel></rss>
    """
}

func mgrItem(version: String, short: String? = nil, url: String = "https://example.com/app.zip", extra: String = "") -> String {
    """
    <item><title>Version \(short ?? version)</title><pubDate>Tue, 07 Oct 2025 10:00:00 +0000</pubDate>
    \(short.map { "<sparkle:shortVersionString>\($0)</sparkle:shortVersionString>" } ?? "")
    \(extra)
    <enclosure url="\(url)" sparkle:version="\(version)" length="12345" type="application/octet-stream" sparkle:edSignature="abc"/></item>
    """
}

@MainActor
func mgrWait(_ cond: @MainActor () -> Bool, tries: Int = 400) async {
    for _ in 0..<tries {
        if cond() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
