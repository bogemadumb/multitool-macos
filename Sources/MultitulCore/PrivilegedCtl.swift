import Foundation
import MultitulCtlCore

public struct CtlResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var isOK: Bool { exitCode == 0 }
}

public enum CtlError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case sudoNotConfigured
    case invalidArguments(String)
    case timedOut
    case failed(CtlResult)

    public var description: String {
        switch self {
        case .notInstalled: return "multitul-ctl не установлен (нужен install-root.sh)"
        case .sudoNotConfigured: return "sudo просит пароль: правило /etc/sudoers.d/multitul не установлено"
        case .invalidArguments(let m): return "команда отклонена: \(m)"
        case .timedOut: return "multitul-ctl не ответил вовремя"
        case .failed(let r):
            let text = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "multitul-ctl завершился с кодом \(r.exitCode)" + (text.isEmpty ? "" : ": \(text)")
        }
    }
}

public final class PrivilegedCtl: @unchecked Sendable {
    public static let defaultBinary = "/usr/local/libexec/multitul-ctl"

    private let binary: String
    private let sudo: String
    private let runner: ProcessRunning
    private let binaryExists: (String) -> Bool
    private let stagingDir: String

    public init(binary: String = PrivilegedCtl.defaultBinary,
                sudo: String = "/usr/bin/sudo",
                runner: ProcessRunning = SystemProcessRunner(),
                stagingDir: String = MultitulPaths.stagingDir,
                binaryExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.binary = binary
        self.sudo = sudo
        self.runner = runner
        self.stagingDir = stagingDir
        self.binaryExists = binaryExists
    }

    // Blocking: call off the main thread.
    @discardableResult
    public func run(_ command: CtlCommand, timeout: TimeInterval = 60) throws -> CtlResult {
        let ctx = CtlContext(ownPid: 0, parentPid: 0, allowedApplyDirs: [stagingDir])
        do { _ = try CtlParser.parse(command.arguments, context: ctx) } catch {
            throw CtlError.invalidArguments("\(error)")
        }
        guard binaryExists(binary) else { throw CtlError.notInstalled }
        let r = runner.run(sudo, ["-n", binary] + command.arguments, timeout: timeout)
        if r.timedOut { throw CtlError.timedOut }
        let result = CtlResult(exitCode: r.status, stdout: r.stdout, stderr: r.stderr)
        if r.status != 0 {
            if r.stderr.contains("a password is required") || r.stderr.contains("a terminal is required") { throw CtlError.sudoNotConfigured }
            if r.status == CtlExit.usage { throw CtlError.invalidArguments(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            throw CtlError.failed(result)
        }
        return result
    }

    public func runAsync(_ command: CtlCommand, timeout: TimeInterval = 60) async throws -> CtlResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do { cont.resume(returning: try self.run(command, timeout: timeout)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func selftest() throws -> CtlResult { try run(.selftest) }
    public func vpnOn() throws { try run(.vpn(.on)) }
    public func vpnOff() throws { try run(.vpn(.off)) }
    public func vpnRestart() throws { try run(.vpn(.restart)) }
    public func vpnShow() throws -> String { try run(.vpn(.show)).stdout }
    public func killSwitch(_ a: KillSwitchAction) throws -> String { try run(.vpn(.killswitch(a))).stdout }
    public func disableSleep(_ on: Bool) throws { try run(.powerDisableSleep(on)) }
    public func purgeMemory() throws { try run(.memPurge, timeout: 120) }
    public func kill(pid: Int32, signal: Int32 = SIGTERM) throws { try run(.procKill(pid: pid, signal: signal)) }
    public func fanAuto(_ selector: FanSelector, timeout: TimeInterval = 15) throws { try run(.smcFanAuto(selector), timeout: timeout) }
    public func fanSet(index: Int, rpm: Int, timeout: TimeInterval = 15) throws { try run(.smcFanSet(index: index, rpm: rpm), timeout: timeout) }
    public func fanMode(index: Int, manual: Bool, timeout: TimeInterval = 15) throws { try run(.smcFanMode(index: index, manual: manual), timeout: timeout) }

    // The config (which may hold the clash secret) travels through a 0600 file, never through arguments.
    @discardableResult
    public func vpnApply(configData: Data) throws -> CtlResult {
        let fm = FileManager.default
        try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = stagingDir + "/staged-\(UUID().uuidString).json"
        guard fm.createFile(atPath: path, contents: configData, attributes: [.posixPermissions: 0o600]) else {
            throw CtlError.invalidArguments("не удалось записать временный файл")
        }
        defer { try? fm.removeItem(atPath: path) }
        return try run(.vpn(.apply(path: path)), timeout: 120)
    }

    // One file per call in its own 0700 directory: ctl takes the target from the file name.
    @discardableResult
    public func vpnRulesWrite(target: String, data: Data) throws -> CtlResult {
        guard VpnRules.targets.contains(target) else { throw CtlError.invalidArguments("unknown rule target \(target)") }
        let fm = FileManager.default
        let dir = stagingDir + "/rules-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: dir) }
        let path = dir + "/\(target).json"
        guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CtlError.invalidArguments("не удалось записать временный файл")
        }
        return try run(.vpn(.rulesWrite(path: path)), timeout: 30)
    }
}
