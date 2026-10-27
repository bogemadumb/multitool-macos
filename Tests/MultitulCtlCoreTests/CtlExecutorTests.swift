import Testing
import Foundation
@testable import MultitulCtlCore

final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    var calls: [String] = []
    var handler: (String, [String]) -> ProcessOutput = { _, _ in ProcessOutput(status: 0) }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        calls.append(([executable] + arguments).joined(separator: " "))
        return handler(executable, arguments)
    }
}

private struct Rig {
    let runner = ScriptedRunner()
    let dir: String
    let stagingDir: String
    var out: [String] { box.out }
    var err: [String] { box.err }
    let box = LogBox()
    var kills: [(Int32, Int32)] { box.kills }

    init() {
        dir = NSTemporaryDirectory() + "multitul-ctl-\(UUID().uuidString)"
        stagingDir = dir + "/staging"
        try? FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
    }

    func executor(euid: uid_t = 0, killErrno: Int32 = 0) -> CtlExecutor {
        var paths = CtlPaths()
        paths.configDir = dir
        paths.killswitchRules = dir + "/killswitch.pf"
        paths.killswitchToken = dir + "/token"
        paths.singbox = "/usr/bin/true"
        let ctx = CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: [stagingDir])
        let box = self.box
        return CtlExecutor(runner: runner, paths: paths, context: ctx, trustedUid: getuid(), euid: euid, tunnelAttempts: 2,
                           sleeper: { _ in }, killer: { pid, sig in box.kills.append((pid, sig)); return killErrno },
                           out: { box.out.append($0) }, err: { box.err.append($0) })
    }
}

final class LogBox: @unchecked Sendable {
    var out: [String] = []
    var err: [String] = []
    var kills: [(Int32, Int32)] = []
}

private let currentConfig = """
{"inbounds":[{"type":"tun"}],"outbounds":[{"type":"vless","uuid":"11111111-2222","password":"pw"}],"experimental":{"clash_api":{"secret":"s3cr3t","external_controller":"127.0.0.1:9090"}}}
"""

private let multiConfig = """
{"outbounds":[{"type":"vless","tag":"fin","uuid":"aaaaaaaa-0001"},{"type":"vless","tag":"bvpn-nl","uuid":"bbbbbbbb-0002"},{"type":"vless","tag":"bvpn-lt","uuid":"bbbbbbbb-0002"},{"type":"direct","tag":"direct"}],"experimental":{"clash_api":{"secret":"s3cr3t"}}}
"""

@Suite struct CtlExecutorTests {
    @Test func vpnOnFallsBackToKickstart() {
        let rig = Rig()
        rig.runner.handler = { _, a in ProcessOutput(status: a.first == "bootstrap" ? 5 : 0) }
        #expect(rig.executor().execute(.vpn(.on)) == 0)
        #expect(rig.runner.calls == [
            "/bin/launchctl enable system/dev.multitool.singbox",
            "/bin/launchctl bootstrap system /Library/LaunchDaemons/dev.multitool.singbox.plist",
            "/bin/launchctl kickstart -k system/dev.multitool.singbox"
        ])
    }

    @Test func vpnOffDropsKillswitchFirst() {
        let rig = Rig()
        #expect(rig.executor().execute(.vpn(.off)) == 0)
        let pf = rig.runner.calls.firstIndex { $0.contains("pfctl") }
        let boot = rig.runner.calls.firstIndex { $0.contains("bootout") }
        #expect(pf != nil && boot != nil && pf! < boot!)
        #expect(rig.runner.calls.last == "/bin/launchctl disable system/dev.multitool.singbox")
    }

    @Test func powerAndPurgeCommands() {
        let rig = Rig()
        let e = rig.executor()
        #expect(e.execute(.powerDisableSleep(true)) == 0)
        #expect(e.execute(.powerDisableSleep(false)) == 0)
        #expect(e.execute(.memPurge) == 0)
        #expect(rig.runner.calls == ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0", "/usr/sbin/purge"])
    }

    @Test func procKillRespectsGuardsAndReportsErrno() {
        let rig = Rig()
        #expect(rig.executor().execute(.procKill(pid: 1, signal: SIGTERM)) == CtlExit.usage)
        #expect(rig.executor().execute(.procKill(pid: 500, signal: SIGTERM)) == CtlExit.usage)
        #expect(rig.executor().execute(.procKill(pid: 400, signal: SIGTERM)) == CtlExit.usage)
        #expect(rig.kills.isEmpty)
        #expect(rig.executor().execute(.procKill(pid: 900, signal: SIGKILL)) == 0)
        #expect(rig.kills.count == 1 && rig.kills[0].0 == 900 && rig.kills[0].1 == SIGKILL)
        #expect(rig.executor(killErrno: ESRCH).execute(.procKill(pid: 901, signal: SIGTERM)) == CtlExit.failure)
    }

    @Test func smcWithoutDeviceIsUnavailable() {
        let rig = Rig()
        #expect(rig.executor().execute(.smcFanAuto(.index(0))) == CtlExit.unavailable)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func selftestNeedsRoot() {
        #expect(Rig().executor(euid: 0).execute(.selftest) == 0)
        #expect(Rig().executor(euid: 501).execute(.selftest) == CtlExit.noPermission)
    }

    @Test func killswitchRulesKeepVpsAndTunnelExceptions() {
        let text = Rig().executor().killswitchRulesText()
        #expect(text.contains("pass out quick inet to 203.0.113.10"))
        #expect(text.contains("utun15"))
        #expect(text.hasSuffix("block drop out quick inet6 all\n"))
    }

    @Test func killswitchStatusParsesPfctl() {
        let rig = Rig()
        rig.runner.handler = { _, _ in ProcessOutput(status: 0, stdout: "block drop out quick inet all\n") }
        _ = rig.executor().execute(.vpn(.killswitch(.status)))
        #expect(rig.out == ["killswitch: on"])
    }

    @Test func showMasksSecrets() throws {
        let rig = Rig()
        try currentConfig.write(toFile: rig.dir + "/config.json", atomically: true, encoding: .utf8)
        #expect(rig.executor().execute(.vpn(.show)) == 0)
        let text = rig.out.joined()
        #expect(text.contains("__UUID__") && text.contains("__CLASH_SECRET__") && text.contains("__MASKED__"))
        #expect(!text.contains("s3cr3t") && !text.contains("11111111") && !text.contains("\"pw\""))
    }

    @Test func applyRejectsPathOutsideAllowedDirs() throws {
        let rig = Rig()
        let outside = NSTemporaryDirectory() + "multitul-outside-\(UUID().uuidString).json"
        try "{}".write(toFile: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        #expect(rig.executor().execute(.vpn(.apply(path: outside))) == CtlExit.badStaged)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func applyRejectsSymlinkEscapingAllowedDir() throws {
        let rig = Rig()
        let target = rig.dir + "/secret.json"
        try "{}".write(toFile: target, atomically: true, encoding: .utf8)
        let link = rig.stagingDir + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(rig.executor().execute(.vpn(.apply(path: link))) == CtlExit.badStaged)
    }

    @Test func applyHappyPathFillsPlaceholdersAndKeepsBackup() throws {
        let rig = Rig()
        try currentConfig.write(toFile: rig.dir + "/config.json", atomically: true, encoding: .utf8)
        let staged = rig.stagingDir + "/s.json"
        try #"{"outbounds":[{"type":"vless","uuid":"__UUID__"}],"experimental":{"clash_api":{"secret":"__CLASH_SECRET__"}}}"#
            .write(toFile: staged, atomically: true, encoding: .utf8)
        rig.runner.handler = { exe, a in
            if exe == "/bin/launchctl", a.first == "print" { return ProcessOutput(status: 0, stdout: "state = running") }
            if exe == "/sbin/ifconfig" { return ProcessOutput(status: 0, stdout: "inet 172.19.0.1") }
            if exe == "/usr/bin/curl" { return ProcessOutput(status: 0, stdout: "204") }
            return ProcessOutput(status: 0)
        }
        #expect(rig.executor().execute(.vpn(.apply(path: staged))) == 0)
        let written = try String(contentsOfFile: rig.dir + "/config.json", encoding: .utf8)
        #expect(written.contains("11111111-2222") && written.contains("s3cr3t") && !written.contains("__UUID__"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: rig.dir).filter { $0.hasPrefix("config.json.backup-") }
        #expect(backups.count == 1)
        #expect(rig.out.last?.hasPrefix("apply: ok") == true)
    }

    @Test func applyRollsBackWhenTunnelStaysDown() throws {
        let rig = Rig()
        try currentConfig.write(toFile: rig.dir + "/config.json", atomically: true, encoding: .utf8)
        let staged = rig.stagingDir + "/s.json"
        try #"{"outbounds":[{"uuid":"__UUID__","marker":"new"}]}"#.write(toFile: staged, atomically: true, encoding: .utf8)
        rig.runner.handler = { exe, a in
            if exe == "/bin/launchctl", a.first == "print" { return ProcessOutput(status: 0, stdout: "state = waiting") }
            return ProcessOutput(status: 0)
        }
        #expect(rig.executor().execute(.vpn(.apply(path: staged))) == CtlExit.rolledBack)
        let restored = try String(contentsOfFile: rig.dir + "/config.json", encoding: .utf8)
        #expect(restored == currentConfig)
        #expect(rig.err.contains { $0.contains("rolling back") })
        #expect(rig.runner.calls.filter { $0.contains("kickstart") }.count == 2)
    }

    @Test func applyKeepsConfigWhenSingboxCheckFails() throws {
        let rig = Rig()
        try currentConfig.write(toFile: rig.dir + "/config.json", atomically: true, encoding: .utf8)
        let staged = rig.stagingDir + "/s.json"
        try #"{"outbounds":[{"uuid":"__UUID__"}]}"#.write(toFile: staged, atomically: true, encoding: .utf8)
        rig.runner.handler = { exe, _ in exe == "/usr/bin/true" ? ProcessOutput(status: 1, stderr: "bad config") : ProcessOutput(status: 0) }
        #expect(rig.executor().execute(.vpn(.apply(path: staged))) == CtlExit.checkFailed)
        #expect(try String(contentsOfFile: rig.dir + "/config.json", encoding: .utf8) == currentConfig)
        #expect(!rig.runner.calls.contains { $0.contains("kickstart") })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.dir).filter { $0.hasPrefix(".staged.") }
        #expect(leftovers.isEmpty)
    }
}

@Suite struct VpnConfigTests {
    @Test func maskRoundTripPlaceholders() throws {
        let masked = try VpnConfig.mask(Data(currentConfig.utf8))
        let filled = try VpnConfig.fill(staged: masked, current: Data(currentConfig.utf8))
        let a = try JSONSerialization.jsonObject(with: filled) as? [String: Any]
        let ob = (a?["outbounds"] as? [[String: Any]])?.first
        #expect(ob?["uuid"] as? String == "11111111-2222")
        #expect(ob?["password"] as? String == "__MASKED__")
    }

    @Test func fillRejectsBrokenInput() {
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: Data("not json".utf8), current: Data(currentConfig.utf8)) }
    }

    @Test func loneUuidPlaceholderNeedsExactlyOneUuid() throws {
        let staged = Data(#"{"o":{"uuid":"__UUID__"}}"#.utf8)
        let two = Data(multiConfig.utf8)
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: staged, current: two) }
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: staged, current: Data("{}".utf8)) }
        let ok = try VpnConfig.fill(staged: staged, current: Data(currentConfig.utf8))
        #expect(String(decoding: ok, as: UTF8.self).contains("11111111-2222"))
    }

    @Test func multiOutboundMaskFillRoundtrip() throws {
        let cur = Data(multiConfig.utf8)
        let masked = String(decoding: try VpnConfig.mask(cur), as: UTF8.self)
        for tag in ["fin", "bvpn-nl", "bvpn-lt"] { #expect(masked.contains("__UUID:\(tag)__")) }
        for real in ["aaaaaaaa-0001", "bbbbbbbb-0002"] { #expect(!masked.contains(real)) }
        let filled = try VpnConfig.fill(staged: Data(masked.utf8), current: cur)
        let obs = ((try JSONSerialization.jsonObject(with: filled) as? [String: Any])?["outbounds"] as? [[String: Any]]) ?? []
        let byTag = Dictionary(uniqueKeysWithValues: obs.compactMap { o in (o["tag"] as? String).map { ($0, o["uuid"] as? String) } })
        #expect(byTag["fin"] == "aaaaaaaa-0001")
        #expect(byTag["bvpn-nl"] == "bbbbbbbb-0002")
        #expect(byTag["bvpn-lt"] == "bbbbbbbb-0002")
    }

    @Test func rejectsLiteralUuid() {
        let staged = #"{"outbounds":[{"type":"vless","tag":"fin","uuid":"aaaaaaaa-0001"}]}"#
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: Data(staged.utf8), current: Data(multiConfig.utf8)) }
    }

    @Test func rejectsUnknownTagPlaceholder() {
        let staged = #"{"outbounds":[{"type":"vless","tag":"new","uuid":"__UUID:new__"}]}"#
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: Data(staged.utf8), current: Data(multiConfig.utf8)) }
    }

    @Test func rejectsNewOutboundWithoutUuid() {
        let staged = #"{"outbounds":[{"type":"vless","tag":"new","server":"1.2.3.4"}]}"#
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: Data(staged.utf8), current: Data(multiConfig.utf8)) }
        let vmess = #"{"outbounds":[{"type":"vmess","tag":"x"}]}"#
        #expect(throws: VpnConfigError.self) { try VpnConfig.fill(staged: Data(vmess.utf8), current: Data(multiConfig.utf8)) }
    }

    @Test func nonUuidOutboundsPassWithoutUuid() throws {
        let staged = #"{"outbounds":[{"type":"direct","tag":"direct"}]}"#
        _ = try VpnConfig.fill(staged: Data(staged.utf8), current: Data(multiConfig.utf8))
    }

    @Test func secretPlaceholderWithoutCurrentSecretFails() {
        let cur = #"{"o":{"uuid":"x"}}"#
        #expect(throws: VpnConfigError.self) {
            try VpnConfig.fill(staged: Data(#"{"s":"__CLASH_SECRET__"}"#.utf8), current: Data(cur.utf8))
        }
    }

    @Test func literalSecretInStagedFileIsKept() throws {
        let out = try VpnConfig.fill(staged: Data(#"{"secret":"new-secret"}"#.utf8),
                                     current: Data(#"{"o":{"uuid":"x"}}"#.utf8))
        #expect(String(decoding: out, as: UTF8.self).contains("new-secret"))
    }
}
