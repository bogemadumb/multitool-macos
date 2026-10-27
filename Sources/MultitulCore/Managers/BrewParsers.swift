import Foundation

public enum BrewParseError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedShape
}

public enum BrewParsers {
    private static func object(_ text: String) throws -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        guard let data = t.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else { throw BrewParseError.invalidJSON }
        return any
    }

    private static func stringList(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String, !s.isEmpty { return [s] }
        return []
    }

    private static func versionText(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    // `brew info --json=v2 [--installed] [names]`
    public static func parseInfo(_ text: String) throws -> [BrewPackage] {
        guard let any = try object(text) else { return [] }
        guard let root = any as? [String: Any] else { throw BrewParseError.unexpectedShape }
        var out: [BrewPackage] = []
        for f in (root["formulae"] as? [[String: Any]]) ?? [] {
            guard let name = f["name"] as? String, !name.isEmpty else { continue }
            let installed = (f["installed"] as? [[String: Any]]) ?? []
            let last = installed.last
            let versions = f["versions"] as? [String: Any]
            let stable = (versions?["stable"] as? String) ?? ""
            out.append(BrewPackage(
                name: name,
                fullName: (f["full_name"] as? String) ?? name,
                kind: .formula,
                desc: (f["desc"] as? String) ?? "",
                homepage: (f["homepage"] as? String) ?? "",
                tap: (f["tap"] as? String) ?? "",
                installedVersion: installed.isEmpty ? nil : ((last?["version"] as? String) ?? ""),
                latestVersion: stable,
                installedOnRequest: installed.contains { ($0["installed_on_request"] as? Bool) == true },
                installedAsDependency: !installed.isEmpty && installed.allSatisfy { ($0["installed_as_dependency"] as? Bool) == true },
                pinned: (f["pinned"] as? Bool) ?? false,
                outdated: (f["outdated"] as? Bool) ?? false,
                deprecated: (f["deprecated"] as? Bool) ?? false,
                disabled: (f["disabled"] as? Bool) ?? false,
                dependencies: stringList(f["dependencies"])
            ))
        }
        for c in (root["casks"] as? [[String: Any]]) ?? [] {
            guard let token = c["token"] as? String, !token.isEmpty else { continue }
            var apps: [String] = []
            for art in (c["artifacts"] as? [Any]) ?? [] {
                if let d = art as? [String: Any], let list = d["app"] as? [Any] {
                    apps += list.compactMap { $0 as? String }
                }
            }
            let names = stringList(c["name"])
            out.append(BrewPackage(
                name: token,
                fullName: (c["full_token"] as? String) ?? token,
                kind: .cask,
                displayName: names.first ?? token,
                desc: (c["desc"] as? String) ?? "",
                homepage: (c["homepage"] as? String) ?? "",
                tap: (c["tap"] as? String) ?? "",
                installedVersion: versionText(c["installed"]),
                latestVersion: versionText(c["version"]) ?? "",
                outdated: (c["outdated"] as? Bool) ?? false,
                autoUpdates: (c["auto_updates"] as? Bool) ?? false,
                deprecated: (c["deprecated"] as? Bool) ?? false,
                disabled: (c["disabled"] as? Bool) ?? false,
                appNames: apps
            ))
        }
        return out
    }

    // `brew outdated --json=v2`
    public static func parseOutdated(_ text: String) throws -> [BrewOutdatedItem] {
        guard let any = try object(text) else { return [] }
        guard let root = any as? [String: Any] else { throw BrewParseError.unexpectedShape }
        var out: [BrewOutdatedItem] = []
        for (key, kind) in [("formulae", BrewKind.formula), ("casks", BrewKind.cask)] {
            for e in (root[key] as? [[String: Any]]) ?? [] {
                guard let name = e["name"] as? String, !name.isEmpty else { continue }
                out.append(BrewOutdatedItem(
                    name: name,
                    kind: kind,
                    installedVersions: stringList(e["installed_versions"]),
                    currentVersion: versionText(e["current_version"]) ?? "",
                    pinned: (e["pinned"] as? Bool) ?? false
                ))
            }
        }
        return out
    }

    // `brew services list --json`
    public static func parseServices(_ text: String) throws -> [BrewServiceInfo] {
        guard let any = try object(text) else { return [] }
        guard let list = any as? [[String: Any]] else { throw BrewParseError.unexpectedShape }
        return list.compactMap { e in
            guard let name = e["name"] as? String, !name.isEmpty else { return nil }
            let status = BrewServiceStatus(rawValue: ((e["status"] as? String) ?? "").lowercased()) ?? .unknown
            return BrewServiceInfo(name: name, status: status, user: (e["user"] as? String) ?? "", file: (e["file"] as? String) ?? "",
                                   exitCode: (e["exit_code"] as? NSNumber)?.intValue)
        }
    }

    private static func cleanLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // `brew search [--desc] query`; headers "==> Formulae" and "==> Casks" appear when both kinds match
    public static func parseSearch(_ text: String, defaultKind: BrewKind? = nil) -> [BrewSearchResult] {
        var kind = defaultKind
        var out: [BrewSearchResult] = []
        var seen = Set<String>()
        for raw in cleanLines(text) {
            if raw.hasPrefix("==>") {
                let h = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                if h.hasPrefix("formulae") || h.hasPrefix("formula") { kind = .formula } else if h.hasPrefix("casks") || h.hasPrefix("cask") { kind = .cask }
                continue
            }
            if raw.hasPrefix("Error:") || raw.hasPrefix("Warning:") || raw.hasPrefix("No formula") || raw.hasPrefix("If you meant") || raw.hasPrefix("Did you mean") { continue }
            var line = raw
            if line.hasPrefix("✔") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.hasSuffix("✔") { line = String(line.dropLast()).trimmingCharacters(in: .whitespaces) }
            var name = line
            var desc = ""
            if let r = line.range(of: ": ") {
                name = String(line[..<r.lowerBound])
                desc = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard BrewName.isValid(name), seen.insert((kind?.rawValue ?? "any") + ":" + name).inserted else { continue }
            out.append(BrewSearchResult(name: name, kind: kind, desc: desc))
        }
        return out
    }

    // `brew leaves` and `brew uses --installed x`: one name per line
    public static func parseNameList(_ text: String) -> [String] {
        var seen = Set<String>()
        return cleanLines(text).filter { BrewName.isValid($0) && seen.insert($0).inserted }
    }

    // `brew deps --tree name`
    public static func parseDepsTree(_ text: String) -> BrewDepNode? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return nil }
        let rootName = first.trimmingCharacters(in: .whitespaces)
        guard BrewName.isValid(rootName) else { return nil }
        var stack: [(depth: Int, path: [Int])] = []
        var root = BrewDepNode(name: rootName)

        func insert(_ node: BrewDepNode, at path: [Int]) {
            func go(_ n: inout BrewDepNode, _ p: ArraySlice<Int>) {
                if p.isEmpty { n.children.append(node); return }
                go(&n.children[p.first!], p.dropFirst())
            }
            go(&root, path[...])
        }

        for line in lines.dropFirst() {
            var depth = 0
            var rest = Substring(line)
            while true {
                if rest.hasPrefix("│   ") || rest.hasPrefix("    ") { rest = rest.dropFirst(4); depth += 1 } else { break }
            }
            guard rest.hasPrefix("├── ") || rest.hasPrefix("└── ") else { continue }
            let name = rest.dropFirst(4).replacingOccurrences(of: " (*)", with: "").trimmingCharacters(in: .whitespaces)
            guard BrewName.isValid(name) else { continue }
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            var parent = root
            for i in parentPath { parent = parent.children[i] }
            let index = parent.children.count
            insert(BrewDepNode(name: name), at: parentPath)
            stack.append((depth, parentPath + [index]))
        }
        return root
    }

    // `brew autoremove --dry-run`
    public static func parseAutoremove(_ text: String) -> [String] {
        var out: [String] = []
        var inList = false
        for line in cleanLines(text) {
            if line.hasPrefix("==> Would autoremove") || line.hasPrefix("==> Autoremoving") { inList = true; continue }
            if line.hasPrefix("==>") || line.hasPrefix("Warning") || line.hasPrefix("Error") { inList = false; continue }
            if inList, BrewName.isValid(line) { out.append(line) }
        }
        return out
    }

    // `brew cleanup -n` / `brew cleanup`
    public static func parseCleanup(_ text: String) -> BrewCleanupReport {
        var items: [String] = []
        var bytes: Int64 = 0
        var dry = true
        for line in cleanLines(text) {
            if line.hasPrefix("Would remove:") {
                items.append(String(line.dropFirst("Would remove:".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Removing:") {
                dry = false
                items.append(String(line.dropFirst("Removing:".count)).trimmingCharacters(in: .whitespaces))
            } else if line.contains("freed approximately") {
                dry = false
                bytes = sizeBytes(in: line) ?? bytes
            } else if line.contains("would free approximately") {
                bytes = sizeBytes(in: line) ?? bytes
            }
        }
        return BrewCleanupReport(items: items, bytes: bytes, isDryRun: dry)
    }

    // "1.2GB", "512.4KB", "10B", "3.1 MB"
    public static func sizeBytes(in text: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s?(TB|GB|MB|KB|B)\b"#) else { return nil }
        let ns = text as NSString
        guard let m = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = ns.substring(with: m.range(at: 2))
        let table: [String: Double] = ["B": 1, "KB": 1_024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776]
        let mult = table[unit] ?? 1
        return Int64(n * mult)
    }
}
