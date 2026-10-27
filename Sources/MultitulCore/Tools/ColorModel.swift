import Foundation

public enum ColorSpaceKind: String, CaseIterable, Sendable {
    case srgb, displayP3

    public var title: String { self == .srgb ? "sRGB" : "Display P3" }
}

struct Mat3 {
    let m: [Double]

    init(_ m: [Double]) { self.m = m }

    func apply(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2, m[3] * v.0 + m[4] * v.1 + m[5] * v.2, m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    var inverse: Mat3 {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        let k = 1 / det
        return Mat3([(e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k,
                     (f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k,
                     (d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k])
    }

    static let srgbToXYZ = Mat3([0.4123907992659595, 0.357584339383878, 0.1804807884018343,
                                 0.21263900587151036, 0.715168678767756, 0.07219231536073371,
                                 0.01933081871559185, 0.11919477979462599, 0.9505321522496606])
    static let p3ToXYZ = Mat3([0.4865709486482162, 0.26566769316909306, 0.1982172852343625,
                               0.2289745640697488, 0.6917385218365064, 0.079286914093745,
                               0.0, 0.04511338185890264, 1.043944368900976])
    static let d65ToD50 = Mat3([1.0479298208405488, 0.022946793341019088, -0.05019222954313557,
                                0.029627815688159344, 0.990434484573249, -0.01707382502938514,
                                -0.009243058152591178, 0.015055144896577895, 0.7518742899580008])
}

public enum ColorTransfer {
    public static func decode(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return c < 0 ? -v : v
    }

    public static func encode(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return c < 0 ? -v : v
    }
}

public struct HSLColor: Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double
    public var a: Double
}

public struct HSBColor: Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var b: Double
    public var a: Double
}

public struct CMYKColor: Equatable, Sendable {
    public var c: Double
    public var m: Double
    public var y: Double
    public var k: Double
}

public struct LabColor: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double
}

public struct OKLCHColor: Equatable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double
}

public struct RGBAColor: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public var space: ColorSpaceKind

    public init(r: Double, g: Double, b: Double, a: Double = 1, space: ColorSpaceKind = .srgb) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.space = space
    }

    public init(red8: Int, green8: Int, blue8: Int, alpha8: Int = 255, space: ColorSpaceKind = .srgb) {
        self.init(r: Double(red8) / 255, g: Double(green8) / 255, b: Double(blue8) / 255, a: Double(alpha8) / 255, space: space)
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)

    public static func byte(_ v: Double) -> Int { Int((ToolsClamp.double(v, 0...1) * 255).rounded()) }

    public var red8: Int { Self.byte(r) }
    public var green8: Int { Self.byte(g) }
    public var blue8: Int { Self.byte(b) }
    public var alpha8: Int { Self.byte(a) }

    public var isOpaque: Bool { alpha8 == 255 }

    public var isInGamut: Bool {
        let eps = 1e-6
        return [r, g, b].allSatisfy { $0 >= -eps && $0 <= 1 + eps }
    }

    public var clamped: RGBAColor {
        RGBAColor(r: ToolsClamp.double(r, 0...1), g: ToolsClamp.double(g, 0...1), b: ToolsClamp.double(b, 0...1), a: ToolsClamp.double(a, 0...1), space: space)
    }

    public var linear: (Double, Double, Double) { (ColorTransfer.decode(r), ColorTransfer.decode(g), ColorTransfer.decode(b)) }

    public func converted(to target: ColorSpaceKind) -> RGBAColor {
        if target == space { return self }
        let toXYZ = space == .srgb ? Mat3.srgbToXYZ : Mat3.p3ToXYZ
        let fromXYZ = (target == .srgb ? Mat3.srgbToXYZ : Mat3.p3ToXYZ).inverse
        let lin = fromXYZ.apply(toXYZ.apply(linear))
        return RGBAColor(r: ColorTransfer.encode(lin.0), g: ColorTransfer.encode(lin.1), b: ColorTransfer.encode(lin.2), a: a, space: target)
    }

    public var srgb: RGBAColor { converted(to: .srgb) }

    public var xyzD65: (Double, Double, Double) {
        (space == .srgb ? Mat3.srgbToXYZ : Mat3.p3ToXYZ).apply(linear)
    }

    public var hsl: HSLColor {
        let c = srgb.clamped
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-12 else { return HSLColor(h: 0, s: 0, l: l, a: c.a) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        return HSLColor(h: Self.hue(c, mx, d), s: s, l: l, a: c.a)
    }

    public var hsb: HSBColor {
        let c = srgb.clamped
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let d = mx - mn
        guard d > 1e-12 else { return HSBColor(h: 0, s: 0, b: mx, a: c.a) }
        return HSBColor(h: Self.hue(c, mx, d), s: d / mx, b: mx, a: c.a)
    }

    public var cmyk: CMYKColor {
        let c = srgb.clamped
        let k = 1 - max(c.r, c.g, c.b)
        guard k < 1 - 1e-12 else { return CMYKColor(c: 0, m: 0, y: 0, k: 1) }
        return CMYKColor(c: (1 - c.r - k) / (1 - k), m: (1 - c.g - k) / (1 - k), y: (1 - c.b - k) / (1 - k), k: k)
    }

    private static func hue(_ c: RGBAColor, _ mx: Double, _ d: Double) -> Double {
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    public init(hsl: HSLColor) {
        let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
        self = RGBAColor.fromHue(hsl.h, chroma: c, match: hsl.l - c / 2, alpha: hsl.a)
    }

    public init(hsb: HSBColor) {
        let c = hsb.b * hsb.s
        self = RGBAColor.fromHue(hsb.h, chroma: c, match: hsb.b - c, alpha: hsb.a)
    }

    public init(cmyk: CMYKColor, alpha: Double = 1) {
        self.init(r: (1 - cmyk.c) * (1 - cmyk.k), g: (1 - cmyk.m) * (1 - cmyk.k), b: (1 - cmyk.y) * (1 - cmyk.k), a: alpha)
    }

    private static func fromHue(_ hue: Double, chroma c: Double, match m: Double, alpha: Double) -> RGBAColor {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let t: (Double, Double, Double)
        switch hp {
        case ..<1: t = (c, x, 0)
        case ..<2: t = (x, c, 0)
        case ..<3: t = (0, c, x)
        case ..<4: t = (0, x, c)
        case ..<5: t = (x, 0, c)
        default: t = (c, 0, x)
        }
        return RGBAColor(r: t.0 + m, g: t.1 + m, b: t.2 + m, a: alpha)
    }

    private static let d50 = (0.3457 / 0.3585, 1.0, (1 - 0.3457 - 0.3585) / 0.3585)
    private static let eps = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    public var lab: LabColor {
        let x65 = xyzD65
        let x = Mat3.d65ToD50.apply(x65)
        func f(_ v: Double) -> Double { v > Self.eps ? cbrt(v) : (Self.kappa * v + 16) / 116 }
        let fx = f(x.0 / Self.d50.0), fy = f(x.1 / Self.d50.1), fz = f(x.2 / Self.d50.2)
        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public init(lab: LabColor, alpha: Double = 1) {
        let fy = (lab.l + 16) / 116
        let fx = lab.a / 500 + fy
        let fz = fy - lab.b / 200
        func inv(_ f: Double, white: Double) -> Double {
            let f3 = f * f * f
            return (f3 > RGBAColor.eps ? f3 : (116 * f - 16) / RGBAColor.kappa) * white
        }
        let yv = lab.l > RGBAColor.kappa * RGBAColor.eps ? pow((lab.l + 16) / 116, 3) : lab.l / RGBAColor.kappa
        let d50 = (inv(fx, white: RGBAColor.d50.0), yv * RGBAColor.d50.1, inv(fz, white: RGBAColor.d50.2))
        let x65 = Mat3.d65ToD50.inverse.apply(d50)
        let lin = Mat3.srgbToXYZ.inverse.apply(x65)
        self.init(r: ColorTransfer.encode(lin.0), g: ColorTransfer.encode(lin.1), b: ColorTransfer.encode(lin.2), a: alpha)
    }

    public var oklab: (l: Double, a: Double, b: Double) {
        let s = srgb
        let (r, g, b) = s.linear
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let sv = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * sv,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * sv,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * sv)
    }

    public var oklch: OKLCHColor {
        let o = oklab
        let c = (o.a * o.a + o.b * o.b).squareRoot()
        var h = atan2(o.b, o.a) * 180 / .pi
        if h < 0 { h += 360 }
        return OKLCHColor(l: o.l, c: c, h: c < 1e-4 ? 0 : h)
    }

    public init(oklabL l: Double, a: Double, b: Double, alpha: Double = 1) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        self.init(r: ColorTransfer.encode(r), g: ColorTransfer.encode(g), b: ColorTransfer.encode(bl), a: alpha)
    }

    public init(oklch: OKLCHColor, alpha: Double = 1) {
        let rad = oklch.h * .pi / 180
        self.init(oklabL: oklch.l, a: oklch.c * cos(rad), b: oklch.c * sin(rad), alpha: alpha)
    }

    public func approximatelyEquals(_ o: RGBAColor, tolerance: Double) -> Bool {
        let x = o.converted(to: space)
        return abs(r - x.r) <= tolerance && abs(g - x.g) <= tolerance && abs(b - x.b) <= tolerance && abs(a - x.a) <= tolerance
    }
}
