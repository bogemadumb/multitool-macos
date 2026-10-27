import Foundation
import CoreGraphics

public struct ShotWindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var ownerPid: Int32
    public var ownerName: String
    public var bundleID: String?
    public var title: String
    public var frame: CGRect
    public var layer: Int
    public var isOnScreen: Bool

    public init(id: UInt32, ownerPid: Int32 = 0, ownerName: String = "", bundleID: String? = nil, title: String = "", frame: CGRect,
                layer: Int = 0, isOnScreen: Bool = true) {
        self.id = id
        self.ownerPid = ownerPid
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

public enum ShotWindowFilter {
    public static let minSide: CGFloat = 40

    public static func selectable(_ windows: [ShotWindowInfo], excludingPids: Set<Int32> = [], minSide: CGFloat = ShotWindowFilter.minSide) -> [ShotWindowInfo] {
        windows.filter { w in
            w.layer == 0 && w.isOnScreen && !excludingPids.contains(w.ownerPid) && w.frame.width >= minSide && w.frame.height >= minSide
        }
    }

    public static func topmost(at p: CGPoint, in windows: [ShotWindowInfo]) -> ShotWindowInfo? {
        windows.first { $0.frame.contains(p) }
    }

    public static func label(_ w: ShotWindowInfo) -> String {
        let t = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.ownerName.isEmpty { return t }
        return t.isEmpty ? w.ownerName : "\(w.ownerName) — \(t)"
    }
}

public struct ShotShadowInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let standard = ShotShadowInsets(top: 16, left: 24, bottom: 40, right: 24)
    public static let none = ShotShadowInsets(top: 0, left: 0, bottom: 0, right: 0)
}

public struct ShotWindowPlan: Equatable, Sendable {
    public var windowFrame: CGRect
    public var captureFrame: CGRect
    public var scale: CGFloat
    public var withShadow: Bool

    public var pixelWidth: Int { Int((captureFrame.width * scale).rounded()) }
    public var pixelHeight: Int { Int((captureFrame.height * scale).rounded()) }
    public var windowRectInImage: CGRect {
        CGRect(x: (windowFrame.minX - captureFrame.minX) * scale, y: (windowFrame.minY - captureFrame.minY) * scale,
               width: windowFrame.width * scale, height: windowFrame.height * scale)
    }
}

public enum ShotWindowMath {
    public static func plan(frame: CGRect, scale: CGFloat, withShadow: Bool, insets: ShotShadowInsets = .standard) -> ShotWindowPlan {
        let f = frame.standardized
        let cap = withShadow
            ? CGRect(x: f.minX - insets.left, y: f.minY - insets.top, width: f.width + insets.left + insets.right, height: f.height + insets.top + insets.bottom)
            : f
        return ShotWindowPlan(windowFrame: f, captureFrame: cap, scale: max(scale, 1), withShadow: withShadow)
    }

    public static func scale(for window: CGRect, displays: [ShotDisplay]) -> CGFloat {
        let center = CGPoint(x: window.midX, y: window.midY)
        return ShotSpace.display(containing: center, in: displays)?.scale ?? 2
    }
}

public struct ShotBackdropLayout: Equatable, Sendable {
    public var canvas: CGSize
    public var imageRect: CGRect
    public var cornerRadius: CGFloat
    public var hasBackground: Bool
}

public enum ShotBackdropMath {
    public static func layout(imageSize: CGSize, paddingPoints: Int, scale: CGFloat, background: ShotBackground, cornerRadiusPoints: Int) -> ShotBackdropLayout {
        let pad = CGFloat(max(paddingPoints, 0)) * max(scale, 1)
        let has = !background.isNone && pad > 0
        let p = pad
        let canvas = CGSize(width: imageSize.width + p * 2, height: imageSize.height + p * 2)
        let radius = has ? min(CGFloat(max(cornerRadiusPoints, 0)) * max(scale, 1), min(imageSize.width, imageSize.height) / 2) : 0
        return ShotBackdropLayout(canvas: canvas, imageRect: CGRect(x: p, y: p, width: imageSize.width, height: imageSize.height), cornerRadius: radius, hasBackground: has)
    }

    public static func gradientEndpoints(angleDegrees: Int, in size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let a = Double(((angleDegrees % 360) + 360) % 360) * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let cx = size.width / 2, cy = size.height / 2
        let half = abs(dx) * size.width / 2 + abs(dy) * size.height / 2
        return (CGPoint(x: cx - dx * half, y: cy - dy * half), CGPoint(x: cx + dx * half, y: cy + dy * half))
    }
}

public enum ShotWatermarkMath {
    public static func rect(textSize: CGSize, canvas: CGSize, corner: ShotCorner, margin: CGFloat = 12) -> CGRect {
        let x = corner.isRight ? canvas.width - textSize.width - margin : margin
        let y = corner.isTop ? margin : canvas.height - textSize.height - margin
        return CGRect(x: max(x, 0), y: max(y, 0), width: textSize.width, height: textSize.height)
    }
}
