import Foundation
import SwiftUI

public enum VpnSpeedMath {
    public static func mbps(bytes: Double, seconds: Double) -> Double {
        seconds > 0 ? bytes / seconds / 1_000_000 : 0
    }

    public static func format(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    public static func eventDetail(mbps: Double, bytes: Double, seconds: Double) -> String {
        "\(format(mbps)) МБ/с · \(VpnFormat.bytes(bytes)) за \(format(seconds)) с"
    }
}

public protocol VpnSpeedRunning: Sendable {
    func run(progress: @escaping @Sendable (Double, Double) -> Void) async -> (bytes: Double, seconds: Double)?
}

public final class CloudflareSpeedTester: NSObject, URLSessionDataDelegate, VpnSpeedRunning, @unchecked Sendable {
    public static let url = "https://speed.cloudflare.com/__down?bytes=25000000"
    private var received = 0.0
    private var started = Date()
    private var lastReport = Date.distantPast
    private var cont: CheckedContinuation<(bytes: Double, seconds: Double)?, Never>?
    private var progress: (@Sendable (Double, Double) -> Void)?
    private var session: URLSession?

    public override init() { super.init() }

    public func run(progress: @escaping @Sendable (Double, Double) -> Void) async -> (bytes: Double, seconds: Double)? {
        self.progress = progress
        return await withCheckedContinuation { c in
            cont = c
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 45
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            started = Date()
            s.dataTask(with: URL(string: Self.url)!).resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Double(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            progress?(received, now.timeIntervalSince(started))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let secs = Date().timeIntervalSince(started)
        let ok = error == nil && received > 1_000_000
        session.finishTasksAndInvalidate()
        cont?.resume(returning: ok ? (received, secs) : nil)
        cont = nil
    }
}

@MainActor
public final class VpnSpeedModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle, running(Double), done(Double), failed
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var finishedAt: Date?
    public var onResult: ((Double, Double, Double) -> Void)?

    private let makeRunner: @Sendable () -> VpnSpeedRunning
    private let clock: () -> Date

    public init(makeRunner: @escaping @Sendable () -> VpnSpeedRunning = { CloudflareSpeedTester() }, clock: @escaping () -> Date = { Date() }) {
        self.makeRunner = makeRunner
        self.clock = clock
    }

    public var isRunning: Bool { if case .running = phase { return true } else { return false } }

    // Awaitable so tests can drive it; the UI wraps this in a Task.
    public func run() async {
        guard !isRunning else { return }
        phase = .running(0)
        let runner = makeRunner()
        let r = await runner.run { [weak self] bytes, secs in
            let v = VpnSpeedMath.mbps(bytes: bytes, seconds: secs)
            Task { @MainActor in
                if self?.isRunning == true { self?.phase = .running(v) }
            }
        }
        finishedAt = clock()
        if let r {
            let v = VpnSpeedMath.mbps(bytes: r.bytes, seconds: r.seconds)
            phase = .done(v)
            Log.write("vpn speedtest mbps=\(VpnSpeedMath.format(v)) bytes=\(Int(r.bytes)) seconds=\(String(format: "%.2f", r.seconds))")
            onResult?(v, r.bytes, r.seconds)
        } else {
            phase = .failed
            Log.write("vpn speedtest failed")
        }
    }

    public func start() {
        guard !isRunning else { return }
        Task { await run() }
    }
}
