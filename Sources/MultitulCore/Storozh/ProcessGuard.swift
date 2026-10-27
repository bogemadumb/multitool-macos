import Foundation

public func nameMatches(_ pattern: String, _ name: String) -> Bool {
    fnmatch(pattern, name, 0) == 0
}

// Entry forms: "name*" glob, "pid<200", "path:/prefix", "pathhas:substring" (path or args).
public func isListed(name: String, pid: Int32, path: String?, list: [String], args: String? = nil) -> Bool {
    for e in list {
        if e.hasPrefix("pid<") {
            if let n = Int32(e.dropFirst(4)), pid < n { return true }
        } else if e.hasPrefix("pathhas:") {
            let part = String(e.dropFirst(8))
            if let p = path, p.contains(part) { return true }
            if let a = args, a.contains(part) { return true }
        } else if e.hasPrefix("path:") {
            let prefix = String(e.dropFirst(5))
            if let p = path, p.hasPrefix(prefix) { return true }
        } else if nameMatches(e, name) {
            return true
        }
    }
    return false
}

public func isClaudeProcess(name: String, pid: Int32, path: String?, args: String?) -> Bool {
    let patterns = StorozhLists.builtinUntouchable.filter { e in
        let l = e.lowercased()
        return l.contains("claude") || l.contains("codex") || l.contains("openai.chatgpt")
    }
    return isListed(name: name, pid: pid, path: path, list: patterns, args: args)
}

public func isUntouchable(_ i: ProcInfo, _ lists: StorozhLists) -> Bool {
    isListed(name: i.name, pid: i.pid, path: i.path, list: lists.effectiveUntouchable, args: i.args)
}

public func mainBundlePath(ofExecutable path: String) -> String? {
    guard let r = path.range(of: ".app/Contents/MacOS/") else { return nil }
    let bundle = String(path[..<r.lowerBound]) + ".app"
    return bundle.contains(".app/") ? nil : bundle
}

public func pidPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}
