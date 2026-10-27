import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FakeLeakFetcher: VpnLeakFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var fetches: VpnLeakFetches
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(_ f: VpnLeakFetches) { fetches = f }
    func once() async -> VpnLeakFetches { lock.lock(); _calls += 1; lock.unlock(); return fetches }
}

let traceFI = "fl=29f\nh=www.cloudflare.com\nip=203.0.113.10\nts=1.2\nloc=FI\ncolo=HEL\n"

func cleanFetches() -> VpnLeakFetches {
    VpnLeakFetches(geo: .response(status: 200, body: traceFI), ipv6: .failed("x"), dns: .response(status: 200, body: traceFI),
                   ru: .response(status: 302, body: ""), blocked: .response(status: 200, body: ""))
}

final class FakeSpeed: VpnSpeedRunning, @unchecked Sendable {
    var result: (bytes: Double, seconds: Double)? = (25_000_000, 2)
    func run(progress: @escaping @Sendable (Double, Double) -> Void) async -> (bytes: Double, seconds: Double)? {
        progress(5_000_000, 0.5)
        return result
    }
}

@MainActor
private struct HRig {
    let clash = FakeClash()
    let daemon = FakeDaemon()
    let control = FakeControl()
    let notices = NoticeBox()
    let clock = ClockBox()
    let history: VpnHistoryStore
    let fetcher = FakeLeakFetcher(cleanFetches())
    let speedRunner = FakeSpeed()
    let controller: VpnController

    init() {
        let h = try! makeHistory()
        history = h
        let defaults = InMemoryKeyValueStore()
        let dir = NSTemporaryDirectory() + "vpnctl-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = VpnRuleFiles(dir: dir, writer: LocalRuleWriter(dir: dir))
        let n = notices, c = clock, f = fetcher, sp = speedRunner
        controller = VpnController(client: clash, daemon: daemon, control: control, files: files, defaults: defaults,
                                   notifier: { kind, _, _ in n.add(kind) }, clock: { c.t },
                                   history: h, server: VpnServerModel(runner: FakeAdmin()),
                                   speed: VpnSpeedModel(makeRunner: { sp }, clock: { c.t }),
                                   checks: VpnChecksModel(fetcher: f, clock: { c.t }))
    }

    func settle() async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }
}

@MainActor
@Suite struct VpnControllerHistoryTests {
    @Test func watchdogRestartIsJournaled() async {
        let r = HRig()
        await r.controller.refreshDaemon()
        r.clash.apiUp = false
        r.clock.advance(30); await r.controller.probe()
        r.clock.advance(35); await r.controller.probe()
        await r.settle()
        let ev = r.history.events(limit: 10).filter { $0.kind == "watchdog" }
        #expect(ev.count == 1 && ev[0].detail.contains("перезапуск"))
    }

    @Test func dropOpensAndClosesAJournalEntry() async {
        let r = HRig()
        await r.controller.refreshDaemon()
        await r.controller.probe()
        r.clash.apiUp = false
        r.clash.delay = nil
        r.clock.advance(15); await r.controller.probe()
        r.clock.advance(61); await r.controller.probe()
        let open = r.history.events(limit: 10).filter { VpnEventKind.isDrop($0.kind) }
        #expect(open.count == 1 && open[0].isOpen)
        r.clash.apiUp = true
        r.clash.delay = 40
        r.clock.advance(15); await r.controller.probe()
        r.clock.advance(15); await r.controller.probe()
        let closed = r.history.events(limit: 10).filter { VpnEventKind.isDrop($0.kind) }
        #expect(closed.count == 1 && !closed[0].isOpen && closed[0].duration! > 0)
    }

    @Test func controllerStartClosesStaleDrops() async {
        let r = HRig()
        r.history.insertEvent(start: r.clock.t, end: nil, kind: "net", detail: "старый обрыв")
        r.controller.start()
        r.controller.stop()
        #expect(r.history.events(limit: 5).first!.detail.hasSuffix("(приложение перезапущено)"))
    }

    @Test func speedResultBecomesEvent() async {
        let r = HRig()
        await r.controller.speed.run()
        #expect(r.controller.speed.phase == .done(12.5))
        let e = r.history.events(limit: 5).first!
        #expect(e.kind == "speed" && e.detail == "12,5 МБ/с · 25 МБ за 2,0 с")
    }

    @Test func leakIsJournaledAndNotifiedOnce() async {
        let r = HRig()
        var f = cleanFetches()
        f.ipv6 = .response(status: 200, body: "ip=2a00::1\nloc=RU\n")
        r.fetcher.fetches = f
        await r.controller.checks.run(mode: "Rule")
        #expect(r.controller.checks.verdict.leak)
        let leaks = r.history.events(limit: 5).filter { $0.kind == "leak" }
        #expect(leaks.count == 1 && leaks[0].detail.contains("IPv6"))
        #expect(r.notices.kinds.filter { $0 == "leak" }.count == 1)
        r.clock.advance(1)
        await r.controller.checks.run(mode: "Rule")
        #expect(r.history.events(limit: 5).filter { $0.kind == "leak" }.count == 1)
    }

    @Test func checksRunAfterWarmupThenEveryFiveMinutes() async {
        let r = HRig()
        await r.controller.refreshDaemon()
        await r.controller.probe()
        await r.controller.checksTick()
        #expect(r.fetcher.calls == 0)
        r.clock.advance(13)
        await r.controller.checksTick()
        #expect(r.fetcher.calls == 1 && r.controller.checks.chips.last?.text == "утечек нет")
        r.clock.advance(100)
        await r.controller.checksTick()
        #expect(r.fetcher.calls == 1)
        r.clock.advance(201)
        await r.controller.checksTick()
        #expect(r.fetcher.calls == 2)
    }

    @Test func checksAreSkippedWhileVpnIsOff() async {
        let r = HRig()
        r.daemon.status = VpnDaemonStatus(running: false, started: nil, disabled: false)
        await r.controller.refreshDaemon()
        await r.controller.checksTick()
        #expect(r.fetcher.calls == 0 && r.controller.checks.chips.isEmpty)
    }
}

@Suite struct VpnClashProxyDelayTests {
    private func make() -> (ClashClient, FakeTransport) {
        let t = FakeTransport()
        t.handler = { _ in (Data("{\"delay\": 55}".utf8), 200) }
        return (ClashClient(transport: t, provider: FakeSecret("k")), t)
    }

    @Test func delayForSiteThroughNamedOutbound() async throws {
        let (c, t) = make()
        #expect(try await c.delay(timeoutMs: 2500, url: "https://ya.ru", proxy: "direct") == 55)
        #expect(t.requests[0].url!.absoluteString == "http://127.0.0.1:9090/proxies/direct/delay?url=https%3A%2F%2Fya%2Eru&timeout=2500")
        #expect(t.requests[0].timeoutInterval == 5.5)
    }

    @Test func badProxyNameIsRejectedBeforeAnyRequest() async {
        let (c, t) = make()
        await #expect(throws: ClashError.badBody) { try await c.delay(timeoutMs: 1000, url: "https://x", proxy: "a/../b") }
        await #expect(throws: ClashError.badBody) { try await c.delay(timeoutMs: 1000, url: "https://x", proxy: "") }
        #expect(t.requests.isEmpty)
    }
}
