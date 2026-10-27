import Foundation

public struct ManagerCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 60) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    public var display: String { ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ") }
    public var runsAsRootEscalation: Bool { (executable as NSString).lastPathComponent == "sudo" || executable == "/usr/bin/su" }
}

public enum ManagerStreamKind: Equatable, Sendable { case out, err }

public struct ManagerLine: Equatable, Sendable {
    public var stream: ManagerStreamKind
    public var text: String
    public init(_ stream: ManagerStreamKind, _ text: String) {
        self.stream = stream
        self.text = text
    }
}

public struct ManagerResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var cancelled: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, cancelled: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public var ok: Bool { status == 0 && !timedOut && !cancelled }
    public var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
    public static let launchFailure = ManagerResult(status: 127)
}

public protocol ManagerRunning: Sendable {
    func run(_ command: ManagerCommand) async -> ManagerResult
    func stream(_ command: ManagerCommand, onLine: @escaping @Sendable (ManagerLine) -> Void) async -> ManagerResult
}

// Splits a byte stream into lines on \n, \r and \r\n; multi-byte characters survive chunk borders because decoding happens per finished line.
public struct LineBuffer {
    private var pending = Data()
    private var lastWasCR = false

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if lastWasCR { lastWasCR = false; continue }
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else if byte == 0x0D {
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
                lastWasCR = true
            } else {
                lastWasCR = false
                pending.append(byte)
            }
        }
        return lines
    }

    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let s = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return s
    }
}

public final class SystemManagerRunner: ManagerRunning, @unchecked Sendable {
    public static var defaultEnvironment: [String: String] {
        [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb"
        ]
    }

    private let base: [String: String]

    public init(base: [String: String] = SystemManagerRunner.defaultEnvironment) { self.base = base }

    public func run(_ command: ManagerCommand) async -> ManagerResult { await stream(command, onLine: { _ in }) }

    public func stream(_ command: ManagerCommand, onLine: @escaping @Sendable (ManagerLine) -> Void) async -> ManagerResult {
        guard !command.runsAsRootEscalation else { return ManagerResult(status: 126, stderr: "privilege escalation is not allowed") }
        let flag = CancelFlag()
        let env = base.merging(command.environment) { _, new in new }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ManagerResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Self.execute(command, env: env, flag: flag, onLine: onLine))
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private static func execute(_ command: ManagerCommand, env: [String: String], flag: CancelFlag, onLine: @escaping @Sendable (ManagerLine) -> Void) -> ManagerResult {
        if flag.isSet { return ManagerResult(status: 130, cancelled: true) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.executable)
        p.arguments = command.arguments
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ManagerResult(status: 127, stderr: "cannot launch \(command.executable): \(error.localizedDescription)")
        }
        let sink = Collected()
        let group = DispatchGroup()
        for (pipe, kind) in [(out, ManagerStreamKind.out), (err, ManagerStreamKind.err)] {
            group.enter()
            DispatchQueue.global().async {
                var buffer = LineBuffer()
                let h = pipe.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    sink.append(chunk, kind)
                    for line in buffer.feed(chunk) { onLine(ManagerLine(kind, line)) }
                }
                if let rest = buffer.flush() { onLine(ManagerLine(kind, rest)) }
                group.leave()
            }
        }
        var timedOut = false
        var cancelled = false
        let deadline = Date().addingTimeInterval(command.timeout)
        while p.isRunning {
            if flag.isSet { cancelled = true; p.terminate(); break }
            if Date() > deadline { timedOut = true; p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if cancelled || timedOut {
            let killAt = Date().addingTimeInterval(3)
            while p.isRunning && Date() < killAt { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        group.wait()
        let (o, e) = sink.snapshot()
        return ManagerResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func append(_ d: Data, _ kind: ManagerStreamKind) {
        lock.lock()
        if kind == .out { out.append(d) } else { err.append(d) }
        lock.unlock()
    }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

public struct ToolLocator {
    public var directories: [String]
    private let files: LauncherFileChecking

    public static let defaultDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    public init(files: LauncherFileChecking, directories: [String] = ToolLocator.defaultDirectories) {
        self.files = files
        self.directories = directories
    }

    public func find(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return directories.map { $0 + "/" + name }.first { files.isExecutable($0) }
    }
}

public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0)) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func line(_ parts: [String]) -> String { parts.map(quote).joined(separator: " ") }
}

public enum TerminalScript {
    public static func appleScript(running command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
    }
}

public enum ManagerBytes {
    public static func format(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        if b < 1024 { return "\(Int(b)) Б" }
        let units = ["КБ", "МБ", "ГБ", "ТБ"]
        var v = b / 1024
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }
}
