import Foundation
import CoreGraphics

public struct ShelfScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visible: CGRect
    public init(frame: CGRect, visible: CGRect) {
        self.frame = frame
        self.visible = visible
    }
}

public enum ShelfPlacement {
    public static let margin: CGFloat = 12
    public static let cursorOffset: CGFloat = 28

    public static func screen(containing p: CGPoint, in screens: [ShelfScreen]) -> ShelfScreen? {
        if let hit = screens.first(where: { $0.frame.contains(p) }) { return hit }
        return screens.min { distance(p, $0.frame) < distance(p, $1.frame) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func clamp(_ origin: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        let maxX = max(area.minX, area.maxX - size.width)
        let maxY = max(area.minY, area.maxY - size.height)
        return CGPoint(x: min(max(origin.x, area.minX), maxX), y: min(max(origin.y, area.minY), maxY))
    }

    public static func origin(mode: ShelfPlacementMode, cursor: CGPoint, size: CGSize, screens: [ShelfScreen]) -> CGPoint {
        guard let sc = screen(containing: cursor, in: screens) else { return .zero }
        let area = sc.visible.insetBy(dx: margin, dy: margin)
        let y = cursor.y - size.height / 2
        switch mode {
        case .leftEdge:
            return clamp(CGPoint(x: area.minX, y: y), size: size, in: area)
        case .rightEdge:
            return clamp(CGPoint(x: area.maxX - size.width, y: y), size: size, in: area)
        case .nearCursor:
            var x = cursor.x + cursorOffset
            if x + size.width > area.maxX { x = cursor.x - cursorOffset - size.width }
            return clamp(CGPoint(x: x, y: y), size: size, in: area)
        }
    }

    public static func belowStatusItem(icon: CGRect, size: CGSize, screens: [ShelfScreen], gap: CGFloat = 4) -> CGPoint {
        let mid = CGPoint(x: icon.midX, y: icon.midY)
        guard let sc = screen(containing: mid, in: screens) else { return .zero }
        let area = CGRect(x: sc.visible.minX + 8, y: sc.visible.minY + 8, width: sc.visible.width - 16, height: sc.visible.height - 8)
        let top = min(icon.minY - gap, sc.visible.maxY)
        return clamp(CGPoint(x: icon.midX - size.width / 2, y: top - size.height), size: size, in: area)
    }

    public static func size(itemCount: Int, compact: Bool = false) -> CGSize {
        let width: CGFloat = 340
        let header: CGFloat = 44
        let row: CGFloat = 50
        let maxRows = 6
        if itemCount <= 0 { return CGSize(width: width, height: header + (compact ? 70 : 110)) }
        let rows = CGFloat(min(itemCount, maxRows))
        return CGSize(width: width, height: header + rows * row + 12)
    }
}

public enum ShelfAutoHideEvent: Equatable, Sendable {
    case itemsChanged
    case dragEnded(droppedOnShelf: Bool)
    case dragOutCompleted
}

public enum ShelfAutoHideDecision: Equatable, Sendable {
    case keep
    case hide(after: TimeInterval)
}

public enum ShelfAutoHide {
    public static func decide(_ event: ShelfAutoHideEvent, isEmpty: Bool, autoHideEmpty: Bool, openedBy: ShelfOpenReason?, hovering: Bool) -> ShelfAutoHideDecision {
        guard openedBy != nil else { return .keep }
        switch event {
        case .itemsChanged, .dragOutCompleted:
            return autoHideEmpty && isEmpty ? .hide(after: 0.35) : .keep
        case .dragEnded(let dropped):
            guard let reason = openedBy, reason.isAutomatic, !dropped, !hovering else { return .keep }
            return isEmpty || reason == .menuBarDrag ? .hide(after: 1.0) : .keep
        }
    }
}
