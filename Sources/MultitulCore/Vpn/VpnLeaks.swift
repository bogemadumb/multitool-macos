import Foundation
import SwiftUI

public enum VpnCheckStatus: String, Sendable {
    case pending, ok, warn, fail, skipped
}

public struct VpnCheckItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var status: VpnCheckStatus
    public var text: String
}

public enum VpnFetch: Equatable, Sendable {
    case response(status: Int, body: String)
    case failed(String)
}

public struct VpnLeakFetches: Sendable {
    public var geo: VpnFetch
    public var ipv6: VpnFetch
    public var dns: VpnFetch
    public var ru: VpnFetch
    public var blocked: VpnFetch

    public init(geo: VpnFetch, ipv6: VpnFetch, dns: VpnFetch, ru: VpnFetch, blocked: VpnFetch) {
        self.geo = geo
        self.ipv6 = ipv6
        self.dns = dns
        self.ru = ru
        self.blocked = blocked
    }
}

public struct VpnLeakVerdict: Equatable, Sendable {
    public var leak: Bool
    public var detail: String
}

public struct VpnChip: Equatable, Sendable {
    public let text: String
    public let status: VpnCheckStatus
}

public enum VpnLeakLogic {
    // Exit nodes (fin, bvpn-se/lt/nl) are picked by urltest, so any non-home country means the tunnel.
    public static let home = "RU"

    public static func parseTrace(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let k = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    private static func trace(_ f: VpnFetch) -> (loc: String, ip: String)? {
        guard case .response(let s, let body) = f, (200..<300).contains(s) else { return nil }
        let t = parseTrace(body)
        guard let loc = t["loc"], !loc.isEmpty else { return nil }
        return (loc, t["ip"] ?? "")
    }

    public static func pending() -> [VpnCheckItem] {
        [VpnCheckItem(id: "ru", name: "Российские сайты", status: .pending, text: "проверяю…"),
         VpnCheckItem(id: "blocked", name: "Заблокированные", status: .pending, text: "проверяю…"),
         VpnCheckItem(id: "ipv6", name: "Утечка IPv6", status: .pending, text: "проверяю…"),
         VpnCheckItem(id: "dns", name: "DNS", status: .pending, text: "проверяю…"),
         VpnCheckItem(id: "geo", name: "Гео для cloudflare.com", status: .pending, text: "проверяю…")]
    }

    public static func skipped(_ reason: String) -> [VpnCheckItem] {
        pending().map { VpnCheckItem(id: $0.id, name: $0.name, status: .skipped, text: reason) }
    }

    public static func geo(_ f: VpnFetch) -> VpnCheckItem {
        let name = "Гео для cloudflare.com"
        guard let t = trace(f) else { return VpnCheckItem(id: "geo", name: name, status: .warn, text: "нет ответа") }
        if t.loc != home {
            return VpnCheckItem(id: "geo", name: name, status: .ok, text: "\(t.loc) · \(t.ip)")
        }
        return VpnCheckItem(id: "geo", name: name, status: .fail, text: "утечка: \(t.loc) · \(t.ip)")
    }

    public static func ipv6(_ f: VpnFetch) -> VpnCheckItem {
        let name = "Утечка IPv6"
        if let t = trace(f) {
            if t.loc != home { return VpnCheckItem(id: "ipv6", name: name, status: .ok, text: "нет, через туннель (\(t.loc))") }
            return VpnCheckItem(id: "ipv6", name: name, status: .fail, text: "утечка: \(t.loc) · \(t.ip)")
        }
        return VpnCheckItem(id: "ipv6", name: name, status: .ok, text: "нет")
    }

    public static func dns(_ f: VpnFetch) -> VpnCheckItem {
        let name = "DNS"
        guard let t = trace(f) else { return VpnCheckItem(id: "dns", name: name, status: .warn, text: "нет ответа от 1.1.1.1") }
        if t.loc != home { return VpnCheckItem(id: "dns", name: name, status: .ok, text: "через туннель, 1.1.1.1 (\(t.loc))") }
        return VpnCheckItem(id: "dns", name: name, status: .fail, text: "утечка: 1.1.1.1 виден из \(t.loc)")
    }

    public static func site(id: String, name: String, _ f: VpnFetch) -> VpnCheckItem {
        if case .response(let s, _) = f, s > 0, s < 500 {
            return VpnCheckItem(id: id, name: name, status: .ok, text: "открываются")
        }
        return VpnCheckItem(id: id, name: name, status: .fail, text: "не открываются")
    }

    public static func evaluate(_ f: VpnLeakFetches, mode: String) -> [VpnCheckItem] {
        var items = [site(id: "ru", name: "Российские сайты", f.ru),
                     site(id: "blocked", name: "Заблокированные", f.blocked),
                     ipv6(f.ipv6), dns(f.dns), geo(f.geo)]
        if mode == "Direct" {
            for i in items.indices where items[i].id == "ipv6" || items[i].id == "dns" {
                items[i].status = .skipped
                items[i].text = "режим «напрямую»"
            }
        }
        return items
    }

    public static func verdict(_ items: [VpnCheckItem]) -> VpnLeakVerdict {
        let bad = items.filter { $0.status == .fail && ["geo", "ipv6", "dns"].contains($0.id) }
        return VpnLeakVerdict(leak: !bad.isEmpty, detail: bad.map { "\($0.name): \($0.text.replacingOccurrences(of: "утечка: ", with: ""))" }.joined(separator: "; "))
    }

    public static func chips(_ items: [VpnCheckItem]) -> [VpnChip] {
        func item(_ id: String) -> VpnCheckItem? { items.first { $0.id == id } }
        guard !items.isEmpty, !items.allSatisfy({ $0.status == .skipped }) else { return [] }
        if items.allSatisfy({ $0.status == .pending }) { return [VpnChip(text: "проверяю связь…", status: .pending)] }
        var out: [VpnChip] = []
        if let r = item("ru") {
            out.append(VpnChip(text: r.status == .ok ? "РФ-сайты открываются" : "РФ-сайты не открываются", status: r.status))
        }
        if let b = item("blocked") {
            out.append(VpnChip(text: b.status == .ok ? "заблокированные открываются" : "заблокированные не открываются", status: b.status))
        }
        let v = verdict(items)
        if v.leak {
            out.append(VpnChip(text: "утечка", status: .fail))
        } else if ["geo", "ipv6", "dns"].contains(where: { item($0)?.status == .warn }) {
            out.append(VpnChip(text: "утечки не подтверждены", status: .warn))
        } else {
            out.append(VpnChip(text: "утечек нет", status: .ok))
        }
        return out
    }

    public static func externalAddress(_ items: [VpnCheckItem]) -> String? {
        guard let g = items.first(where: { $0.id == "geo" }), g.status == .ok || g.status == .fail || g.status == .warn,
              g.text.contains("·") else { return nil }
        return g.text.replacingOccurrences(of: "утечка: ", with: "")
    }
}

public protocol VpnLeakFetching: Sendable {
    func once() async -> VpnLeakFetches
}

public struct URLSessionLeakFetcher: VpnLeakFetching {
    public init() {}

    static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    static func trace(_ url: String, timeout: TimeInterval = 8) async -> VpnFetch {
        guard let u = URL(string: url) else { return .failed("bad url") }
        do {
            let (data, resp) = try await session(timeout: timeout).data(from: u)
            return .response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        } catch { return .failed("\((error as NSError).code)") }
    }

    static func site(_ url: String, timeout: TimeInterval = 8) async -> VpnFetch {
        guard let u = URL(string: url) else { return .failed("bad url") }
        var r = URLRequest(url: u)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await session(timeout: timeout).bytes(for: r)
            return .response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: "")
        } catch { return .failed("\((error as NSError).code)") }
    }

    public func once() async -> VpnLeakFetches {
        async let geo = Self.trace("https://www.cloudflare.com/cdn-cgi/trace")
        async let v6 = Self.trace("https://[2606:4700:4700::1111]/cdn-cgi/trace")
        async let dns = Self.trace("https://1.1.1.1/cdn-cgi/trace")
        async let ru = Self.site("https://ya.ru")
        async let blocked = Self.site("https://www.instagram.com")
        return await VpnLeakFetches(geo: geo, ipv6: v6, dns: dns, ru: ru, blocked: blocked)
    }
}

public enum VpnLeakProbe {
    // A failing or warning check is re-measured once before it is reported.
    public static func run(mode: String, fetcher: VpnLeakFetching) async -> [VpnCheckItem] {
        var f = await fetcher.once()
        var items = VpnLeakLogic.evaluate(f, mode: mode)
        let retry = items.filter { $0.status == .fail || $0.status == .warn }.map { $0.id }
        if !retry.isEmpty {
            let again = await fetcher.once()
            if retry.contains("geo") { f.geo = again.geo }
            if retry.contains("dns") { f.dns = again.dns }
            if retry.contains("ru") { f.ru = again.ru }
            if retry.contains("blocked") { f.blocked = again.blocked }
            if retry.contains("ipv6") { f.ipv6 = again.ipv6 }
            items = VpnLeakLogic.evaluate(f, mode: mode)
        }
        return items
    }
}

@MainActor
public final class VpnChecksModel: ObservableObject {
    @Published public private(set) var items = VpnLeakLogic.pending()
    @Published public private(set) var running = false
    @Published public private(set) var lastRun: Date?
    @Published public private(set) var verdict = VpnLeakVerdict(leak: false, detail: "")
    public var onLeak: ((String) -> Void)?
    private var wasLeak = false
    private let fetcher: VpnLeakFetching
    private let clock: () -> Date

    public init(fetcher: VpnLeakFetching = URLSessionLeakFetcher(), clock: @escaping () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.clock = clock
    }

    public var chips: [VpnChip] { VpnLeakLogic.chips(items) }
    public var externalAddress: String? { VpnLeakLogic.externalAddress(items) }

    public func run(mode: String) async {
        guard !running else { return }
        running = true
        let result = await VpnLeakProbe.run(mode: mode, fetcher: fetcher)
        apply(result)
        running = false
    }

    public func apply(_ result: [VpnCheckItem]) {
        items = result
        lastRun = clock()
        verdict = VpnLeakLogic.verdict(result)
        Log.write("vpn checks " + result.map { "\($0.id)=\($0.status.rawValue)(\($0.text))" }.joined(separator: " "))
        if verdict.leak && !wasLeak { onLeak?(verdict.detail) }
        wasLeak = verdict.leak
    }

    public func skip(_ reason: String) {
        guard items.contains(where: { $0.status != .skipped || $0.text != reason }) else { return }
        items = VpnLeakLogic.skipped(reason)
        wasLeak = false
    }
}
