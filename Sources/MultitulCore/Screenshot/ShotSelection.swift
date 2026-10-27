import Foundation
import CoreGraphics

public struct ShotModifiers: Equatable, Sendable {
    public var shift = false
    public var option = false
    public var command = false
    public var control = false

    public init(shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) {
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }

    public static let none = ShotModifiers()
}

public enum ShotSelectionInput: Equatable, Sendable {
    case mouseMoved(CGPoint, ShotModifiers)
    case mouseDown(CGPoint, ShotModifiers)
    case mouseDragged(CGPoint, ShotModifiers)
    case mouseUp(CGPoint, ShotModifiers)
    case keyDown(UInt32, ShotModifiers)
    case keyUp(UInt32)
}

public struct ShotSelectionResult: Equatable, Sendable {
    public var rect: CGRect
    public var window: ShotWindowInfo?
}

public enum ShotSelectionOutcome: Equatable, Sendable {
    case none
    case changed
    case warpCursor(CGPoint)
    case confirmed(ShotSelectionResult)
    case cancelled
}

public enum ShotSelectionState: Equatable, Sendable {
    case idle, dragging, adjusting, finished
}

public struct ShotSelectionConfig: Equatable, Sendable {
    public var minSide: CGFloat = 4
    public var snapThreshold: CGFloat = 6
    public var snapToWindows = true
    public var snapToDisplays = true
    public var lockedRatio: CGFloat?
    public var confirmOnRelease = true
    public var windowPickOnly = false
    public var nudgeStep: CGFloat = 1
    public var bigNudgeStep: CGFloat = 10

    public init() {}
}

public final class ShotSelectionSession {
    public private(set) var state = ShotSelectionState.idle
    public private(set) var rect: CGRect?
    public private(set) var cursor: CGPoint = .zero
    public private(set) var hoverWindow: ShotWindowInfo?
    public private(set) var pickedWindow: ShotWindowInfo?
    public private(set) var guideX: CGFloat?
    public private(set) var guideY: CGFloat?
    public var config: ShotSelectionConfig
    public let displays: [ShotDisplay]
    public let windows: [ShotWindowInfo]

    private let bounds: CGRect
    private var anchor: CGPoint = .zero
    private var moving = false
    private var lastDrag: CGPoint = .zero

    public init(displays: [ShotDisplay], windows: [ShotWindowInfo] = [], config: ShotSelectionConfig = ShotSelectionConfig(), cursor: CGPoint? = nil) {
        self.displays = displays
        self.windows = windows
        self.config = config
        bounds = ShotSpace.bounds(displays)
        if let cursor {
            self.cursor = cursor
            hoverWindow = ShotWindowFilter.topmost(at: cursor, in: windows)
        }
    }

    public var isMovingSelection: Bool { moving }

    @discardableResult
    public func handle(_ input: ShotSelectionInput) -> ShotSelectionOutcome {
        guard state != .finished else { return .none }
        switch input {
        case .mouseMoved(let p, _): return moved(p)
        case .mouseDown(let p, _): return down(p)
        case .mouseDragged(let p, let m): return dragged(p, m)
        case .mouseUp(let p, _): return up(p)
        case .keyDown(let code, let m): return key(code, m)
        case .keyUp(let code):
            if code == Keys.space { moving = false }
            return .none
        }
    }

    private func moved(_ p: CGPoint) -> ShotSelectionOutcome {
        cursor = ShotSpace.clamp(p, to: bounds)
        guard state == .idle else { return .none }
        hoverWindow = ShotWindowFilter.topmost(at: cursor, in: windows)
        return .changed
    }

    private func down(_ p: CGPoint) -> ShotSelectionOutcome {
        let q = ShotSpace.clamp(p, to: bounds)
        cursor = q
        if config.windowPickOnly {
            hoverWindow = ShotWindowFilter.topmost(at: q, in: windows)
            return .changed
        }
        anchor = q
        lastDrag = q
        state = .dragging
        rect = CGRect(origin: q, size: .zero)
        pickedWindow = nil
        moving = false
        return .changed
    }

    private func dragged(_ p: CGPoint, _ m: ShotModifiers) -> ShotSelectionOutcome {
        guard state == .dragging else { return .none }
        let q = ShotSpace.clamp(p, to: bounds)
        cursor = q
        defer { lastDrag = q }
        if moving, let r = rect {
            let moved = ShotSpace.moved(r.offsetBy(dx: q.x - lastDrag.x, dy: q.y - lastDrag.y), inside: bounds)
            anchor = CGPoint(x: anchor.x + (moved.minX - r.minX), y: anchor.y + (moved.minY - r.minY))
            rect = moved
            return .changed
        }
        rect = dragRect(anchor: anchor, point: q, mods: m)
        return .changed
    }

    private func up(_ p: CGPoint) -> ShotSelectionOutcome {
        let q = ShotSpace.clamp(p, to: bounds)
        cursor = q
        if config.windowPickOnly {
            guard let w = ShotWindowFilter.topmost(at: q, in: windows) else { return .none }
            return finish(ShotSelectionResult(rect: w.frame.intersection(bounds), window: w))
        }
        guard state == .dragging else { return .none }
        moving = false
        guizeReset()
        guard let r = rect else { state = .idle; return .changed }
        if r.width < config.minSide && r.height < config.minSide {
            if let w = ShotWindowFilter.topmost(at: q, in: windows) {
                let fr = w.frame.intersection(bounds)
                pickedWindow = w
                rect = fr
                state = .adjusting
                return config.confirmOnRelease ? finish(ShotSelectionResult(rect: fr, window: w)) : .changed
            }
            rect = nil
            state = .idle
            return .changed
        }
        guard r.width >= config.minSide, r.height >= config.minSide else {
            rect = nil
            state = .idle
            return .changed
        }
        state = .adjusting
        return config.confirmOnRelease ? finish(ShotSelectionResult(rect: r, window: nil)) : .changed
    }

    private func guizeReset() {
        guideX = nil
        guideY = nil
    }

    private func finish(_ r: ShotSelectionResult) -> ShotSelectionOutcome {
        state = .finished
        return .confirmed(r)
    }

    private func key(_ code: UInt32, _ m: ShotModifiers) -> ShotSelectionOutcome {
        switch code {
        case Keys.escape:
            state = .finished
            return .cancelled
        case Keys.returnKey, Keys.enterKey:
            if state == .adjusting, let r = rect, r.width >= config.minSide, r.height >= config.minSide {
                return finish(ShotSelectionResult(rect: r, window: pickedWindow))
            }
            if state == .idle, let w = hoverWindow {
                return finish(ShotSelectionResult(rect: w.frame.intersection(bounds), window: w))
            }
            return .none
        case Keys.space:
            if state == .dragging { moving = true }
            return .none
        case Keys.left, Keys.right, Keys.up, Keys.down:
            return arrow(code, m)
        default:
            return .none
        }
    }

    private func arrow(_ code: UInt32, _ m: ShotModifiers) -> ShotSelectionOutcome {
        let step = m.shift ? config.bigNudgeStep : config.nudgeStep
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch code {
        case Keys.left: dx = -step
        case Keys.right: dx = step
        case Keys.up: dy = -step
        default: dy = step
        }
        switch state {
        case .adjusting:
            guard var r = rect else { return .none }
            if m.option {
                r.size.width = max(config.minSide, min(r.width + dx, bounds.maxX - r.minX))
                r.size.height = max(config.minSide, min(r.height + dy, bounds.maxY - r.minY))
                if let ratio = config.lockedRatio, ratio > 0 { r.size.height = max(r.width / ratio, config.minSide) }
                rect = ShotSpace.moved(r, inside: bounds)
            } else {
                rect = ShotSpace.moved(r.offsetBy(dx: dx, dy: dy), inside: bounds)
            }
            if let w = pickedWindow, rect?.size != w.frame.intersection(bounds).size { pickedWindow = nil }
            return .changed
        case .idle, .dragging:
            let target = ShotSpace.clamp(CGPoint(x: cursor.x + dx, y: cursor.y + dy), to: bounds)
            cursor = target
            if state == .dragging {
                lastDrag = target
                rect = dragRect(anchor: anchor, point: target, mods: m)
            } else {
                hoverWindow = ShotWindowFilter.topmost(at: target, in: windows)
            }
            return .warpCursor(target)
        case .finished:
            return .none
        }
    }

    func dragRect(anchor: CGPoint, point: CGPoint, mods: ShotModifiers) -> CGRect {
        var ratio: CGFloat? = config.lockedRatio
        if mods.shift && ratio == nil { ratio = 1 }
        let fromCenter = mods.option
        var target = point
        guideX = nil
        guideY = nil
        if ratio == nil && !mods.command { target = snapped(point, anchor: anchor) }
        let dx = target.x - anchor.x, dy = target.y - anchor.y
        let sx: CGFloat = dx >= 0 ? 1 : -1, sy: CGFloat = dy >= 0 ? 1 : -1
        var w = abs(dx), h = abs(dy)
        if let ratio, ratio > 0 {
            if w / max(h, 0.0001) > ratio { h = w / ratio } else { w = h * ratio }
        }
        let maxW: CGFloat, maxH: CGFloat
        if fromCenter {
            maxW = min(anchor.x - bounds.minX, bounds.maxX - anchor.x)
            maxH = min(anchor.y - bounds.minY, bounds.maxY - anchor.y)
        } else {
            maxW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            maxH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        }
        if ratio != nil {
            var k: CGFloat = 1
            if w > 0 { k = min(k, maxW / w) }
            if h > 0 { k = min(k, maxH / h) }
            w *= k
            h *= k
        } else {
            w = min(w, maxW)
            h = min(h, maxH)
        }
        if fromCenter { return CGRect(x: anchor.x - w, y: anchor.y - h, width: w * 2, height: h * 2) }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    private func snapped(_ p: CGPoint, anchor: CGPoint) -> CGPoint {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        if config.snapToWindows {
            for w in windows { xs += [w.frame.minX, w.frame.maxX]; ys += [w.frame.minY, w.frame.maxY] }
        }
        if config.snapToDisplays {
            for d in displays { xs += [d.frame.minX, d.frame.maxX]; ys += [d.frame.minY, d.frame.maxY] }
        }
        var out = p
        if let x = nearest(p.x, in: xs), x != anchor.x { out.x = x; guideX = x }
        if let y = nearest(p.y, in: ys), y != anchor.y { out.y = y; guideY = y }
        return out
    }

    private func nearest(_ v: CGFloat, in list: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        var bestD = config.snapThreshold + 0.0001
        for c in list {
            let d = abs(c - v)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }
}

public struct ShotMagnifierModel: Equatable, Sendable {
    public var displayID: UInt32
    public var pixelX: Int
    public var pixelY: Int
    public var desktopPoint: CGPoint
    public var gridSize: Int
    public var sourcePixelRect: CGRect
    public var loupeFrame: CGRect
    public var pixelText: String
    public var pointText: String
}

public enum ShotMagnifier {
    public static func model(cursor: CGPoint, displays: [ShotDisplay], gridSize: Int = 15, loupeSide: CGFloat = 120, offset: CGFloat = 20) -> ShotMagnifierModel? {
        guard let d = ShotSpace.display(containing: cursor, in: displays) else { return nil }
        let grid = max(3, gridSize | 1)
        let px = d.pixelSize
        let c = ShotSpace.clamp(cursor, to: d.frame)
        let ix = min(max(Int(((c.x - d.frame.minX) * d.scale).rounded(.down)), 0), Int(px.width) - 1)
        let iy = min(max(Int(((c.y - d.frame.minY) * d.scale).rounded(.down)), 0), Int(px.height) - 1)
        let half = grid / 2
        let src = CGRect(x: ix - half, y: iy - half, width: grid, height: grid)
        var x = c.x + offset
        var y = c.y + offset
        if x + loupeSide > d.frame.maxX { x = c.x - offset - loupeSide }
        if y + loupeSide > d.frame.maxY { y = c.y - offset - loupeSide }
        x = min(max(x, d.frame.minX), max(d.frame.maxX - loupeSide, d.frame.minX))
        y = min(max(y, d.frame.minY), max(d.frame.maxY - loupeSide, d.frame.minY))
        let px0 = Int(c.x.rounded(.down)), py0 = Int(c.y.rounded(.down))
        return ShotMagnifierModel(displayID: d.id, pixelX: ix, pixelY: iy, desktopPoint: c, gridSize: grid, sourcePixelRect: src,
                                  loupeFrame: CGRect(x: x, y: y, width: loupeSide, height: loupeSide),
                                  pixelText: "\(ix), \(iy) px", pointText: "\(px0), \(py0)")
    }

    public static func sizeLabel(_ rect: CGRect, scale: CGFloat) -> String {
        "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
    }

    public static func labelFrame(selection: CGRect, labelSize: CGSize, in bounds: CGRect, gap: CGFloat = 6) -> CGRect {
        var x = selection.minX
        var y = selection.maxY + gap
        if y + labelSize.height > bounds.maxY { y = selection.minY - labelSize.height - gap }
        if y < bounds.minY { y = selection.minY + gap }
        x = min(max(x, bounds.minX), max(bounds.maxX - labelSize.width, bounds.minX))
        return CGRect(x: x, y: y, width: labelSize.width, height: labelSize.height)
    }
}
