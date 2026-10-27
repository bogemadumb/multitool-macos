import Testing
import Foundation
@testable import MultitulCtlCore

private let ctx = CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: ["/Users/u/Library/Application Support/Multitul/staging"])
private let staged = "/Users/u/Library/Application Support/Multitul/staging/r-1/direct.json"

private func data(_ s: String) -> Data { Data(s.utf8) }

private let good = "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\"]}, {\"process_name\": [\"Google Chrome Helper (Renderer)\"]}, {\"ip_cidr\": [\"10.1.0.0/16\", \"2001:db8::/32\"]}]}\n"

private final class RulesRig: @unchecked Sendable {
    let dir = NSTemporaryDirectory() + "multitul-rules-\(UUID().uuidString)"
    var stagingDir: String { dir + "/staging" }
    var rulesDir: String { dir + "/user" }
    var out: [String] = []
    var err: [String] = []

    init(createRulesDir: Bool = true) {
        try? FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        if createRulesDir { try? FileManager.default.createDirectory(atPath: rulesDir, withIntermediateDirectories: true) }
    }

    func stage(_ name: String, _ text: String, mode: Int = 0o600) -> String {
        let p = stagingDir + "/" + name
        FileManager.default.createFile(atPath: p, contents: data(text), attributes: [.posixPermissions: mode])
        return p
    }

    func executor() -> CtlExecutor {
        var paths = CtlPaths()
        paths.configDir = dir
        let ctx = CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: [stagingDir])
        return CtlExecutor(runner: ScriptedRunner(), paths: paths, context: ctx, trustedUid: getuid(), euid: 0,
                           sleeper: { _ in }, out: { [self] in out.append($0) }, err: { [self] in err.append($0) })
    }

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: rulesDir + "/" + name).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite struct VpnRulesParserTests {
    @Test func parsesWriteForTheThreeTargets() throws {
        for t in ["direct", "proxy", "block"] {
            let p = "/Users/u/Library/Application Support/Multitul/staging/r-1/\(t).json"
            #expect(try CtlParser.parse(["vpn", "rules", "write", p], context: ctx) == .vpn(.rulesWrite(path: p)))
            #expect(CtlCommand.vpn(.rulesWrite(path: p)).arguments == ["vpn", "rules", "write", p])
        }
    }

    @Test func rejectsOtherNamesAndPaths() {
        let dir = "/Users/u/Library/Application Support/Multitul/staging/r-1/"
        let bad: [[String]] = [
            ["vpn", "rules", "write", dir + "always-vps.json"],
            ["vpn", "rules", "write", dir + "config.json"],
            ["vpn", "rules", "write", dir + "direct.json.bak"],
            ["vpn", "rules", "write", "/usr/local/etc/singbox/user/direct.json"],
            ["vpn", "rules", "write", dir + "../direct.json"],
            ["vpn", "rules", "write", "direct.json"],
            ["vpn", "rules", "write"],
            ["vpn", "rules", "write", dir + "direct.json", "extra"],
            ["vpn", "rules", "delete", dir + "direct.json"],
            ["vpn", "rules"]
        ]
        for a in bad { #expect(throws: CtlParseError.self) { try CtlParser.parse(a, context: ctx) } }
    }
}

@Suite struct VpnRulesValidatorTests {
    @Test func acceptsRealisticDocuments() throws {
        try VpnRules.validate(data(good))
        try VpnRules.validate(data("{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}]}\n"))
        try VpnRules.validate(data("{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"bad.example\"], \"port\": [80, 443]}]}"))
    }

    @Test func rejectsStructuralGarbage() {
        let bad = [
            "not json", "[]", "{}", "{\"version\": 2}", "{\"version\": 1, \"rules\": [{\"domain\": [\"a.b\"]}]}",
            "{\"version\": 2, \"rules\": []}", "{\"version\": 2, \"rules\": [\"x\"]}", "{\"version\": 2, \"rules\": [{}]}",
            "{\"version\": 2, \"rules\": [{\"domain\": [\"a.b\"]}], \"extra\": 1}",
            "{\"version\": 2, \"rules\": [{\"type\": \"logical\", \"rules\": []}]}",
            "{\"version\": 2, \"rules\": [{\"domain_regex\": [\".*\"]}]}"
        ]
        for b in bad { #expect(throws: VpnConfigError.self) { try VpnRules.validate(data(b)) } }
    }

    @Test func rejectsBadValues() {
        let values = [
            "{\"domain_suffix\": [\"a b.com\"]}", "{\"domain_suffix\": [\"a.com/x\"]}", "{\"domain_suffix\": [\"\"]}",
            "{\"domain_suffix\": [\"a\\u0000b.com\"]}", "{\"domain_suffix\": [\"привет.рф\"]}",
            "{\"ip_cidr\": [\"10.0.0.0/33\"]}", "{\"ip_cidr\": [\"999.1.1.1/8\"]}", "{\"ip_cidr\": [\"x\"]}", "{\"ip_cidr\": [\"1.2.3.4/\"]}",
            "{\"process_name\": [\"/bin/sh\"]}", "{\"process_name\": [\"a\\nb\"]}", "{\"process_name\": [\"\(String(repeating: "a", count: 200))\"]}",
            "{\"port\": [0]}", "{\"port\": [70000]}", "{\"port\": [\"80\"]}", "{\"network\": [\"icmp\"]}", "{\"invert\": 1}"
        ]
        for v in values {
            #expect(throws: VpnConfigError.self, Comment(rawValue: v)) { try VpnRules.validate(data("{\"version\": 2, \"rules\": [\(v)]}")) }
        }
    }
}

@Suite struct VpnRulesExecutorTests {
    @Test func writesValidatedFileAtomically() {
        let rig = RulesRig()
        let p = rig.stage("direct.json", good)
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: p))) == 0)
        #expect(rig.read("direct.json") == good)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: rig.rulesDir + "/direct.json"))?[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o644)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.rulesDir)) ?? []
        #expect(leftovers == ["direct.json"])
    }

    @Test func invalidContentChangesNothing() {
        let rig = RulesRig()
        try? "old".write(toFile: rig.rulesDir + "/proxy.json", atomically: true, encoding: .utf8)
        let p = rig.stage("proxy.json", "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"a b\"]}]}")
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: p))) == CtlExit.badStaged)
        #expect(rig.read("proxy.json") == "old")
    }

    @Test func alwaysVpsIsNeverWritable() {
        let rig = RulesRig()
        try? "keep".write(toFile: rig.rulesDir + "/always-vps.json", atomically: true, encoding: .utf8)
        let p = rig.stage("always-vps.json", good)
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: p))) == CtlExit.usage)
        #expect(rig.read("always-vps.json") == "keep")
    }

    @Test func missingRulesDirIsReportedNotCreated() {
        let rig = RulesRig(createRulesDir: false)
        let p = rig.stage("block.json", good)
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: p))) == CtlExit.badConfig)
        #expect(!FileManager.default.fileExists(atPath: rig.rulesDir))
    }

    @Test func rejectsPathOutsideStagingAndSymlinks() throws {
        let rig = RulesRig()
        let outside = NSTemporaryDirectory() + "multitul-out-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try good.write(toFile: outside + "/direct.json", atomically: true, encoding: .utf8)
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: outside + "/direct.json"))) == CtlExit.badStaged)
        try FileManager.default.createSymbolicLink(atPath: rig.stagingDir + "/block.json", withDestinationPath: outside + "/direct.json")
        #expect(rig.executor().execute(.vpn(.rulesWrite(path: rig.stagingDir + "/block.json"))) == CtlExit.badStaged)
        #expect(rig.read("block.json") == nil)
    }
}
