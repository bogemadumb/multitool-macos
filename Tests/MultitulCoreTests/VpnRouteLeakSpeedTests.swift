import Testing
import Foundation
@testable import MultitulCore

@Suite struct VpnRouteAnalysisTests {
    private func kind(_ i: VpnRouteInput) -> VpnVerdictKind { VpnRouteAnalysis.analyze(i).verdict.kind }

    @Test func homeNetworkIsFine() {
        let ok = VpnRouteInput(netName: "Ethernet", routerMs: 1, providerMs: 2, providerAddr: "185.1.1.1", vpsMs: 36, siteMs: 70, gstaticMs: 66)
        let a = VpnRouteAnalysis.analyze(ok)
        #expect(a.verdict.kind == .ok && a.verdict.title == "Всё в норме")
        #expect(a.hops.count == 5 && a.hops.map(\.id) == ["mac", "router", "provider", "vps", "site"])
        #expect(a.hops.allSatisfy { $0.status != .warn })
        #expect(!a.verdict.isProblem)
    }

    @Test func slowProviderBlamesProviderNotVpn() {
        let slow = VpnRouteInput(netName: "Wi-Fi", mobile: true, routerMs: 10, providerMs: 95, providerAddr: "100.64.0.1", vpsMs: 112, siteMs: 140, gstaticMs: 118)
        let a = VpnRouteAnalysis.analyze(slow)
        #expect(a.verdict.kind == .provider && a.verdict.title == "Тормозит сеть до провайдера, не VPN")
        #expect(a.hops[2].status == .warn && a.hops[3].status == .ok && a.hops[2].delta == 85)
        #expect(a.verdict.isProblem)
    }

    @Test func pfBlocksTracerouteFallsBackToYaRuOverHttps() {
        let ks = VpnRouteInput(netName: "Ethernet", routerMs: 1, providerMs: 55, providerAddr: "ya.ru", providerViaHTTPS: true, vpsMs: 8, siteMs: 68, gstaticMs: 69)
        let a = VpnRouteAnalysis.analyze(ks)
        #expect(a.verdict.kind == .ok)
        #expect(a.hops[2].delta == nil && a.hops[3].delta == 7 && a.hops[2].sub == "до ya.ru напрямую")
        #expect(a.verdict.detail.contains("ya.ru напрямую 55 мс"))
        let slow = VpnRouteInput(netName: "Wi-Fi", mobile: true, routerMs: 12, providerMs: 420, providerAddr: "ya.ru", providerViaHTTPS: true, vpsMs: 60, siteMs: 200, gstaticMs: 190)
        #expect(kind(slow) == .provider)
    }

    @Test func routerServerSiteAndDownVerdicts() {
        #expect(kind(VpnRouteInput(netName: "W", routerMs: 38, providerMs: 50, vpsMs: 112, siteMs: 140)) == .router)
        let srv = VpnRouteInput(netName: "Ethernet", routerMs: 1, providerMs: 3, vpsMs: 120, siteMs: 180)
        #expect(kind(srv) == .server && VpnRouteAnalysis.analyze(srv).verdict.title == "Тормозит сервер")
        #expect(kind(VpnRouteInput(netName: "E", routerMs: 1, providerMs: 3, vpsMs: 36, siteMs: 600)) == .site)
        #expect(kind(VpnRouteInput(netName: "E", routerMs: 1, providerMs: 3, vpsMs: nil)) == .serverDown)
        #expect(kind(VpnRouteInput(netName: "E")) == .routerDown)
    }

    @Test func limitsAndTiesAreInclusive() {
        #expect(kind(VpnRouteInput(netName: "E", routerMs: 30, providerMs: 90, vpsMs: 170, siteMs: 250)) == .ok)
        #expect(kind(VpnRouteInput(netName: "E", routerMs: 5, providerMs: 100, vpsMs: 400, siteMs: 450)) == .server)
    }

    @Test func vpnOffStillMeasuresPhysicalPath() {
        let off = VpnRouteInput(netName: "E", routerMs: 1, providerMs: 3, vpsMs: 36, siteMs: nil, gstaticMs: nil, tunnelUp: false)
        let a = VpnRouteAnalysis.analyze(off)
        #expect(a.verdict.kind == .ok && a.hops[4].sub == "VPN выключен")
        var silent = VpnRouteInput(netName: "E", routerMs: 1, providerMs: 2, providerAddr: "1.1.1.1", vpsMs: 36, siteMs: nil, gstaticMs: 60)
        #expect(VpnRouteAnalysis.analyze(silent).hops[4].sub.contains("не отвечает"))
        silent.providerMs = nil
        #expect(VpnRouteAnalysis.analyze(silent).hops[2].status == .unknown && VpnRouteAnalysis.analyze(silent).hops[3].delta == 35)
    }
}

@Suite struct VpnNetParseTests {
    @Test func netstatAndTraceroute() {
        let ns = "Destination        Gateway            Flags               Netif Expire\ndefault            192.168.1.1        UGScg                en12\ndefault            192.168.1.1        UGScIg                en0\n1                  172.19.0.1         UGSc                utun7\n"
        #expect(VpnNetParse.physicalDefault(ns)?.iface == "en12" && VpnNetParse.physicalDefault(ns)?.gateway == "192.168.1.1")
        #expect(VpnNetParse.physicalDefault("default 172.19.0.1 UGSc utun7\n") == nil)
        let tr = "traceroute to 1.1.1.1, 5 hops max\n 1  192.168.1.1  1.2 ms\n 2  *\n 3  10.5.5.5  4 ms\n 4  185.171.192.177  9 ms\n"
        #expect(VpnNetParse.firstPublicHop(tr, gateway: "192.168.1.1") == "185.171.192.177")
        #expect(VpnNetParse.firstPublicHop(" 1  192.168.1.1  1 ms\n 2  *\n", gateway: "192.168.1.1") == nil)
    }

    @Test func pingSsidAndPorts() {
        #expect(VpnNetParse.pingMedian("64 bytes from x: time=1.5 ms\n64 bytes from x: time=9.0 ms\n64 bytes from x: time=2.0 ms\n") == 2.0)
        #expect(VpnNetParse.pingMedian("Request timeout\n") == nil)
        #expect(VpnNetParse.ssid("  SSID : <redacted>\n") == nil && VpnNetParse.ssid("  SSID : Home\n") == "Home")
        #expect(VpnNetParse.portNames("Hardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: USB LAN\nDevice: en12\n")["en12"] == "USB LAN")
    }
}

final class FakeRouteProbe: VpnRouteProbing, @unchecked Sendable {
    var input = VpnRouteInput(netName: "Ethernet", routerMs: 1, providerMs: 2, vpsMs: 36, siteMs: 70)
    private(set) var asked: [(Bool, Bool)] = []
    func measure(tunnelUp: Bool, mobile: Bool) async -> VpnRouteInput {
        asked.append((tunnelUp, mobile))
        return input
    }
}

@MainActor
@Suite struct VpnRouteModelTests {
    @Test func measureFillsHopsAndVerdict() async {
        let p = FakeRouteProbe()
        let m = VpnRouteModel(probe: p, clock: { Date(timeIntervalSince1970: 5) })
        await m.measure(tunnelUp: true, mobile: false)
        #expect(m.hops.count == 5 && m.verdict?.kind == .ok && !m.running)
        #expect(m.measuredAt == Date(timeIntervalSince1970: 5))
        #expect(p.asked.count == 1 && p.asked[0] == (true, false))
    }

    @Test func slowVpsIsReportedAsServerProblem() async {
        let p = FakeRouteProbe()
        p.input = VpnRouteInput(netName: "Ethernet", routerMs: 1, providerMs: 3, vpsMs: 120, siteMs: 180)
        let m = VpnRouteModel(probe: p)
        await m.measure(tunnelUp: true, mobile: false)
        #expect(m.verdict?.title == "Тормозит сервер")
    }
}

@Suite struct VpnLeakLogicTests {
    @Test func traceParser() {
        #expect(VpnLeakLogic.parseTrace(traceFI)["loc"] == "FI" && VpnLeakLogic.parseTrace(traceFI)["ip"] == "203.0.113.10")
        #expect(VpnLeakLogic.parseTrace("garbage\n\n=x\nloc = RU \r\n")["loc"] == "RU")
    }

    @Test func geoCheck() {
        #expect(VpnLeakLogic.geo(.response(status: 200, body: traceFI)).status == .ok)
        #expect(VpnLeakLogic.geo(.response(status: 200, body: "ip=198.51.100.68\nloc=RU\n")).status == .fail)
        #expect(VpnLeakLogic.geo(.response(status: 200, body: "ip=9.9.9.9\nloc=FI\n")).status == .ok)
        #expect(VpnLeakLogic.geo(.response(status: 200, body: "ip=198.51.100.131\nloc=SE\n")).status == .ok)
        #expect(VpnLeakLogic.dns(.response(status: 200, body: "ip=198.51.100.131\nloc=SE\n")).status == .ok)
        #expect(VpnLeakLogic.geo(.failed("timeout")).status == .warn)
        #expect(VpnLeakLogic.geo(.response(status: 403, body: "")).status == .warn)
    }

    @Test func ipv6Probe() {
        #expect(VpnLeakLogic.ipv6(.failed("no route")).status == .ok)
        #expect(VpnLeakLogic.ipv6(.response(status: 200, body: "ip=2a00::1\nloc=FI\n")).status == .ok)
        let leak = VpnLeakLogic.ipv6(.response(status: 200, body: "ip=2a00::1\nloc=RU\n"))
        #expect(leak.status == .fail && leak.text == "утечка: RU · 2a00::1")
    }

    @Test func dnsProbe() {
        #expect(VpnLeakLogic.dns(.response(status: 200, body: traceFI)).status == .ok)
        #expect(VpnLeakLogic.dns(.response(status: 200, body: "loc=RU\n")).status == .fail)
        #expect(VpnLeakLogic.dns(.failed("x")).status == .warn)
    }

    @Test func siteReachability() {
        #expect(VpnLeakLogic.site(id: "ru", name: "x", .response(status: 302, body: "")).status == .ok)
        #expect(VpnLeakLogic.site(id: "ru", name: "x", .response(status: 503, body: "")).status == .fail)
        #expect(VpnLeakLogic.site(id: "ru", name: "x", .failed("timeout")).status == .fail)
    }

    @Test func cleanRunChipsAndExternalAddress() {
        let items = VpnLeakLogic.evaluate(cleanFetches(), mode: "Rule")
        #expect(!VpnLeakLogic.verdict(items).leak)
        #expect(VpnLeakLogic.chips(items) == [VpnChip(text: "РФ-сайты открываются", status: .ok),
                                              VpnChip(text: "заблокированные открываются", status: .ok),
                                              VpnChip(text: "утечек нет", status: .ok)])
        #expect(VpnLeakLogic.externalAddress(items) == "FI · 203.0.113.10")
    }

    @Test func leakDetectedAndModeDirectSkipsIpv6Dns() {
        var bad = cleanFetches()
        bad.ipv6 = .response(status: 200, body: "ip=2a00::1\nloc=RU\n")
        let items = VpnLeakLogic.evaluate(bad, mode: "Rule")
        #expect(VpnLeakLogic.verdict(items).leak && VpnLeakLogic.verdict(items).detail.contains("IPv6"))
        #expect(VpnLeakLogic.chips(items).last == VpnChip(text: "утечка", status: .fail))
        var direct = cleanFetches()
        direct.dns = .response(status: 200, body: "loc=RU\n")
        direct.ipv6 = .response(status: 200, body: "loc=RU\n")
        #expect(!VpnLeakLogic.verdict(VpnLeakLogic.evaluate(direct, mode: "Direct")).leak)
        #expect(VpnLeakLogic.verdict(VpnLeakLogic.evaluate(direct, mode: "Rule")).leak)
    }

    @Test func warningChipAndBlockedSiteChip() {
        var f = cleanFetches()
        f.geo = .failed("x")
        #expect(VpnLeakLogic.chips(VpnLeakLogic.evaluate(f, mode: "Rule")).last == VpnChip(text: "утечки не подтверждены", status: .warn))
        var b = cleanFetches()
        b.blocked = .failed("timeout")
        #expect(VpnLeakLogic.chips(VpnLeakLogic.evaluate(b, mode: "Rule"))[1].status == .fail)
    }

    @Test func chipsHiddenWhenOffAndPendingBeforeFirstRun() {
        #expect(VpnLeakLogic.chips(VpnLeakLogic.skipped("VPN выключен")).isEmpty)
        #expect(VpnLeakLogic.chips(VpnLeakLogic.pending()).first?.status == .pending)
    }

    @Test func failedCheckIsRemeasuredOnce() async {
        let f = FakeLeakFetcher(cleanFetches())
        f.fetches.dns = .response(status: 200, body: "loc=RU\n")
        let items = await VpnLeakProbe.run(mode: "Rule", fetcher: f)
        #expect(f.calls == 2 && items.first { $0.id == "dns" }?.status == .fail)
        let clean = FakeLeakFetcher(cleanFetches())
        _ = await VpnLeakProbe.run(mode: "Rule", fetcher: clean)
        #expect(clean.calls == 1)
    }
}

final class FlakySpeed: VpnSpeedRunning, @unchecked Sendable {
    var results: [(bytes: Double, seconds: Double)?]
    init(_ r: [(bytes: Double, seconds: Double)?]) { results = r }
    func run(progress: @escaping @Sendable (Double, Double) -> Void) async -> (bytes: Double, seconds: Double)? {
        results.isEmpty ? nil : results.removeFirst()
    }
}

@MainActor
@Suite struct VpnSpeedTests {
    @Test func mathAndFormat() {
        #expect(VpnSpeedMath.mbps(bytes: 25_000_000, seconds: 2) == 12.5 && VpnSpeedMath.format(12.5) == "12,5")
        #expect(VpnSpeedMath.mbps(bytes: 1, seconds: 0) == 0)
        #expect(VpnSpeedMath.eventDetail(mbps: 14.2, bytes: 25_000_000, seconds: 1.8) == "14,2 МБ/с · 25 МБ за 1,8 с")
        #expect(CloudflareSpeedTester.url == "https://speed.cloudflare.com/__down?bytes=25000000")
    }

    @Test func doneAndFailedPhases() async {
        let runner = FlakySpeed([(25_000_000, 2), nil])
        var got: [(Double, Double, Double)] = []
        let m = VpnSpeedModel(makeRunner: { runner }, clock: { Date(timeIntervalSince1970: 9) })
        m.onResult = { got.append(($0, $1, $2)) }
        #expect(m.phase == .idle && !m.isRunning)
        await m.run()
        #expect(m.phase == .done(12.5) && m.finishedAt == Date(timeIntervalSince1970: 9) && got.count == 1)
        await m.run()
        #expect(m.phase == .failed && got.count == 1)
    }
}
