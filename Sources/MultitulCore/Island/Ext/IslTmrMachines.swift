import Foundation

public enum IslTmrPhase: String, Codable, Sendable { case idle, running, paused, finished }

public struct IslTmrCountdown: Codable, Equatable, Sendable {
    public static let maxSeconds: TimeInterval = 24 * 3600

    public var phase = IslTmrPhase.idle
    public var total: TimeInterval = 0
    public var endsAt: Date?
    public var pausedRemaining: TimeInterval = 0
    public var finishedAt: Date?

    public init() {}

    public mutating func start(duration: TimeInterval, now: Date) {
        guard duration.isFinite else { return }
        let d = min(max(duration, 1), Self.maxSeconds)
        total = d
        endsAt = now.addingTimeInterval(d)
        pausedRemaining = 0
        finishedAt = nil
        phase = .running
    }

    public mutating func pause(now: Date) {
        guard phase == .running, let e = endsAt else { return }
        pausedRemaining = max(e.timeIntervalSince(now), 0)
        endsAt = nil
        phase = .paused
    }

    public mutating func resume(now: Date) {
        guard phase == .paused else { return }
        endsAt = now.addingTimeInterval(pausedRemaining)
        pausedRemaining = 0
        phase = .running
    }

    public mutating func reset() {
        self = IslTmrCountdown()
    }

    public mutating func add(seconds: TimeInterval, now: Date) {
        guard seconds.isFinite else { return }
        switch phase {
        case .running:
            if let e = endsAt {
                let next = e.addingTimeInterval(seconds)
                endsAt = max(next, now.addingTimeInterval(1))
                total = min(max(total + seconds, 1), Self.maxSeconds)
            }
        case .paused:
            pausedRemaining = min(max(pausedRemaining + seconds, 1), Self.maxSeconds)
            total = min(max(total + seconds, 1), Self.maxSeconds)
        default:
            break
        }
    }

    // True exactly once, on the transition to finished.
    public mutating func tick(now: Date) -> Bool {
        guard phase == .running, let e = endsAt, now >= e else { return false }
        phase = .finished
        finishedAt = e
        endsAt = nil
        pausedRemaining = 0
        return true
    }

    public func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running: max((endsAt ?? now).timeIntervalSince(now), 0)
        case .paused: pausedRemaining
        case .finished: 0
        case .idle: 0
        }
    }

    public func progress(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        if phase == .finished { return 1 }
        if phase == .idle { return 0 }
        return min(max(1 - remaining(at: now) / total, 0), 1)
    }

    public var isActive: Bool { phase == .running || phase == .paused }
}

public struct IslTmrStopwatch: Codable, Equatable, Sendable {
    public static let maxLaps = 99

    public var phase = IslTmrPhase.idle
    public var startedAt: Date?
    public var accumulated: TimeInterval = 0
    public var laps: [TimeInterval] = []

    public init() {}

    public mutating func start(now: Date) {
        guard phase == .idle else { return }
        startedAt = now
        accumulated = 0
        laps = []
        phase = .running
    }

    public mutating func pause(now: Date) {
        guard phase == .running, let s = startedAt else { return }
        accumulated += max(now.timeIntervalSince(s), 0)
        startedAt = nil
        phase = .paused
    }

    public mutating func resume(now: Date) {
        guard phase == .paused else { return }
        startedAt = now
        phase = .running
    }

    public mutating func reset() { self = IslTmrStopwatch() }

    public func elapsed(at now: Date) -> TimeInterval {
        switch phase {
        case .running: accumulated + max(now.timeIntervalSince(startedAt ?? now), 0)
        case .paused: accumulated
        default: 0
        }
    }

    public mutating func lap(now: Date) {
        guard phase == .running, laps.count < Self.maxLaps else { return }
        laps.append(elapsed(at: now))
    }

    public var lapSplits: [TimeInterval] {
        var prev: TimeInterval = 0
        return laps.map { l in defer { prev = l }; return l - prev }
    }

    public var isActive: Bool { phase == .running || phase == .paused }
}

public enum IslPomPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .focus: "Фокус"
        case .shortBreak: "Короткий перерыв"
        case .longBreak: "Длинный перерыв"
        }
    }

    public var isBreak: Bool { self != .focus }
}

public struct IslPomSettings: Codable, Equatable, Sendable {
    public static let focusRange = 1...180
    public static let shortRange = 1...60
    public static let longRange = 1...120
    public static let sessionsRange = 2...12

    public var focusMinutes = 25
    public var shortMinutes = 5
    public var longMinutes = 15
    public var sessionsBeforeLong = 4
    public var autoStart = true

    public init() {}

    public var sanitized: IslPomSettings {
        var s = self
        s.focusMinutes = ToolsClamp.int(focusMinutes, Self.focusRange)
        s.shortMinutes = ToolsClamp.int(shortMinutes, Self.shortRange)
        s.longMinutes = ToolsClamp.int(longMinutes, Self.longRange)
        s.sessionsBeforeLong = ToolsClamp.int(sessionsBeforeLong, Self.sessionsRange)
        return s
    }

    public func duration(of phase: IslPomPhase) -> TimeInterval {
        switch phase {
        case .focus: TimeInterval(focusMinutes) * 60
        case .shortBreak: TimeInterval(shortMinutes) * 60
        case .longBreak: TimeInterval(longMinutes) * 60
        }
    }
}

public struct IslPomEvent: Equatable, Sendable {
    public var finished: IslPomPhase
    public var next: IslPomPhase
    public var autoStarted: Bool
    public var at: Date
}

public struct IslTmrPomodoro: Codable, Equatable, Sendable {
    public var phase = IslPomPhase.focus
    public var session = 1
    public var completedFocus = 0
    public var clock = IslTmrCountdown()
    public var started = false

    public init() {}

    public var isActive: Bool { clock.isActive }
    public var waiting: Bool { started && clock.phase == .idle }

    public mutating func start(now: Date, settings: IslPomSettings) {
        guard clock.phase == .idle else { return }
        started = true
        clock.start(duration: settings.duration(of: phase), now: now)
    }

    public mutating func pause(now: Date) { clock.pause(now: now) }

    public mutating func resume(now: Date) { clock.resume(now: now) }

    public mutating func reset() { self = IslTmrPomodoro() }

    public mutating func skip(now: Date, settings: IslPomSettings) {
        guard started else { return }
        advance(from: phase, settings: settings)
        clock.reset()
        clock.start(duration: settings.duration(of: phase), now: now)
    }

    private mutating func advance(from finished: IslPomPhase, settings: IslPomSettings) {
        switch finished {
        case .focus:
            phase = session >= settings.sessionsBeforeLong ? .longBreak : .shortBreak
        case .shortBreak:
            session += 1
            phase = .focus
        case .longBreak:
            session = 1
            phase = .focus
        }
    }

    public mutating func tick(now: Date, settings: IslPomSettings) -> [IslPomEvent] {
        var out: [IslPomEvent] = []
        var guardCount = 0
        while guardCount < 24, clock.tick(now: now) {
            guardCount += 1
            let at = clock.finishedAt ?? now
            let done = phase
            if done == .focus { completedFocus += 1 }
            advance(from: done, settings: settings)
            if settings.autoStart {
                clock.reset()
                clock.start(duration: settings.duration(of: phase), now: at)
            } else {
                clock.reset()
            }
            out.append(IslPomEvent(finished: done, next: phase, autoStarted: settings.autoStart, at: at))
            if !settings.autoStart { break }
        }
        return out
    }

    public func remaining(at now: Date, settings: IslPomSettings) -> TimeInterval {
        clock.phase == .idle ? settings.duration(of: phase) : clock.remaining(at: now)
    }

    public func label(settings: IslPomSettings) -> String {
        phase == .focus ? "Фокус \(session)/\(settings.sessionsBeforeLong)" : phase.title
    }
}
