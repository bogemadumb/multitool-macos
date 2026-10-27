import Foundation
import CoreGraphics

public struct ScrollZoomSettings: Equatable, Sendable {
    public var cmdZoom = true
    public var exceptions = AppExceptionList()
    public init() {}
}

public enum ZoomDecision: Equatable, Sendable {
    case pass
    case zoomIn
    case zoomOut
}

public enum ScrollZoom {
    public static let magnificationPerTick = 0.08

    public static func decision(_ s: ScrollSample, isMouseWheel: Bool, cmdZoom: Bool) -> ZoomDecision {
        guard cmdZoom, isMouseWheel, s.verticalOnly, s.flags.intersection(ScrollMath.shortcutFlags) == .maskCommand else { return .pass }
        let ticks = ScrollMath.ticks(s.vertical, continuous: s.isContinuous)
        if ticks > 0 { return .zoomIn }
        if ticks < 0 { return .zoomOut }
        return .pass
    }

    public static func magnification(_ d: ZoomDecision) -> Double {
        switch d {
        case .pass: 0
        case .zoomIn: magnificationPerTick
        case .zoomOut: -magnificationPerTick
        }
    }
}

public final class ScrollZoomStage: ScrollStage {
    public var cmdZoom: Bool
    private let poster: MagnifyPosting
    public private(set) var zoomCount = 0

    public init(hub: EventTapHub, gate: ExceptionGate, poster: MagnifyPosting, cmdZoom: Bool = true, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.poster = poster
        self.cmdZoom = cmdZoom
        super.init(hub: hub, gate: gate, priority: InputPriority.zoom, clock: clock)
    }

    override func process(_ s: ScrollSample, _ e: CGEvent) -> EventTapAction {
        let d = ScrollZoom.decision(s, isMouseWheel: true, cmdZoom: cmdZoom)
        guard d != .pass else { return .pass }
        poster.post(magnification: ScrollZoom.magnification(d))
        zoomCount += 1
        return .drop
    }
}

public extension InputSettingsStore {
    func loadZoom() -> ScrollZoomSettings {
        var s = ScrollZoomSettings()
        s.cmdZoom = bool("input.zoom.cmdZoom", s.cmdZoom)
        s.exceptions = list("input.zoom.exceptions", s.exceptions)
        return s
    }

    func saveZoom(_ s: ScrollZoomSettings) {
        let b = ScrollZoomSettings()
        put("input.zoom.cmdZoom", s.cmdZoom, b.cmdZoom)
        putList("input.zoom.exceptions", s.exceptions, b.exceptions)
    }
}
