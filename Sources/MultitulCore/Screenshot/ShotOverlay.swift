import Foundation
import CoreGraphics

public enum ShotOverlayAction: String, CaseIterable, Sendable {
    case copy, save, edit, pin, link, share, delete, close

    public var title: String {
        switch self {
        case .copy: "Копировать"
        case .save: "Сохранить"
        case .edit: "Редактор"
        case .pin: "Закрепить"
        case .link: "Ссылка"
        case .share: "Поделиться"
        case .delete: "Удалить"
        case .close: "Закрыть"
        }
    }

    public var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .edit: "pencil.and.outline"
        case .pin: "pin"
        case .link: "link"
        case .share: "square.and.arrow.up"
        case .delete: "trash"
        case .close: "xmark"
        }
    }
}

public enum ShotOverlayLogic {
    public static let thumbSide: CGFloat = 220
    public static let margin: CGFloat = 16
    public static let spacing: CGFloat = 10
    public static let maxVisible = 4

    public static func actions(saved: Bool, uploadConfigured: Bool, copiedAlready: Bool = false) -> [ShotOverlayAction] {
        var a: [ShotOverlayAction] = [.copy]
        if !saved { a.append(.save) }
        a += [.edit, .pin]
        if uploadConfigured { a.append(.link) }
        a.append(.share)
        a += [.delete, .close]
        return a
    }

    public static func thumbnailSize(pixel: CGSize) -> CGSize {
        guard pixel.width > 0, pixel.height > 0 else { return CGSize(width: thumbSide, height: thumbSide * 0.6) }
        let k = min(thumbSide / pixel.width, thumbSide * 0.75 / pixel.height, 1)
        return CGSize(width: max((pixel.width * k).rounded(), 80), height: max((pixel.height * k).rounded(), 50))
    }

    public static func frame(slot: Int, corner: ShotCorner, visible: CGRect, size: CGSize) -> CGRect {
        let x = corner.isRight ? visible.maxX - margin - size.width : visible.minX + margin
        let step = size.height + spacing
        let y = corner.isTop ? visible.maxY - margin - size.height - CGFloat(slot) * step : visible.minY + margin + CGFloat(slot) * step
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

public struct ShotOverlayStack: Equatable, Sendable {
    public private(set) var ids: [Int64] = []
    public let limit: Int

    public init(limit: Int = ShotOverlayLogic.maxVisible) { self.limit = max(limit, 1) }

    @discardableResult
    public mutating func push(_ id: Int64) -> Int64? {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        guard ids.count > limit else { return nil }
        return ids.removeLast()
    }

    public mutating func remove(_ id: Int64) { ids.removeAll { $0 == id } }
    public func slot(of id: Int64) -> Int? { ids.firstIndex(of: id) }
}

public struct ShotOverlayTimer: Equatable, Sendable {
    public let total: Double
    public private(set) var remaining: Double
    public private(set) var paused = false

    public init(seconds: Int) {
        total = Double(max(seconds, 0))
        remaining = total
    }

    public var isSticky: Bool { total == 0 }
    public var fraction: Double { total > 0 ? max(remaining / total, 0) : 1 }

    public mutating func setHover(_ hovering: Bool) {
        paused = hovering
        if !hovering { remaining = max(remaining, min(total, 2)) }
    }

    public mutating func tick(_ dt: Double) -> Bool {
        guard !isSticky, !paused else { return false }
        remaining -= dt
        return remaining <= 0
    }
}

public struct ShotCountdown: Equatable, Sendable {
    public private(set) var remaining: Int
    public private(set) var cancelled = false

    public init(seconds: Int) { remaining = max(seconds, 0) }

    public var isRunning: Bool { remaining > 0 && !cancelled }

    public mutating func tick() -> Bool {
        guard !cancelled else { return false }
        if remaining > 0 { remaining -= 1 }
        return remaining == 0
    }

    public mutating func cancel() { cancelled = true }
}
