import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

func tmpDir() -> String {
    let d = NSTemporaryDirectory() + "vpnrules-\(getpid())-\(Int.random(in: 0..<1_000_000))"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func put(_ dir: String, _ name: String, _ text: String, mode: Int = 0o644) {
    FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data(text.utf8), attributes: [.posixPermissions: mode])
}

func slurp(_ dir: String, _ name: String) -> String {
    String(data: FileManager.default.contents(atPath: "\(dir)/\(name)") ?? Data(), encoding: .utf8) ?? ""
}

func mode(_ dir: String, _ name: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(name)"))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

struct LocalRuleWriter: VpnRuleWriting {
    let dir: String
    func write(_ target: VpnRuleTarget, data: Data) throws {
        let tmp = "\(dir)/.\(target.rawValue).tmp"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644])
        guard rename(tmp, "\(dir)/\(target.rawValue).json") == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class FailingRuleWriter: VpnRuleWriting, @unchecked Sendable {
    var writes: [(VpnRuleTarget, Data)] = []
    func write(_ target: VpnRuleTarget, data: Data) throws {
        writes.append((target, data))
        throw CtlError.sudoNotConfigured
    }
}

@Suite struct VpnRoutingTests {
    @Test func ruleFilesScenario() {
    let directOrig = "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\"]}]}\n"
    let placeOrig = "{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}]}\n"

    let d = tmpDir()
    put(d, "direct.json", directOrig, mode: 0o600)
    put(d, "proxy.json", placeOrig)
    put(d, "block.json", placeOrig)
    put(d, "always-vps.json", "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.com\", \"example.net\"]}]}\n")
    let f = VpnRuleFiles(dir: d, writer: LocalRuleWriter(dir: d))

    check((try? f.add("ifconfig.me", kind: .domainSuffix, target: .direct)) == true, "add returns changed")
    check(slurp(d, "direct.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\", \"ifconfig.me\"]}]}\n", "add merges into existing domain_suffix object, python-style format")
    check(mode(d, "direct.json") == 0o644, "written through the writer with mode 644")
    check((try? f.add("ifconfig.me", kind: .domainSuffix, target: .direct)) == false, "duplicate add changes nothing")
    try? f.remove(VpnUserRule(target: .direct, kind: .domainSuffix, value: "ifconfig.me"))
    check(slurp(d, "direct.json") == directOrig, "add+remove domain is byte-identical")

    _ = try? f.add("curl", kind: .processName, target: .direct)
    check(slurp(d, "direct.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\"]}, {\"process_name\": [\"curl\"]}]}\n", "process rule is a separate OR-ed rule object")
    _ = try? f.add("10.1.0.0/16", kind: .ipCidr, target: .direct)
    let txt = slurp(d, "direct.json")
    check(txt.contains("{\"ip_cidr\": [\"10.1.0.0/16\"]}") && txt.contains("\\/") == false, "cidr slash is not escaped")
    try? f.remove(VpnUserRule(target: .direct, kind: .processName, value: "curl"))
    try? f.remove(VpnUserRule(target: .direct, kind: .ipCidr, value: "10.1.0.0/16"))
    check(slurp(d, "direct.json") == directOrig, "add+remove process and cidr is byte-identical")

    _ = try? f.add("example.org", kind: .domainSuffix, target: .proxy)
    check(slurp(d, "proxy.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.org\"]}]}\n", "placeholder dropped when real rule added")
    try? f.remove(VpnUserRule(target: .proxy, kind: .domainSuffix, value: "example.org"))
    check(slurp(d, "proxy.json") == placeOrig, "placeholder restored when last rule removed")

    _ = try? f.add("moved.example", kind: .domainSuffix, target: .direct)
    _ = try? f.add("moved.example", kind: .domainSuffix, target: .proxy)
    check(f.find(.domainSuffix, "moved.example") == .proxy, "adding to another target moves the rule")
    check(!slurp(d, "direct.json").contains("moved.example"), "moved rule removed from the old file")
    try? f.remove(VpnUserRule(target: .proxy, kind: .domainSuffix, value: "moved.example"))
    check(slurp(d, "direct.json") == directOrig && slurp(d, "proxy.json") == placeOrig, "move round trip restores both files")

    let loaded = f.load()
    check(loaded.count == 2 && loaded.allSatisfy { $0.target == .direct }, "load hides placeholders, lists user entries")
    check(f.alwaysVps() == ["example.com", "example.net"], "always-vps read")

    put(d, "block.json", "{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}, {\"domain_suffix\": [\"bad.example\"], \"port\": [80]}]}\n")
    _ = try? f.add("x.example", kind: .domainSuffix, target: .block)
    check(slurp(d, "block.json").contains("\"port\": [80]") && slurp(d, "block.json").contains("bad.example"), "compound rule object preserved untouched")

    put(d, "proxy.json", "not json")
    check((try? f.add("a.example", kind: .domainSuffix, target: .proxy)) == nil, "corrupt file is not overwritten")
    check(slurp(d, "proxy.json") == "not json", "corrupt file content intact")
    try? FileManager.default.removeItem(atPath: d)
    }

    @Test func detectRuleKinds() {
    func kind(_ s: String) -> String { VpnRuleDetect.parse(s).map { "\($0.kind.rawValue):\($0.value)" } ?? "nil" }
    check(kind("ifconfig.me") == "domain_suffix:ifconfig.me", "detect: domain")
    check(kind("1.2.3.4") == "ip_cidr:1.2.3.4/32", "detect: ipv4 gets /32")
    check(kind("10.0.0.0/8") == "ip_cidr:10.0.0.0/8", "detect: cidr")
    check(kind("2001:db8::1") == "ip_cidr:2001:db8::1/128", "detect: ipv6")
    check(kind("curl") == "process_name:curl", "detect: bare word is process")
    check(kind("Google Chrome") == "process_name:Google Chrome", "detect: name with space is process")
    check(kind("https://www.Example.org/x?y=1") == "domain_suffix:example.org", "detect: url gives host without www")
    check(kind("*.example.org") == "domain_suffix:example.org", "detect: wildcard prefix stripped")
    check(kind("999.1.1.1") == "domain_suffix:999.1.1.1", "detect: bad octet is not an ip")
    check(kind("1.2.3.4/33") == "process_name:1.2.3.4/33" || kind("1.2.3.4/33") == "process_name:33", "detect: bad prefix is not cidr")
    check(kind("   ") == "nil", "detect: blank is nil")
    check(kind("Claude.app") == "domain_suffix:claude.app", "detect: dotted word is domain per spec")
    check(VpnRuleDetect.hostFromURL("https://example.gov/epz/main") == "example.gov", "host from url")
    check(VpnRuleDetect.hostFromURL("https://example.org/x") == "example.org", "host from url: example.org")
    check(VpnRuleDetect.hostFromURL("about:blank") == nil, "host from url: about:blank has none")
    check(VpnRuleDetect.hostFromURL("favorites://") == nil, "host from url: favorites has none")
    }

    @Test func processNames() {
    check(VpnConnLogic.processName("/Users/user/.vscode/extensions/x/native-binary/claude (user)") == "claude", "process name from path with user")
    check(VpnConnLogic.processName("/Applications/Telegram.app/Contents/MacOS/Telegram (user)") == "Telegram", "process name: Telegram")
    check(VpnConnLogic.processName("/System/Library/PrivateFrameworks/ApplePushService.framework/apsd (root)") == "apsd", "process name: apsd")
    check(VpnConnLogic.processName("") == "", "process name: empty")
    check(VpnConnLogic.processName("/Applications/Google Chrome.app/Contents/Frameworks/X/Google Chrome Helper (Renderer) (user)") == "Google Chrome Helper (Renderer)", "process name keeps inner parentheses")
    }

    @Test func humanRuleNames() {
    let h = VpnConnLogic.humanRule
    check(h("rule_set=user-direct => route(direct)") == "Мои: напрямую", "rule name: user-direct")
    check(h("rule_set=user-proxy => route(vps)") == "Мои: через VPS", "rule name: user-proxy")
    check(h("rule_set=user-block => reject") == "Мои: блок", "rule name: user-block")
    check(h("rule_set=user-always-vps => route(vps)") == "Всегда через VPS", "rule name: always-vps")
    check(h("final") == "Всё остальное", "rule name: final")
    check(h("rule_set=geoip-ru => route(direct)") == "Сайты РФ", "rule name: geoip-ru")
    check(h("ip_cidr=17.0.0.0/8 => route(direct)") == "Apple", "rule name: Apple")
    check(h("ip_cidr=203.0.113.10/32 => route(direct)") == "Сам сервер", "rule name: server")
    check(h("ip_is_private=true => route(direct)") == "Локальная сеть", "rule name: private")
    check(h("clash_mode=Direct => route(direct)") == "Режим «напрямую»", "rule name: mode direct")
    check(h("port=[993 995 465 587] => route(direct)") == "Почтовые порты", "rule name: mail ports")
    check(h("something=odd => route(vps)") == "something=odd", "rule name: unknown falls back to raw condition")
    }

    @Test func routeChips() {
    let r = VpnConnLogic.route
    check(r(["vps"], "final", "1.1.1.1") == .vps, "chip: final via vps")
    check(r(["direct"], "rule_set=geoip-ru => route(direct)", "5.255.255.5") == .direct, "chip: geoip direct")
    check(r(["direct"], "ip_is_private=true => route(direct)", "192.168.1.20") == .local, "chip: private rule is local")
    check(r(["direct"], "final", "10.1.2.3") == .local, "chip: private ip is local")
    check(r([], "rule_set=user-block => reject", "1.1.1.1") == .block, "chip: reject is block")
    check(r([], "rule_set=user-direct => route(direct)", "1.1.1.1") == .direct, "chip: no chains falls back to action")
    check(r(["vps"], "rule_set=user-always-vps => route(vps)", "160.79.104.10") == .vps, "chip: always-vps")
    check(VpnConnLogic.isPrivateIP("172.20.10.1") && !VpnConnLogic.isPrivateIP("172.32.0.1") && !VpnConnLogic.isPrivateIP("8.8.8.8"), "private ip ranges")
    check(VpnConnLogic.parseDate("2026-10-03T01:20:28.804898+03:00") != nil, "parse date with microseconds")
    check(VpnFormat.speed(0) == "0" && VpnFormat.speed(120_000) == "0,1 МБ/с" && VpnFormat.speed(45_000) == "45 КБ/с" && VpnFormat.speed(500) == "500 Б/с", "speed format")
    check(VpnFormat.age(40) == "40 с" && VpnFormat.age(14 * 60) == "14 мин" && VpnFormat.age(3 * 3600) == "3 ч", "age format")
    }

}
