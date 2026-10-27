import Foundation
import CoreGraphics

public enum IslTrigger: String, Sendable {
    case hover, scroll, click, hotkey, peekRequest, drag, outsideClick, escape, leave, timeout, suppression, programmatic
}

public enum IslSuppression: String, CaseIterable, Hashable, Sendable {
    case fullscreen, menuOpen, locked, disabled

    var blocksExplicit: Bool { self == .locked || self == .disabled }
}

public struct IslTransition: Equatable, Sendable {
    public var from: IslState
    public var to: IslState
    public var trigger: IslTrigger
}

public enum IslEvent: Equatable, Sendable {
    case pointerEntered
    case pointerLeft
    case scrollOpen
    case scrollClose
    case clicked
    case hotkey
    case escape
    case outsideClick
    case peek(duration: TimeInterval?)
    case dragEntered
    case setPinned(Bool)
    case suppressed(Set<IslSuppression>)
    case forceClose
}

public struct IslMachineConfig: Equatable, Sendable {
    public var openOnHover = true
    public var hoverDelay = 0.25
    public var openOnScroll = true
    public var openOnClick = true
    public var closeOnScrollUp = true
    public var closeBehavior = IslCloseBehavior.onLeave
    public var leaveGrace = 0.4
    public var peekDuration = 3.0
    public var peekOnChange = true

    public init() {}

    public init(_ s: IslSettings) {
        openOnHover = s.openOnHover
        hoverDelay = s.hoverDelay
        openOnScroll = s.openOnScroll
        openOnClick = s.openOnClick
        closeOnScrollUp = s.closeOnScrollUp
        closeBehavior = s.closeBehavior
        leaveGrace = s.leaveGrace
        peekDuration = s.peekDuration
        peekOnChange = s.peekOnChange
    }
}

public final class IslStateMachine {
    public private(set) var state = IslState.closed
    public private(set) var pinned = false
    public private(set) var pointerInside = false
    public private(set) var suppression = Set<IslSuppression>()
    public private(set) var openedBy: IslTrigger?
    public var config: IslMachineConfig { didSet { configChanged() } }

    private var pointerSeenInside = false
    private var openAt: Date?
    private var closeAt: Date?
    private var peekEndAt: Date?

    public init(config: IslMachineConfig = IslMachineConfig()) { self.config = config }

    public var nextDeadline: Date? { [openAt, closeAt, peekEndAt].compactMap { $0 }.min() }

    public var isSuppressed: Bool { !suppression.isEmpty }

    private var blocksExplicit: Bool { suppression.contains { $0.blocksExplicit } }

    private func configChanged() {
        if !config.openOnHover { openAt = nil }
        if config.closeBehavior != .onLeave { closeAt = nil }
    }

    private func go(_ to: IslState, _ trigger: IslTrigger) -> [IslTransition] {
        guard to != state else { return [] }
        let t = IslTransition(from: state, to: to, trigger: trigger)
        state = to
        switch to {
        case .closed:
            pinned = false
            openAt = nil
            closeAt = nil
            peekEndAt = nil
            openedBy = nil
            pointerSeenInside = false
        case .peek:
            openAt = nil
            closeAt = nil
            openedBy = trigger
        case .open:
            openAt = nil
            peekEndAt = nil
            closeAt = nil
            openedBy = trigger
            pointerSeenInside = pointerInside
        }
        return [t]
    }

    private func armLeaveClose(_ now: Date) {
        guard state == .open, !pinned, config.closeBehavior == .onLeave else { return }
        if openedBy == .hotkey && !pointerSeenInside { return }
        closeAt = now.addingTimeInterval(config.leaveGrace)
    }

    public func handle(_ event: IslEvent, now: Date) -> [IslTransition] {
        switch event {
        case .suppressed(let set):
            suppression = set
            if !set.isEmpty {
                openAt = nil
                return go(.closed, .suppression)
            }
            return []

        case .forceClose:
            return go(.closed, .programmatic)

        case .pointerEntered:
            pointerInside = true
            closeAt = nil
            if state == .open { pointerSeenInside = true; return [] }
            if state == .peek { peekEndAt = nil }
            if config.openOnHover, suppression.isEmpty, openAt == nil { openAt = now.addingTimeInterval(config.hoverDelay) }
            return []

        case .pointerLeft:
            pointerInside = false
            openAt = nil
            if state == .open { armLeaveClose(now) }
            if state == .peek { peekEndAt = now.addingTimeInterval(min(config.leaveGrace, 1)) }
            return []

        case .scrollOpen:
            guard config.openOnScroll, suppression.isEmpty, state != .open else { return [] }
            return go(.open, .scroll)

        case .scrollClose:
            guard config.closeOnScrollUp, state == .open, !pinned else { return [] }
            return go(.closed, .scroll)

        case .clicked:
            switch state {
            case .closed, .peek:
                guard config.openOnClick, !blocksExplicit, suppression.subtracting([.menuOpen]).isEmpty else { return [] }
                return go(.open, .click)
            case .open:
                return pinned ? [] : go(.closed, .click)
            }

        case .hotkey:
            guard !blocksExplicit else { return [] }
            return state == .open ? go(.closed, .hotkey) : go(.open, .hotkey)

        case .escape:
            return state == .closed ? [] : go(.closed, .escape)

        case .outsideClick:
            guard state != .closed, !pinned else { return [] }
            if state == .open && config.closeBehavior == .manual { return [] }
            return go(.closed, .outsideClick)

        case .peek(let duration):
            guard state != .open, suppression.isEmpty else { return [] }
            let d = duration ?? config.peekDuration
            let tr = go(.peek, .peekRequest)
            peekEndAt = pointerInside ? nil : now.addingTimeInterval(d)
            return tr

        case .dragEntered:
            guard state != .open, suppression.isEmpty else { return [] }
            return go(.open, .drag)

        case .setPinned(let on):
            guard state == .open else { return [] }
            pinned = on
            if on { closeAt = nil } else if !pointerInside { armLeaveClose(now) }
            return []
        }
    }

    public func tick(now: Date) -> [IslTransition] {
        var out: [IslTransition] = []
        if let t = openAt, t <= now {
            openAt = nil
            if pointerInside, suppression.isEmpty, state != .open { out += go(.open, .hover) }
        }
        if let t = closeAt, t <= now {
            closeAt = nil
            if state == .open, !pinned, !pointerInside { out += go(.closed, .leave) }
        }
        if let t = peekEndAt, t <= now {
            peekEndAt = nil
            if state == .peek, !pointerInside { out += go(.closed, .timeout) }
        }
        return out
    }
}

public struct IslPointerTracker: Sendable {
    public private(set) var inside = false

    public init() {}

    public mutating func update(_ p: CGPoint, state: IslState, frames: IslFrames) -> IslEvent? {
        let now = IslHoverZone.contains(p, state: state, frames: frames)
        guard now != inside else { return nil }
        inside = now
        return now ? .pointerEntered : .pointerLeft
    }

    public mutating func reset() { inside = false }

    public mutating func sync(_ p: CGPoint, state: IslState, frames: IslFrames) {
        inside = IslHoverZone.contains(p, state: state, frames: frames)
    }
}
