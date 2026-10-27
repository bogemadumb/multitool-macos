import Foundation

public struct VpnConfigError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum VpnConfig {
    public static let uuidPlaceholder = "__UUID__"
    public static let secretPlaceholder = "__CLASH_SECRET__"
    public static let maskedPlaceholder = "__MASKED__"

    private static let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    private static func parse(_ data: Data, _ what: String) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw VpnConfigError("\(what): invalid JSON")
        }
    }

    private static func dump(_ obj: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else { throw VpnConfigError("config is not a JSON object") }
        return try JSONSerialization.data(withJSONObject: obj, options: options)
    }

    public static func mask(_ data: Data) throws -> Data {
        try dump(maskValue(try parse(data, "current config")))
    }

    static func uuidPlaceholder(tag: String) -> String { "__UUID:\(tag)__" }

    static func tagOfPlaceholder(_ s: String) -> String? {
        guard s.hasPrefix("__UUID:"), s.hasSuffix("__"), s.count >= 9 else { return nil }
        return String(s.dropFirst(7).dropLast(2))
    }

    static func maskValue(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d {
                switch k {
                case "uuid":
                    if let tag = d["tag"] as? String, !tag.isEmpty, x is String { out[k] = uuidPlaceholder(tag: tag) }
                    else { out[k] = uuidPlaceholder }
                case "password", "private_key", "psk": out[k] = maskedPlaceholder
                case "secret": out[k] = secretPlaceholder
                default: out[k] = maskValue(x)
                }
            }
            return out
        }
        if let a = v as? [Any] { return a.map(maskValue) }
        return v
    }

    private struct Source {
        var uuids: Set<String> = []
        var byTag: [String: String] = [:]
        var secrets: [String] = []
    }

    private static func collect(_ v: Any, into src: inout Source) {
        if let d = v as? [String: Any] {
            if let u = d["uuid"] as? String {
                src.uuids.insert(u)
                if let tag = d["tag"] as? String, !tag.isEmpty { src.byTag[tag] = u }
            }
            for (k, x) in d {
                if k == "uuid" { continue }
                if k == "secret", let s = x as? String { src.secrets.append(s) }
                else { collect(x, into: &src) }
            }
        } else if let a = v as? [Any] {
            for x in a { collect(x, into: &src) }
        }
    }

    private static let uuidOutboundTypes: Set<String> = ["vless", "vmess"]

    private static func fillValue(_ v: Any, src: Source) throws -> Any {
        if let s = v as? String {
            if s == secretPlaceholder {
                guard let secret = src.secrets.first else { throw VpnConfigError("\(secretPlaceholder) but no secret in current config") }
                return secret
            }
            return s
        }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d {
                if k == "uuid" { out[k] = try fillUuid(x, src: src); continue }
                out[k] = try fillValue(x, src: src)
            }
            if let t = d["type"] as? String, uuidOutboundTypes.contains(t), d["uuid"] == nil {
                throw VpnConfigError("outbound \(d["tag"] as? String ?? "?") (\(t)) has no uuid; use \(uuidPlaceholder(tag: "<tag>"))")
            }
            return out
        }
        if let a = v as? [Any] { return try a.map { try fillValue($0, src: src) } }
        return v
    }

    private static func fillUuid(_ x: Any, src: Source) throws -> String {
        guard let s = x as? String else { throw VpnConfigError("uuid must be a placeholder string") }
        if s == uuidPlaceholder {
            guard src.uuids.count == 1, let u = src.uuids.first else {
                throw VpnConfigError("\(uuidPlaceholder) is ambiguous: \(src.uuids.count) uuids in current config, use \(uuidPlaceholder(tag: "<tag>"))")
            }
            return u
        }
        if let tag = tagOfPlaceholder(s) {
            guard let u = src.byTag[tag] else { throw VpnConfigError("no outbound with tag '\(tag)' and uuid in current config") }
            return u
        }
        throw VpnConfigError("staged config contains a literal uuid, only placeholders are allowed")
    }

    public static func fill(staged: Data, current: Data) throws -> Data {
        let cur = try parse(current, "current config")
        let new = try parse(staged, "staged config")
        var src = Source()
        collect(cur, into: &src)
        return try dump(try fillValue(new, src: src))
    }
}
