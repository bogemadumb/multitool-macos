import Testing
import Foundation
@testable import MultitulCtlCore

private let ctx = CtlContext(ownPid: 500, parentPid: 400,
                             allowedApplyDirs: ["/Users/user/Library/Application Support/Multitul/staging", "/usr/local/etc/singbox/staged"])
private let stagedFile = "/Users/user/Library/Application Support/Multitul/staging/staged-1.json"

private func parse(_ s: String) throws -> CtlCommand {
    try CtlParser.parse(s.isEmpty ? [] : s.components(separatedBy: " "), context: ctx)
}

@Suite struct CtlParserTests {
    @Test func validForms() throws {
        #expect(try parse("selftest") == .selftest)
        #expect(try parse("vpn on") == .vpn(.on))
        #expect(try parse("vpn off") == .vpn(.off))
        #expect(try parse("vpn restart") == .vpn(.restart))
        #expect(try parse("vpn show") == .vpn(.show))
        #expect(try parse("vpn killswitch on") == .vpn(.killswitch(.on)))
        #expect(try parse("vpn killswitch off") == .vpn(.killswitch(.off)))
        #expect(try parse("vpn killswitch status") == .vpn(.killswitch(.status)))
        #expect(try parse("power disablesleep on") == .powerDisableSleep(true))
        #expect(try parse("power disablesleep off") == .powerDisableSleep(false))
        #expect(try parse("mem purge") == .memPurge)
        #expect(try parse("proc kill 1234") == .procKill(pid: 1234, signal: SIGTERM))
        #expect(try parse("proc kill 1234 9") == .procKill(pid: 1234, signal: SIGKILL))
        #expect(try parse("proc kill 1234 KILL") == .procKill(pid: 1234, signal: SIGKILL))
        #expect(try parse("proc kill 1234 sigstop") == .procKill(pid: 1234, signal: SIGSTOP))
        #expect(try parse("smc fan-auto all") == .smcFanAuto(.all))
        #expect(try parse("smc fan-set 1 3000") == .smcFanSet(index: 1, rpm: 3000))
        #expect(try CtlParser.parse(["vpn", "apply", stagedFile], context: ctx) == .vpn(.apply(path: stagedFile)))
    }

    @Test func rejectedForms() {
        let bad = [
            "", "foo", "vpn", "vpn foo", "vpn on now", "vpn killswitch", "vpn killswitch maybe", "vpn killswitch on extra",
            "vpn apply", "vpn show extra", "power", "power disablesleep", "power disablesleep maybe", "power sleep on",
            "power disablesleep on off", "mem", "mem purge now", "mem flush", "selftest now",
            "proc", "proc kill", "proc kill abc", "proc kill 12x", "proc kill -5", "proc kill 1234 BOGUS", "proc kill 1234 0",
            "proc kill 1234 9 9", "proc term 1234", "proc kill 99999999999",
            "smc", "smc fan 0 auto", "smc fan-auto", "smc fan-auto x", "smc fan-set 0", "smc fan-set 0 abc", "smc fan-set 0 10001",
            "smc fan-mode 0 turbo", "smc led 0 on",
            "VPN on", "vpn  on"
        ]
        for line in bad {
            #expect(throws: CtlParseError.self, "\(line)") { try parse(line) }
        }
    }

    @Test func pidGuard() {
        for pid in ["0", "1", "500", "400"] {
            #expect(throws: CtlParseError.self, "pid \(pid)") { try parse("proc kill \(pid)") }
        }
        #expect(throws: CtlParseError.self) { try parse("proc kill 2147483648") }
        #expect(throws: CtlParseError.self) { try parse("proc kill 501 SEGV") }
        #expect((try? parse("proc kill 2")) != nil)
        #expect((try? parse("proc kill 2147483647")) != nil)
    }

    @Test func signalsAreAllowlisted() {
        #expect(throws: CtlParseError.self) { try CtlParser.parseSignal("SEGV") }
        #expect(throws: CtlParseError.self) { try CtlParser.parseSignal("11") }
        #expect(throws: CtlParseError.self) { try CtlParser.parseSignal("-9") }
        #expect((try? CtlParser.parseSignal("TERM")) == SIGTERM)
        #expect((try? CtlParser.parseSignal("15")) == SIGTERM)
    }

    @Test func applyPathGuard() {
        let allowedOK = [
            stagedFile,
            "/usr/local/etc/singbox/staged/x.json",
            "/usr/local/etc/singbox//staged/x.json"
        ]
        for p in allowedOK { #expect((try? CtlParser.parse(["vpn", "apply", p], context: ctx)) != nil, "\(p)") }
        let denied = [
            "", "relative.json", "staged.json", "/etc/passwd", "/tmp/x.json", "/usr/local/etc/singbox/config.json",
            "/usr/local/etc/singbox/staged", "/usr/local/etc/singbox/staged/",
            "/usr/local/etc/singbox/staged/../config.json",
            "/usr/local/etc/singbox/staged/./x.json",
            "/usr/local/etc/singbox/stagedevil/x.json",
            "/Users/user/Library/Application Support/Multitul/staging/../../../../../etc/passwd",
            "/Users/user/Library/Application Support/Multitul/staging-evil/x.json"
        ]
        for p in denied {
            #expect(throws: CtlParseError.self, "\(p)") { try CtlParser.parse(["vpn", "apply", p], context: ctx) }
        }
        let noDirs = CtlContext(allowedApplyDirs: [])
        #expect(throws: CtlParseError.self) { try CtlParser.parse(["vpn", "apply", stagedFile], context: noDirs) }
    }

    @Test func argumentsRoundTrip() throws {
        let all: [CtlCommand] = [
            .selftest, .vpn(.on), .vpn(.off), .vpn(.restart), .vpn(.show), .vpn(.apply(path: stagedFile)),
            .vpn(.killswitch(.on)), .vpn(.killswitch(.off)), .vpn(.killswitch(.status)),
            .powerDisableSleep(true), .powerDisableSleep(false), .memPurge,
            .procKill(pid: 777, signal: SIGHUP), .smcFanAuto(.index(2)), .smcFanAuto(.all), .smcFanSet(index: 3, rpm: 4200), .smcFanMode(index: 1, manual: true)
        ]
        for c in all { #expect(try CtlParser.parse(c.arguments, context: ctx) == c) }
    }
}
