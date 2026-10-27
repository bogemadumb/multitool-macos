import Foundation

public struct RecSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var srcStart: Double
    public var srcEnd: Double
    public var speed: Double

    public init(id: Int, srcStart: Double, srcEnd: Double, speed: Double = 1) {
        self.id = id
        self.srcStart = srcStart
        self.srcEnd = srcEnd
        self.speed = speed
    }

    public var srcDuration: Double { srcEnd - srcStart }
    public var outDuration: Double { srcDuration / speed }
}

public struct RecTimeline: Equatable, Codable, Sendable {
    public static let minSegment = 0.05
    public static let speedRange = 0.1...32.0
    public static let speedChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8]
    static let eps = 1e-6

    public private(set) var segments: [RecSegment]
    public private(set) var sourceDuration: Double
    private var nextID: Int

    public init(sourceDuration: Double) {
        let d = max(sourceDuration.isFinite ? sourceDuration : 0, 0)
        self.sourceDuration = d
        segments = d > 0 ? [RecSegment(id: 1, srcStart: 0, srcEnd: d)] : []
        nextID = 2
    }

    public var outputDuration: Double { segments.reduce(0) { $0 + $1.outDuration } }
    public var keptDuration: Double { segments.reduce(0) { $0 + $1.srcDuration } }
    public var isIdentity: Bool { segments.count == 1 && segments[0].srcStart <= Self.eps && abs(segments[0].srcEnd - sourceDuration) <= Self.eps && segments[0].speed == 1 }
    public var hasSpeedChanges: Bool { segments.contains { $0.speed != 1 } }

    public func outputStart(ofIndex i: Int) -> Double { segments[..<min(i, segments.count)].reduce(0) { $0 + $1.outDuration } }

    public var keptRanges: [ClosedRange<Double>] { segments.map { $0.srcStart...$0.srcEnd } }

    public var cutRanges: [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var cursor = 0.0
        for s in segments {
            if s.srcStart - cursor > Self.eps { out.append(cursor...s.srcStart) }
            cursor = s.srcEnd
        }
        if sourceDuration - cursor > Self.eps { out.append(cursor...sourceDuration) }
        return out
    }

    public func isKept(source t: Double) -> Bool { segments.contains { t >= $0.srcStart - Self.eps && t <= $0.srcEnd + Self.eps } }

    public func segmentIndex(atSource t: Double) -> Int? { segments.firstIndex { t >= $0.srcStart - Self.eps && t < $0.srcEnd - Self.eps } ?? (segments.indices.last.flatMap { abs(t - segments[$0].srcEnd) <= Self.eps ? $0 : nil }) }

    public func segmentIndex(atOutput t: Double) -> Int? {
        var acc = 0.0
        for (i, s) in segments.enumerated() {
            let end = acc + s.outDuration
            if t < end - Self.eps || (i == segments.count - 1 && t <= end + Self.eps) { return i }
            acc = end
        }
        return nil
    }

    public func sourceToOutput(_ t: Double) -> Double? {
        var acc = 0.0
        for s in segments {
            if t >= s.srcStart - Self.eps && t <= s.srcEnd + Self.eps {
                return acc + (min(max(t, s.srcStart), s.srcEnd) - s.srcStart) / s.speed
            }
            acc += s.outDuration
        }
        return nil
    }

    // nearest kept moment for a source time that may have been cut
    public func snapToKept(source t: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        var best: Double?
        var bestD = Double.infinity
        for s in segments {
            let c = min(max(t, s.srcStart), s.srcEnd)
            let d = abs(c - t)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    public func outputToSource(_ o: Double) -> Double {
        guard !segments.isEmpty else { return 0 }
        let t = min(max(o, 0), outputDuration)
        var acc = 0.0
        for (i, s) in segments.enumerated() {
            let end = acc + s.outDuration
            if t < end - Self.eps || i == segments.count - 1 { return min(s.srcStart + (t - acc) * s.speed, s.srcEnd) }
            acc = end
        }
        return segments[segments.count - 1].srcEnd
    }

    private mutating func splitBoundary(at t: Double) {
        guard let i = segments.firstIndex(where: { t > $0.srcStart + Self.eps && t < $0.srcEnd - Self.eps }) else { return }
        var right = segments[i]
        right.id = nextID
        nextID += 1
        right.srcStart = t
        segments[i].srcEnd = t
        segments.insert(right, at: i + 1)
    }

    private mutating func normalize() {
        segments.removeAll { $0.srcDuration < Self.eps }
        segments.sort { $0.srcStart < $1.srcStart }
        var out: [RecSegment] = []
        for s in segments {
            if var last = out.last, abs(last.srcEnd - s.srcStart) < Self.eps, last.speed == s.speed {
                last.srcEnd = s.srcEnd
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        segments = out
    }

    @discardableResult
    public mutating func split(at t: Double) -> Bool {
        guard segments.contains(where: { t > $0.srcStart + Self.minSegment && t < $0.srcEnd - Self.minSegment }) else { return false }
        splitBoundary(at: t)
        return true
    }

    @discardableResult
    public mutating func cut(from a: Double, to b: Double) -> Bool {
        let lo = max(min(a, b), 0), hi = min(max(a, b), sourceDuration)
        guard hi - lo >= Self.eps else { return false }
        var probe = self
        probe.splitBoundary(at: lo)
        probe.splitBoundary(at: hi)
        probe.segments.removeAll { $0.srcStart >= lo - Self.eps && $0.srcEnd <= hi + Self.eps }
        probe.normalize()
        guard probe.keptDuration >= Self.minSegment, probe.segments != segments else { return false }
        self = probe
        return true
    }

    @discardableResult
    public mutating func trim(from a: Double, to b: Double) -> Bool {
        let lo = max(min(a, b), 0), hi = min(max(a, b), sourceDuration)
        guard hi - lo >= Self.minSegment else { return false }
        var probe = self
        probe.splitBoundary(at: lo)
        probe.splitBoundary(at: hi)
        probe.segments.removeAll { $0.srcEnd <= lo + Self.eps || $0.srcStart >= hi - Self.eps }
        probe.normalize()
        guard probe.keptDuration >= Self.minSegment, probe.segments != segments else { return false }
        self = probe
        return true
    }

    @discardableResult
    public mutating func setSpeed(from a: Double, to b: Double, speed: Double) -> Bool {
        let v = ToolsClamp.double(speed, Self.speedRange)
        let lo = max(min(a, b), 0), hi = min(max(a, b), sourceDuration)
        guard hi - lo >= Self.eps, segments.contains(where: { $0.srcEnd > lo + Self.eps && $0.srcStart < hi - Self.eps }) else { return false }
        splitBoundary(at: lo)
        splitBoundary(at: hi)
        for i in segments.indices where segments[i].srcStart >= lo - Self.eps && segments[i].srcEnd <= hi + Self.eps { segments[i].speed = v }
        normalize()
        return true
    }

    @discardableResult
    public mutating func setSpeed(segmentID: Int, speed: Double) -> Bool {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return false }
        segments[i].speed = ToolsClamp.double(speed, Self.speedRange)
        normalize()
        return true
    }

    @discardableResult
    public mutating func remove(segmentID: Int) -> Bool {
        guard segments.count > 1, let i = segments.firstIndex(where: { $0.id == segmentID }) else { return false }
        guard keptDuration - segments[i].srcDuration >= Self.minSegment else { return false }
        segments.remove(at: i)
        normalize()
        return true
    }

    public mutating func reset() {
        self = RecTimeline(sourceDuration: sourceDuration)
    }

    public var validationIssues: [String] {
        var out: [String] = []
        var cursor = -Double.infinity
        for s in segments {
            if s.srcStart < -Self.eps || s.srcEnd > sourceDuration + Self.eps { out.append("сегмент \(s.id) вне источника") }
            if s.srcStart < cursor - Self.eps { out.append("сегмент \(s.id) пересекается с предыдущим") }
            if !(Self.speedRange.contains(s.speed)) { out.append("скорость сегмента \(s.id) вне диапазона") }
            cursor = s.srcEnd
        }
        return out
    }
}

public struct RecUndoStack<State: Equatable>: Sendable where State: Sendable {
    public let limit: Int
    public private(set) var undoStates: [State] = []
    public private(set) var redoStates: [State] = []

    public init(limit: Int = 100) { self.limit = max(limit, 1) }

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    public mutating func record(before: State) {
        if undoStates.last == before { return }
        undoStates.append(before)
        if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
        redoStates.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let prev = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return prev
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }

    public mutating func clear() {
        undoStates = []
        redoStates = []
    }
}
