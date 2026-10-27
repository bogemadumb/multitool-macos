import Foundation
import CoreGraphics

public enum RecEase: String, Codable, CaseIterable, Sendable {
    case linear, cubic, quint, smoother, out

    public var title: String {
        switch self {
        case .linear: "Линейно"
        case .cubic: "Плавно"
        case .quint: "Мягко"
        case .smoother: "Очень плавно"
        case .out: "Быстро в начале"
        }
    }

    public func apply(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        switch self {
        case .linear: return t
        case .cubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .quint: return t < 0.5 ? 16 * pow(t, 5) : 1 - pow(-2 * t + 2, 5) / 2
        case .smoother: return t * t * t * (t * (t * 6 - 15) + 10)
        case .out: return 1 - pow(1 - t, 3)
        }
    }
}

public struct RecZoomSettings: Equatable, Codable, Sendable {
    public var level = 1.8
    public var leadIn = 0.25
    public var rampIn = 0.55
    public var rampOut = 0.7
    public var minHold = 1.4
    public var mergeGap = 2.4
    public var minGap = 0.9
    public var panDuration = 0.6
    public var follow = true
    public var followMargin = 0.2
    public var dwell = false
    public var dwellSeconds = 1.2
    public var dwellRadius = 0.035
    public var rightClicks = true
    public var skipBefore = 0.0
    public var easing = RecEase.cubic

    public init() {}

    public var sanitized: RecZoomSettings {
        var s = self
        s.level = ToolsClamp.double(level, RecSettings.zoomLevelRange)
        s.leadIn = ToolsClamp.double(leadIn, 0...3)
        s.rampIn = ToolsClamp.double(rampIn, 0.1...3)
        s.rampOut = ToolsClamp.double(rampOut, 0.1...3)
        s.minHold = ToolsClamp.double(minHold, 0.3...30)
        s.mergeGap = ToolsClamp.double(mergeGap, 0...30)
        s.minGap = ToolsClamp.double(minGap, 0...10)
        s.panDuration = ToolsClamp.double(panDuration, 0.1...3)
        s.followMargin = ToolsClamp.double(followMargin, 0...0.45)
        s.dwellSeconds = ToolsClamp.double(dwellSeconds, 0.3...10)
        s.dwellRadius = ToolsClamp.double(dwellRadius, 0.005...0.2)
        s.skipBefore = max(skipBefore, 0)
        return s
    }
}

public struct RecZoomPoint: Equatable, Codable, Sendable {
    public var t: Double
    public var cx: Double
    public var cy: Double

    public init(t: Double, cx: Double, cy: Double) {
        self.t = t
        self.cx = cx
        self.cy = cy
    }
}

public struct RecZoomSpan: Equatable, Codable, Sendable {
    public var start: Double
    public var holdStart: Double
    public var holdEnd: Double
    public var end: Double
    public var level: Double
    public var path: [RecZoomPoint]

    public init(start: Double, holdStart: Double, holdEnd: Double, end: Double, level: Double, path: [RecZoomPoint]) {
        self.start = start
        self.holdStart = holdStart
        self.holdEnd = holdEnd
        self.end = end
        self.level = level
        self.path = path
    }
}

public struct RecZoomSample: Equatable, Sendable {
    public var scale: Double
    public var cx: Double
    public var cy: Double

    public static let identity = RecZoomSample(scale: 1, cx: 0.5, cy: 0.5)
    public var isIdentity: Bool { scale <= 1.0001 }
}

public enum RecZoomMath {
    public static func viewRect(scale: Double, cx: Double, cy: Double) -> CGRect {
        let s = max(scale, 1)
        let size = 1 / s
        let x = min(max(cx - size / 2, 0), 1 - size)
        let y = min(max(cy - size / 2, 0), 1 - size)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    public static func clampCenter(_ c: (x: Double, y: Double), scale: Double) -> (x: Double, y: Double) {
        let r = viewRect(scale: scale, cx: c.x, cy: c.y)
        return (Double(r.midX), Double(r.midY))
    }
}

public struct RecZoomTimeline: Equatable, Codable, Sendable {
    public var spans: [RecZoomSpan]
    public var easing: RecEase
    public var panDuration: Double

    public init(spans: [RecZoomSpan] = [], easing: RecEase = .cubic, panDuration: Double = 0.6) {
        self.spans = spans.sorted { $0.start < $1.start }
        self.easing = easing
        self.panDuration = panDuration
    }

    public func span(at t: Double) -> RecZoomSpan? {
        spans.first { t >= $0.start && t <= $0.end }
    }

    func center(_ s: RecZoomSpan, at t: Double) -> (Double, Double) {
        guard let first = s.path.first else { return (0.5, 0.5) }
        var cx = first.cx, cy = first.cy
        for i in 1..<max(s.path.count, 1) {
            let prev = s.path[i - 1], cur = s.path[i]
            let pan = min(panDuration, max(cur.t - prev.t, 0.0001))
            let begin = cur.t - pan
            if t <= begin { break }
            if t >= cur.t {
                cx = cur.cx
                cy = cur.cy
                continue
            }
            let u = easing.apply((t - begin) / pan)
            cx = prev.cx + (cur.cx - prev.cx) * u
            cy = prev.cy + (cur.cy - prev.cy) * u
            break
        }
        return (cx, cy)
    }

    public func sample(at t: Double) -> RecZoomSample {
        guard let s = span(at: t) else { return .identity }
        if t < s.holdStart {
            let p = (t - s.start) / max(s.holdStart - s.start, 0.0001)
            let c = s.path.first.map { ($0.cx, $0.cy) } ?? (0.5, 0.5)
            return clamped(1 + (s.level - 1) * easing.apply(p), c.0, c.1)
        }
        if t <= s.holdEnd {
            let c = center(s, at: t)
            return clamped(s.level, c.0, c.1)
        }
        let p = (t - s.holdEnd) / max(s.end - s.holdEnd, 0.0001)
        let c = center(s, at: s.holdEnd)
        return clamped(s.level - (s.level - 1) * easing.apply(p), c.0, c.1)
    }

    private func clamped(_ scale: Double, _ cx: Double, _ cy: Double) -> RecZoomSample {
        let cc = RecZoomMath.clampCenter((cx, cy), scale: scale)
        return RecZoomSample(scale: max(scale, 1), cx: cc.x, cy: cc.y)
    }

    public struct Keyframe: Equatable, Sendable {
        public var t: Double
        public var scale: Double
        public var cx: Double
        public var cy: Double
    }

    public var keyframes: [Keyframe] {
        var out: [Keyframe] = []
        for s in spans {
            let a = s.path.first ?? RecZoomPoint(t: s.holdStart, cx: 0.5, cy: 0.5)
            let b = s.path.last ?? a
            out.append(Keyframe(t: s.start, scale: 1, cx: a.cx, cy: a.cy))
            out.append(Keyframe(t: s.holdStart, scale: s.level, cx: a.cx, cy: a.cy))
            for p in s.path.dropFirst() { out.append(Keyframe(t: p.t, scale: s.level, cx: p.cx, cy: p.cy)) }
            out.append(Keyframe(t: s.holdEnd, scale: s.level, cx: b.cx, cy: b.cy))
            out.append(Keyframe(t: s.end, scale: 1, cx: b.cx, cy: b.cy))
        }
        return out
    }
}

public enum RecAutoZoom {
    struct Trigger {
        var t: Double
        var x: Double
        var y: Double
    }

    static func triggers(log: RecInputLog, s: RecZoomSettings) -> [Trigger] {
        var out: [Trigger] = []
        for e in log.events where e.kind == .down && e.inside && e.t >= s.skipBefore {
            if e.button == .right && !s.rightClicks { continue }
            if e.button == .other { continue }
            out.append(Trigger(t: e.t, x: e.x, y: e.y))
        }
        if s.dwell {
            let pts = log.events.filter { ($0.kind == .move || $0.kind == .up || $0.kind == .down) && $0.inside }
            var i = 0
            while i < pts.count {
                let a = pts[i]
                var j = i + 1
                while j < pts.count, hypot(pts[j].x - a.x, pts[j].y - a.y) <= s.dwellRadius { j += 1 }
                let endT = pts[min(j, pts.count - 1)].t
                if endT - a.t >= s.dwellSeconds, a.t >= s.skipBefore { out.append(Trigger(t: a.t + s.dwellSeconds * 0.5, x: a.x, y: a.y)) }
                i = max(j, i + 1)
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    public static func plan(log: RecInputLog, duration: Double, settings raw: RecZoomSettings = RecZoomSettings()) -> RecZoomTimeline {
        let s = raw.sanitized
        guard duration > 0 else { return RecZoomTimeline(easing: s.easing, panDuration: s.panDuration) }
        let trig = triggers(log: log, s: s).filter { $0.t < duration }
        struct Build {
            var start: Double
            var holdStart: Double
            var holdEnd: Double
            var last: Trigger
            var members: [Trigger]
        }
        var builds: [Build] = []
        for t in trig {
            var holdStart = t.t - s.leadIn
            var start = holdStart - s.rampIn
            if start < 0 {
                start = 0
                holdStart = min(s.rampIn, max(t.t, 0.05))
            }
            let holdEnd = max(t.t + s.minHold, holdStart + s.minHold)
            if var cur = builds.last {
                let closeClicks = t.t - cur.last.t <= s.mergeGap
                let closeSpans = start < cur.holdEnd + s.rampOut + s.minGap
                if closeClicks || closeSpans {
                    cur.holdEnd = max(cur.holdEnd, holdEnd)
                    cur.last = t
                    cur.members.append(t)
                    builds[builds.count - 1] = cur
                    continue
                }
            }
            builds.append(Build(start: start, holdStart: holdStart, holdEnd: holdEnd, last: t, members: [t]))
        }
        var spans: [RecZoomSpan] = []
        for b in builds {
            var end = b.holdEnd + s.rampOut
            var holdEnd = b.holdEnd
            if end > duration {
                end = duration
                holdEnd = max(min(holdEnd, end - min(s.rampOut, end - b.holdStart) * 0.5), b.holdStart)
            }
            guard end - b.start >= 0.3, holdEnd >= b.holdStart else { continue }
            let c0 = RecZoomMath.clampCenter((b.members[0].x, b.members[0].y), scale: s.level)
            var path = [RecZoomPoint(t: b.holdStart, cx: c0.x, cy: c0.y)]
            var cur = c0
            let clickTimes = Set(b.members.map(\.t))
            var events: [(t: Double, x: Double, y: Double, forced: Bool)] = b.members.dropFirst().map { ($0.t - s.leadIn, $0.x, $0.y, true) }
            if s.follow {
                for e in log.events where (e.kind == .move || e.kind == .up) && e.inside && e.t > b.holdStart && e.t < holdEnd && !clickTimes.contains(e.t) {
                    events.append((e.t + 0.25, e.x, e.y, false))
                }
            }
            events.sort { $0.t < $1.t }
            let half = 0.5 / s.level
            let safe = half * (1 - 2 * s.followMargin)
            var lastKey = b.holdStart
            for e in events where e.t > b.holdStart && e.t <= holdEnd {
                var target = cur
                if e.forced {
                    target = RecZoomMath.clampCenter((e.x, e.y), scale: s.level)
                } else {
                    guard e.t - lastKey >= 0.35 else { continue }
                    var nx = cur.x, ny = cur.y
                    if e.x > cur.x + safe { nx = e.x - safe } else if e.x < cur.x - safe { nx = e.x + safe }
                    if e.y > cur.y + safe { ny = e.y - safe } else if e.y < cur.y - safe { ny = e.y + safe }
                    target = RecZoomMath.clampCenter((nx, ny), scale: s.level)
                }
                if hypot(target.x - cur.x, target.y - cur.y) < 0.015 { continue }
                if e.t <= lastKey + 0.0001 { continue }
                path.append(RecZoomPoint(t: e.t, cx: target.x, cy: target.y))
                cur = target
                lastKey = e.t
            }
            spans.append(RecZoomSpan(start: b.start, holdStart: b.holdStart, holdEnd: holdEnd, end: end, level: s.level, path: path))
        }
        return RecZoomTimeline(spans: spans, easing: s.easing, panDuration: s.panDuration)
    }
}
