import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

private func conn(_ id: String, path: String = "", host: String = "", ip: String = "1.1.1.1", chains: [String] = ["vps"], rule: String = "final",
                  down: Double = 0, up: Double = 0, start: String? = nil) -> ClashConn {
    var o: [String: Any] = ["id": id, "metadata": ["processPath": path, "host": host, "destinationIP": ip, "destinationPort": "443"],
                            "chains": chains, "rule": rule, "download": down, "upload": up]
    if let start { o["start"] = start }
    return ClashConn(json: o)!
}

private let placeholder = "{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}]}\n"

@MainActor
private func rulesRig(writer: ((String) -> VpnRuleWriting)? = nil) -> (VpnRulesModel, String) {
    let d = tmpDir()
    for n in ["direct", "proxy", "block"] { put(d, "\(n).json", placeholder) }
    put(d, "always-vps.json", "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.com\", \"example.net\"]}]}\n")
    let files = VpnRuleFiles(dir: d, writer: writer?(d) ?? LocalRuleWriter(dir: d))
    return (VpnRulesModel(files: files, browser: { .noBrowser }), d)
}

@MainActor
@Suite struct VpnConnectionsModelTests {
    private func make(_ clash: FakeClash) -> VpnConnectionsModel {
        let (rules, _) = rulesRig()
        return VpnConnectionsModel(client: clash, rules: rules)
    }

    @Test func rowsAreMappedFilteredAndSearched() async {
        let clash = FakeClash()
        clash.conns = [
            conn("a", path: "/Applications/Telegram.app/Contents/MacOS/Telegram (user)", host: "t.me", start: "2026-10-22T10:00:00+03:00"),
            conn("b", path: "/usr/bin/curl (user)", host: "example.gov", ip: "5.5.5.5", chains: ["direct"], rule: "rule_set=user-direct => route(direct)", start: "2026-10-22T10:05:00+03:00"),
            conn("c", ip: "192.168.1.20", chains: ["direct"], rule: "ip_is_private=true => route(direct)", start: "2026-10-22T09:00:00+03:00"),
            conn("d", host: "bad.example", chains: [], rule: "rule_set=user-block => reject")
        ]
        let m = make(clash)
        await m.poll()
        #expect(m.rows.map(\.id) == ["b", "a", "c", "d"])
        #expect(m.rows[0].app == "curl" && m.rows[0].route == .direct && m.rows[0].ruleText == "Мои: напрямую")
        #expect(m.rows[1].app == "Telegram" && m.rows[1].route == .vps)
        #expect(m.rows[2].app == "—" && m.rows[2].host == "192.168.1.20:443" && m.rows[2].route == .local)
        #expect(m.rows[3].route == .block)
        #expect(m.count(.all) == 4 && m.count(.vps) == 1 && m.count(.direct) == 1 && m.count(.local) == 1)
        m.filter = .direct
        #expect(m.visible.map(\.id) == ["b"])
        m.filter = .all
        m.search = "  TELE "
        #expect(m.visible.map(\.id) == ["a"])
        m.search = "example.gov"
        #expect(m.visible.map(\.id) == ["b"])
        m.search = "nothing"
        #expect(m.visible.isEmpty)
    }

    @Test func speedIsComputedFromTwoPolls() async {
        let clash = FakeClash()
        clash.conns = [conn("a", down: 1000, up: 0, start: "2026-10-22T10:00:00+03:00")]
        let m = make(clash)
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        await m.poll(at: t0)
        clash.conns = [conn("a", down: 11_000, up: 0, start: "2026-10-22T10:00:00+03:00")]
        await m.poll(at: t0.addingTimeInterval(2))
        #expect(m.rows[0].speed == 5000)
    }

    @Test func failureIsFlaggedAndRecovers() async {
        let clash = FakeClash()
        clash.apiUp = false
        let m = make(clash)
        await m.poll()
        #expect(m.failed && m.rows.isEmpty)
        clash.apiUp = true
        await m.poll()
        #expect(!m.failed)
    }

    @Test func dropClosesTheConnectionById() async {
        let clash = FakeClash()
        clash.conns = [conn("zz")]
        let m = make(clash)
        await m.poll()
        m.drop(m.rows[0])
        for _ in 0..<50 where clash.closed.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(clash.closed == ["zz"])
    }
}

@MainActor
@Suite struct VpnRulesModelTests {
    @Test func addListsRuleAndMovesBetweenTargets() async {
        let (m, d) = rulesRig()
        await m.reload()
        #expect(m.user.isEmpty && m.alwaysVps == ["example.com", "example.net"])
        #expect(await m.add(kind: .domainSuffix, value: "example.com", target: .direct))
        #expect(m.user == [VpnUserRule(target: .direct, kind: .domainSuffix, value: "example.com")])
        #expect(await m.add(kind: .domainSuffix, value: "example.com", target: .proxy))
        #expect(m.user == [VpnUserRule(target: .proxy, kind: .domainSuffix, value: "example.com")])
        #expect(slurp(d, "direct.json") == placeholder)
        await m.remove(m.user[0])
        #expect(m.user.isEmpty && slurp(d, "proxy.json") == placeholder)
    }

    @Test func alwaysVpsFileIsNeverWritten() async {
        let (m, d) = rulesRig()
        let before = slurp(d, "always-vps.json")
        _ = await m.add(kind: .domainSuffix, value: "example.org", target: .direct)
        _ = await m.add(kind: .processName, value: "claude", target: .block)
        #expect(slurp(d, "always-vps.json") == before)
        #expect(VpnRuleTarget.allCases.map(\.rawValue).contains("always-vps") == false)
    }

    @Test func writerFailureSurfacesAsToastAndLeavesFilesAlone() async {
        let fail = FailingRuleWriter()
        let (m, d) = rulesRig { _ in fail }
        let ok = await m.add(kind: .domainSuffix, value: "a.example", target: .direct)
        #expect(!ok)
        #expect(m.toast?.contains("Не удалось записать правило") == true)
        #expect(slurp(d, "direct.json") == placeholder && fail.writes.count == 1)
    }

    @Test func corruptFileBlocksAllWrites() async {
        let fail = FailingRuleWriter()
        let (m, d) = rulesRig { _ in fail }
        put(d, "block.json", "not json")
        let ok = await m.add(kind: .domainSuffix, value: "a.example", target: .direct)
        #expect(!ok && fail.writes.isEmpty)
        #expect(slurp(d, "block.json") == "not json")
    }

    @Test func currentSiteFromBrowserBecomesDirectRule() async {
        let (m, d) = rulesRig()
        await m.applyBrowser(.url("https://www.Example.com/procedures?x=1"))
        #expect(m.siteNote == "example.com — теперь напрямую")
        #expect(slurp(d, "direct.json").contains("\"domain_suffix\": [\"example.com\"]"))
        await m.applyBrowser(.url("https://example.com/other"))
        #expect(m.siteNote == "example.com уже напрямую")
    }

    @Test func browserProblemsAreExplained() async {
        let (m, d) = rulesRig()
        await m.applyBrowser(.noBrowser)
        #expect(m.siteNote == "Открой сайт в Safari или Chrome")
        await m.applyBrowser(.denied)
        #expect(m.siteNote?.contains("Автоматизация") == true)
        await m.applyBrowser(.url("about:blank"))
        #expect(m.siteNote == "В браузере нет открытого сайта")
        #expect(slurp(d, "direct.json") == placeholder)
    }

    @Test func ruleListShowsBuiltinsMineAndKeepsAlwaysVpsRule() {
        let mine = [VpnUserRule(target: .proxy, kind: .domainSuffix, value: "p.example"),
                    VpnUserRule(target: .block, kind: .ipCidr, value: "1.2.3.4/32"),
                    VpnUserRule(target: .direct, kind: .processName, value: "curl")]
        let items = VpnRuleList.items(user: mine, alwaysVps: ["example.com", "example.net"])
        let claude = items.first { $0.id == "always-vps" }
        #expect(claude?.route == .vps && claude?.note == "example.com, example.net" && claude?.user == nil)
        let userIDs = items.compactMap(\.user).map(\.value)
        #expect(userIDs == ["1.2.3.4/32", "curl", "p.example"])
        #expect(items.last?.id == "final" && items.contains { $0.id == "ru" })
        #expect(items.compactMap(\.user).map { $0.target.route } == [.block, .direct, .vps])
        #expect(VpnRuleList.items(user: [], alwaysVps: []).contains { $0.id == "mine-empty" })
    }
}

@Suite struct VpnModuleRegistryTests {
    @Test func vpnModuleIsDescribedCorrectly() {
        let i = ModuleID.vpn.info
        #expect(i.group == .net && i.title == "VPN" && !i.enabledByDefault)
        #expect(i.permissions.contains(.notifications) && i.permissions.contains(.automation))
        #expect(i.hotkeys.count == 1 && i.hotkeys[0].id == "vpn.open")
        #expect(i.hotkeys[0].defaultCombo == KeyCombo(keyCode: 9, modifiers: KeyCombo.opt | KeyCombo.cmd))
        #expect(ModuleID.vpn.enabledKey == "module.vpn.enabled")
    }

    @Test func allIdentifiersAreAscii() {
        for id in ModuleID.allCases { #expect(id.rawValue.allSatisfy { $0.isASCII }) }
        for k in [VpnKeys.intentOn, VpnKeys.killSwitch, VpnKeys.notifications, VpnKeys.watchdog, VpnKeys.showShield] { #expect(k.allSatisfy { $0.isASCII }) }
    }
}

@Suite struct VpnPrivilegedRulesTests {
    final class Spy: ProcessRunning, @unchecked Sendable {
        var args: [String] = []
        var staged: String?
        var stagedMode: Int?
        var result = ProcessOutput(status: 0)
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
            args = arguments
            if let p = arguments.last, p.hasSuffix(".json") {
                staged = FileManager.default.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) }
                stagedMode = ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue
            }
            return result
        }
    }

    private func make(_ s: Spy) -> (PrivilegedCtl, String) {
        let stg = NSTemporaryDirectory() + "multitul-stg-\(UUID().uuidString)"
        return (PrivilegedCtl(runner: s, stagingDir: stg, binaryExists: { _ in true }), stg)
    }

    @Test func stagesFileCallsCtlAndCleansUp() throws {
        let spy = Spy()
        let (ctl, stg) = make(spy)
        try ctl.vpnRulesWrite(target: "direct", data: Data("DATA".utf8))
        #expect(Array(spy.args.prefix(5)) == ["-n", "/usr/local/libexec/multitul-ctl", "vpn", "rules", "write"])
        #expect(spy.args.last!.hasPrefix(stg + "/rules-") && spy.args.last!.hasSuffix("/direct.json"))
        #expect(spy.staged == "DATA" && spy.stagedMode == 0o600)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stg)) == [])
    }

    @Test func unknownTargetNeverReachesSudo() {
        let spy = Spy()
        let (ctl, _) = make(spy)
        #expect(throws: CtlError.self) { try ctl.vpnRulesWrite(target: "always-vps", data: Data("x".utf8)) }
        #expect(spy.args.isEmpty)
    }

    @Test func ctlRefusalIsReportedAndStagingStillCleaned() {
        let spy = Spy()
        spy.result = ProcessOutput(status: 2, stderr: "rules: bad cidr")
        let (ctl, stg) = make(spy)
        do { try ctl.vpnRulesWrite(target: "block", data: Data("x".utf8)); Issue.record("expected throw") } catch let CtlError.failed(r) {
            #expect(r.exitCode == 2 && r.stderr.contains("bad cidr"))
        } catch { Issue.record("wrong error \(error)") }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stg)) == [])
    }
}
