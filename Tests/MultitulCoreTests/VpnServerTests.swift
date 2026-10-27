import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FakeAdmin: VpnAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [VpnAdminCommand] = []
    var responses: [String: String] = [:]
    var calls: [VpnAdminCommand] { lock.lock(); defer { lock.unlock() }; return _calls }

    func call(_ command: VpnAdminCommand) -> Result<Data, VpnServerError> {
        lock.lock(); _calls.append(command); lock.unlock()
        guard let a = command.arguments else { return .failure(.remote("command not allowed")) }
        guard let r = responses[a[0]] else { return .failure(.unreachable("нет связи")) }
        return .success(Data(r.utf8))
    }
}

final class HungAdmin: VpnAdminRunning, @unchecked Sendable {
    let gate: DispatchSemaphore
    init(gate: DispatchSemaphore) { self.gate = gate }
    func call(_ command: VpnAdminCommand) -> Result<Data, VpnServerError> {
        gate.wait()
        return .failure(.unreachable("late"))
    }
}

final class FakePasteboard: VpnPasteboarding {
    var changeCount = 0
    var text: String?
    func clearContents() { changeCount += 1; text = nil }
    func setString(_ s: String) { changeCount += 1; text = s }
}

let healthJSON = Data("""
{"xray": true, "nginx": true, "cpu_percent": 42.3, "load": [1.4091796875, 1.609375, 1.80615234375], "cpus": 2, "ram_used": 1968607232, "ram_total": 4106096640, "disk_free": 8722026496, "disk_total": 31615700992, "uptime_s": 5213620, "cert_not_after": "2026-12-12T18:59:20+00:00", "vnstat_month": {"iface": "eth0", "rx": 7310336811, "tx": 4764197011}}
""".utf8)
let statsJSON = #"{"month": "2026-10", "users": [{"email": "home", "up": 51693, "down": 109123, "last_seen": "2026-10-03T02:16:42+03:00"}, {"email": "mac", "up": 770388277, "down": 2210965496, "last_seen": "2026-10-03T02:29:00+03:00"}, {"email": "test-del", "up": 589, "down": 3066, "last_seen": null}]}"#
let usersJSON = #"{"users": [{"email": "home", "level": 0, "notorrent": false, "created": null}, {"email": "mac", "level": 0, "notorrent": false, "created": null}, {"email": "friend", "level": 0, "notorrent": true, "created": "2026-10-03"}]}"#

@Suite struct VpnServerParseTests {
    let now = VpnServerParse.date("2026-10-03T02:30:00+03:00")!

    @Test func healthParsesAllFields() throws {
        guard case .success(let h) = VpnServerParse.health(healthJSON) else { Issue.record("health parse"); return }
        #expect(h.xray && h.nginx && h.cpus == 2 && h.cpuPercent == 42.3 && h.load.count == 3)
        #expect(h.ramUsed == 1968607232 && h.diskFree == 8722026496 && h.uptime == 5213620)
        #expect(h.vnstat == VpnVnstatMonth(iface: "eth0", rx: 7310336811, tx: 4764197011))
        #expect(VpnServerLogic.monthTotal(h) == 12074533822)
        #expect(VpnServerLogic.certDays(h, now: now) == 70)
        #expect(h.xrayVersion == nil)
    }

    @Test func healthWithNullsAndLevels() throws {
        let noVn = Data(#"{"xray": false, "nginx": true, "cpu_percent": 99, "load": [3, 3, 3], "cpus": 2, "ram_used": 1, "ram_total": 2, "disk_free": 1, "disk_total": 100, "uptime_s": 5, "cert_not_after": null, "vnstat_month": null}"#.utf8)
        guard case .success(let h2) = VpnServerParse.health(noVn) else { Issue.record("nulls"); return }
        #expect(h2.vnstat == nil && h2.certNotAfter == nil && !h2.xray)
        let lv = VpnServerLogic.levels(h2, now: now)
        #expect(lv.xray == .alarm && lv.load == .warn && lv.cpu == .warn && lv.disk == .warn && lv.cert == .ok)
        guard case .success(let h) = VpnServerParse.health(healthJSON) else { return }
        let good = VpnServerLogic.levels(h, now: now)
        #expect(good.xray == .ok && good.load == .ok && good.cpu == .ok && good.ram == .ok && good.disk == .ok && good.cert == .ok)
        var c = h
        c.certNotAfter = VpnServerParse.date("2026-10-20T00:00:00+00:00")
        #expect(VpnServerLogic.levels(c, now: now).cert == .warn)
        c.certNotAfter = VpnServerParse.date("2026-10-05T00:00:00+00:00")
        #expect(VpnServerLogic.levels(c, now: now).cert == .alarm)
        c.load = [2.0, 2.0, 2.0]
        #expect(VpnServerLogic.levels(c, now: now).load == .ok)
        c.load = [2.4, 2.0, 1.9]
        #expect(VpnServerLogic.levels(c, now: now).load == .warn)
    }

    @Test func uptimeText() {
        #expect(VpnServerLogic.uptimeText(5213620) == "60 д 8 ч" && VpnServerLogic.uptimeText(3700) == "1 ч 1 мин" && VpnServerLogic.uptimeText(120) == "2 мин")
    }

    @Test func errorsSurface() {
        #expect(VpnServerParse.health(Data(#"{"error": "command not allowed"}"#.utf8)) == .failure(.remote("command not allowed")))
        #expect(VpnServerParse.health(Data("garbage".utf8)) == .failure(.badOutput))
        #expect(VpnServerParse.health(Data(#"{"xray": true}"#.utf8)) == .failure(.badOutput))
        #expect(VpnServerError.remote("user exists").text == "Такой ключ уже есть")
        #expect(VpnServerError.remote("something").text == "Сервер ответил: something")
    }

    @Test func statsUsersAndRows() throws {
        guard case .success(let st) = VpnServerParse.stats(Data(statsJSON.utf8)), case .success(let us) = VpnServerParse.users(Data(usersJSON.utf8)) else {
            Issue.record("stats/users"); return
        }
        #expect(st.month == "2026-10" && st.users.count == 3 && st.users["mac"]?.down == 2210965496)
        #expect(st.users["test-del"]?.lastSeen == nil && st.users["home"]?.lastSeen != nil)
        #expect(us.count == 3 && us[2].notorrent && us[2].created == "2026-10-03" && us[0].created == nil)
        let rows = VpnServerLogic.rows(users: us, stats: st, now: now)
        #expect(rows.map(\.name) == ["home", "mac", "friend"])
        #expect(rows[0].label == "Домашний сервер" && rows[1].label == "Этот Мак" && rows[2].label == "Друг")
        #expect(rows[1].online && !rows[0].online && !rows[2].online)
        #expect(rows[2].up == 0 && rows[2].lastSeen == nil)
        #expect(VpnServerLogic.limits(rows[2]) == "без торрентов" && VpnServerLogic.limits(rows[0]) == "нет")
        #expect(VpnServerLogic.rows(users: us, stats: nil, now: now).allSatisfy { !$0.online })
    }

    @Test func linkAndOk() {
        if case .success(let l) = VpnServerParse.link(Data(#"{"name": "x", "link": "vless://abc@h:443?x=1#x"}"#.utf8)) { #expect(l.hasPrefix("vless://")) } else { Issue.record("link") }
        #expect(VpnServerParse.link(Data(#"{"error": "no such user"}"#.utf8)) == .failure(.remote("no such user")))
        #expect(VpnServerParse.link(Data(#"{"link": "http://x"}"#.utf8)) == .failure(.badOutput))
        #expect(VpnServerParse.ok(Data(#"{"ok": true, "restart_needed": false}"#.utf8)) == .success(false))
        #expect(VpnServerParse.ok(Data(#"{"ok": true, "restart_needed": true}"#.utf8)) == .success(true))
        #expect(VpnServerParse.ok(Data(#"{"ok": false}"#.utf8)) == .failure(.badOutput))
    }

    @Test func nameValidationAndRelativeTime() {
        #expect(VpnServerLogic.validName("a") && VpnServerLogic.validName("test-ui") && VpnServerLogic.validName("a_b-9") && VpnServerLogic.validName("0abc"))
        #expect(VpnServerLogic.validName(String(repeating: "a", count: 32)) && !VpnServerLogic.validName(String(repeating: "a", count: 33)))
        #expect(!VpnServerLogic.validName("") && !VpnServerLogic.validName("-a") && !VpnServerLogic.validName("_a"))
        #expect(!VpnServerLogic.validName("Abc") && !VpnServerLogic.validName("a b") && !VpnServerLogic.validName("имя") && !VpnServerLogic.validName("a.b"))
        #expect(!VpnServerLogic.validName("abc\n") && !VpnServerLogic.validName("a;rm"))
        #expect(VpnServerLogic.nameError("", existing: []) == nil && VpnServerLogic.nameError("ok-name", existing: ["mac"]) == nil)
        #expect(VpnServerLogic.nameError("Bad", existing: []) != nil && VpnServerLogic.nameError("mac", existing: ["mac"]) == "Такой ключ уже есть")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let n = VpnServerParse.date("2026-10-03T15:00:00+03:00")!
        func rel(_ iso: String?) -> String { VpnServerLogic.relative(iso.flatMap { VpnServerParse.date($0) }, now: n, calendar: cal) }
        #expect(rel(nil) == "не подключался" && rel("2026-10-03T14:58:00+03:00") == "сейчас")
        #expect(rel("2026-10-03T14:30:00+03:00") == "30 мин назад" && rel("2026-10-03T12:00:00+03:00") == "3 ч назад")
        #expect(rel("2026-10-02T22:10:00+03:00") == "вчера, 22:10" && rel("2026-09-28T09:05:00+03:00") == "28.09, 09:05")
        #expect(VpnServerLogic.isOnline(n.addingTimeInterval(-299), now: n) && !VpnServerLogic.isOnline(n.addingTimeInterval(-300), now: n))
    }
}

@Suite struct VpnAdminRunnerTests {
    @Test func commandsMatchForcedCommandGrammar() {
        #expect(VpnAdminCommand.health.arguments == ["health"])
        #expect(VpnAdminCommand.stats.arguments == ["stats"] && VpnAdminCommand.users.arguments == ["users"])
        #expect(VpnAdminCommand.link("friend-1").arguments == ["link", "friend-1"])
        #expect(VpnAdminCommand.add("friend-1", noTorrent: true).arguments == ["add", "friend-1", "--no-torrent"])
        #expect(VpnAdminCommand.add("friend-1", noTorrent: false).arguments == ["add", "friend-1"])
        #expect(VpnAdminCommand.revoke("friend-1").arguments == ["revoke", "friend-1"])
        #expect(VpnAdminCommand.revoke("mac").arguments == nil)
        #expect(VpnAdminCommand.add("Bad Name", noTorrent: false).arguments == nil)
        #expect(VpnAdminCommand.link("a;rm -rf").arguments == nil)
        #expect(VpnAdminCommand.link("имя").arguments == nil)
        #expect(VpnAdminCommand.add("x", noTorrent: true).timeout > VpnAdminCommand.health.timeout)
    }

    private func make(_ r: FakeRunner, keyExists: Bool = true) -> SshVpnAdminRunner {
        SshVpnAdminRunner(runner: r, keyPath: "/k/multitul_vpn", host: "root@h", keyExists: { _ in keyExists })
    }

    @Test func buildsSshCommandWithKeyAndBatchMode() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 0, stdout: #"{"users": []}"#)
        let res = make(r).call(.users)
        #expect(res == .success(Data(#"{"users": []}"#.utf8)))
        #expect(r.calls.count == 1 && r.calls[0].0 == "/usr/bin/ssh")
        let a = r.calls[0].1
        #expect(a.starts(with: ["-i", "/k/multitul_vpn"]))
        #expect(a.contains("BatchMode=yes") && a.contains("IdentitiesOnly=yes"))
        #expect(Array(a.suffix(2)) == ["root@h", "users"])
    }

    @Test func missingKeyTimeoutAndEmptyOutput() {
        let r = FakeRunner()
        #expect(make(r, keyExists: false).call(.health) == .failure(.unreachable("Нет ключа ~/.ssh/multitul_vpn")))
        #expect(r.calls.isEmpty)
        r.result = ProcessOutput(status: 255, stdout: "", stderr: "denied")
        #expect(make(r).call(.health) == .failure(.unreachable("Нет связи с сервером по ssh")))
        r.result = ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true)
        #expect(make(r).call(.health) == .failure(.unreachable("Сервер не ответил за 20 с")))
    }

    @Test func refusedCommandNeverReachesSsh() {
        let r = FakeRunner()
        #expect(make(r).call(.revoke("mac")) == .failure(.remote("command not allowed")))
        #expect(r.calls.isEmpty)
    }
}

@MainActor
@Suite struct VpnServerModelTests {
    let clock = DateBox(Date(timeIntervalSince1970: 1_790_000_000))

    private func make(_ fake: FakeAdmin) -> VpnServerModel {
        VpnServerModel(runner: fake, clock: { [clock] in clock.date })
    }

    private func full() -> FakeAdmin {
        let f = FakeAdmin()
        f.responses = ["health": String(decoding: healthJSON, as: UTF8.self), "stats": statsJSON, "users": usersJSON,
                       "link": #"{"name": "n", "link": "vless://id@h:443#n"}"#, "add": #"{"ok": true, "restart_needed": false}"#,
                       "revoke": #"{"ok": true, "restart_needed": false}"#]
        return f
    }

    @Test func hungRunnerEndsWithTimeoutErrorInsteadOfSpinningForever() async {
        let gate = DispatchSemaphore(value: 0)
        let hung = HungAdmin(gate: gate)
        let m = VpnServerModel(runner: hung, clock: { [clock] in clock.date }, hardLimit: { _ in 0.2 })
        await m.refreshKeys(force: true)
        #expect(!m.loadingKeys)
        #expect(m.keysError?.contains("не ответил") == true)
        await m.refreshHealth(force: true)
        #expect(!m.loadingHealth && m.healthError?.contains("не ответил") == true)
        for _ in 0..<3 { gate.signal() }
    }

    @Test func healthIsCachedForAMinute() async {
        let f = full(); let m = make(f)
        await m.refreshHealth()
        await m.refreshHealth()
        #expect(m.health != nil && f.calls.filter { $0 == .health }.count == 1)
        clock.advance(61)
        await m.refreshHealth()
        #expect(f.calls.filter { $0 == .health }.count == 2)
        await m.refreshHealth(force: true)
        #expect(f.calls.filter { $0 == .health }.count == 3)
    }

    @Test func healthErrorKeepsOldValue() async {
        let f = full(); let m = make(f)
        await m.refreshHealth()
        f.responses["health"] = nil
        await m.refreshHealth(force: true)
        #expect(m.health != nil && m.healthError == "нет связи")
    }

    @Test func keysCombineUsersAndStats() async {
        let f = full(); let m = make(f)
        await m.refreshKeys()
        #expect(m.keys.map(\.name) == ["home", "mac", "friend"])
        #expect(m.keys[1].down == 2210965496 && m.keysError == nil)
    }

    @Test func statsFailureStillShowsKeysWithWarning() async {
        let f = full(); f.responses["stats"] = nil
        let m = make(f)
        await m.refreshKeys()
        #expect(m.keys.count == 3 && (m.keysError ?? "").hasPrefix("Статистика недоступна"))
    }

    @Test func usersFailureSetsError() async {
        let f = full(); f.responses["users"] = #"{"error": "xray api unavailable"}"#
        let m = make(f)
        await m.refreshKeys()
        #expect(m.keys.isEmpty && m.keysError == "Сервер ответил: xray api unavailable")
    }

    @Test func addCreatesThenRefreshesAndReturnsLink() async {
        let f = full(); let m = make(f)
        let r = await m.add("friend-1", noTorrent: true)
        #expect(r == .ok(link: "vless://id@h:443#n", restartNeeded: false))
        #expect(f.calls.contains(.add("friend-1", noTorrent: true)))
        #expect(f.calls.contains(.users) && m.keys.count == 3)
    }

    @Test func addRejectsBadNameWithoutCalling() async {
        let f = full(); let m = make(f)
        #expect(await m.add("Bad Name", noTorrent: false) == .failed("Недопустимое имя"))
        #expect(f.calls.isEmpty)
    }

    @Test func addReportsServerErrorAndMissingLink() async {
        let f = full(); f.responses["add"] = #"{"error": "user exists"}"#
        let m = make(f)
        #expect(await m.add("mac2", noTorrent: false) == .failed("Такой ключ уже есть"))
        f.responses["add"] = #"{"ok": true, "restart_needed": true}"#
        f.responses["link"] = nil
        if case .createdNoLink(let t) = await m.add("mac3", noTorrent: false) { #expect(t.contains("Ключ создан")) } else { Issue.record("expected createdNoLink") }
    }

    @Test func revokeProtectsMacAndReportsRestartHint() async {
        let f = full(); let m = make(f)
        #expect(await m.revoke("mac") == "Этот ключ не отзывается")
        #expect(f.calls.isEmpty)
        #expect(await m.revoke("friend") == nil)
        #expect(f.calls.contains(.revoke("friend")))
        f.responses["revoke"] = #"{"ok": true, "restart_needed": true}"#
        #expect((await m.revoke("home") ?? "").contains("перезапуска xray"))
        f.responses["revoke"] = #"{"error": "no such user"}"#
        #expect(await m.revoke("ghost") == "Такого ключа нет на сервере")
    }

    @Test func linkRoundTrip() async {
        let f = full(); let m = make(f)
        #expect(await m.link("home") == .success("vless://id@h:443#n"))
        f.responses["link"] = #"{"error": "no such user"}"#
        #expect(await m.link("ghost") == .failure(.remote("no such user")))
    }
}

@MainActor
@Suite struct VpnClipboardTests {
    @MainActor final class Timers {
        var pending: [(TimeInterval, @MainActor () -> Void)] = []
        func schedule(_ d: TimeInterval, _ w: @escaping @MainActor () -> Void) { pending.append((d, w)) }
        func fireAll() { let p = pending; pending = []; p.forEach { $0.1() } }
    }

    @Test func clearsAfterSixtySecondsIfUntouched() {
        let pb = FakePasteboard(); let t = Timers()
        let c = VpnSecretClipboard(pasteboard: pb, schedule: t.schedule)
        c.copy("vless://secret")
        #expect(pb.text == "vless://secret" && t.pending.count == 1 && t.pending[0].0 == 60)
        t.fireAll()
        #expect(pb.text == nil)
    }

    @Test func doesNotClearSomethingElseTheUserCopied() {
        let pb = FakePasteboard(); let t = Timers()
        let c = VpnSecretClipboard(pasteboard: pb, schedule: t.schedule)
        c.copy("vless://secret")
        pb.clearContents(); pb.setString("my own text")
        t.fireAll()
        #expect(pb.text == "my own text")
    }
}

@Suite struct VpnQRTests {
    @Test func rendersSquareImageAndRoundTrips() {
        let link = "vless://11111111-2222-3333-4444-555555555555@vpn.example.org:443?encryption=none&security=tls&sni=vpn.example.org&type=ws&host=vpn.example.org&path=%2Fwsx#test"
        guard let img = VpnQR.cgImage(link) else { Issue.record("no qr"); return }
        #expect(img.width == img.height && img.width % 8 == 0)
        #expect(VpnQR.decode(img) == link)
    }
}
