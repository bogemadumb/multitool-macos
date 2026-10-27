import Foundation
import CoreGraphics

public protocol SnapPreviewing: AnyObject {
    func show(_ frame: CGRect, display: WndDisplay)
    func hide()
}

public final class EdgeDragTracker {
    public enum Phase: Equatable {
        case idle
        case candidate
        case moving
        case rejected
    }

    public static let minReadInterval: TimeInterval = 0.025

    public private(set) var phase = Phase.idle
    public private(set) var target: SnapTarget?
    public private(set) var snapCount = 0
    private let driver: WindowDriving
    private let engine: WindowLayoutEngine
    private let preview: SnapPreviewing
    private let settingsProvider: () -> WindowLayoutSettings
    private var window: WndWindow?
    private var startFrame = CGRect.zero
    private var startPoint = CGPoint.zero
    private var lastRead: TimeInterval = -1
    private var trail = PointerTrail()

    public init(driver: WindowDriving, engine: WindowLayoutEngine, preview: SnapPreviewing, settings: @escaping () -> WindowLayoutSettings) {
        self.driver = driver
        self.engine = engine
        self.preview = preview
        self.settingsProvider = settings
    }

    public func reset() {
        if target != nil { preview.hide() }
        phase = .idle
        target = nil
        window = nil
        trail.reset()
        lastRead = -1
    }

    public func mouseDown(at p: CGPoint, time: TimeInterval) {
        reset()
        let s = settingsProvider()
        guard s.edge.enabled, let w = driver.window(at: p), !s.ignoredApp(w), driver.isManageable(w), let f = driver.frame(of: w) else { return }
        guard !SnapZoneResolver.startsOnResizeHandle(p, frame: f) else { phase = .rejected; return }
        window = w
        startFrame = f
        startPoint = p
        phase = .candidate
        trail.add(p, at: time)
    }

    public func mouseDragged(to p: CGPoint, time: TimeInterval) {
        guard phase == .candidate || phase == .moving, let w = window else { return }
        trail.add(p, at: time)
        guard lastRead < 0 || time - lastRead >= Self.minReadInterval else { return }
        lastRead = time
        guard let now = driver.frame(of: w) else { return }
        if phase == .candidate {
            switch SnapZoneResolver.classify(initial: startFrame, current: now, pointerStart: startPoint, pointerNow: p) {
            case .waiting: return
            case .moving: phase = .moving
            case .resizing, .unrelated:
                phase = .rejected
                return
            }
        }
        updateTarget(at: p, time: time)
    }

    public func mouseUp(at p: CGPoint, time: TimeInterval) {
        defer { reset() }
        guard phase == .moving, let w = window else { return }
        trail.add(p, at: time)
        updateTarget(at: p, time: time, silent: true)
        guard let t = target else { return }
        engine.place(t.action, on: w, displayIndex: t.displayIndex, reference: startFrame)
        snapCount += 1
    }

    private func updateTarget(at p: CGPoint, time: TimeInterval, silent: Bool = false) {
        let s = settingsProvider()
        let displays = driver.displays()
        let next = SnapZoneResolver.resolve(at: p, displays: displays, velocity: trail.velocity(at: time), settings: s)
        guard next != target else { return }
        target = next
        guard !silent else { return }
        if let n = next, s.edge.showPreview, displays.indices.contains(n.displayIndex) {
            preview.show(n.frame, display: displays[n.displayIndex])
        } else {
            preview.hide()
        }
    }
}
