import Foundation
import CoreGraphics

public enum RadialMode: Equatable, Sendable {
    case hold, sticky
}

public enum RadialOutcome: Equatable, Sendable {
    case none
    case run(RadialItem)
    case enteredSubmenu
    case leftSubmenu
    case becameSticky
    case cancelled
}

public final class RadialSession {
    public static let armDistance = 8.0

    public let geometry: RadialGeometry
    public private(set) var center: CGPoint
    public private(set) var mode: RadialMode
    public private(set) var hovered: Int?
    public private(set) var levels: [[RadialItem]]
    public private(set) var titles: [String]
    public private(set) var finished = false
    private let anchor: CGPoint
    private var armed = false
    private let openedAt: TimeInterval
    private let stickyThreshold: TimeInterval
    private let clock: () -> TimeInterval

    public init(items: [RadialItem], center: CGPoint, anchor: CGPoint? = nil, geometry: RadialGeometry, mode: RadialMode = .hold, stickyMs: Int = 250,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.geometry = geometry
        self.center = center
        self.anchor = anchor ?? center
        self.mode = mode
        levels = [Array(items.prefix(RadialSettings.maxItems))]
        titles = [""]
        stickyThreshold = Double(stickyMs) / 1000
        self.clock = clock
        openedAt = clock()
        armed = (anchor ?? center) == center
    }

    public var items: [RadialItem] { levels.last ?? [] }

    public var depth: Int { levels.count - 1 }

    public var title: String { titles.last ?? "" }

    public var hoveredItem: Int? { hovered }

    public func move(to p: CGPoint) {
        guard !finished else { return }
        if !armed {
            if hypot(Double(p.x - anchor.x), Double(p.y - anchor.y)) >= Self.armDistance { armed = true } else { hovered = nil; return }
        }
        hovered = geometry.index(dx: Double(p.x - center.x), dy: Double(p.y - center.y), count: items.count, current: hovered)
    }

    private func finish(_ o: RadialOutcome) -> RadialOutcome {
        finished = true
        hovered = nil
        return o
    }

    @discardableResult
    public func pick(index: Int) -> RadialOutcome {
        guard !finished, items.indices.contains(index) else { return .none }
        let item = items[index]
        if item.isSubmenu {
            let kids = item.children
            guard !kids.isEmpty else { return .none }
            levels.append(Array(kids.prefix(RadialSettings.maxItems)))
            titles.append(item.title)
            hovered = nil
            mode = .sticky
            return .enteredSubmenu
        }
        return finish(.run(item))
    }

    @discardableResult
    public func pick(number: Int) -> RadialOutcome {
        let i = number == 0 ? 9 : number - 1
        return pick(index: i)
    }

    @discardableResult
    public func back() -> RadialOutcome {
        guard !finished else { return .none }
        if levels.count > 1 {
            levels.removeLast()
            titles.removeLast()
            hovered = nil
            return .leftSubmenu
        }
        return finish(.cancelled)
    }

    @discardableResult
    public func cancel() -> RadialOutcome { finished ? .none : finish(.cancelled) }

    // The trigger key or button went up.
    @discardableResult
    public func release(at p: CGPoint) -> RadialOutcome {
        guard !finished, mode == .hold else { return .none }
        move(to: p)
        if let h = hovered { return pick(index: h) }
        if clock() - openedAt < stickyThreshold {
            mode = .sticky
            return .becameSticky
        }
        return finish(.cancelled)
    }

    // A click while the wheel is open.
    @discardableResult
    public func click(at p: CGPoint) -> RadialOutcome {
        guard !finished else { return .none }
        move(to: p)
        if let h = hovered { return pick(index: h) }
        let r = geometry.radius(dx: Double(p.x - center.x), dy: Double(p.y - center.y))
        if r < geometry.innerRadius, levels.count > 1 { return back() }
        return finish(.cancelled)
    }
}
