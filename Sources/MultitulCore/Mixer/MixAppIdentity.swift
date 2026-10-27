import Foundation

// Audio is produced by helper processes (renderers, XPC services); the mixer shows and controls the app that owns them.
public enum MixAppIdentity {
    public static func isIgnored(_ p: MixProcessInfo, ownPID: Int32) -> Bool {
        if p.pid == ownPID { return true }
        guard let b = p.bundleID else { return false }
        if b == MixIdentity.ownBundleID || b.hasPrefix(MixIdentity.ownBundleID + ".") { return true }
        return MixIdentity.ignoredBundlePrefixes.contains { b.hasPrefix($0) }
    }

    public static func outermostBundlePath(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    public static func displayName(bundleID: String?, executablePath: String?) -> String {
        if let path = executablePath, let app = outermostBundlePath(path) {
            let n = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
            if !n.isEmpty { return n }
        }
        if let path = executablePath {
            let n = URL(fileURLWithPath: path).lastPathComponent
            if !n.isEmpty { return n }
        }
        if let b = bundleID, let last = b.split(separator: ".").last { return String(last) }
        return "Процесс"
    }

    private static func owner(of p: MixProcessInfo, apps: [MixRunningApp]) -> MixRunningApp? {
        if let a = apps.first(where: { $0.pid == p.pid && $0.bundleID != nil }) { return a }
        if let b = p.bundleID {
            let parents = apps.filter { $0.isRegular && $0.bundleID != nil && (b == $0.bundleID! || b.hasPrefix($0.bundleID! + ".")) }
            if let best = parents.max(by: { $0.bundleID!.count < $1.bundleID!.count }) { return best }
        }
        if let path = p.executablePath, let outer = outermostBundlePath(path) {
            if let a = apps.first(where: { $0.isRegular && $0.bundleID != nil && $0.bundlePath.map({ trim($0) == trim(outer) }) == true }) { return a }
        }
        return nil
    }

    private static func trim(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

    public static func resolve(_ procs: [MixProcessInfo], apps: [MixRunningApp], ownPID: Int32) -> [MixAppEntry] {
        var byKey: [String: MixAppEntry] = [:]
        var order: [String] = []
        for p in procs where !isIgnored(p, ownPID: ownPID) {
            let key: String
            let name: String
            if let a = owner(of: p, apps: apps), let b = a.bundleID {
                key = b
                name = a.name
            } else if let b = p.bundleID, !b.isEmpty {
                key = b
                name = displayName(bundleID: b, executablePath: p.executablePath)
            } else if let path = p.executablePath, !path.isEmpty {
                let exe = URL(fileURLWithPath: path).lastPathComponent
                key = MixIdentity.exeKeyPrefix + exe
                name = displayName(bundleID: nil, executablePath: path)
            } else {
                continue
            }
            if var e = byKey[key] {
                e.processObjectIDs.append(p.objectID)
                e.pids.append(p.pid)
                e.isOutputting = e.isOutputting || p.isRunningOutput
                byKey[key] = e
            } else {
                byKey[key] = MixAppEntry(key: key, name: name, processObjectIDs: [p.objectID], pids: [p.pid], isOutputting: p.isRunningOutput)
                order.append(key)
            }
        }
        return order.compactMap { k in
            guard var e = byKey[k] else { return nil }
            e.processObjectIDs = Array(Set(e.processObjectIDs)).sorted()
            e.pids = Array(Set(e.pids)).sorted()
            return e
        }
    }
}
