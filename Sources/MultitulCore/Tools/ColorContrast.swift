import Foundation

public enum WcagLevel: String, Sendable {
    case fail, aa, aaLarge, aaa

    public var title: String {
        switch self {
        case .fail: "не проходит"
        case .aaLarge: "AA для крупного текста"
        case .aa: "AA"
        case .aaa: "AAA"
        }
    }
}

public enum ColorContrast {
    public static func luminance(_ c: RGBAColor) -> Double {
        let (r, g, b) = c.srgb.clamped.linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    public static func composite(_ top: RGBAColor, over bottom: RGBAColor) -> RGBAColor {
        let t = top.srgb.clamped, b = bottom.srgb.clamped
        let a = t.a + b.a * (1 - t.a)
        guard a > 0 else { return RGBAColor(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ x: Double, _ y: Double) -> Double { (x * t.a + y * b.a * (1 - t.a)) / a }
        return RGBAColor(r: mix(t.r, b.r), g: mix(t.g, b.g), b: mix(t.b, b.b), a: a)
    }

    public static func ratio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = luminance(composite(a, over: .white)), lb = luminance(composite(b, over: .white))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public static func level(forRatio r: Double) -> WcagLevel {
        if r >= 7 { return .aaa }
        if r >= 4.5 { return .aa }
        if r >= 3 { return .aaLarge }
        return .fail
    }

    public static func passes(ratio r: Double, level: WcagLevel, largeText: Bool) -> Bool {
        let need: Double
        switch level {
        case .aaa: need = largeText ? 4.5 : 7
        case .aa: need = largeText ? 3 : 4.5
        case .aaLarge: need = 3
        case .fail: need = 0
        }
        return r >= need
    }

    public static func describe(_ r: Double) -> String { String(format: "%.2f:1", r) }

    public static func readableText(on background: RGBAColor) -> RGBAColor {
        ratio(.black, background) >= ratio(.white, background) ? .black : .white
    }
}
