import Testing
import Foundation
@testable import MultitulCtlCore

private let ctx = CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: ["/Users/x/Library/Application Support/Multitul/staging"])

@Suite struct CtlPowerTests {
    @Test func onlyExactLowercaseOnOffAccepted() throws {
        #expect(try CtlParser.parse(["power", "disablesleep", "on"], context: ctx) == .powerDisableSleep(true))
        #expect(try CtlParser.parse(["power", "disablesleep", "off"], context: ctx) == .powerDisableSleep(false))
        for bad in ["ON", "Off", "1", "0", "true", " on", "on ", "", "on;reboot", "-a"] {
            #expect(throws: CtlParseError.self) { try CtlParser.parse(["power", "disablesleep", bad], context: ctx) }
        }
    }

    @Test func otherPmsetVerbsAreRejected() {
        let bad: [[String]] = [["power"], ["power", "sleepnow"], ["power", "disablesleep"], ["power", "disablesleep", "on", "now"],
                               ["power", "displaysleep", "0"], ["power", "-a", "disablesleep", "1"], ["pmset", "disablesleep", "on"],
                               ["power", "disablesleep", "on", "off"]]
        for args in bad { #expect(throws: CtlParseError.self) { try CtlParser.parse(args, context: ctx) } }
    }

    @Test func argumentsRoundTrip() throws {
        for on in [true, false] {
            let cmd = CtlCommand.powerDisableSleep(on)
            #expect(try CtlParser.parse(cmd.arguments, context: ctx) == cmd)
        }
    }
}
