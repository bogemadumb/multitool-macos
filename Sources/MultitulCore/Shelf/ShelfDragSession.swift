import Foundation

public protocol DragPasteboardProbing: AnyObject {
    var changeCount: Int { get }
    var hasContent: Bool { get }
}

public enum ShelfDragEvent: Equatable, Sendable {
    case started
    case shake
    case ended
}

public struct ShelfDragConfig: Equatable, Sendable {
    public var shakeEnabled = true
    public var sensitivity = ShakeSensitivity.medium
    public var excludedApps: Set<String> = []
    public var shelfVisible = false
    public init() {}

    public static let neverTrackedSources: Set<String> = ["com.apple.dock"]
}

public final class ShelfDragSession {
    private enum Phase { case idle, pending, content, ignored }

    public var config = ShelfDragConfig()
    private let probe: DragPasteboardProbing
    private let frontmost: () -> String?
    private var phase = Phase.idle
    private var baseCount = 0
    private var detector = ShakeDetector()
    private var shakeAllowed = false
    private var downPoint = CGPoint.zero
    public private(set) var source: String?

    public init(probe: DragPasteboardProbing, frontmost: @escaping () -> String?) {
        self.probe = probe
        self.frontmost = frontmost
    }

    public var isContentDrag: Bool { phase == .content }

    public func mouseDown(at p: CGPoint) {
        phase = .pending
        baseCount = probe.changeCount
        downPoint = p
        source = frontmost()
        detector = ShakeDetector(sensitivity: config.sensitivity)
        shakeAllowed = false
        if let s = source, ShelfDragConfig.neverTrackedSources.contains(s) { phase = .ignored }
    }

    public func mouseDragged(to p: CGPoint, at t: TimeInterval) -> [ShelfDragEvent] {
        var events: [ShelfDragEvent] = []
        if phase == .pending, probe.changeCount != baseCount, probe.hasContent {
            phase = .content
            shakeAllowed = config.shakeEnabled && !(source.map { config.excludedApps.contains($0) } ?? false)
            events.append(.started)
        }
        guard phase == .content, shakeAllowed, !config.shelfVisible else { return events }
        if detector.feed(x: Double(p.x), y: Double(p.y), at: t) { events.append(.shake) }
        return events
    }

    public func mouseUp() -> [ShelfDragEvent] {
        defer { phase = .idle; detector.reset() }
        guard phase != .idle else { return [] }
        return phase == .content ? [.ended] : []
    }

    public func cancel() {
        phase = .idle
        detector.reset()
    }
}
