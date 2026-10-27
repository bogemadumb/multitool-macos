import Foundation
import Darwin

public enum VpnRules {
    public static let targets = ["direct", "proxy", "block"]
    public static let maxRules = 2000
    public static let maxValues = 5000

    public static func target(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".json") else { return nil }
        let base = String(name.dropLast(5))
        return targets.contains(base) ? base : nil
    }

    private static let stringKeys: Set<String> = ["domain", "domain_suffix", "domain_keyword", "ip_cidr", "source_ip_cidr",
                                                  "port_range", "process_name", "process_path", "network"]
    private static let intKeys: Set<String> = ["port"]
    private static let boolKeys: Set<String> = ["invert"]

    public static func validate(_ data: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VpnConfigError("rules: not a JSON object")
        }
        guard Set(obj.keys) == ["version", "rules"] else { throw VpnConfigError("rules: expected exactly version and rules") }
        guard let ver = obj["version"] as? Int, ver == 2 else { throw VpnConfigError("rules: version must be 2") }
        guard let rules = obj["rules"] as? [Any], !rules.isEmpty, rules.count <= maxRules else {
            throw VpnConfigError("rules: rules must be a non-empty array (max \(maxRules))")
        }
        for r in rules {
            guard let d = r as? [String: Any], !d.isEmpty else { throw VpnConfigError("rules: every rule must be an object") }
            for (k, v) in d { try validateField(k, v) }
        }
    }

    private static func validateField(_ key: String, _ value: Any) throws {
        if boolKeys.contains(key) {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw VpnConfigError("rules: \(key) must be bool") }
            return
        }
        guard stringKeys.contains(key) || intKeys.contains(key) else { throw VpnConfigError("rules: key not allowed: \(key)") }
        let list: [Any]
        if let a = value as? [Any] { list = a } else { list = [value] }
        guard !list.isEmpty, list.count <= maxValues else { throw VpnConfigError("rules: \(key) has bad length") }
        for item in list {
            if intKeys.contains(key) {
                guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (1...65535).contains(n.intValue) else {
                    throw VpnConfigError("rules: bad port")
                }
                continue
            }
            guard let s = item as? String else { throw VpnConfigError("rules: \(key) values must be strings") }
            try validateString(key, s)
        }
    }

    static func validateString(_ key: String, _ s: String) throws {
        guard !s.isEmpty, s.utf8.count <= 253 else { throw VpnConfigError("rules: bad \(key) value length") }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { throw VpnConfigError("rules: control character in \(key)") }
        switch key {
        case "domain", "domain_suffix", "domain_keyword":
            let ok = s.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7a) || ($0.value >= 0x41 && $0.value <= 0x5a) || $0 == "." || $0 == "-" || $0 == "_" }
            guard ok else { throw VpnConfigError("rules: bad domain \(s)") }
        case "ip_cidr", "source_ip_cidr":
            guard isCIDR(s) else { throw VpnConfigError("rules: bad cidr \(s)") }
        case "process_name":
            guard !s.contains("/"), s.utf8.count <= 128 else { throw VpnConfigError("rules: bad process name") }
        case "port_range":
            let p = s.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, p.allSatisfy({ $0.isEmpty || (Int($0).map { (0...65535).contains($0) } ?? false) }) else { throw VpnConfigError("rules: bad port range") }
        case "network":
            guard s == "tcp" || s == "udp" else { throw VpnConfigError("rules: bad network") }
        default: break
        }
    }

    static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        let isV4 = inet_pton(AF_INET, parts[0], &v4) == 1
        let isV6 = !isV4 && inet_pton(AF_INET6, parts[0], &v6) == 1
        guard isV4 || isV6 else { return false }
        if parts.count == 1 { return true }
        guard !parts[1].isEmpty, parts[1].count <= 3, parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(parts[1]) else { return false }
        return n <= (isV4 ? 32 : 128)
    }
}
