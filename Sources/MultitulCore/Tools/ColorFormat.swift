import Foundation

public enum ColorFormat: String, CaseIterable, Identifiable, Sendable {
    case hex, rgb, hsl, hsb, cmyk, swiftUI, nsColor, uiColor, cssName, cssP3, oklch, lab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .hsb: "HSB"
        case .cmyk: "CMYK"
        case .swiftUI: "SwiftUI Color"
        case .nsColor: "NSColor"
        case .uiColor: "UIColor"
        case .cssName: "Имя CSS"
        case .cssP3: "CSS Display P3"
        case .oklch: "OKLCH"
        case .lab: "Lab"
        }
    }

    public static let catalog: [ColorFormat] = [.hex, .rgb, .hsl, .swiftUI]
}

public struct ColorFormatOptions: Equatable, Sendable {
    public var withoutHash = false
    public var uppercaseHex = true

    public init(withoutHash: Bool = false, uppercaseHex: Bool = true) {
        self.withoutHash = withoutHash
        self.uppercaseHex = uppercaseHex
    }
}

public enum ColorFormatter {
    static func num(_ v: Double, _ decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    private static func int(_ v: Double) -> Int { Int(v.rounded()) }

    public static func hex(_ color: RGBAColor, options: ColorFormatOptions = ColorFormatOptions()) -> String {
        let c = color.srgb
        var s = String(format: "%02X%02X%02X", c.red8, c.green8, c.blue8)
        if !c.isOpaque { s += String(format: "%02X", c.alpha8) }
        if !options.uppercaseHex { s = s.lowercased() }
        return options.withoutHash ? s : "#" + s
    }

    public static func format(_ color: RGBAColor, as format: ColorFormat, options: ColorFormatOptions = ColorFormatOptions()) -> String {
        let s = color.srgb.clamped
        let opaque = s.isOpaque
        let alpha = num(s.a, 3)
        switch format {
        case .hex:
            return hex(color, options: options)
        case .rgb:
            return opaque ? "rgb(\(s.red8), \(s.green8), \(s.blue8))" : "rgba(\(s.red8), \(s.green8), \(s.blue8), \(alpha))"
        case .hsl:
            let h = s.hsl
            let body = "\(int(h.h) % 360), \(int(h.s * 100))%, \(int(h.l * 100))%"
            return opaque ? "hsl(\(body))" : "hsla(\(body), \(alpha))"
        case .hsb:
            let h = s.hsb
            let body = "\(int(h.h) % 360), \(int(h.s * 100))%, \(int(h.b * 100))%"
            return opaque ? "hsb(\(body))" : "hsba(\(body), \(alpha))"
        case .cmyk:
            let k = s.cmyk
            return "cmyk(\(int(k.c * 100))%, \(int(k.m * 100))%, \(int(k.y * 100))%, \(int(k.k * 100))%)"
        case .swiftUI:
            let n = color.clamped
            let rgb = "red: \(num(n.r, 3)), green: \(num(n.g, 3)), blue: \(num(n.b, 3))"
            let space = color.space == .displayP3 ? ".displayP3, " : ""
            return n.a < 1 - 1e-9 ? "Color(\(space)\(rgb), opacity: \(num(n.a, 3)))" : "Color(\(space)\(rgb))"
        case .nsColor:
            let n = color.clamped
            let label = color.space == .displayP3 ? "displayP3Red" : "srgbRed"
            return "NSColor(\(label): \(num(n.r, 3)), green: \(num(n.g, 3)), blue: \(num(n.b, 3)), alpha: \(num(n.a, 3)))"
        case .uiColor:
            let n = color.clamped
            let label = color.space == .displayP3 ? "displayP3Red" : "red"
            return "UIColor(\(label): \(num(n.r, 3)), green: \(num(n.g, 3)), blue: \(num(n.b, 3)), alpha: \(num(n.a, 3)))"
        case .cssName:
            return ColorNames.nearestName(to: s)
        case .cssP3:
            let p = color.converted(to: .displayP3).clamped
            let body = "\(num(p.r, 4)) \(num(p.g, 4)) \(num(p.b, 4))"
            return opaque ? "color(display-p3 \(body))" : "color(display-p3 \(body) / \(alpha))"
        case .oklch:
            let o = color.oklch
            let body = "\(num(o.l, 4)) \(num(o.c, 4)) \(num(o.h, 2))"
            return opaque ? "oklch(\(body))" : "oklch(\(body) / \(alpha))"
        case .lab:
            let l = color.lab
            let body = "\(num(l.l, 2)) \(num(l.a, 2)) \(num(l.b, 2))"
            return opaque ? "lab(\(body))" : "lab(\(body) / \(alpha))"
        }
    }

    public static func formatAll(_ color: RGBAColor, options: ColorFormatOptions = ColorFormatOptions()) -> [(format: ColorFormat, text: String)] {
        ColorFormat.allCases.map { ($0, format(color, as: $0, options: options)) }
    }
}
