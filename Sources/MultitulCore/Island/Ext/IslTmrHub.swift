import Foundation

public enum IslTmrKind: String, Codable, Sendable { case timer, stopwatch, pomodoro }

public enum IslTmrEvent: Equatable, Sendable {
    case timerFinished(at: Date)
    case pomodoroFinished(IslPomEvent)

    public var title: String {
        switch self {
        case .timerFinished: "Таймер закончился"
        case .pomodoroFinished(let e):
            e.finished == .focus ? "Фокус закончился: \(e.next.title.lowercased())" : "Перерыв закончился: пора за работу"
        }
    }
}

public enum IslTmrSounds {
    public static let names = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Purr", "Tink", "Sosumi", "Basso", "Blow", "Bottle", "Frog", "Morse", "Pop"]
    public static let fallback = "Glass"
}

public struct IslTmrSettings: Equatable, Sendable {
    public static let minutesRange = 1...600
    public static let repeatsRange = 1...5

    public var defaultMinutes = 15
    public var hideCountdown = false
    public var soundEnabled = true
    public var sound = IslTmrSounds.fallback
    public var soundRepeats = 1
    public var pomodoro = IslPomSettings()

    public init() {}

    public var sanitized: IslTmrSettings {
        var s = self
        s.defaultMinutes = ToolsClamp.int(defaultMinutes, Self.minutesRange)
        s.soundRepeats = ToolsClamp.int(soundRepeats, Self.repeatsRange)
        if !IslTmrSounds.names.contains(sound) { s.sound = IslTmrSounds.fallback }
        s.pomodoro = pomodoro.sanitized
        return s
    }
}

public final class IslTmrSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.timer."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslTmrSettings {
        var s = IslTmrSettings()
        let p = Self.prefix
        s.defaultMinutes = a.int(p + "defaultMinutes", s.defaultMinutes)
        s.hideCountdown = a.bool(p + "hideCountdown", s.hideCountdown)
        s.soundEnabled = a.bool(p + "soundEnabled", s.soundEnabled)
        if let v = a.string(p + "sound") { s.sound = v }
        s.soundRepeats = a.int(p + "soundRepeats", s.soundRepeats)
        s.pomodoro.focusMinutes = a.int(p + "pomFocus", s.pomodoro.focusMinutes)
        s.pomodoro.shortMinutes = a.int(p + "pomShort", s.pomodoro.shortMinutes)
        s.pomodoro.longMinutes = a.int(p + "pomLong", s.pomodoro.longMinutes)
        s.pomodoro.sessionsBeforeLong = a.int(p + "pomSessions", s.pomodoro.sessionsBeforeLong)
        s.pomodoro.autoStart = a.bool(p + "pomAutoStart", s.pomodoro.autoStart)
        return s.sanitized
    }

    public func save(_ settings: IslTmrSettings) {
        let s = settings.sanitized
        let b = IslTmrSettings()
        let p = Self.prefix
        a.put(p + "defaultMinutes", s.defaultMinutes, b.defaultMinutes)
        a.put(p + "hideCountdown", s.hideCountdown, b.hideCountdown)
        a.put(p + "soundEnabled", s.soundEnabled, b.soundEnabled)
        a.put(p + "sound", s.sound, b.sound)
        a.put(p + "soundRepeats", s.soundRepeats, b.soundRepeats)
        a.put(p + "pomFocus", s.pomodoro.focusMinutes, b.pomodoro.focusMinutes)
        a.put(p + "pomShort", s.pomodoro.shortMinutes, b.pomodoro.shortMinutes)
        a.put(p + "pomLong", s.pomodoro.longMinutes, b.pomodoro.longMinutes)
        a.put(p + "pomSessions", s.pomodoro.sessionsBeforeLong, b.pomodoro.sessionsBeforeLong)
        a.put(p + "pomAutoStart", s.pomodoro.autoStart, b.pomodoro.autoStart)
    }
}

public enum IslTmrHotkeys {
    public static let toggle = HotkeySpec(id: "notch.timer.toggle", title: "Остров: запустить или поставить на паузу таймер", defaultCombo: .none)
    public static let cancel = HotkeySpec(id: "notch.timer.cancel", title: "Остров: сбросить таймер", defaultCombo: .none)
    public static let all = [toggle, cancel]
}

public struct IslTmrPrimary: Equatable, Sendable {
    public var kind: IslTmrKind
    public var seconds: TimeInterval
    public var progress: Double?
    public var running: Bool
    public var label: String
}

public struct IslTmrState: Codable, Equatable, Sendable {
    public var timer = IslTmrCountdown()
    public var stopwatch = IslTmrStopwatch()
    public var pomodoro = IslTmrPomodoro()
    public init() {}
}

public struct IslTmrHub: Equatable, Sendable {
    public static let alertLifetime: TimeInterval = 8

    public var state = IslTmrState()
    public var settings = IslTmrSettings()
    public private(set) var alertAt: Date?
    public private(set) var alertTitle = ""

    public init(state: IslTmrState = IslTmrState(), settings: IslTmrSettings = IslTmrSettings()) {
        self.state = state
        self.settings = settings.sanitized
    }

    // MARK: intents

    public mutating func startTimer(minutes: Int? = nil, now: Date) {
        let m = ToolsClamp.int(minutes ?? settings.defaultMinutes, IslTmrSettings.minutesRange)
        state.timer.start(duration: TimeInterval(m) * 60, now: now)
    }

    public mutating func startTimer(seconds: TimeInterval, now: Date) { state.timer.start(duration: seconds, now: now) }

    public mutating func toggleTimer(now: Date) {
        switch state.timer.phase {
        case .idle, .finished: startTimer(now: now)
        case .running: state.timer.pause(now: now)
        case .paused: state.timer.resume(now: now)
        }
    }

    public mutating func toggleStopwatch(now: Date) {
        switch state.stopwatch.phase {
        case .idle: state.stopwatch.start(now: now)
        case .running: state.stopwatch.pause(now: now)
        case .paused: state.stopwatch.resume(now: now)
        case .finished: state.stopwatch.reset()
        }
    }

    public mutating func togglePomodoro(now: Date) {
        if state.pomodoro.clock.phase == .running { state.pomodoro.pause(now: now) }
        else if state.pomodoro.clock.phase == .paused { state.pomodoro.resume(now: now) }
        else { state.pomodoro.start(now: now, settings: settings.pomodoro) }
    }

    public mutating func reset(_ kind: IslTmrKind) {
        switch kind {
        case .timer: state.timer.reset()
        case .stopwatch: state.stopwatch.reset()
        case .pomodoro: state.pomodoro.reset()
        }
    }

    public mutating func dismissAlert() {
        alertAt = nil
        alertTitle = ""
    }

    public mutating func updateSettings(_ s: IslTmrSettings) { settings = s.sanitized }

    // MARK: time

    public mutating func tick(now: Date) -> [IslTmrEvent] {
        var out: [IslTmrEvent] = []
        if state.timer.tick(now: now) { out.append(.timerFinished(at: state.timer.finishedAt ?? now)) }
        for e in state.pomodoro.tick(now: now, settings: settings.pomodoro) { out.append(.pomodoroFinished(e)) }
        if let last = out.last {
            alertAt = now
            alertTitle = last.title
        }
        if let a = alertAt, now.timeIntervalSince(a) >= Self.alertLifetime || now < a { dismissAlert() }
        return out
    }

    public var anyActive: Bool {
        state.timer.isActive || state.stopwatch.isActive || state.pomodoro.isActive || state.pomodoro.waiting
    }

    public func primary(now: Date) -> IslTmrPrimary? {
        var candidates: [(Date, IslTmrPrimary)] = []
        if state.timer.phase == .running, let e = state.timer.endsAt {
            candidates.append((e, IslTmrPrimary(kind: .timer, seconds: state.timer.remaining(at: now), progress: state.timer.progress(at: now), running: true, label: "Таймер")))
        }
        let pom = state.pomodoro
        if pom.clock.phase == .running, let e = pom.clock.endsAt {
            candidates.append((e, IslTmrPrimary(kind: .pomodoro, seconds: pom.clock.remaining(at: now), progress: pom.clock.progress(at: now), running: true, label: pom.label(settings: settings.pomodoro))))
        }
        if let best = candidates.min(by: { $0.0 < $1.0 }) { return best.1 }
        if state.timer.phase == .paused {
            return IslTmrPrimary(kind: .timer, seconds: state.timer.pausedRemaining, progress: state.timer.progress(at: now), running: false, label: "Таймер на паузе")
        }
        if pom.clock.phase == .paused {
            return IslTmrPrimary(kind: .pomodoro, seconds: pom.clock.pausedRemaining, progress: pom.clock.progress(at: now), running: false, label: pom.label(settings: settings.pomodoro) + ", пауза")
        }
        if pom.waiting {
            return IslTmrPrimary(kind: .pomodoro, seconds: settings.pomodoro.duration(of: pom.phase), progress: 0, running: false, label: pom.phase.title + ": ждёт старта")
        }
        if state.stopwatch.isActive {
            return IslTmrPrimary(kind: .stopwatch, seconds: state.stopwatch.elapsed(at: now), progress: nil, running: state.stopwatch.phase == .running,
                                 label: state.stopwatch.phase == .running ? "Секундомер" : "Секундомер на паузе")
        }
        return nil
    }

    public func activity(now: Date) -> IslActivity? {
        if let a = alertAt, now >= a, now.timeIntervalSince(a) < Self.alertLifetime {
            return IslActivity(id: "timer", section: IslSectionIDs.timer, priority: IslPriority.timer, startedAt: a, expiresAt: a.addingTimeInterval(Self.alertLifetime),
                               peeks: true, token: "done|\(Int(a.timeIntervalSince1970))", title: alertTitle)
        }
        guard let p = primary(now: now) else { return nil }
        let started: Date
        switch p.kind {
        case .timer: started = state.timer.endsAt.map { $0.addingTimeInterval(-state.timer.total) } ?? now
        case .pomodoro: started = state.pomodoro.clock.endsAt.map { $0.addingTimeInterval(-state.pomodoro.clock.total) } ?? now
        case .stopwatch: started = state.stopwatch.startedAt ?? now
        }
        let token = "\(p.running ? "run" : "pause")|\(p.kind.rawValue)|" + (p.kind == .pomodoro ? "\(state.pomodoro.phase.rawValue)|\(state.pomodoro.session)" : "")
        return IslActivity(id: "timer", section: IslSectionIDs.timer, priority: IslPriority.timer, startedAt: started, peeks: false, token: token, title: p.label)
    }
}

public final class IslTmrPersistence {
    private let kv: KeyValueStoring
    static let key = "notch.timer.state"
    static var keyForTests: String { key }

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    public func save(_ state: IslTmrState) {
        let idle = state == IslTmrState()
        if idle { kv.removeObject(forKey: Self.key); return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(state), let s = String(data: d, encoding: .utf8) { kv.set(s, forKey: Self.key) }
    }

    public func load() -> IslTmrState {
        guard let s = kv.object(forKey: Self.key) as? String, let d = s.data(using: .utf8) else { return IslTmrState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode(IslTmrState.self, from: d)) ?? IslTmrState()
    }
}

public enum IslTmrFormat {
    public static func clock(_ seconds: TimeInterval) -> String { IslTimeFormat.clock(seconds) }

    public static func stopwatch(_ seconds: TimeInterval) -> String {
        let t = max(seconds, 0)
        let cs = Int((t * 100).rounded(.down)) % 100
        return IslTimeFormat.clock(t) + String(format: ".%02d", cs)
    }

    public static func parseMinutes(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), IslTmrSettings.minutesRange.contains(v) else { return nil }
        return v
    }
}
