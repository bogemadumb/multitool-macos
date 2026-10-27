import Testing
import Foundation
@testable import MultitulCtlCore

private let ctx = CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: ["/Users/x/Library/Application Support/Multitul/staging"])
private func parse(_ line: String) throws -> CtlCommand {
    try CtlParser.parse(line.split(separator: " ", omittingEmptySubsequences: false).map(String.init), context: ctx)
}

@Suite struct CtlSmcParserTests {
    @Test func fanAutoAcceptsIndexOrAll() throws {
        #expect(try parse("smc fan-auto all") == .smcFanAuto(.all))
        #expect(try parse("smc fan-auto 0") == .smcFanAuto(.index(0)))
        #expect(try parse("smc fan-auto 9") == .smcFanAuto(.index(9)))
    }

    @Test func fanSetAcceptsIndexAndRpm() throws {
        #expect(try parse("smc fan-set 0 0") == .smcFanSet(index: 0, rpm: 0))
        #expect(try parse("smc fan-set 1 3200") == .smcFanSet(index: 1, rpm: 3200))
        #expect(try parse("smc fan-set 9 10000") == .smcFanSet(index: 9, rpm: 10000))
    }

    @Test func fanModeAcceptsAutoAndManual() throws {
        #expect(try parse("smc fan-mode 2 manual") == .smcFanMode(index: 2, manual: true))
        #expect(try parse("smc fan-mode 2 auto") == .smcFanMode(index: 2, manual: false))
    }

    @Test func indexMustBeBelowTen() {
        for line in ["smc fan-auto 10", "smc fan-set 10 3000", "smc fan-mode 10 auto", "smc fan-auto 99", "smc fan-set 255 3000"] {
            #expect(throws: CtlParseError.self, "\(line)") { try parse(line) }
        }
    }

    @Test func rpmMustBeInRange() {
        for line in ["smc fan-set 0 10001", "smc fan-set 0 99999", "smc fan-set 0 100000", "smc fan-set 0 -1", "smc fan-set 0 +500",
                     "smc fan-set 0 1e3", "smc fan-set 0 3000.5", "smc fan-set 0 0x10", "smc fan-set 0 ٣٠٠٠"] {
            #expect(throws: CtlParseError.self, "\(line)") { try parse(line) }
        }
    }

    @Test func nonCanonicalNumbersAreRejected() {
        for line in ["smc fan-auto 01", "smc fan-set 00 3000", "smc fan-set 0 03000", "smc fan-set  0 3000", "smc fan-set 0  3000", "smc fan-set  0"] {
            #expect(throws: CtlParseError.self, "\(line)") { try parse(line) }
        }
    }

    @Test func wrongArityIsRejected() {
        let bad = ["smc", "smc fan-auto", "smc fan-auto 0 1", "smc fan-auto all all", "smc fan-set", "smc fan-set 0", "smc fan-set 0 3000 1",
                   "smc fan-mode", "smc fan-mode 0", "smc fan-mode 0 auto extra"]
        for line in bad { #expect(throws: CtlParseError.self, "\(line)") { try parse(line) } }
    }

    @Test func unknownActionsAreRejected() {
        let bad = ["smc fan 0 auto", "smc fan 1 rpm 3000", "smc write F0Tg 3000", "smc read FNum", "smc fan-turbo 0", "smc led 0 on",
                   "smc FAN-AUTO all", "smc fan-auto ALL", "smc fan-auto -1", "smc fan-mode 0 AUTO", "smc fan-mode 0 on", "smc fan-mode 0 1",
                   "smc fan-auto all;reboot", "smc fan-auto $(id)", "smc fan-set 0 3000;1"]
        for line in bad { #expect(throws: CtlParseError.self, "\(line)") { try parse(line) } }
    }

    @Test func argumentsRoundTrip() throws {
        let all: [CtlCommand] = [.smcFanAuto(.all), .smcFanAuto(.index(4)), .smcFanSet(index: 1, rpm: 0), .smcFanSet(index: 9, rpm: 10000),
                                 .smcFanMode(index: 0, manual: true), .smcFanMode(index: 3, manual: false)]
        for c in all { #expect(try CtlParser.parse(c.arguments, context: ctx) == c) }
    }

    @Test func argumentsAreExactlyTheDocumentedForms() {
        #expect(CtlCommand.smcFanAuto(.all).arguments == ["smc", "fan-auto", "all"])
        #expect(CtlCommand.smcFanSet(index: 1, rpm: 3000).arguments == ["smc", "fan-set", "1", "3000"])
        #expect(CtlCommand.smcFanMode(index: 0, manual: true).arguments == ["smc", "fan-mode", "0", "manual"])
    }

    @Test func usageMentionsEverySmcForm() {
        for form in ["smc fan-auto", "smc fan-set", "smc fan-mode"] { #expect(ctlUsage.contains(form)) }
    }
}
