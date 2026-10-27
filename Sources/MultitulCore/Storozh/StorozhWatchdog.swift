import Foundation
import MultitulCtlCore

public struct AgentKicker: Sendable {
    public static let label = "dev.multitool.app.agent"
    private let runner: ProcessRunning
    private let uid: uid_t

    public init(runner: ProcessRunning = SystemProcessRunner(), uid: uid_t = getuid()) {
        self.runner = runner
        self.uid = uid
    }

    public var arguments: [String] { ["kickstart", "-k", "gui/\(uid)/\(Self.label)"] }

    // Blocking. Never called from tests with the real runner.
    @discardableResult
    public func kickstart() -> Bool {
        runner.run("/bin/launchctl", arguments, timeout: 20).status == 0
    }
}

// App-side decision "the collector is silent, ask launchd to restart it": a few attempts, spaced out, until it answers again.
public struct CollectorWatchdog {
    public var maxAttempts = 3
    public var retryInterval: TimeInterval = 300
    public private(set) var attempts = 0
    private var lastAttempt: Date?

    public init(maxAttempts: Int = 3, retryInterval: TimeInterval = 300) {
        self.maxAttempts = maxAttempts
        self.retryInterval = retryInterval
    }

    public mutating func shouldKick(health: AgentHealth, now: Date) -> Bool {
        switch health.status {
        case .alive:
            attempts = 0
            lastAttempt = nil
            return false
        case .never:
            return false
        case .silent:
            guard attempts < maxAttempts else { return false }
            if let l = lastAttempt, now.timeIntervalSince(l) < retryInterval { return false }
            attempts += 1
            lastAttempt = now
            return true
        }
    }
}
