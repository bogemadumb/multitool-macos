import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class ShfFS: ShelfFileSystem {
    var files: [String: Int] = [:]
    var dirs: Set<String> = []
    var bookmarkTargets: [Data: String] = [:]
    var staleBookmarks: Set<Data> = []
    var failBookmarks = false
    var written: [String: Data] = [:]
    var removed: [String] = []
    var links: [(at: String, to: String)] = []
    var madeDirs: [String] = []
    private var counter = 0

    func addFile(_ p: String, size: Int = 10) { files[p] = size }
    func addDir(_ p: String) { dirs.insert(p) }

    func exists(_ path: String) -> Bool {
        files[path] != nil || dirs.contains(path) || files.keys.contains { $0.hasPrefix(path + "/") }
    }
    func isDirectory(_ path: String) -> Bool { dirs.contains(path) || files.keys.contains { $0.hasPrefix(path + "/") } }
    func fileSize(_ path: String) -> Int { files[path] ?? 0 }

    func makeBookmark(_ path: String) -> Data? {
        guard !failBookmarks else { return nil }
        counter += 1
        let d = Data("bm\(counter):\(path)".utf8)
        bookmarkTargets[d] = path
        return d
    }

    func resolveBookmark(_ data: Data) -> ShelfBookmarkResult {
        guard let t = bookmarkTargets[data] else { return .failed }
        return .resolved(path: t, stale: staleBookmarks.contains(data))
    }

    func move(_ from: String, _ to: String) {
        if let s = files.removeValue(forKey: from) { files[to] = s }
        if dirs.remove(from) != nil { dirs.insert(to) }
        for (k, v) in bookmarkTargets where v == from { bookmarkTargets[k] = to }
    }

    func remove(_ path: String) -> Bool {
        removed.append(path)
        let had = exists(path)
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        dirs = dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }
        return had
    }

    func list(_ dir: String) -> [String] {
        var names = Set<String>()
        for p in Array(files.keys) + Array(dirs) where p.hasPrefix(dir + "/") {
            if let first = p.dropFirst(dir.count + 1).split(separator: "/").first { names.insert(String(first)) }
        }
        return names.sorted()
    }

    func write(_ data: Data, to path: String) -> Bool {
        written[path] = data
        files[path] = data.count
        return true
    }

    func makeDirectory(_ path: String) -> Bool {
        madeDirs.append(path)
        dirs.insert(path)
        return true
    }

    func symlink(at path: String, to target: String) -> Bool {
        links.append((path, target))
        files[path] = files[target] ?? 0
        return true
    }
}

final class ShfProbe: DragPasteboardProbing {
    var changeCount = 1
    var hasContent = false
    func startDrag() { changeCount += 1; hasContent = true }
}

final class ShfRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessOutput(status: 0)
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        calls.append((executable, arguments))
        return result
    }
}

final class ShfClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

enum Shf {
    static let owned = "/shelf/files"
    static let archives = "/shelf/archives"
    static let out = "/shelf/out"

    static func store(clock: ShfClock = ShfClock(), path: String? = nil) -> ShelfStore {
        try! ShelfStore(store: ShelfSchema.openStore(path: path ?? tempDBPath()), now: { clock.now })
    }

    static func service(fs: ShfFS = ShfFS(), clock: ShfClock = ShfClock(), settings: ShelfSettings = ShelfSettings(), path: String? = nil) -> ShelfService {
        ShelfService(store: store(clock: clock, path: path), fs: fs, settings: settings, ownedDirs: [owned, archives], outDir: out)
    }

    static func text(_ s: String) -> PasteboardItemData { PasteboardItemData(text: s) }

    static func fileItem(_ path: String) -> PasteboardItemData {
        PasteboardItemData(reps: [PBType.fileURL: Data(URL(fileURLWithPath: path).absoluteString.utf8)])
    }

    static func zigzag(_ d: inout ShakeDetector, legs: Int, amp: Double, step: Double = 10, dt: TimeInterval = 0.01, t0: TimeInterval = 0, vertical: Bool = false) -> (fired: Bool, end: TimeInterval) {
        var pos = 500.0
        var dir = 1.0
        var t = t0
        var fired = false
        _ = vertical ? d.feed(x: 300, y: pos, at: t) : d.feed(x: pos, y: 300, at: t)
        for _ in 0..<legs {
            for _ in 0..<Int(amp / step) {
                pos += dir * step
                t += dt
                if (vertical ? d.feed(x: 300, y: pos, at: t) : d.feed(x: pos, y: 300, at: t)) { fired = true }
            }
            dir = -dir
        }
        return (fired, t)
    }
}
