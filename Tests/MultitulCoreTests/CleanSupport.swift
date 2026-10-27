import Foundation
@testable import MultitulCore

// A throw-away home directory. Every trash/purge/exec in tests goes through the closures set here, never to the real system.
final class CleanFixture: @unchecked Sendable {
    let root: String
    let home: String
    private let fm = FileManager.default
    let trashFail = LockedBox<Set<String>>([])
    let launchctl = LockedBox<[String]>([])
    let execLog = LockedBox<[String]>([])

    init() {
        let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        root = base + "/multitul-clean-test/" + UUID().uuidString
        home = root + "/home"
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(atPath: root) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, daysAgo: Double = 0) -> String {
        let p = home + "/" + rel
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: Data(repeating: 65, count: bytes))
        if daysAgo > 0 { age(p, daysAgo) }
        return p
    }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = home + "/" + rel
        try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func link(_ rel: String, to target: String) {
        let p = home + "/" + rel
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: p, withDestinationPath: target)
    }

    func age(_ path: String, _ days: Double) {
        let t = Date().addingTimeInterval(-days * 86400).timeIntervalSince1970
        var tv = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
        utimes(path, &tv)
    }

    // Ages every file and folder under a path, so "newest file" reads as old.
    func ageTree(_ rel: String, _ days: Double) {
        let p = home + "/" + rel
        if let en = fm.enumerator(atPath: p) { for case let r as String in en { age(p + "/" + r, days) } }
        age(p, days)
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(home + "/" + rel, &st) == 0
    }

    func existsAbs(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    func trashContents() -> [String] { ((try? fm.contentsOfDirectory(atPath: home + "/.Trash")) ?? []).sorted() }

    func env(running: [RunningApp] = [], services: [String]? = nil) -> CleanEnv {
        var e = CleanEnv(home: home)
        e.running = running
        e.allowExec = false
        e.settle = 0
        e.sleeper = { _ in }
        e.toolDirs = [root + "/bin"]
        e.appDirs = [root + "/Applications"]
        e.screenshotDirs = [home + "/Desktop"]
        e.lastOpened = { _ in nil }
        let failing = trashFail
        let h = home
        e.trasher = { p in
            if failing.value.contains(p) { return nil }
            let trash = h + "/.Trash"
            try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            let dst = trash + "/" + (p as NSString).lastPathComponent + "-" + UUID().uuidString.prefix(6)
            return (try? FileManager.default.moveItem(atPath: p, toPath: dst)) != nil ? dst : nil
        }
        let calls = launchctl
        e.launchctlList = {
            var out = ""
            calls.mutate { c in out = c.isEmpty ? "" : (c.count > 1 ? c.removeFirst() : c[0]) }
            return out
        }
        let log = execLog
        e.exec = { tool, args, _ in
            log.mutate { $0.append(([tool] + args).joined(separator: " ")) }
            return (0, "")
        }
        return e
    }

    // launchctl output sequence: the first call is "before", later ones are "after".
    func services(before: [(String, Int?, Int)], after: [(String, Int?, Int)]) {
        func text(_ l: [(String, Int?, Int)]) -> String {
            "PID\tStatus\tLabel\n" + l.map { "\($0.1.map(String.init) ?? "-")\t\($0.2)\t\($0.0)" }.joined(separator: "\n")
        }
        launchctl.mutate { $0 = [text(before), text(after)] }
    }

    func tool(_ name: String) {
        let dir = root + "/bin"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/" + name, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    @discardableResult
    func app(_ name: String, id: String, in dirRel: String = "Applications", version: String = "1.0") -> String {
        let p = root + "/" + dirRel + "/" + name + ".app"
        try? fm.createDirectory(atPath: p + "/Contents", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version]
        (plist as NSDictionary).write(toFile: p + "/Contents/Info.plist", atomically: true)
        fm.createFile(atPath: p + "/Contents/blob", contents: Data(repeating: 1, count: 8192))
        return p
    }
}
