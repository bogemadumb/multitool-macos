import SwiftUI
import AppKit

public extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

public enum Theme {
    public static let accent = Color(nsColor: NSColor(hex: 0x0a84ff))
    public static let ok = Color(light: NSColor(hex: 0x248a3d), dark: NSColor(hex: 0x32d74b))
    public static let warn = Color(light: NSColor(hex: 0xc93400), dark: NSColor(hex: 0xff9f0a))
    public static let danger = Color(light: NSColor(hex: 0xd70015), dark: NSColor(hex: 0xff453a))
    public static let muted = Color(nsColor: .secondaryLabelColor)
    public static let track = Color(light: NSColor(hex: 0xe5e5ea), dark: NSColor(hex: 0x3a3a3c))
    public static let cardFill = Color(light: NSColor(hex: 0xffffff), dark: NSColor(white: 1, alpha: 0.07))
    public static let cardBorder = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.09))
    public static let field = Color(light: NSColor(srgbRed: 0.463, green: 0.463, blue: 0.502, alpha: 0.12), dark: NSColor(srgbRed: 0.463, green: 0.463, blue: 0.502, alpha: 0.24))
    public static let separator = Color(nsColor: .separatorColor)
    public static let tileFill = Color(light: NSColor(hex: 0xffffff), dark: NSColor(white: 1, alpha: 0.10))
    public static let primaryText = Color(nsColor: .labelColor)
    public static let secondaryText = Color(light: NSColor(hex: 0x3a3a3c), dark: NSColor(white: 1, alpha: 0.78))

    public enum Radius {
        public static let card: CGFloat = 14
        public static let small: CGFloat = 8
        public static let tile: CGFloat = 6
        public static let window: CGFloat = 14
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 26
    }

    public enum Fonts {
        public static let pageTitle = Font.system(size: 24, weight: .bold)
        public static let subtitle = Font.system(size: 13)
        public static let label = Font.system(size: 11.5, weight: .semibold)
        public static let body = Font.system(size: 13)
        public static let caption = Font.system(size: 10.5)
        public static let pill = Font.system(size: 11, weight: .bold)
        public static let bigNumber = Font.system(size: 26, weight: .bold).monospacedDigit()
        public static let midNumber = Font.system(size: 19, weight: .bold).monospacedDigit()
        public static let unit = Font.system(size: 13, weight: .medium)
        public static let number = Font.system(size: 13).monospacedDigit()
        public static let mono = Font.system(size: 12, weight: .semibold, design: .monospaced)
    }
}

public struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .popover, blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blending = blending
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = material
        v.blendingMode = blending
        return v
    }

    public func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

extension View {
    @ViewBuilder
    func glassSurface(radius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
