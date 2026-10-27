import Foundation

public enum IslMscStyle: String, CaseIterable, Sendable {
    case minimal, robot

    public var title: String { self == .minimal ? "Минимальный" : "Робот" }
}

public enum IslMscShape: String, CaseIterable, Sendable {
    case round, squircle, drop

    public var title: String {
        switch self {
        case .round: "Круг"
        case .squircle: "Скруглённый квадрат"
        case .drop: "Капля"
        }
    }
}

public enum IslMscPalette: String, CaseIterable, Sendable {
    case blue, green, pink, orange, violet, white

    public var title: String {
        switch self {
        case .blue: "Синий"
        case .green: "Зелёный"
        case .pink: "Розовый"
        case .orange: "Оранжевый"
        case .violet: "Фиолетовый"
        case .white: "Белый"
        }
    }

    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .blue: (0.30, 0.45, 0.92)
        case .green: (0.30, 0.78, 0.50)
        case .pink: (0.96, 0.45, 0.68)
        case .orange: (0.98, 0.62, 0.25)
        case .violet: (0.64, 0.45, 0.95)
        case .white: (0.95, 0.95, 0.97)
        }
    }
}

public enum IslMscSide: String, CaseIterable, Sendable {
    case left, right

    public var title: String { self == .left ? "Слева от камеры" : "Справа от камеры" }
}

public enum IslMscVisits: String, CaseIterable, Sendable {
    case never, rare, normal, often

    public var title: String {
        switch self {
        case .never: "Не заходит"
        case .rare: "Редко (раз в полчаса)"
        case .normal: "Иногда (раз в 10 минут)"
        case .often: "Часто (раз в 3 минуты)"
        }
    }

    public var meanInterval: TimeInterval? {
        switch self {
        case .never: nil
        case .rare: 1800
        case .normal: 600
        case .often: 180
        }
    }
}

public struct IslMscSettings: Equatable, Sendable {
    public var style = IslMscStyle.minimal
    public var shape = IslMscShape.round
    public var palette = IslMscPalette.blue
    public var side = IslMscSide.right
    public var visits = IslMscVisits.normal
    public var visibleAtRest = false
    public var visitSeconds = 6.0
    public var reactToMusic = true
    public var reactToTimer = true
    public var reactToDownloads = true
    public var reactToShots = true
    public var reactToMic = true
    public var reactToKeepAwake = true

    public init() {}

    public var sanitized: IslMscSettings {
        var s = self
        s.visitSeconds = IslSettings.clamp(visitSeconds, 2...30)
        return s
    }
}

public final class IslMscSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.mascot."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslMscSettings {
        var s = IslMscSettings()
        let p = Self.prefix
        if let v = a.string(p + "style"), let m = IslMscStyle(rawValue: v) { s.style = m }
        if let v = a.string(p + "shape"), let m = IslMscShape(rawValue: v) { s.shape = m }
        if let v = a.string(p + "palette"), let m = IslMscPalette(rawValue: v) { s.palette = m }
        if let v = a.string(p + "side"), let m = IslMscSide(rawValue: v) { s.side = m }
        if let v = a.string(p + "visits"), let m = IslMscVisits(rawValue: v) { s.visits = m }
        s.visibleAtRest = a.bool(p + "visibleAtRest", s.visibleAtRest)
        s.visitSeconds = a.double(p + "visitSeconds", s.visitSeconds)
        s.reactToMusic = a.bool(p + "reactToMusic", s.reactToMusic)
        s.reactToTimer = a.bool(p + "reactToTimer", s.reactToTimer)
        s.reactToDownloads = a.bool(p + "reactToDownloads", s.reactToDownloads)
        s.reactToShots = a.bool(p + "reactToShots", s.reactToShots)
        s.reactToMic = a.bool(p + "reactToMic", s.reactToMic)
        s.reactToKeepAwake = a.bool(p + "reactToKeepAwake", s.reactToKeepAwake)
        return s.sanitized
    }

    public func save(_ settings: IslMscSettings) {
        let s = settings.sanitized
        let b = IslMscSettings()
        let p = Self.prefix
        a.put(p + "style", s.style.rawValue, b.style.rawValue)
        a.put(p + "shape", s.shape.rawValue, b.shape.rawValue)
        a.put(p + "palette", s.palette.rawValue, b.palette.rawValue)
        a.put(p + "side", s.side.rawValue, b.side.rawValue)
        a.put(p + "visits", s.visits.rawValue, b.visits.rawValue)
        a.put(p + "visibleAtRest", s.visibleAtRest, b.visibleAtRest)
        a.put(p + "visitSeconds", s.visitSeconds, b.visitSeconds)
        a.put(p + "reactToMusic", s.reactToMusic, b.reactToMusic)
        a.put(p + "reactToTimer", s.reactToTimer, b.reactToTimer)
        a.put(p + "reactToDownloads", s.reactToDownloads, b.reactToDownloads)
        a.put(p + "reactToShots", s.reactToShots, b.reactToShots)
        a.put(p + "reactToMic", s.reactToMic, b.reactToMic)
        a.put(p + "reactToKeepAwake", s.reactToKeepAwake, b.reactToKeepAwake)
    }
}

public enum IslMscMood: String, CaseIterable, Sendable {
    case resting, visiting, dancing, focused, downloading, camera, listening, awake, working, celebrating, alarmed

    public var title: String {
        switch self {
        case .resting: "Отдыхает"
        case .visiting: "Зашёл в гости"
        case .dancing: "Слушает музыку"
        case .focused: "Следит за таймером"
        case .downloading: "Ждёт загрузку"
        case .camera: "Снимает"
        case .listening: "Слушает микрофон"
        case .awake: "Не спит"
        case .working: "Следит за агентом"
        case .celebrating: "Радуется"
        case .alarmed: "Тревога"
        }
    }
}

public struct IslMscSignals: Equatable, Sendable {
    public var musicPlaying = false
    public var timerRunning = false
    public var timerAlertAt: Date?
    public var downloadActive = false
    public var downloadDoneAt: Date?
    public var shotAt: Date?
    public var micActive = false
    public var keepAwake = false
    public var agentWorking = false
    public var calendarImminent = false

    public init() {}
}

public struct IslMscFrame: Equatable, Sendable {
    public var mood: IslMscMood
    public var visible: Bool

    public init(mood: IslMscMood, visible: Bool) {
        self.mood = mood
        self.visible = visible
    }
}

public struct IslMscMachine: Sendable {
    public static let holdSeconds: TimeInterval = 1.5
    public static let alarmLifetime: TimeInterval = 8
    public static let celebrateLifetime: TimeInterval = 4
    public static let cameraLifetime: TimeInterval = 3

    public var settings = IslMscSettings()
    public private(set) var mood = IslMscMood.resting
    private var moodSince = Date.distantPast
    private var nextVisitAt: Date?
    private var visitUntil: Date?

    public init(settings: IslMscSettings = IslMscSettings()) { self.settings = settings.sanitized }

    static func fresh(_ at: Date?, within: TimeInterval, now: Date) -> Bool {
        guard let at else { return false }
        let d = now.timeIntervalSince(at)
        return d >= 0 && d < within
    }

    public func reaction(_ s: IslMscSignals, now: Date) -> IslMscMood? {
        if (settings.reactToTimer && Self.fresh(s.timerAlertAt, within: Self.alarmLifetime, now: now)) || s.calendarImminent { return .alarmed }
        if settings.reactToDownloads, Self.fresh(s.downloadDoneAt, within: Self.celebrateLifetime, now: now) { return .celebrating }
        if settings.reactToShots, Self.fresh(s.shotAt, within: Self.cameraLifetime, now: now) { return .camera }
        if settings.reactToMic, s.micActive { return .listening }
        if settings.reactToTimer, s.timerRunning { return .focused }
        if settings.reactToDownloads, s.downloadActive { return .downloading }
        if s.agentWorking { return .working }
        if settings.reactToMusic, s.musicPlaying { return .dancing }
        if settings.reactToKeepAwake, s.keepAwake { return .awake }
        return nil
    }

    public mutating func update(_ s: IslMscSignals, now: Date, random: () -> Double) -> IslMscFrame {
        var target: IslMscMood
        if let r = reaction(s, now: now) {
            target = r
            visitUntil = nil
        } else if let until = visitUntil, now < until {
            target = .visiting
        } else {
            if visitUntil != nil { visitUntil = nil; nextVisitAt = nil }
            target = .resting
            if let mean = settings.visits.meanInterval {
                if nextVisitAt == nil { nextVisitAt = now.addingTimeInterval(mean * (0.5 + min(max(random(), 0), 1))) }
                if let n = nextVisitAt, now >= n {
                    visitUntil = now.addingTimeInterval(settings.visitSeconds)
                    nextVisitAt = nil
                    target = .visiting
                }
            } else {
                nextVisitAt = nil
            }
        }
        if target != mood {
            let holding = mood != .resting && mood != .visiting && target != .alarmed && now.timeIntervalSince(moodSince) < Self.holdSeconds && now >= moodSince
            if !holding {
                mood = target
                moodSince = now
            }
        }
        let visible = mood != .resting || settings.visibleAtRest
        return IslMscFrame(mood: mood, visible: visible)
    }

    public mutating func reset() {
        mood = .resting
        moodSince = .distantPast
        nextVisitAt = nil
        visitUntil = nil
    }
}

public enum IslMscProp: String, Sendable { case none, headphones, clock, arrow, flash, mic, coffee, sparkle, spinner, bell }

public struct IslMscPose: Equatable, Sendable {
    public var bounce: Double
    public var tilt: Double
    public var eyeOpen: Double
    public var mouth: Double
    public var prop: IslMscProp
}

public enum IslMscAnimator {
    public static func prop(for mood: IslMscMood) -> IslMscProp {
        switch mood {
        case .dancing: .headphones
        case .focused: .clock
        case .downloading: .arrow
        case .camera: .flash
        case .listening: .mic
        case .awake: .coffee
        case .working: .spinner
        case .celebrating: .sparkle
        case .alarmed: .bell
        case .resting, .visiting: .none
        }
    }

    // Blink every ~4 s for 0.14 s; everything else is a smooth function of time.
    public static func eyeOpen(mood: IslMscMood, t: Double) -> Double {
        if mood == .resting { return 0.15 }
        let phase = t.truncatingRemainder(dividingBy: 4.0)
        if phase > 3.86 { return 0.1 }
        return mood == .alarmed ? 1 : 0.9
    }

    public static func pose(mood: IslMscMood, t: Double) -> IslMscPose {
        let tt = t.isFinite ? t : 0
        switch mood {
        case .resting: return IslMscPose(bounce: 0.02 * abs(sin(tt * 1.2)), tilt: 0, eyeOpen: eyeOpen(mood: mood, t: tt), mouth: 0.1, prop: .none)
        case .visiting: return IslMscPose(bounce: 0.1 * abs(sin(tt * 3)), tilt: 6 * sin(tt * 1.5), eyeOpen: eyeOpen(mood: mood, t: tt), mouth: 0.5, prop: .none)
        case .dancing: return IslMscPose(bounce: 0.28 * abs(sin(tt * 5)), tilt: 12 * sin(tt * 2.5), eyeOpen: eyeOpen(mood: mood, t: tt), mouth: 0.6, prop: prop(for: mood))
        case .celebrating: return IslMscPose(bounce: 0.35 * abs(sin(tt * 6)), tilt: 15 * sin(tt * 4), eyeOpen: 0.8, mouth: 1, prop: prop(for: mood))
        case .alarmed: return IslMscPose(bounce: 0.12 * abs(sin(tt * 9)), tilt: 10 * sin(tt * 12), eyeOpen: 1, mouth: 0.8, prop: prop(for: mood))
        default: return IslMscPose(bounce: 0.06 * abs(sin(tt * 2)), tilt: 3 * sin(tt), eyeOpen: eyeOpen(mood: mood, t: tt), mouth: 0.3, prop: prop(for: mood))
        }
    }
}
