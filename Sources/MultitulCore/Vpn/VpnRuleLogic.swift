import Foundation
import Darwin
import MultitulCtlCore

public enum VpnRuleTarget: String, CaseIterable, Sendable {
    case direct, proxy, block

    var fileName: String { rawValue + ".json" }

    public var label: String {
        switch self {
        case .direct: "напрямую"
        case .proxy: "через VPS"
        case .block: "блок"
        }
    }

    public var title: String {
        switch self {
        case .direct: "Напрямую"
        case .proxy: "Через VPS"
        case .block: "Блок"
        }
    }

    public var route: VpnRoute {
        switch self {
        case .direct: .direct
        case .proxy: .vps
        case .block: .block
        }
    }
}

public enum VpnRuleKind: String, CaseIterable, Sendable {
    case domain
    case domainSuffix = "domain_suffix"
    case ipCidr = "ip_cidr"
    case processName = "process_name"

    public var label: String {
        switch self {
        case .domain: "домен"
        case .domainSuffix: "сайт и поддомены"
        case .ipCidr: "адрес"
        case .processName: "приложение"
        }
    }
}

public struct VpnUserRule: Identifiable, Hashable, Sendable {
    public let target: VpnRuleTarget
    public let kind: VpnRuleKind
    public let value: String
    public var id: String { "\(target.rawValue)|\(kind.rawValue)|\(value)" }
    public init(target: VpnRuleTarget, kind: VpnRuleKind, value: String) {
        self.target = target
        self.kind = kind
        self.value = value
    }
}

public enum VpnRuleDetect {
    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        return p.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && Int($0).map { $0 <= 255 } == true }
    }

    static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return s.contains(":") && inet_pton(AF_INET6, s, &a) == 1
    }

    static func cidr(_ raw: String) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let ip = parts.first else { return nil }
        if isIPv4(ip) {
            if parts.count == 1 { return ip + "/32" }
            guard let n = Int(parts[1]), (0...32).contains(n) else { return nil }
            return "\(ip)/\(n)"
        }
        if isIPv6(ip) {
            if parts.count == 1 { return ip.lowercased() + "/128" }
            guard let n = Int(parts[1]), (0...128).contains(n) else { return nil }
            return "\(ip.lowercased())/\(n)"
        }
        return nil
    }

    public static func hostFromURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let h = URL(string: s)?.host, !h.isEmpty else { return nil }
        var host = h.lowercased()
        if host.hasPrefix("www.") && host.count > 4 { host.removeFirst(4) }
        return host
    }

    public static func parse(_ raw: String) -> (kind: VpnRuleKind, value: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.contains("://") {
            guard let h = hostFromURL(s) else { return nil }
            s = h
        }
        if let c = cidr(s) { return (.ipCidr, c) }
        if s.contains("/") {
            let base = s.split(separator: "/").last.map(String.init) ?? ""
            return base.isEmpty ? nil : (.processName, base)
        }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { return nil }
        if s.contains(".") && !s.contains(" ") && !s.hasSuffix(".") {
            return (.domainSuffix, s.lowercased())
        }
        return (.processName, s)
    }

    public static func forHost(_ host: String) -> (kind: VpnRuleKind, value: String)? {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty { return nil }
        if let c = cidr(h) { return (.ipCidr, c) }
        return (.domainSuffix, h.hasPrefix("www.") && h.count > 4 ? String(h.dropFirst(4)) : h)
    }
}

struct VpnRuleDoc {
    static let placeholder = "placeholder.invalid"
    var buckets: [VpnRuleKind: [String]] = [:]
    var opaque: [Any] = []
    var trailingNewline = true

    static func parse(_ data: Data) -> VpnRuleDoc? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = obj["rules"] as? [Any] else { return nil }
        var doc = VpnRuleDoc()
        doc.trailingNewline = data.last == 0x0A
        for r in rules {
            if let d = r as? [String: Any], d.count == 1, let k = d.keys.first,
               let kind = VpnRuleKind(rawValue: k), let vals = d[k] as? [String] {
                for v in vals where !(kind == .domain && v == placeholder) {
                    if !(doc.buckets[kind] ?? []).contains(v) { doc.buckets[kind, default: []].append(v) }
                }
            } else {
                doc.opaque.append(r)
            }
        }
        return doc
    }

    var entries: [(kind: VpnRuleKind, value: String)] {
        VpnRuleKind.allCases.flatMap { k in (buckets[k] ?? []).map { (k, $0) } }
    }

    func contains(_ kind: VpnRuleKind, _ value: String) -> Bool { (buckets[kind] ?? []).contains(value) }

    mutating func add(_ kind: VpnRuleKind, _ value: String) {
        if !contains(kind, value) { buckets[kind, default: []].append(value) }
    }

    mutating func remove(_ kind: VpnRuleKind, _ value: String) {
        buckets[kind]?.removeAll { $0 == value }
        if buckets[kind]?.isEmpty == true { buckets[kind] = nil }
    }

    func serialize() -> Data {
        var rules: [String] = []
        for k in VpnRuleKind.allCases {
            if let v = buckets[k], !v.isEmpty { rules.append("{\(Self.str(k.rawValue)): \(Self.arr(v))}") }
        }
        for o in opaque { rules.append(Self.py(o)) }
        if rules.isEmpty { rules.append("{\"domain\": [\(Self.str(Self.placeholder))]}") }
        let text = "{\"version\": 2, \"rules\": [\(rules.joined(separator: ", "))]}" + (trailingNewline ? "\n" : "")
        return Data(text.utf8)
    }

    static func str(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let t = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    static func arr(_ v: [String]) -> String { "[" + v.map(str).joined(separator: ", ") + "]" }

    static func py(_ o: Any) -> String {
        if let d = o as? [String: Any] {
            return "{" + d.keys.sorted().map { "\(str($0)): \(py(d[$0]!))" }.joined(separator: ", ") + "}"
        }
        if let a = o as? [Any] { return "[" + a.map(py).joined(separator: ", ") + "]" }
        if let s = o as? String { return str(s) }
        if let n = o as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return "null"
    }
}

protocol VpnRuleWriting: Sendable {
    func write(_ target: VpnRuleTarget, data: Data) throws
}

struct PrivilegedRuleWriter: VpnRuleWriting {
    let ctl: PrivilegedCtl
    func write(_ target: VpnRuleTarget, data: Data) throws {
        try ctl.vpnRulesWrite(target: target.rawValue, data: data)
    }
}

struct VpnRuleFiles: Sendable {
    static let defaultDir = "/usr/local/etc/singbox/user"
    let dir: String
    let writer: VpnRuleWriting

    init(dir: String = VpnRuleFiles.defaultDir, writer: VpnRuleWriting) {
        self.dir = dir
        self.writer = writer
    }

    static func live() -> VpnRuleFiles { VpnRuleFiles(writer: PrivilegedRuleWriter(ctl: PrivilegedCtl())) }

    func path(_ t: VpnRuleTarget) -> String { dir + "/" + t.fileName }

    private func read(_ t: VpnRuleTarget) throws -> VpnRuleDoc {
        guard let data = FileManager.default.contents(atPath: path(t)), let doc = VpnRuleDoc.parse(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return doc
    }

    private func write(_ doc: VpnRuleDoc, _ t: VpnRuleTarget) throws {
        let data = doc.serialize()
        if FileManager.default.contents(atPath: path(t)) == data { return }
        try writer.write(t, data: data)
    }

    func load() -> [VpnUserRule] {
        var out: [VpnUserRule] = []
        for t in [VpnRuleTarget.block, .direct, .proxy] {
            guard let doc = try? read(t) else { continue }
            out += doc.entries.map { VpnUserRule(target: t, kind: $0.kind, value: $0.value) }
        }
        return out
    }

    func alwaysVps() -> [String] {
        guard let data = FileManager.default.contents(atPath: dir + "/always-vps.json"),
              let doc = VpnRuleDoc.parse(data) else { return [] }
        return doc.entries.map { $0.value }
    }

    @discardableResult
    func add(_ value: String, kind: VpnRuleKind, target: VpnRuleTarget) throws -> Bool {
        var docs: [VpnRuleTarget: VpnRuleDoc] = [:]
        for t in VpnRuleTarget.allCases { docs[t] = try read(t) }
        var changed = !(docs[target]?.contains(kind, value) ?? false)
        docs[target]?.add(kind, value)
        try write(docs[target]!, target)
        for other in VpnRuleTarget.allCases where other != target {
            if docs[other]?.contains(kind, value) == true {
                docs[other]?.remove(kind, value)
                try write(docs[other]!, other)
                changed = true
            }
        }
        return changed
    }

    func remove(_ rule: VpnUserRule) throws {
        var doc = try read(rule.target)
        doc.remove(rule.kind, rule.value)
        try write(doc, rule.target)
    }

    func find(_ kind: VpnRuleKind, _ value: String) -> VpnRuleTarget? {
        load().first { $0.kind == kind && $0.value == value }?.target
    }
}

public struct VpnRuleItem: Identifiable, Sendable {
    public let id: String
    public let what: String
    public let note: String
    public let route: VpnRoute
    public let user: VpnUserRule?
}

public enum VpnRuleList {
    public static func items(user: [VpnUserRule], alwaysVps: [String]) -> [VpnRuleItem] {
        func fixed(_ id: String, _ what: String, _ note: String, _ route: VpnRoute) -> VpnRuleItem {
            VpnRuleItem(id: id, what: what, note: note, route: route, user: nil)
        }
        var out: [VpnRuleItem] = [
            fixed("mail", "Почтовые порты", "993, 995, 465, 587", .direct),
            fixed("server", "Сам сервер", "\(VpnEndpoint.serverAddress) — иначе петля", .direct),
            fixed("lan", "Локальная сеть", "192.168.0.0/16 и др.", .local),
            fixed("apple", "Apple", "17.0.0.0/8 — iCloud", .direct),
            fixed("always-vps", "Всегда через VPS", alwaysVps.isEmpty ? "всегда через VPS, выше режимов" : alwaysVps.joined(separator: ", "), .vps),
            fixed("mode-direct", "Режим «Напрямую»", "весь трафик мимо туннеля", .direct),
            fixed("mode-global", "Режим «Всё через VPS»", "весь трафик в туннель", .vps),
        ]
        let mine = user.filter { $0.target == .block } + user.filter { $0.target == .direct } + user.filter { $0.target == .proxy }
        if mine.isEmpty {
            out.append(fixed("mine-empty", "Мои правила", "добавь сайт, адрес или приложение справа", .vps))
        }
        for u in mine {
            out.append(VpnRuleItem(id: u.id, what: u.value, note: "мои · \(u.kind.label)", route: u.target.route, user: u))
        }
        out.append(fixed("ru", "Сайты РФ", "база geoip-ru", .direct))
        out.append(fixed("final", "Всё остальное", "по умолчанию", .vps))
        return out
    }
}
