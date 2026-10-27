import Foundation
import Network
import SwiftUI
import MultitulCtlCore

public struct VpnRouteInput: Equatable, Sendable {
    public var netName = "сеть"
    public var netNote = ""
    public var mobile = false
    public var gateway: String?
    public var routerMs: Int?
    public var providerMs: Int?
    public var providerAddr: String?
    public var providerViaHTTPS = false
    public var vpsMs: Int?
    public var siteMs: Int?
    public var gstaticMs: Int?
    public var tunnelUp = true
    public var siteHost = "example.com"

    public init(netName: String = "сеть", netNote: String = "", mobile: Bool = false, gateway: String? = nil,
                routerMs: Int? = nil, providerMs: Int? = nil, providerAddr: String? = nil, providerViaHTTPS: Bool = false,
                vpsMs: Int? = nil, siteMs: Int? = nil, gstaticMs: Int? = nil, tunnelUp: Bool = true, siteHost: String = "example.com") {
        self.netName = netName
        self.netNote = netNote
        self.mobile = mobile
        self.gateway = gateway
        self.routerMs = routerMs
        self.providerMs = providerMs
        self.providerAddr = providerAddr
        self.providerViaHTTPS = providerViaHTTPS
        self.vpsMs = vpsMs
        self.siteMs = siteMs
        self.gstaticMs = gstaticMs
        self.tunnelUp = tunnelUp
        self.siteHost = siteHost
    }
}

public enum VpnHopStatus: Sendable { case ok, warn, unknown }

public struct VpnHop: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sub: String
    public let ms: Int?
    public let delta: Int?
    public let status: VpnHopStatus
}

public enum VpnVerdictKind: Equatable, Sendable {
    case ok, router, provider, server, site, serverDown, routerDown
}

public struct VpnRouteVerdict: Equatable, Sendable {
    public let kind: VpnVerdictKind
    public let title: String
    public let detail: String

    public var isProblem: Bool { kind != .ok }
}

public enum VpnRouteLimits {
    public static let router = 30
    public static let provider = 60
    public static let providerHTTPS = 250
    public static let server = 80
    public static let site = 300
}

public enum VpnRouteAnalysis {
    public static let vpsAddress = VpnEndpoint.serverAddress

    public static func analyze(_ m: VpnRouteInput) -> (hops: [VpnHop], verdict: VpnRouteVerdict) {
        var hops: [VpnHop] = []
        hops.append(VpnHop(id: "mac", name: "Мак", sub: "этот компьютер", ms: 0, delta: nil, status: .ok))
        var prev = 0

        func step(_ ms: Int?) -> Int? {
            guard let ms else { return nil }
            let d = max(0, ms - prev)
            prev = max(prev, ms)
            return d
        }

        let routerDelta = step(m.routerMs)
        let routerWarn = (m.routerMs ?? 0) > VpnRouteLimits.router
        hops.append(VpnHop(id: "router", name: "Роутер", sub: m.netName, ms: m.routerMs, delta: routerDelta,
                           status: m.routerMs == nil ? .unknown : (routerWarn ? .warn : .ok)))

        let provDelta = m.providerViaHTTPS ? nil : step(m.providerMs)
        let provWarn = m.providerViaHTTPS
            ? (m.providerMs ?? 0) > VpnRouteLimits.providerHTTPS
            : (provDelta ?? 0) > VpnRouteLimits.provider
        let provSub: String = {
            if m.providerViaHTTPS, m.providerAddr != nil { return "до ya.ru напрямую" }
            let base = m.mobile ? "мобильная сеть" : "первый узел"
            if let a = m.providerAddr { return "\(base) · \(a)" }
            return m.mobile ? base : "не определён"
        }()
        hops.append(VpnHop(id: "provider", name: "Провайдер", sub: provSub, ms: m.providerMs, delta: provDelta,
                           status: m.providerMs == nil ? .unknown : (provWarn ? .warn : .ok)))

        let vpsDelta = step(m.vpsMs)
        let vpsWarn = (vpsDelta ?? 0) > VpnRouteLimits.server
        hops.append(VpnHop(id: "vps", name: "Твой VPS", sub: "Финляндия, xray", ms: m.vpsMs, delta: vpsDelta,
                           status: m.vpsMs == nil ? .unknown : (vpsWarn ? .warn : .ok)))

        let siteDelta = step(m.siteMs)
        let siteWarn = (siteDelta ?? 0) > VpnRouteLimits.site
        var siteSub = "\(m.siteHost) через туннель"
        if !m.tunnelUp { siteSub = "VPN выключен" }
        else if m.siteMs == nil && m.gstaticMs != nil { siteSub = "\(m.siteHost) не отвечает" }
        else if let g = m.gstaticMs { siteSub += " · \(g) мс до generate_204" }
        hops.append(VpnHop(id: "site", name: "Сайт", sub: siteSub, ms: m.siteMs, delta: siteDelta,
                           status: m.siteMs == nil ? .unknown : (siteWarn ? .warn : .ok)))

        return (hops, verdict(m, provDelta: provDelta, vpsDelta: vpsDelta, siteDelta: siteDelta))
    }

    private static func verdict(_ m: VpnRouteInput, provDelta: Int?, vpsDelta: Int?, siteDelta: Int?) -> VpnRouteVerdict {
        if m.routerMs == nil && m.vpsMs == nil && m.providerMs == nil {
            return VpnRouteVerdict(kind: .routerDown, title: "Нет связи с сетью",
                                   detail: "Ни роутер, ни сервер не отвечают. Проверь Wi‑Fi или кабель.")
        }
        if m.vpsMs == nil && (m.routerMs != nil || m.providerMs != nil) {
            return VpnRouteVerdict(kind: .serverDown, title: "Сервер не отвечает",
                                   detail: "Сеть до провайдера работает, а до сервера \(vpsAddress) соединение не открывается.")
        }
        var cands: [(VpnVerdictKind, Double)] = []
        if let r = m.routerMs, r > VpnRouteLimits.router { cands.append((.router, Double(r) / Double(VpnRouteLimits.router))) }
        if let d = provDelta, d > VpnRouteLimits.provider { cands.append((.provider, Double(d) / Double(VpnRouteLimits.provider))) }
        if m.providerViaHTTPS, let p = m.providerMs, p > VpnRouteLimits.providerHTTPS { cands.append((.provider, Double(p) / Double(VpnRouteLimits.providerHTTPS))) }
        if let d = vpsDelta, d > VpnRouteLimits.server { cands.append((.server, Double(d) / Double(VpnRouteLimits.server))) }
        if let d = siteDelta, d > VpnRouteLimits.site { cands.append((.site, Double(d) / Double(VpnRouteLimits.site))) }
        guard let worst = cands.max(by: { $0.1 < $1.1 }) else {
            var parts: [String] = []
            if let r = m.routerMs { parts.append("роутер \(r) мс") }
            if let d = provDelta { parts.append("провайдер +\(d)") }
            if m.providerViaHTTPS, let p = m.providerMs { parts.append("ya.ru напрямую \(p) мс") }
            if let d = vpsDelta { parts.append("сервер +\(d)") }
            return VpnRouteVerdict(kind: .ok, title: "Всё в норме", detail: "Каждый участок в пределах нормы: " + parts.joined(separator: ", ") + ".")
        }
        let tail = " Значок не краснеет, пока сайты открываются."
        switch worst.0 {
        case .router:
            return VpnRouteVerdict(kind: .router, title: "Тормозит сеть до роутера, не VPN",
                                   detail: "Уже до роутера \(m.routerMs ?? 0) мс: \(m.netName). Дальше задержка растёт нормально." + tail)
        case .provider:
            let src = m.mobile ? "мобильная сеть" : m.netName
            let srv = vpsDelta.map { " Сервер добавляет \($0) мс — \($0 > VpnRouteLimits.server ? "много" : "норма")." } ?? ""
            return VpnRouteVerdict(kind: .provider, title: "Тормозит сеть до провайдера, не VPN",
                                   detail: "Задержка набирается до провайдера (+\(provDelta ?? m.providerMs ?? 0) мс): \(src).\(srv)" + tail)
        case .server:
            return VpnRouteVerdict(kind: .server, title: "Тормозит сервер",
                                   detail: "Сеть до провайдера в порядке, но до сервера добавляется +\(vpsDelta ?? 0) мс. Нагрузка на VPS или канал до него.")
        default:
            return VpnRouteVerdict(kind: .site, title: "Тормозит сайт, не VPN",
                                   detail: "До сервера быстро, а от сервера до \(m.siteHost) +\(siteDelta ?? 0) мс.")
        }
    }
}

public enum VpnNetParse {
    public static func physicalDefault(_ netstat: String) -> (iface: String, gateway: String)? {
        for line in netstat.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, f[0] == "default", f[3].hasPrefix("en"), VpnRuleDetect.isIPv4(f[1]) else { continue }
            return (f[3], f[1])
        }
        return nil
    }

    public static func portNames(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var port = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst(15)) }
            else if line.hasPrefix("Device: ") { out[String(line.dropFirst(8))] = port }
        }
        return out
    }

    public static func ssid(_ summary: String) -> String? {
        for raw in summary.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SSID : ") {
                let v = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if v.isEmpty || v.contains("redacted") { return nil }
                return v
            }
        }
        return nil
    }

    public static func firstPublicHop(_ trace: String, gateway: String) -> String? {
        for line in trace.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 2, Int(f[0]) != nil, VpnRuleDetect.isIPv4(f[1]) else { continue }
            let ip = f[1]
            if ip == gateway || VpnConnLogic.isPrivateIP(ip) || ip.hasPrefix("0.") { continue }
            return ip
        }
        return nil
    }

    public static func pingMedian(_ out: String) -> Double? {
        var v: [Double] = []
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: "time=") else { continue }
            let rest = line[r.upperBound...]
            if let n = Double(rest.prefix { $0.isNumber || $0 == "." }) { v.append(n) }
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return v[v.count / 2]
    }
}

public struct VpnNetInfo: Equatable, Sendable {
    public var iface: String
    public var gateway: String
    public var kind: String
    public var name: String
    public var note: String
    public var key: String { "\(iface)|\(gateway)|\(note)" }
}

public protocol VpnRouteProbing: Sendable {
    func measure(tunnelUp: Bool, mobile: Bool) async -> VpnRouteInput
}

final class VpnOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

final class VpnPartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: VpnRouteInput
    init(_ v: VpnRouteInput) { self.v = v }
    var value: VpnRouteInput { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout VpnRouteInput) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

final class VpnRouteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (ip: String?, at: Date)] = [:]
    func get(_ key: String) -> (ip: String?, at: Date)? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func set(_ key: String, _ ip: String?, _ at: Date) { lock.lock(); items[key] = (ip, at); lock.unlock() }
}

// Chain: Mac -> router -> provider -> VPS -> site. pf blocks traceroute while the tunnel is up,
// so the provider hop falls back to a ya.ru delay measured by the core over the "direct" outbound.
final class SystemRouteProbe: VpnRouteProbing, @unchecked Sendable {
    static let vpsPort: UInt16 = 443
    static let siteURL = "https://example.com"
    static let budget = 6.0

    private let client: ClashAPI
    private let runner: ProcessRunning
    private let cache = VpnRouteCache()
    private let clock: @Sendable () -> Date

    init(client: ClashAPI, runner: ProcessRunning = SystemProcessRunner(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.runner = runner
        self.clock = clock
    }

    private func shell(_ path: String, _ args: [String], timeout: Double) async -> String? {
        let r = runner
        return await Task.detached { () -> String? in
            let o = r.run(path, args, timeout: timeout)
            return o.timedOut ? nil : o.stdout
        }.value
    }

    func detect() async -> VpnNetInfo? {
        guard let ns = await shell("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 2),
              let d = VpnNetParse.physicalDefault(ns) else { return nil }
        async let ports = shell("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 2)
        async let summary = shell("/usr/sbin/ipconfig", ["getsummary", d.iface], timeout: 2)
        let port = VpnNetParse.portNames(await ports ?? "")[d.iface] ?? ""
        let ssid = VpnNetParse.ssid(await summary ?? "")
        let hotspot = d.gateway == "172.20.10.1"
        var kind = "other", name = port.isEmpty ? d.iface : port
        if port.contains("Wi-Fi") {
            kind = "wifi"
            name = ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
        } else if port.contains("Ethernet") || port.contains("LAN") {
            kind = "ethernet"
            name = "Ethernet"
        }
        if hotspot { name += " · раздача с iPhone" }
        return VpnNetInfo(iface: d.iface, gateway: d.gateway, kind: kind, name: name, note: hotspot ? "hotspot" : "")
    }

    func ping(_ ip: String, iface: String) async -> Int? {
        guard let out = await shell("/sbin/ping", ["-b", iface, "-c", "3", "-i", "0.2", "-t", "3", ip], timeout: 4.5),
              let ms = VpnNetParse.pingMedian(out) else { return nil }
        return max(0, Int(ms.rounded()))
    }

    func providerAddr(net: VpnNetInfo) async -> String? {
        let now = clock()
        if let h = cache.get(net.key), h.ip != nil || now.timeIntervalSince(h.at) < 30 { return h.ip }
        guard let tr = await shell("/usr/sbin/traceroute", ["-n", "-m", "5", "-q", "1", "-w", "1", "-i", net.iface, "1.1.1.1"], timeout: 4.5)
        else { return nil }
        let ip = VpnNetParse.firstPublicHop(tr, gateway: net.gateway)
        if !Task.isCancelled { cache.set(net.key, ip, now) }
        return ip
    }

    func providerPing(net: VpnNetInfo) async -> (String?, Int?) {
        guard let ip = await providerAddr(net: net) else { return (nil, nil) }
        return (ip, await ping(ip, iface: net.iface))
    }

    static func lookupInterface(_ name: String) async -> NWInterface? {
        await withCheckedContinuation { (c: CheckedContinuation<NWInterface?, Never>) in
            let m = NWPathMonitor()
            let q = DispatchQueue(label: "dev.multitool.app.vpn.iflookup")
            let once = VpnOnce()
            m.pathUpdateHandler = { path in
                guard once.take() else { return }
                m.cancel()
                c.resume(returning: path.availableInterfaces.first { $0.name == name })
            }
            m.start(queue: q)
            q.asyncAfter(deadline: .now() + 0.8) {
                guard once.take() else { return }
                m.cancel()
                c.resume(returning: nil)
            }
        }
    }

    static func tcpOnce(host: String, port: UInt16, iface: NWInterface?, kind: String, timeout: Double) async -> Double? {
        let params = NWParameters.tcp
        if let i = iface { params.requiredInterface = i }
        else if kind == "wifi" { params.requiredInterfaceType = .wifi }
        else if kind == "ethernet" { params.requiredInterfaceType = .wiredEthernet }
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let q = DispatchQueue(label: "dev.multitool.app.vpn.tcpprobe")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
                let once = VpnOnce()
                let t0 = DispatchTime.now()
                conn.stateUpdateHandler = { st in
                    switch st {
                    case .ready:
                        guard once.take() else { return }
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
                        conn.cancel()
                        c.resume(returning: ms)
                    case .failed, .cancelled:
                        guard once.take() else { return }
                        conn.cancel()
                        c.resume(returning: nil)
                    default: break
                    }
                }
                conn.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) {
                    guard once.take() else { return }
                    conn.cancel()
                    c.resume(returning: nil)
                }
            }
        } onCancel: { conn.cancel() }
    }

    func vpsTCP(net: VpnNetInfo) async -> Int? {
        let iface = await Self.lookupInterface(net.iface)
        var v: [Double] = []
        for _ in 0..<3 {
            if Task.isCancelled { break }
            if let ms = await Self.tcpOnce(host: VpnRouteAnalysis.vpsAddress, port: Self.vpsPort, iface: iface, kind: net.kind, timeout: 1.3) { v.append(ms) }
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return Int(v[v.count / 2].rounded())
    }

    func measure(tunnelUp: Bool, mobile: Bool) async -> VpnRouteInput {
        let box = VpnPartialBox({ var i = VpnRouteInput(); i.mobile = mobile; i.tunnelUp = tunnelUp; return i }())
        let client = self.client
        let work = Task {
            guard let net = await detect() else { return }
            box.update { $0.netName = net.name; $0.gateway = net.gateway; $0.netNote = net.kind }
            await withTaskGroup(of: Void.self) { g in
                g.addTask {
                    let ms = await self.ping(net.gateway, iface: net.iface)
                    box.update { $0.routerMs = ms }
                }
                g.addTask {
                    async let traced = self.providerPing(net: net)
                    async let viaCore: Int? = {
                        guard tunnelUp else { return nil }
                        _ = try? await client.delay(timeoutMs: 2500, url: "https://ya.ru", proxy: "direct")
                        return try? await client.delay(timeoutMs: 2500, url: "https://ya.ru", proxy: "direct")
                    }()
                    var (ip, ms) = await traced
                    let fallback = await viaCore
                    var viaHTTPS = false
                    if ms == nil, let d = fallback {
                        ip = "ya.ru"; ms = d; viaHTTPS = true
                    }
                    box.update { $0.providerAddr = ip; $0.providerMs = ms; $0.providerViaHTTPS = viaHTTPS }
                }
                g.addTask {
                    let ms = await self.vpsTCP(net: net)
                    box.update { $0.vpsMs = ms }
                }
                if tunnelUp {
                    g.addTask {
                        let ms = try? await client.delay(timeoutMs: 4000, url: Self.siteURL, proxy: "vps")
                        box.update { $0.siteMs = ms }
                    }
                    g.addTask {
                        let ms = try? await client.delay(timeoutMs: 4000)
                        box.update { $0.gstaticMs = ms }
                    }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = VpnOnce()
            Task {
                await work.value
                if once.take() { c.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.budget * 1_000_000_000))
                work.cancel()
                if once.take() { c.resume() }
            }
        }
        return box.value
    }
}

@MainActor
public final class VpnRouteModel: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var input: VpnRouteInput?
    @Published public private(set) var hops: [VpnHop] = []
    @Published public private(set) var verdict: VpnRouteVerdict?
    @Published public private(set) var measuredAt: Date?

    private let probe: VpnRouteProbing
    private let clock: () -> Date
    private var generation = 0

    public init(probe: VpnRouteProbing, clock: @escaping () -> Date = { Date() }) {
        self.probe = probe
        self.clock = clock
    }

    public func measure(tunnelUp: Bool, mobile: Bool) async {
        generation += 1
        let mine = generation
        running = true
        let r = await probe.measure(tunnelUp: tunnelUp, mobile: mobile)
        guard mine == generation else { return }
        let a = VpnRouteAnalysis.analyze(r)
        input = r
        hops = a.hops
        verdict = a.verdict
        measuredAt = clock()
        running = false
        Log.write("vpn route verdict=\(a.verdict.kind) router=\(r.routerMs.map(String.init) ?? "-") provider=\(r.providerMs.map(String.init) ?? "-") vps=\(r.vpsMs.map(String.init) ?? "-") site=\(r.siteMs.map(String.init) ?? "-") https=\(r.providerViaHTTPS)")
    }

    public func cancel() {
        generation += 1
        running = false
    }
}
