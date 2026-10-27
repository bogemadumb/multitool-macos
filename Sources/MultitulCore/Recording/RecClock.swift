import Foundation

public struct RecGap: Equatable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

public struct RecPauseClock: Equatable, Sendable {
    public private(set) var origin: Double?
    public private(set) var gaps: [RecGap] = []
    public private(set) var stoppedAt: Double?

    public init() {}

    public var isStarted: Bool { origin != nil }
    public var isPaused: Bool { gaps.last.map { $0.end == nil } ?? false }

    public mutating func begin(at host: Double) {
        origin = host
        gaps = []
        stoppedAt = nil
    }

    public mutating func pause(at host: Double) {
        guard origin != nil, stoppedAt == nil, !isPaused, host >= (origin ?? 0) else { return }
        gaps.append(RecGap(start: host))
    }

    public mutating func resume(at host: Double) {
        guard isPaused, let i = gaps.indices.last else { return }
        gaps[i].end = max(host, gaps[i].start)
    }

    public mutating func stop(at host: Double) {
        guard origin != nil, stoppedAt == nil else { return }
        if isPaused { resume(at: host) }
        stoppedAt = max(host, origin ?? host)
    }

    public func pausedTotal(before pts: Double) -> Double {
        var total = 0.0
        for g in gaps {
            guard let e = g.end else { continue }
            if e <= pts { total += e - g.start } else if g.start < pts { total += pts - g.start }
        }
        return total
    }

    public func isInsideGap(_ pts: Double) -> Bool {
        gaps.contains { pts >= $0.start && pts < ($0.end ?? .infinity) }
    }

    public func timeline(for pts: Double) -> Double? {
        guard let o = origin, pts >= o, !isInsideGap(pts) else { return nil }
        if let s = stoppedAt, pts > s { return nil }
        return pts - o - pausedTotal(before: pts)
    }

    public func elapsed(at host: Double) -> Double {
        guard let o = origin else { return 0 }
        let h = min(host, stoppedAt ?? host)
        return max(h - o - pausedTotal(before: h) - (isPaused ? max(h - (gaps.last?.start ?? h), 0) : 0), 0)
    }

    public var totalPaused: Double { stoppedAt.map { pausedTotal(before: $0) } ?? gaps.reduce(0) { $0 + (($1.end ?? $1.start) - $1.start) } }

    public func finalDuration() -> Double? {
        guard let o = origin, let s = stoppedAt else { return nil }
        return max(s - o - pausedTotal(before: s), 0)
    }
}

public enum RecDropReason: Equatable, Sendable {
    case notStarted, beforeOrigin, paused, afterStop, nonMonotonic, invalid, trackDisabled
}

public enum RecRoute: Equatable, Sendable {
    case drop(RecDropReason)
    case write(outPTS: Double, trimHead: Double)
}

public struct RecTrackStats: Equatable, Sendable {
    public var written = 0
    public var dropped = 0
    public var droppedPaused = 0
    public var lastOut: Double?
    public var lastEnd: Double = 0
}

public struct RecSampleRouter: Sendable {
    public private(set) var clock = RecPauseClock()
    public private(set) var stats: [RecTrackKind: RecTrackStats] = [:]
    public let enabled: Set<RecTrackKind>
    public static let epsilon = 0.0005

    public init(enabled: Set<RecTrackKind>) { self.enabled = enabled }

    public mutating func begin(at host: Double) { clock.begin(at: host) }
    public mutating func pause(at host: Double) { clock.pause(at: host) }
    public mutating func resume(at host: Double) { clock.resume(at: host) }
    public mutating func stop(at host: Double) { clock.stop(at: host) }

    public var duration: Double? { clock.finalDuration() }

    public func stat(_ k: RecTrackKind) -> RecTrackStats { stats[k] ?? RecTrackStats() }

    public mutating func route(_ track: RecTrackKind, pts: Double, duration: Double) -> RecRoute {
        func drop(_ r: RecDropReason) -> RecRoute {
            var s = stat(track)
            s.dropped += 1
            if r == .paused { s.droppedPaused += 1 }
            stats[track] = s
            return .drop(r)
        }
        guard enabled.contains(track) else { return .drop(.trackDisabled) }
        guard pts.isFinite, duration.isFinite, duration >= 0 else { return drop(.invalid) }
        guard let origin = clock.origin else { return drop(.notStarted) }
        var trim = 0.0
        var effective = pts
        if track.isAudio, pts < origin, pts + duration > origin + 0.001 {
            trim = origin - pts
            effective = origin
        }
        if effective < origin { return drop(.beforeOrigin) }
        if let s = clock.stoppedAt, effective > s { return drop(.afterStop) }
        if clock.isInsideGap(effective) { return drop(.paused) }
        guard let out = clock.timeline(for: effective) else { return drop(.beforeOrigin) }
        var s = stat(track)
        if let last = s.lastOut, out <= last + Self.epsilon { return drop(.nonMonotonic) }
        s.written += 1
        s.lastOut = out
        s.lastEnd = out + max(duration - trim, 0)
        stats[track] = s
        return .write(outPTS: out, trimHead: trim)
    }

    // audio drift: difference between the last written audio and video end times
    public func avDrift(audio: RecTrackKind) -> Double? {
        let v = stat(.video), a = stat(audio)
        guard v.written > 0, a.written > 0 else { return nil }
        return a.lastEnd - v.lastEnd
    }
}

public enum RecTimeFormat {
    public static func clock(_ seconds: Double) -> String {
        let t = Int(max(seconds, 0).rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public static func precise(_ seconds: Double) -> String {
        let v = max(seconds, 0)
        let t = Int(v.rounded(.down))
        let cs = Int(((v - Double(t)) * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", t / 60, t % 60, min(cs, 99))
    }

    public static func bytes(_ n: Int) -> String {
        let v = Double(max(n, 0))
        if v < 1_000_000 { return String(format: "%.0f КБ", v / 1000) }
        if v < 1_000_000_000 { return String(format: "%.1f МБ", v / 1_000_000) }
        return String(format: "%.2f ГБ", v / 1_000_000_000)
    }
}
