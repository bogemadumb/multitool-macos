import Foundation

public struct IslWatSignature: Equatable, Sendable {
    public static let side = 16
    public var cells: [UInt8]

    public init(cells: [UInt8]) { self.cells = cells }

    // Box-averages a grayscale frame into a 16x16 grid.
    public static func make(gray: [UInt8], width: Int, height: Int) -> IslWatSignature? {
        guard width > 0, height > 0, gray.count >= width * height else { return nil }
        let n = side
        var out = [UInt8](repeating: 0, count: n * n)
        for gy in 0..<n {
            let y0 = gy * height / n, y1 = max((gy + 1) * height / n, y0 + 1)
            for gx in 0..<n {
                let x0 = gx * width / n, x1 = max((gx + 1) * width / n, x0 + 1)
                var sum = 0, count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        sum += Int(gray[y * width + x])
                        count += 1
                    }
                }
                out[gy * n + gx] = count == 0 ? 0 : UInt8(sum / count)
            }
        }
        return IslWatSignature(cells: out)
    }

    // 0 identical ... 1 opposite; mean absolute difference per cell.
    public func distance(to o: IslWatSignature) -> Double {
        guard cells.count == o.cells.count, !cells.isEmpty else { return 1 }
        var sum = 0
        for i in cells.indices { sum += abs(Int(cells[i]) - Int(o.cells[i])) }
        return Double(sum) / Double(cells.count * 255)
    }
}

public enum IslWatText {
    public static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // "73%", "73 %", "Progress: 73.5%" -> 0.735
    public static func percent(in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d+)?)\s?%"#) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var values: [Double] = []
        for m in matches {
            let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            if let v = Double(raw), v >= 0, v <= 100 { values.append(v / 100) }
        }
        return values.last
    }

    public static func done(in text: String) -> Bool {
        let t = text.lowercased()
        return ["complete", "completed", "finished", "build succeeded", "done", "готово", "завершен", "завершён", "выполнено", "успешно"].contains { t.contains($0) }
    }
}

public enum IslWatEvent: Equatable, Sendable {
    case started
    case changed
    case settled(after: TimeInterval)
    case progress(Double)
}

public struct IslWatSettings: Equatable, Sendable {
    public static let settleRange: ClosedRange<Double> = 5...300
    public static let intervalRange: ClosedRange<Double> = 0.5...30
    public static let sensitivityRange: ClosedRange<Double> = 0.002...0.2

    public var settleSeconds = 30.0
    public var interval = 2.0
    public var sensitivity = 0.012
    public var readText = true
    public var stopAfterSettled = true

    public init() {}

    public var sanitized: IslWatSettings {
        var s = self
        s.settleSeconds = IslSettings.clamp(settleSeconds, Self.settleRange)
        s.interval = IslSettings.clamp(interval, Self.intervalRange)
        s.sensitivity = IslSettings.clamp(sensitivity, Self.sensitivityRange)
        return s
    }
}

public final class IslWatSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.watch."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslWatSettings {
        var s = IslWatSettings()
        let p = Self.prefix
        s.settleSeconds = a.double(p + "settleSeconds", s.settleSeconds)
        s.interval = a.double(p + "interval", s.interval)
        s.sensitivity = a.double(p + "sensitivity", s.sensitivity)
        s.readText = a.bool(p + "readText", s.readText)
        s.stopAfterSettled = a.bool(p + "stopAfterSettled", s.stopAfterSettled)
        return s.sanitized
    }

    public func save(_ settings: IslWatSettings) {
        let s = settings.sanitized
        let b = IslWatSettings()
        let p = Self.prefix
        a.put(p + "settleSeconds", s.settleSeconds, b.settleSeconds)
        a.put(p + "interval", s.interval, b.interval)
        a.put(p + "sensitivity", s.sensitivity, b.sensitivity)
        a.put(p + "readText", s.readText, b.readText)
        a.put(p + "stopAfterSettled", s.stopAfterSettled, b.stopAfterSettled)
    }
}

public struct IslWatRegion: Equatable, Sendable {
    public var displayID: UInt32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(displayID: UInt32, x: Double, y: Double, width: Double, height: Double) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool { width >= 8 && height >= 8 && [x, y, width, height].allSatisfy(\.isFinite) }

    public var stored: String { [Double(displayID), x, y, width, height].map { String(Int($0.rounded())) }.joined(separator: ",") }

    public init?(stored: String?) {
        guard let parts = stored?.split(separator: ",").compactMap({ Double($0) }), parts.count == 5, parts[0] >= 0 else { return nil }
        self.init(displayID: UInt32(parts[0]), x: parts[1], y: parts[2], width: parts[3], height: parts[4])
        if !isValid { return nil }
    }
}

public struct IslWatDetector: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, watching, changing, settled }

    public private(set) var phase = Phase.idle
    public private(set) var baseline: IslWatSignature?
    public private(set) var lastChange: Date?
    public private(set) var firstChange: Date?
    public private(set) var changes = 0
    public private(set) var progress: Double?
    public private(set) var lastText = ""
    public var settings = IslWatSettings()

    public init(settings: IslWatSettings = IslWatSettings()) { self.settings = settings.sanitized }

    public var isRunning: Bool { phase != .idle && phase != .settled }

    public mutating func begin(_ sig: IslWatSignature?, text: String? = nil, now: Date) -> [IslWatEvent] {
        self = IslWatDetector(settings: settings)
        phase = .watching
        baseline = sig
        lastText = IslWatText.normalized(text ?? "")
        progress = text.flatMap(IslWatText.percent(in:))
        return [.started]
    }

    public mutating func stop() { self = IslWatDetector(settings: settings) }

    public mutating func feed(_ sig: IslWatSignature?, text: String? = nil, now: Date) -> [IslWatEvent] {
        guard phase == .watching || phase == .changing else { return [] }
        var events: [IslWatEvent] = []
        var moved = false
        if let sig {
            if let b = baseline { moved = sig.distance(to: b) >= settings.sensitivity }
            baseline = sig
        }
        if settings.readText, let text {
            let norm = IslWatText.normalized(text)
            if norm != lastText {
                moved = true
                lastText = norm
            }
            if let p = IslWatText.percent(in: text), p != progress {
                progress = p
                events.append(.progress(p))
            }
        }
        if moved {
            changes += 1
            lastChange = now
            if firstChange == nil { firstChange = now }
            if phase == .watching { events.append(.changed) }
            phase = .changing
        } else if phase == .changing, let last = lastChange, now.timeIntervalSince(last) >= settings.settleSeconds {
            phase = .settled
            events.append(.settled(after: now.timeIntervalSince(firstChange ?? last)))
        }
        return events
    }
}

public enum IslWatActivityFactory {
    public static let doneLifetime: TimeInterval = 10

    public static func activity(_ d: IslWatDetector, settledAt: Date?, now: Date) -> IslActivity? {
        switch d.phase {
        case .watching, .changing:
            let started = d.firstChange ?? now
            let title = d.progress.map { "Наблюдение: \(Int(($0 * 100).rounded()))%" } ?? (d.phase == .changing ? "Область меняется" : "Слежу за областью")
            return IslActivity(id: "watch", section: IslSectionIDs.watch, priority: IslPriority.watch, startedAt: started, peeks: false,
                               token: "run|\(d.phase.rawValue)", title: title)
        case .settled:
            guard let at = settledAt, now >= at, now.timeIntervalSince(at) < doneLifetime else { return nil }
            return IslActivity(id: "watch", section: IslSectionIDs.watch, priority: IslPriority.watch, startedAt: at, expiresAt: at.addingTimeInterval(doneLifetime), peeks: true,
                               token: "done|\(Int(at.timeIntervalSince1970))", title: "Область перестала меняться")
        case .idle:
            return nil
        }
    }
}
