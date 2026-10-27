import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessOutput(status: 0)
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        calls.append((executable, arguments))
        return result
    }
}

@Suite struct PrivilegedCtlTests {
    private func make(_ r: FakeRunner, installed: Bool = true) -> PrivilegedCtl {
        PrivilegedCtl(runner: r, stagingDir: NSTemporaryDirectory() + "multitul-stg-\(UUID().uuidString)", binaryExists: { _ in installed })
    }

    @Test func buildsSudoNCommand() throws {
        let r = FakeRunner()
        try make(r).vpnRestart()
        #expect(r.calls.count == 1)
        #expect(r.calls[0].0 == "/usr/bin/sudo")
        #expect(r.calls[0].1 == ["-n", "/usr/local/libexec/multitul-ctl", "vpn", "restart"])
    }

    @Test func killIncludesNumericSignal() throws {
        let r = FakeRunner()
        try make(r).kill(pid: 4321, signal: SIGKILL)
        #expect(r.calls[0].1.suffix(4) == ["proc", "kill", "4321", "9"])
    }

    @Test func notInstalled() {
        let r = FakeRunner()
        #expect(throws: CtlError.notInstalled) { try make(r, installed: false).vpnOn() }
        #expect(r.calls.isEmpty)
    }

    @Test func invalidCommandNeverReachesSudo() {
        let r = FakeRunner()
        #expect(throws: CtlError.self) { try make(r).kill(pid: 1) }
        #expect(throws: CtlError.self) { try make(r).run(.smcFanSet(index: 99, rpm: 3000)) }
        #expect(throws: CtlError.self) { try make(r).run(.vpn(.apply(path: "/etc/passwd"))) }
        #expect(r.calls.isEmpty)
    }

    @Test func sudoPasswordRequiredIsMapped() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 1, stderr: "sudo: a password is required")
        #expect(throws: CtlError.sudoNotConfigured) { try make(r).vpnOn() }
    }

    @Test func nonZeroExitCarriesResult() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 6, stdout: "", stderr: "apply: rolled back")
        do { try make(r).vpnRestart(); Issue.record("expected throw") } catch let CtlError.failed(res) {
            #expect(res.exitCode == 6)
            #expect(res.stderr.contains("rolled back"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func timeoutIsReported() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 15, timedOut: true)
        #expect(throws: CtlError.timedOut) { try make(r).vpnOn() }
    }

    @Test func applyPassesOnlyAPathAndCleansUp() throws {
        let r = FakeRunner()
        let ctl = make(r)
        let secret = "SUPER-SECRET-VALUE"
        try ctl.vpnApply(configData: Data("{\"secret\":\"\(secret)\"}".utf8))
        let args = r.calls[0].1
        #expect(args[2...3] == ["vpn", "apply"])
        #expect(!args.joined(separator: " ").contains(secret))
        #expect(!FileManager.default.fileExists(atPath: args[4]))
    }

    @Test func showReturnsStdout() throws {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 0, stdout: "{}\n")
        #expect(try make(r).vpnShow() == "{}\n")
    }
}
