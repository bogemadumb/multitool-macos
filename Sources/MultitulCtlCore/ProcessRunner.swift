import Foundation

public struct ProcessOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutput
}

public struct SystemProcessRunner: ProcessRunning {
    public static let defaultEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    private let environment: [String: String]

    public init(environment: [String: String] = SystemProcessRunner.defaultEnvironment) { self.environment = environment }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ProcessOutput(status: 127, stderr: "cannot launch \(executable): \(error.localizedDescription)")
        }
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.waitUntilExit()
        group.wait()
        return ProcessOutput(status: p.terminationStatus,
                             stdout: String(decoding: box.out, as: UTF8.self),
                             stderr: String(decoding: box.err, as: UTF8.self),
                             timedOut: timedOut)
    }
}

private final class DataBox: @unchecked Sendable {
    var out = Data()
    var err = Data()
}
