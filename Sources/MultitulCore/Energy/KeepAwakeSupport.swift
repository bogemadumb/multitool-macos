import Foundation

public enum KeepAwakeFormat {
    public static func remaining(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    public static func duration(minutes: Int) -> String {
        if minutes <= 0 { return "бессрочно" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    public static func menuTitle(session: KeepAwakeSession?, now: Date, showRemaining: Bool) -> String {
        guard showRemaining, let s = session, let r = s.remaining(at: now) else { return "" }
        return " " + remaining(r)
    }

    public static func status(engine: KeepAwakeEngine, now: Date) -> String {
        guard let s = engine.session else { return engine.automationOn ? "Включён по условию" : "Выключен" }
        let lid = s.closedLid ? ", крышка закрыта" : ""
        switch s.end {
        case .never: return "Включён, бессрочно" + lid
        case .at(let d): return "Осталось \(remaining(d.timeIntervalSince(now)))" + lid
        case .appQuits: return "Пока работает приложение" + lid
        }
    }
}

public enum KeepAwakeUntil {
    // Next occurrence of hh:mm strictly after now (today, else tomorrow).
    public static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
    }
}

public enum KeepAwakeParsers {
    // `pmset -g` prints " SleepDisabled\t\t1".
    public static func sleepDisabled(pmsetG text: String) -> Bool? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }
}

public enum KeepAwakeRecoveryPlan: Equatable, Sendable {
    case nothing
    case restoreAndClear
    case clearFlagOnly
    case foreignSleepDisabled
}

public enum KeepAwakeRecovery {
    public static func plan(flag: Bool, sleepDisabled: Bool?) -> KeepAwakeRecoveryPlan {
        switch (flag, sleepDisabled) {
        case (true, false?): .clearFlagOnly
        case (true, _): .restoreAndClear
        case (false, true?): .foreignSleepDisabled
        case (false, _): .nothing
        }
    }
}

public final class KeepAwakeMarkers {
    private let dir: String
    private var lidPath: String { dir + "/keepawake-lid.flag" }
    private var dimPath: String { dir + "/keepawake-dim.json" }

    public init(dir: String = MultitulPaths.home) { self.dir = dir }

    public var lidFlag: Bool { FileManager.default.fileExists(atPath: lidPath) }

    public func setLidFlag(_ on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: lidPath, contents: Data(String(Int(Date().timeIntervalSince1970)).utf8))
        } else {
            try? fm.removeItem(atPath: lidPath)
        }
    }

    public struct Dim: Codable, Equatable, Sendable {
        public var displayID: UInt32
        public var brightness: Double
        public init(displayID: UInt32, brightness: Double) {
            self.displayID = displayID
            self.brightness = brightness
        }
    }

    public var dim: Dim? {
        get { (try? Data(contentsOf: URL(fileURLWithPath: dimPath))).flatMap { try? JSONDecoder().decode(Dim.self, from: $0) } }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: dimPath, contents: d)
            } else {
                try? FileManager.default.removeItem(atPath: dimPath)
            }
        }
    }
}

public protocol KeepAwakeHost: AnyObject {
    func holdAssertion(displayToo: Bool) -> Bool
    func releaseAssertion()
    func setClosedLid(_ on: Bool) -> String?
    func dimBuiltin(_ on: Bool)
    func jiggle()
    func notify(_ notice: KeepAwakeNotice)
    func isSleepDisabled() -> Bool?
}

// Applies engine actions to the system and keeps the lid marker honest:
// set before disablesleep is switched on, removed only after it is confirmed off.
public final class KeepAwakeRunner {
    public private(set) var engine: KeepAwakeEngine
    private let host: KeepAwakeHost
    private let markers: KeepAwakeMarkers
    private var lidRetryAt: Date?

    public init(engine: KeepAwakeEngine, host: KeepAwakeHost, markers: KeepAwakeMarkers) {
        self.engine = engine
        self.host = host
        self.markers = markers
    }

    public func start(_ session: KeepAwakeSession, inputs: KeepAwakeInputs) {
        run(engine.start(session, inputs: inputs), inputs: inputs)
    }

    public func stop(inputs: KeepAwakeInputs) {
        run(engine.stop(inputs: inputs), inputs: inputs)
    }

    public func tick(_ inputs: KeepAwakeInputs) {
        run(engine.tick(inputs), inputs: inputs)
        retryLidRestore(now: inputs.now, force: false)
    }

    // A failed "disablesleep off" leaves the marker behind: keep trying every 30 s while no lid session runs.
    private func retryLidRestore(now: Date, force: Bool) {
        guard markers.lidFlag, !engine.lidHeld else { return }
        if !force, let at = lidRetryAt, now < at { return }
        lidRetryAt = now.addingTimeInterval(30)
        if host.setClosedLid(false) == nil { markers.setLidFlag(false); lidRetryAt = nil }
    }

    public func apply(settings: KeepAwakeSettings, inputs: KeepAwakeInputs) {
        run(engine.apply(settings: settings, inputs: inputs), inputs: inputs)
    }

    public func shutdown(inputs: KeepAwakeInputs) {
        run(engine.shutdown(inputs: inputs), inputs: inputs)
        retryLidRestore(now: inputs.now, force: true)
    }

    @discardableResult
    public func recoverOnStart() -> KeepAwakeRecoveryPlan {
        let plan = KeepAwakeRecovery.plan(flag: markers.lidFlag, sleepDisabled: host.isSleepDisabled())
        switch plan {
        case .nothing, .foreignSleepDisabled: break
        case .clearFlagOnly: markers.setLidFlag(false)
        case .restoreAndClear:
            if let err = host.setClosedLid(false) {
                host.notify(.lidRestoreFailed(err))
            } else {
                markers.setLidFlag(false)
            }
        }
        return plan
    }

    private func run(_ actions: [KeepAwakeAction], inputs: KeepAwakeInputs) {
        var queue = actions
        while !queue.isEmpty {
            let a = queue.removeFirst()
            switch a {
            case .holdAssertion(let d): if !host.holdAssertion(displayToo: d) { Log.write("keepAwake assertion failed") }
            case .releaseAssertion: host.releaseAssertion()
            case .setClosedLid(true):
                markers.setLidFlag(true)
                if let err = host.setClosedLid(true) {
                    markers.setLidFlag(false)
                    queue.append(contentsOf: engine.lidFailed(err, inputs: inputs))
                }
            case .setClosedLid(false):
                if let err = host.setClosedLid(false) {
                    lidRetryAt = inputs.now.addingTimeInterval(30)
                    host.notify(.lidRestoreFailed(err))
                } else {
                    markers.setLidFlag(false)
                }
            case .dimBuiltin(let on): host.dimBuiltin(on)
            case .jiggle: host.jiggle()
            case .notify(let n): host.notify(n)
            }
        }
    }
}
