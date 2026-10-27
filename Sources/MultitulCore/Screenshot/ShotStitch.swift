import Foundation
import CoreGraphics

public struct ShotStitchConfig: Equatable, Sendable {
    public var minOverlapRows = 16
    public var minDistinctRows = 4
    public var mismatchTolerance = 0.0
    public var ignoreLeftColumns = 0
    public var ignoreRightColumns = 0
    public var quantizeBits = 0
    public var maxStickyFraction = 0.34
    public var maxTotalHeight = 30000
    public var maxFrames = 300
    public var maxLostInRow = 2

    public init() {}
}

public enum ShotRowHash {
    public static func hashes(of bm: ShotBitmap, config: ShotStitchConfig = ShotStitchConfig()) -> [UInt64] {
        guard !bm.isEmpty else { return [] }
        let x0 = min(max(config.ignoreLeftColumns, 0), bm.width - 1)
        let x1 = max(bm.width - max(config.ignoreRightColumns, 0), x0 + 1)
        let mask = UInt8(truncatingIfNeeded: 0xFF << min(max(config.quantizeBits, 0), 7))
        var out = [UInt64]()
        out.reserveCapacity(bm.height)
        bm.bytes.withUnsafeBufferPointer { p in
            for y in 0..<bm.height {
                var h: UInt64 = 0xcbf29ce484222325
                let base = y * bm.width * 4
                for i in (base + x0 * 4)..<(base + x1 * 4) {
                    h ^= UInt64(p[i] & mask)
                    h = h &* 0x100000001b3
                }
                out.append(h)
            }
        }
        return out
    }
}

public struct ShotOverlap: Equatable, Sendable {
    public var shift: Int
    public var stickyTop: Int
    public var stickyBottom: Int
    public var mismatches: Int
    public var overlapRows: Int
}

public enum ShotOverlapResult: Equatable, Sendable {
    case same
    case found(ShotOverlap)
    case notFound
}

public enum ShotOverlapFinder {
    public static func leadingEqual(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var n = 0
        while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
        return n
    }

    public static func trailingEqual(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var n = 0
        while n < min(a.count, b.count), a[a.count - 1 - n] == b[b.count - 1 - n] { n += 1 }
        return n
    }

    public static func find(prev: [UInt64], next: [UInt64], hint: Int? = nil, config: ShotStitchConfig = ShotStitchConfig()) -> ShotOverlapResult {
        let h = prev.count
        guard h == next.count, h > 0 else { return .notFound }
        let budgetFull = Int(Double(h) * config.mismatchTolerance)
        var diff = 0
        for i in 0..<h where prev[i] != next[i] { diff += 1; if diff > budgetFull { break } }
        if diff <= budgetFull { return .same }

        let maxSticky = Int(Double(h) * config.maxStickyFraction)
        let lead = min(leadingEqual(prev, next), maxSticky)
        let trail = min(trailingEqual(prev, next), maxSticky)
        var best: ShotOverlap?
        for (sTop, sBottom) in [(lead, trail), (lead, 0), (0, trail), (0, 0)] {
            if best != nil { break }
            if let found = search(prev: prev, next: next, top: sTop, bottom: sBottom, hint: hint, config: config) { best = found }
            if sTop == 0 && sBottom == 0 { break }
        }
        return best.map(ShotOverlapResult.found) ?? .notFound
    }

    static func search(prev: [UInt64], next: [UInt64], top: Int, bottom: Int, hint: Int?, config: ShotStitchConfig) -> ShotOverlap? {
        let h = prev.count
        let area = h - top - bottom
        guard area > config.minOverlapRows else { return nil }
        var best: ShotOverlap?
        var bestScore = Int.max
        var shift = 1
        while shift <= area - config.minOverlapRows {
            let rows = area - shift
            let budget = Int(Double(rows) * config.mismatchTolerance)
            var miss = 0
            var j = 0
            while j < rows {
                if next[top + j] != prev[top + shift + j] { miss += 1; if miss > budget { break } }
                j += 1
            }
            if miss <= budget && distinct(next, from: top, count: rows) >= config.minDistinctRows {
                let score = miss * 100_000 + (hint.map { abs($0 - shift) } ?? shift)
                if score < bestScore {
                    bestScore = score
                    best = ShotOverlap(shift: shift, stickyTop: top, stickyBottom: bottom, mismatches: miss, overlapRows: rows)
                }
                if miss == 0 && hint == nil { break }
            }
            shift += 1
        }
        return best
    }

    static func distinct(_ a: [UInt64], from: Int, count: Int) -> Int {
        var seen = Set<UInt64>()
        for i in from..<(from + count) { seen.insert(a[i]); if seen.count >= 64 { break } }
        return seen.count
    }
}

public enum ShotStitchEvent: Equatable, Sendable {
    case started(height: Int)
    case appended(rows: Int, total: Int)
    case reachedEnd
    case lostOverlap
    case rejected
    case limit
}

public final class ShotStitcher {
    public let config: ShotStitchConfig
    public private(set) var body: ShotBitmap = .empty
    public private(set) var footer: ShotBitmap = .empty
    public private(set) var frames = 0
    public private(set) var finished = false
    public private(set) var lostStreak = 0
    private var prev: ShotBitmap = .empty
    private var prevHashes: [UInt64] = []

    public init(config: ShotStitchConfig = ShotStitchConfig()) { self.config = config }

    public var totalHeight: Int { body.height + footer.height }
    public var width: Int { body.width }

    public var result: ShotBitmap {
        var r = body
        r.append(rows: footer)
        return r
    }

    @discardableResult
    public func add(_ frame: ShotBitmap, hint: Int? = nil) -> ShotStitchEvent {
        guard !finished else { return .reachedEnd }
        guard !frame.isEmpty else { return .rejected }
        if frames == 0 {
            body = frame
            prev = frame
            prevHashes = ShotRowHash.hashes(of: frame, config: config)
            frames = 1
            return .started(height: frame.height)
        }
        guard frame.width == prev.width, frame.height == prev.height else { return .rejected }
        if frames >= config.maxFrames { finished = true; return .limit }
        let hashes = ShotRowHash.hashes(of: frame, config: config)
        switch ShotOverlapFinder.find(prev: prevHashes, next: hashes, hint: hint, config: config) {
        case .same:
            finished = true
            return .reachedEnd
        case .notFound:
            lostStreak += 1
            if lostStreak >= config.maxLostInRow { finished = true }
            return .lostOverlap
        case .found(let o):
            lostStreak = 0
            let h = frame.height
            let newRange = (h - o.stickyBottom - o.shift)..<(h - o.stickyBottom)
            if o.stickyBottom > 0 {
                if footer.isEmpty { body = body.rows(0..<(body.height - o.stickyBottom)) }
                footer = frame.rows((h - o.stickyBottom)..<h)
            }
            let room = config.maxTotalHeight - totalHeight
            var add = frame.rows(newRange)
            var hitLimit = false
            if add.height > room {
                add = add.rows(0..<max(room, 0))
                hitLimit = true
            }
            body.append(rows: add)
            prev = frame
            prevHashes = hashes
            frames += 1
            if hitLimit || totalHeight >= config.maxTotalHeight { finished = true; return .limit }
            return .appended(rows: add.height, total: totalHeight)
        }
    }

    public func finish() { finished = true }
}

public protocol ShotScrollDriving: AnyObject {
    func captureFrame() async -> ShotBitmap?
    func scroll(pixels: Int) async
    func settle() async
}

public enum ShotScrollStop: Equatable, Sendable {
    case reachedEnd, lostOverlap, limit, cancelled, captureFailed, rejected
}

public struct ShotScrollResult {
    public var bitmap: ShotBitmap
    public var frames: Int
    public var stop: ShotScrollStop
}

public final class ShotScrollSession {
    public let config: ShotStitchConfig
    public var stepFraction: Double
    public private(set) var cancelled = false
    public var onProgress: ((Int, Int) -> Void)?

    public init(config: ShotStitchConfig = ShotStitchConfig(), stepFraction: Double = 0.75) {
        self.config = config
        self.stepFraction = min(max(stepFraction, 0.2), 0.95)
    }

    public func cancel() { cancelled = true }

    public func run(driver: ShotScrollDriving) async -> ShotScrollResult {
        let st = ShotStitcher(config: config)
        var hint: Int?
        var stop = ShotScrollStop.limit
        while true {
            if cancelled { stop = .cancelled; break }
            guard let frame = await driver.captureFrame() else { stop = .captureFailed; break }
            let ev = st.add(frame, hint: hint)
            onProgress?(st.frames, st.totalHeight)
            if case .reachedEnd = ev { stop = .reachedEnd; break }
            if case .limit = ev { stop = .limit; break }
            if case .rejected = ev { stop = .rejected; break }
            if case .lostOverlap = ev, st.finished { stop = .lostOverlap; break }
            let step = max(Int(Double(frame.height) * stepFraction), 1)
            hint = step
            await driver.scroll(pixels: step)
            await driver.settle()
        }
        return ShotScrollResult(bitmap: st.result, frames: st.frames, stop: stop)
    }
}
