import Foundation

public struct UrlCleanRules: Equatable, Sendable {
    public static let allSites = ""

    public var added: [String: Set<String>] = [:]
    public var disabled: [String: Set<String>] = [:]
    public var disabledSites: Set<String> = []
    public var unwrapRedirects = false

    public init() {}

    public static func token(site: String, name: String) -> String { site.lowercased() + "|" + name.lowercased() }

    public static func parse(_ raw: String?) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for part in (raw ?? "").split(separator: ",") {
            let p = part.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 2 else { continue }
            let name = p[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            out[p[0].trimmingCharacters(in: .whitespaces).lowercased(), default: []].insert(name)
        }
        return out
    }

    public static func serialize(_ m: [String: Set<String>]) -> String {
        m.keys.sorted().flatMap { site in (m[site] ?? []).sorted().map { site + "|" + $0 } }.joined(separator: ",")
    }
}

public struct UrlCleanResult: Equatable, Sendable {
    public var url: String
    public var removed: [String]
    public var unwrapped: Bool
    public var changed: Bool { !removed.isEmpty || unwrapped }
}

public enum UrlCleanOutcome: Equatable, Sendable {
    case notAUrl, unchanged, cleaned(removed: [String], unwrapped: Bool)
}

public enum UrlCleaner {
    public static let globalNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "msclkid", "yclid", "ysclid", "_openstat", "ymclid",
        "mc_cid", "mc_eid", "igshid", "twclid", "ttclid", "li_fat_id", "mkt_tok", "_hsenc", "_hsmi", "__hstc", "__hssc", "__hsfp",
        "fb_action_ids", "fb_action_types", "fb_source", "mibextid", "rb_clickid", "vero_id", "oly_enc_id", "oly_anon_id",
        "_ga", "_gl", "wickedid", "s_cid", "pk_campaign", "pk_kwd", "pk_source", "pk_medium", "pk_content", "_bta_tid", "_bta_c", "dm_i", "ck_subscriber_id"
    ]
    public static let globalPrefixes = ["utm_", "mtm_", "hsa_", "__cft__"]

    public static let hostRules: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature", "kw", "ab_channel"],
        "youtu.be": ["si", "pp", "feature", "kw"],
        "x.com": ["s", "t", "cn", "src", "ref_src", "ref_url", "refsrc"],
        "twitter.com": ["s", "t", "cn", "src", "ref_src", "ref_url", "refsrc"],
        "instagram.com": ["igsh"],
        "spotify.com": ["si", "nd", "dlsi"],
        "reddit.com": ["correlation_id", "ref_campaign", "ref_source", "ref", "rdt", "share_id", "_branch_match_id", "$deep_link", "$3p", "$original_url"],
        "tiktok.com": ["u_code", "preview_pb", "_d", "_t", "_r", "timestamp", "user_id", "share_app_name", "share_iid", "share_link_id", "share_app_id", "tt_from", "sender_device", "sender_web_id", "is_from_webapp", "is_copy_url", "social_sharing", "checksum", "refer"],
        "facebook.com": ["__tn__", "eav", "rdid", "share_url"],
        "linkedin.com": ["trk", "trkinfo", "lipi", "midtoken", "midsig", "trackingid", "refid", "originalsubdomain"],
        "google.*": ["ved", "ei", "sa", "sxsrf", "uact", "gs_lcp", "gs_lp", "sclient", "oq", "aqs", "rlz", "sca_esv", "sca_upv", "gs_ssp", "iflsig"],
        "amazon.*": ["tag", "ref", "ref_", "pf_rd_r", "pf_rd_p", "pf_rd_m", "pf_rd_s", "pf_rd_t", "pf_rd_i", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "qid", "sr", "crid", "sprefix", "dib", "dib_tag", "linkcode", "linkid", "content-id", "_encoding"],
        "aliexpress.*": ["spm", "scm", "pvid", "algo_pvid", "algo_exp_id", "btsid", "ws_ab_test", "gps-id", "scm-url", "scm_id", "pdp_ext_f", "pdp_npi", "aff_fcid", "aff_fsk", "aff_platform", "aff_trace_key", "terminal_id", "afsmartredirect", "gatewayadapt"],
        "ebay.*": ["_trkparms", "_trksid", "amdata", "mkevt", "mkcid", "mkrid", "campid", "customid", "toolid", "ul_noapp"],
        "ozon.ru": ["at", "_bctx", "sh", "from_sku", "asb", "asb2", "avtc", "avte", "avts", "oos_search", "miniapp"],
        "wildberries.ru": ["targeturl"],
        "market.yandex.ru": ["cpc", "cpa", "clid", "distr_type"],
        "substack.com": ["r", "triedredirect"],
        "apple.com": ["itscg", "itsct", "ls", "at", "ct", "uo"],
    ]

    private struct Wrapper {
        var host: String
        var path: String
        var params: [String]
    }

    private static let wrappers: [Wrapper] = [
        Wrapper(host: "google.*", path: "/url", params: ["q", "url"]),
        Wrapper(host: "vk.com", path: "/away.php", params: ["to"]),
        Wrapper(host: "l.facebook.com", path: "/l.php", params: ["u"]),
        Wrapper(host: "lm.facebook.com", path: "/l.php", params: ["u"]),
        Wrapper(host: "youtube.com", path: "/redirect", params: ["q"]),
        Wrapper(host: "l.instagram.com", path: "/", params: ["u"]),
        Wrapper(host: "steamcommunity.com", path: "/linkfilter/", params: ["u", "url"]),
        Wrapper(host: "slack-redir.net", path: "/link", params: ["url"]),
    ]

    public static func hostMatches(_ host: String, key: String) -> Bool {
        if key.hasSuffix(".*") {
            let label = String(key.dropLast(2))
            let parts = host.split(separator: ".").map(String.init)
            guard let i = parts.firstIndex(of: label) else { return false }
            let rest = parts.count - i - 1
            return rest >= 1 && rest <= 2
        }
        return host == key || host.hasSuffix("." + key)
    }

    struct Parts {
        var scheme: String
        var userinfoHost: String
        var host: String
        var path: String
        var query: String?
        var fragment: String?
    }

    static func parts(_ s: String) -> Parts? {
        let lower = s.lowercased()
        let scheme: String
        if lower.hasPrefix("https://") { scheme = String(s.prefix(8)) } else if lower.hasPrefix("http://") { scheme = String(s.prefix(7)) } else { return nil }
        var rest = s.dropFirst(scheme.count)
        var fragment: String?
        if let h = rest.firstIndex(of: "#") { fragment = String(rest[rest.index(after: h)...]); rest = rest[..<h] }
        var query: String?
        if let q = rest.firstIndex(of: "?") { query = String(rest[rest.index(after: q)...]); rest = rest[..<q] }
        var authority = rest
        var path = ""
        if let sl = rest.firstIndex(of: "/") { authority = rest[..<sl]; path = String(rest[sl...]) }
        guard !authority.isEmpty else { return nil }
        var hostPart = authority
        if let at = hostPart.lastIndex(of: "@") { hostPart = hostPart[hostPart.index(after: at)...] }
        if let c = hostPart.lastIndex(of: ":"), hostPart[hostPart.index(after: c)...].allSatisfy(\.isNumber) { hostPart = hostPart[..<c] }
        let host = hostPart.lowercased()
        guard host.contains("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Parts(scheme: scheme, userinfoHost: String(authority), host: host, path: path, query: query, fragment: fragment)
    }

    static func rebuild(_ p: Parts, query: String?) -> String {
        var s = p.scheme + p.userinfoHost + p.path
        if let q = query, !q.isEmpty { s += "?" + q }
        if let f = p.fragment { s += "#" + f }
        return s
    }

    static func decodedName(_ pair: Substring) -> String {
        let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return (raw.removingPercentEncoding ?? raw).lowercased()
    }

    public static func isRemoved(name: String, host: String, rules: UrlCleanRules) -> Bool {
        let n = name.lowercased()
        let allSites = UrlCleanRules.allSites
        func off(_ site: String) -> Bool { rules.disabled[site]?.contains(n) == true }
        func matches(_ set: Set<String>) -> Bool { set.contains(n) || set.contains { $0.hasSuffix("*") && n.hasPrefix($0.dropLast()) } }
        if !off(allSites) {
            if globalNames.contains(n) { return true }
            if let pre = globalPrefixes.first(where: { n.hasPrefix($0) }), rules.disabled[allSites]?.contains(pre + "*") != true { return true }
        }
        if let g = rules.added[allSites], matches(g) { return true }
        for (site, names) in hostRules where hostMatches(host, key: site) && !rules.disabledSites.contains(site) {
            if names.contains(n), !off(site) { return true }
        }
        for (site, names) in rules.added where site != allSites && hostMatches(host, key: site) {
            if matches(names) { return true }
        }
        return false
    }

    public static func clean(_ input: String, rules: UrlCleanRules = UrlCleanRules()) -> UrlCleanResult? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        return clean(s, rules: rules, depth: 0)
    }

    private static func clean(_ s: String, rules: UrlCleanRules, depth: Int) -> UrlCleanResult? {
        guard let p = parts(s) else { return nil }
        if rules.unwrapRedirects, depth < 3, let target = unwrap(p),
           var inner = clean(target, rules: rules, depth: depth + 1) {
            inner.unwrapped = true
            return inner
        }
        guard let q = p.query, !q.isEmpty else { return UrlCleanResult(url: s, removed: [], unwrapped: false) }
        var kept: [Substring] = []
        var removed: [String] = []
        for pair in q.split(separator: "&", omittingEmptySubsequences: false) {
            let name = decodedName(pair)
            if !name.isEmpty, isRemoved(name: name, host: p.host, rules: rules) {
                if !removed.contains(name) { removed.append(name) }
            } else {
                kept.append(pair)
            }
        }
        if removed.isEmpty { return UrlCleanResult(url: s, removed: [], unwrapped: false) }
        let newQuery = kept.joined(separator: "&")
        return UrlCleanResult(url: rebuild(p, query: newQuery), removed: removed, unwrapped: false)
    }

    static func unwrap(_ p: Parts) -> String? {
        guard let q = p.query else { return nil }
        for w in wrappers where hostMatches(p.host, key: w.host) && p.path.lowercased() == w.path {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2, w.params.contains(String(kv[0]).lowercased()) else { continue }
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { return value }
            }
        }
        return nil
    }

    public static func outcome(for result: UrlCleanResult?) -> UrlCleanOutcome {
        guard let r = result else { return .notAUrl }
        return r.changed ? .cleaned(removed: r.removed, unwrapped: r.unwrapped) : .unchanged
    }

    public static var builtInGlobalList: [String] { ["utm_*"] + globalNames.sorted() }
}

public struct UrlCleanerSettings: Equatable, Sendable {
    public var cleanOnCopy = true
    public var showHud = true
    public var rules = UrlCleanRules()
    public init() {}
}

public final class UrlCleanOnCopy {
    private let pasteboard: PasteboardDriving
    public var settings: UrlCleanerSettings
    public private(set) var cleanedCount = 0
    public var onCleaned: ((UrlCleanResult) -> Void)?

    public init(pasteboard: PasteboardDriving, settings: UrlCleanerSettings) {
        self.pasteboard = pasteboard
        self.settings = settings
    }

    @discardableResult
    public func handle(_ change: PasteboardChange) -> Bool {
        guard settings.cleanOnCopy else { return false }
        return cleanClipboard() != nil
    }

    @discardableResult
    public func cleanClipboard() -> UrlCleanResult? {
        let items = pasteboard.readItems(types: [PBType.utf8, PBType.fileURL, PBType.png, PBType.tiff])
        guard items.count == 1, items[0].reps[PBType.fileURL] == nil, items[0].reps[PBType.png] == nil, items[0].reps[PBType.tiff] == nil,
              let text = items[0].string, let r = UrlCleaner.clean(text, rules: settings.rules), r.changed else { return nil }
        var out = PasteboardItemData(text: r.url)
        out.reps[PBType.url] = Data(r.url.utf8)
        pasteboard.write([out])
        cleanedCount += 1
        onCleaned?(r)
        return r
    }
}
