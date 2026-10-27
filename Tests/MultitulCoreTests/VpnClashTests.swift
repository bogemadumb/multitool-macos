import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FakeTransport: ClashTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var handler: @Sendable (URLRequest) -> (Data, Int) = { _ in (Data("{}".utf8), 200) }

    private func record(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        record(request)
        return handler(request)
    }

    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        record(request)
        return (200, AsyncThrowingStream { $0.finish() })
    }
}

final class FakeSecret: ClashSecretProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var value: String?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(_ value: String?) { self.value = value }
    func secret() -> String? { lock.lock(); _calls += 1; lock.unlock(); return value }
}

final class ClockBox: @unchecked Sendable {
    var t = Date(timeIntervalSince1970: 3_000_000_000)
    func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite struct VpnClashTests {
    private func make(secret: String? = "s3cr3t", clock: ClockBox = ClockBox()) -> (ClashClient, FakeTransport, FakeSecret) {
        let t = FakeTransport(), p = FakeSecret(secret)
        return (ClashClient(transport: t, provider: p, clock: { clock.t }), t, p)
    }

    @Test func secretIsFetchedLazilyAndSentAsBearer() async throws {
        let (c, t, p) = make()
        #expect(p.calls == 0)
        t.handler = { _ in (json("{\"version\": \"sing-box 1.14.0\"}"), 200) }
        #expect(try await c.version() == "sing-box 1.14.0")
        #expect(p.calls == 1)
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer s3cr3t")
        #expect(t.requests[0].url?.absoluteString == "http://127.0.0.1:9090/version")
        _ = try await c.version()
        #expect(p.calls == 1)
    }

    @Test func missingSecretThrowsAndRetriesOncePerMinute() async {
        let clock = ClockBox()
        let (c, t, p) = make(secret: nil, clock: clock)
        await #expect(throws: ClashError.noSecret) { try await c.version() }
        await #expect(throws: ClashError.noSecret) { try await c.version() }
        #expect(p.calls == 1 && t.requests.isEmpty)
        clock.advance(61)
        p.value = "late"
        #expect((try? await c.version()) == nil)
        #expect(p.calls == 2)
        #expect(t.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer late")
    }

    @Test func httpErrorsAreMapped() async {
        let (c, t, _) = make()
        t.handler = { _ in (Data(), 401) }
        await #expect(throws: ClashError.http(401)) { try await c.version() }
        await #expect(throws: ClashError.http(401)) { try await c.setMode("Global") }
    }

    @Test func configsAndModePatch() async throws {
        let (c, t, _) = make()
        t.handler = { _ in (json("{\"mode\": \"Global\", \"mode-list\": [\"Rule\", \"Global\", \"Direct\"]}"), 200) }
        let cfg = try await c.configs()
        #expect(cfg.mode == "Global" && cfg.modes == ["Rule", "Global", "Direct"])
        try await c.setMode("Direct")
        let r = t.requests.last!
        #expect(r.httpMethod == "PATCH" && r.url?.path == "/configs")
        #expect(String(data: r.httpBody ?? Data(), encoding: .utf8) == "{\"mode\":\"Direct\"}")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func unknownModeIsNeverSent() async {
        let (c, t, _) = make()
        await #expect(throws: ClashError.badBody) { try await c.setMode("Evil") }
        #expect(t.requests.isEmpty)
    }

    @Test func delayUsesVpsProxyAndEncodedProbeUrl() async throws {
        let (c, t, _) = make()
        t.handler = { _ in (json("{\"delay\": 87}"), 200) }
        #expect(try await c.delay(timeoutMs: 5000) == 87)
        let u = t.requests[0].url!.absoluteString
        #expect(u == "http://127.0.0.1:9090/proxies/vps/delay?url=https%3A%2F%2Fwww%2Egstatic%2Ecom%2Fgenerate%5F204&timeout=5000")
        #expect(t.requests[0].timeoutInterval == 8)
    }

    @Test func closeConnectionEncodesId() async throws {
        let (c, t, _) = make()
        try await c.closeConnection("ab-12/../x")
        let r = t.requests[0]
        #expect(r.httpMethod == "DELETE")
        #expect(r.url?.absoluteString == "http://127.0.0.1:9090/connections/ab-12%2F%2E%2E%2Fx")
    }

    private let connsJSON = """
    {"downloadTotal": 5000, "uploadTotal": 700, "connections": [
      {"id": "c1", "metadata": {"processPath": "/Applications/Telegram.app/Contents/MacOS/Telegram (user)", "host": "t.me", "destinationIP": "149.154.167.99", "destinationPort": "443", "network": "tcp"},
       "chains": ["vps"], "rule": "final", "download": 1000, "upload": 100, "start": "2026-10-22T10:00:00.123456+03:00"},
      {"id": "c2", "metadata": {"processPath": "", "host": "", "destinationIP": "192.168.1.20", "destinationPort": "22"},
       "chains": ["direct"], "rule": "ip_is_private=true => route(direct)", "download": 5, "upload": 5},
      {"metadata": {}}
    ]}
    """

    @Test func connectionsAndTotalsParse() async throws {
        let (c, t, _) = make()
        t.handler = { _ in (json(self.connsJSON), 200) }
        let list = try await c.connections()
        #expect(list.count == 2)
        #expect(list[0].id == "c1" && list[0].chains == ["vps"] && list[0].download == 1000 && list[0].start != nil)
        #expect(VpnConnLogic.processName(list[0].processPath) == "Telegram")
        #expect(list[1].host == "" && list[1].destPort == "22" && list[1].start == nil)
        let totals = try await c.totals()
        #expect(totals.down == 5000 && totals.up == 700)
    }

    @Test func trafficLinesParse() {
        let s = VpnConnLogic.parseTrafficLine("{\"up\":1200,\"down\":34000}")
        #expect(s?.up == 1200 && s?.down == 34000)
        #expect(VpnConnLogic.parseTrafficLine("garbage") == nil)
    }

    @Test func keychainProviderAsksSecurityToolOnly() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 0, stdout: "topsecret\n")
        #expect(KeychainClashSecret(runner: r).secret() == "topsecret")
        #expect(r.calls[0].0 == "/usr/bin/security")
        #expect(r.calls[0].1 == ["find-generic-password", "-s", "dev.vpnstatusbar.clash", "-a", NSUserName(), "-w"])
        r.result = ProcessOutput(status: 44, stderr: "not found")
        #expect(KeychainClashSecret(runner: r).secret() == nil)
        r.result = ProcessOutput(status: 0, stdout: "  \n")
        #expect(KeychainClashSecret(runner: r).secret() == nil)
        r.result = ProcessOutput(status: 0, stdout: "x", timedOut: true)
        #expect(KeychainClashSecret(runner: r).secret() == nil)
    }
}

@Suite struct VpnDaemonTests {
    private let running = """
    system/dev.multitool.singbox = {
    \tactive count = 1
    \tstate = running
    \tpid = 4242
    }
    """

    @Test func parsesLaunchctlPrint() {
        let p = VpnDaemonParse.running(running)
        #expect(p.running && p.pid == 4242)
        let q = VpnDaemonParse.running("system/dev.multitool.singbox = {\n\tstate = waiting\n}")
        #expect(!q.running && q.pid == nil)
    }

    @Test func probeReportsRunning() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 0, stdout: running)
        let s = LaunchctlDaemonProbe(runner: r).read()
        #expect(s.running && !s.disabled)
        #expect(r.calls.first?.0 == "/bin/launchctl" && r.calls.first?.1 == ["print", "system/dev.multitool.singbox"])
    }

    @Test func probeReportsDisabledWhenStopped() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 113, stdout: "disabled services = {\n\t\"dev.multitool.singbox\" => disabled\n}\n")
        let s = LaunchctlDaemonProbe(runner: r).read()
        #expect(!s.running && s.disabled && s.started == nil)
    }

    @Test func killSwitchStatusParsing() {
        let r = FakeRunner()
        let ctl = PrivilegedCtl(runner: r, stagingDir: NSTemporaryDirectory() + "x", binaryExists: { _ in true })
        let control = PrivilegedVpnControl(ctl: ctl)
        r.result = ProcessOutput(status: 0, stdout: "killswitch: on\n")
        #expect(control.killSwitchStatus() == true)
        r.result = ProcessOutput(status: 0, stdout: "killswitch: off\n")
        #expect(control.killSwitchStatus() == false)
        r.result = ProcessOutput(status: 1, stderr: "sudo: a password is required")
        #expect(control.killSwitchStatus() == nil)
        #expect(control.turnOn() != nil)
        r.result = ProcessOutput(status: 0)
        #expect(control.turnOn() == nil && control.restart() == nil && control.setKillSwitch(true))
        #expect(r.calls.last?.1 == ["-n", "/usr/local/libexec/multitul-ctl", "vpn", "killswitch", "on"])
    }
}
