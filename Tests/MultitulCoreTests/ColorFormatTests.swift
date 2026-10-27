import Testing
import Foundation
@testable import MultitulCore

private func rgb8(_ c: RGBAColor?) -> [Int]? { c.map { [$0.red8, $0.green8, $0.blue8, $0.alpha8] } }

@Suite struct ColorParseTests {
    @Test func hexShortAndLongForms() {
        #expect(rgb8(ColorParser.parse("#F80")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("#F80A")) == [255, 136, 0, 170])
        #expect(rgb8(ColorParser.parse("#FF8800")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("#ff8800cc")) == [255, 136, 0, 204])
    }

    @Test func hexWithoutHashPrefixAndSpaces() {
        #expect(rgb8(ColorParser.parse("FF8800")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("0xFF8800")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("  #336699 ;\n")) == [51, 102, 153, 255])
    }

    @Test func hexRejectsGarbage() {
        for bad in ["#GG0000", "#12345", "#1234567", "", "#", "#12", "хорошо", "#FF88000"] { #expect(ColorParser.parse(bad) == nil, "\(bad)") }
    }

    @Test func rgbFunctionalNotations() {
        #expect(rgb8(ColorParser.parse("rgb(255, 136, 0)")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("rgb(255 136 0)")) == [255, 136, 0, 255])
        #expect(rgb8(ColorParser.parse("rgba(255,136,0,0.5)")) == [255, 136, 0, 128])
        #expect(rgb8(ColorParser.parse("rgb(255 136 0 / 50%)")) == [255, 136, 0, 128])
        #expect(rgb8(ColorParser.parse("rgb(100%, 50%, 0%)")) == [255, 128, 0, 255])
        #expect(rgb8(ColorParser.parse("RGB(0,0,0)")) == [0, 0, 0, 255])
        #expect(rgb8(ColorParser.parse("rgb(300, -5, 0)")) == [255, 0, 0, 255])
    }

    @Test func rgbRejectsBrokenInput() {
        for bad in ["rgb(1,2)", "rgb(a,b,c)", "rgb()", "rgb(1,2,3,4,5)", "rgb(1,2,3", "foo(1,2,3)"] { #expect(ColorParser.parse(bad) == nil, "\(bad)") }
    }

    @Test func hslNotations() {
        #expect(rgb8(ColorParser.parse("hsl(0, 100%, 50%)")) == [255, 0, 0, 255])
        #expect(rgb8(ColorParser.parse("hsl(120deg 100% 25%)")) == [0, 128, 0, 255])
        #expect(rgb8(ColorParser.parse("hsl(0.5turn, 100%, 50%)")) == [0, 255, 255, 255])
        #expect(rgb8(ColorParser.parse("hsla(240, 100%, 50%, 0.25)")) == [0, 0, 255, 64])
        #expect(rgb8(ColorParser.parse("hsl(180 0% 50%)")) == [128, 128, 128, 255])
        let rad = ColorParser.parse("hsl(3.14159265rad 100% 50%)")
        #expect(rgb8(rad) == [0, 255, 255, 255])
    }

    @Test func hsbNotations() {
        #expect(rgb8(ColorParser.parse("hsb(30, 100%, 100%)")) == [255, 128, 0, 255])
        #expect(rgb8(ColorParser.parse("hsv(0 0% 100%)")) == [255, 255, 255, 255])
        #expect(rgb8(ColorParser.parse("hsba(0, 100%, 100%, 0.5)")) == [255, 0, 0, 128])
    }

    @Test func cmykNotations() {
        #expect(rgb8(ColorParser.parse("cmyk(0%, 100%, 100%, 0%)")) == [255, 0, 0, 255])
        #expect(rgb8(ColorParser.parse("cmyk(0, 0, 0, 1)")) == [0, 0, 0, 255])
        #expect(rgb8(ColorParser.parse("cmyk(100, 0, 0, 0)")) == [0, 255, 255, 255])
        #expect(ColorParser.parse("cmyk(1,2,3)") == nil)
    }

    @Test func swiftSnippets() {
        #expect(rgb8(ColorParser.parse("Color(red: 1, green: 0.5, blue: 0)")) == [255, 128, 0, 255])
        #expect(rgb8(ColorParser.parse("Color(red: 0.2, green: 0.4, blue: 0.6).opacity(0.5)")) == [51, 102, 153, 128])
        #expect(rgb8(ColorParser.parse("NSColor(srgbRed: 51/255, green: 102/255, blue: 153/255, alpha: 1)")) == [51, 102, 153, 255])
        #expect(rgb8(ColorParser.parse("UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1.0)")) == [51, 102, 153, 255])
        #expect(rgb8(ColorParser.parse("Color(red: CGFloat(0.2), green: 0.4, blue: 0.6, opacity: 0.5)")) == [51, 102, 153, 128])
    }

    @Test func swiftDisplayP3IsKeptAsP3() {
        let a = ColorParser.parse("Color(.displayP3, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.5)")
        #expect(a?.space == .displayP3)
        #expect(a?.alpha8 == 128)
        #expect(ColorParser.parse("NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)")?.space == .displayP3)
        #expect(ColorParser.parse("UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)")?.space == .displayP3)
        #expect(ColorParser.parse("color(display-p3 1 0 0)")?.space == .displayP3)
        #expect(ColorParser.parse("color(srgb 1 0 0 / 0.5)")?.alpha8 == 128)
    }

    @Test func swiftRejectsUnknownShapes() {
        #expect(ColorParser.parse("Color(white: 0.5)") == nil)
        #expect(ColorParser.parse("Color(red: 1, green: 0)") == nil)
        #expect(ColorParser.parse("Color(red: x, green: 0, blue: 0)") == nil)
    }

    @Test func cssNamesAreCaseAndSpaceInsensitive() {
        #expect(rgb8(ColorParser.parse("tomato")) == [255, 99, 71, 255])
        #expect(rgb8(ColorParser.parse("RebeccaPurple")) == [102, 51, 153, 255])
        #expect(rgb8(ColorParser.parse("  Dark Slate Gray ")) == [47, 79, 79, 255])
        #expect(rgb8(ColorParser.parse("transparent")) == [0, 0, 0, 0])
        #expect(ColorParser.parse("notacolor") == nil)
    }

    @Test func oklchAndLabParsing() {
        let red = RGBAColor(red8: 255, green8: 0, blue8: 0)
        #expect(ColorParser.parse("oklch(0.628 0.2577 29.23)")!.approximatelyEquals(red, tolerance: 0.01))
        #expect(ColorParser.parse("oklch(62.8% 0.2577 29.23deg / 50%)")!.alpha8 == 128)
        #expect(ColorParser.parse("lab(54.29 80.8 69.89)")!.approximatelyEquals(red, tolerance: 0.01))
        #expect(ColorParser.parse("oklab(0.628 0.2249 0.1258)")!.approximatelyEquals(red, tolerance: 0.01))
    }
}

@Suite struct ColorNamesTests {
    @Test func tableHasAllCssColors() {
        #expect(ColorNames.table.count == 148)
        #expect(ColorNames.table.keys.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLowercase } })
    }

    @Test func exactAndNearestNames() {
        #expect(ColorNames.exactName(of: RGBAColor(red8: 255, green8: 99, blue8: 71)) == "tomato")
        #expect(ColorNames.exactName(of: RGBAColor(red8: 0, green8: 255, blue8: 255)) == "cyan")
        #expect(ColorNames.exactName(of: RGBAColor(red8: 128, green8: 128, blue8: 128)) == "gray")
        #expect(ColorNames.exactName(of: RGBAColor(red8: 1, green8: 2, blue8: 3)) == nil)
        #expect(ColorNames.nearestName(to: RGBAColor(red8: 250, green8: 100, blue8: 70)) == "tomato")
        #expect(ColorNames.nearestName(to: RGBAColor(red8: 3, green8: 2, blue8: 1)) == "black")
    }

    @Test func translucentColorsHaveNoExactName() {
        #expect(ColorNames.exactName(of: RGBAColor(red8: 255, green8: 0, blue8: 0, alpha8: 100)) == nil)
    }
}

@Suite struct ColorFormatOutputTests {
    private let orange = RGBAColor(red8: 255, green8: 136, blue8: 0)
    private let blueish = RGBAColor(red8: 51, green8: 102, blue8: 153)

    @Test func hexVariants() {
        #expect(ColorFormatter.hex(orange) == "#FF8800")
        #expect(ColorFormatter.hex(orange, options: ColorFormatOptions(withoutHash: true)) == "FF8800")
        #expect(ColorFormatter.hex(orange, options: ColorFormatOptions(uppercaseHex: false)) == "#ff8800")
        #expect(ColorFormatter.hex(RGBAColor(red8: 255, green8: 136, blue8: 0, alpha8: 128)) == "#FF880080")
        #expect(ColorFormatter.hex(.black, options: ColorFormatOptions(withoutHash: true, uppercaseHex: false)) == "000000")
    }

    @Test func rgbHslHsbCmykText() {
        #expect(ColorFormatter.format(orange, as: .rgb) == "rgb(255, 136, 0)")
        #expect(ColorFormatter.format(RGBAColor(red8: 255, green8: 136, blue8: 0, alpha8: 128), as: .rgb) == "rgba(255, 136, 0, 0.502)")
        #expect(ColorFormatter.format(RGBAColor(red8: 255, green8: 0, blue8: 0), as: .hsl) == "hsl(0, 100%, 50%)")
        #expect(ColorFormatter.format(RGBAColor(red8: 255, green8: 0, blue8: 0, alpha8: 128), as: .hsl) == "hsla(0, 100%, 50%, 0.502)")
        #expect(ColorFormatter.format(RGBAColor(red8: 0, green8: 255, blue8: 0), as: .hsb) == "hsb(120, 100%, 100%)")
        #expect(ColorFormatter.format(RGBAColor(red8: 255, green8: 0, blue8: 0), as: .cmyk) == "cmyk(0%, 100%, 100%, 0%)")
        #expect(ColorFormatter.format(.white, as: .cmyk) == "cmyk(0%, 0%, 0%, 0%)")
        #expect(ColorFormatter.format(.black, as: .cmyk) == "cmyk(0%, 0%, 0%, 100%)")
    }

    @Test func swiftCodeFormats() {
        #expect(ColorFormatter.format(blueish, as: .swiftUI) == "Color(red: 0.2, green: 0.4, blue: 0.6)")
        #expect(ColorFormatter.format(RGBAColor(red8: 51, green8: 102, blue8: 153, alpha8: 128), as: .swiftUI) == "Color(red: 0.2, green: 0.4, blue: 0.6, opacity: 0.502)")
        #expect(ColorFormatter.format(blueish, as: .nsColor) == "NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)")
        #expect(ColorFormatter.format(blueish, as: .uiColor) == "UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)")
    }

    @Test func swiftCodeKeepsDisplayP3() {
        let p3 = RGBAColor(r: 0.2, g: 0.4, b: 0.6, space: .displayP3)
        #expect(ColorFormatter.format(p3, as: .swiftUI) == "Color(.displayP3, red: 0.2, green: 0.4, blue: 0.6)")
        #expect(ColorFormatter.format(p3, as: .nsColor) == "NSColor(displayP3Red: 0.2, green: 0.4, blue: 0.6, alpha: 1)")
        #expect(ColorFormatter.format(p3, as: .uiColor) == "UIColor(displayP3Red: 0.2, green: 0.4, blue: 0.6, alpha: 1)")
        #expect(ColorFormatter.format(p3, as: .cssP3) == "color(display-p3 0.2 0.4 0.6)")
    }

    @Test func hexOfP3ColorUsesSrgbEquivalent() {
        let p3Red = RGBAColor(r: 1, g: 0, b: 0, space: .displayP3)
        #expect(ColorFormatter.hex(p3Red) == "#FF0000")
        let mid = RGBAColor(r: 128.0 / 255, g: 128.0 / 255, b: 128.0 / 255, space: .displayP3)
        #expect(ColorFormatter.hex(mid) == "#808080")
    }

    @Test func cssNameFormatPicksNearest() {
        #expect(ColorFormatter.format(RGBAColor(red8: 255, green8: 99, blue8: 71), as: .cssName) == "tomato")
    }

    @Test func oklchAndLabText() {
        #expect(ColorFormatter.format(.white, as: .oklch) == "oklch(1 0 0)")
        #expect(ColorFormatter.format(.white, as: .lab) == "lab(100 0 0)")
        let red = RGBAColor(red8: 255, green8: 0, blue8: 0)
        let o = red.oklch
        #expect(abs(o.l - 0.628) < 0.002 && abs(o.c - 0.2577) < 0.002 && abs(o.h - 29.23) < 0.1)
        let l = red.lab
        #expect(abs(l.l - 54.29) < 0.1 && abs(l.a - 80.8) < 0.2 && abs(l.b - 69.9) < 0.2)
    }

    @Test func formatAllCoversEveryFormatOnce() {
        let all = ColorFormatter.formatAll(orange)
        #expect(all.map(\.format) == ColorFormat.allCases)
        #expect(all.allSatisfy { !$0.text.isEmpty })
        #expect(Set(ColorFormat.allCases.map(\.rawValue)).count == ColorFormat.allCases.count)
        #expect(ColorFormat.catalog == [.hex, .rgb, .hsl, .swiftUI])
    }
}

@Suite struct ColorRoundTripTests {
    private let samples: [RGBAColor] = [
        RGBAColor(red8: 0, green8: 0, blue8: 0), RGBAColor(red8: 255, green8: 255, blue8: 255), RGBAColor(red8: 255, green8: 0, blue8: 0),
        RGBAColor(red8: 0, green8: 255, blue8: 0), RGBAColor(red8: 0, green8: 0, blue8: 255), RGBAColor(red8: 51, green8: 102, blue8: 153),
        RGBAColor(red8: 255, green8: 136, blue8: 0), RGBAColor(red8: 18, green8: 52, blue8: 86), RGBAColor(red8: 128, green8: 128, blue8: 128),
        RGBAColor(red8: 254, green8: 220, blue8: 186), RGBAColor(red8: 7, green8: 200, blue8: 99), RGBAColor(red8: 200, green8: 7, blue8: 199)
    ]

    private func roundTrip(_ f: ColorFormat, tolerance: Double, alpha: Bool = true) {
        for c in samples {
            for a in alpha ? [255, 128] : [255] {
                let src = RGBAColor(r: c.r, g: c.g, b: c.b, a: Double(a) / 255)
                let text = ColorFormatter.format(src, as: f)
                guard let back = ColorParser.parse(text) else { Issue.record("\(f) failed to parse \(text)"); continue }
                #expect(back.approximatelyEquals(src, tolerance: tolerance), "\(f): \(text)")
            }
        }
    }

    @Test func hexIsLossless() {
        for c in samples {
            let back = ColorParser.parse(ColorFormatter.hex(c))
            #expect(rgb8(back) == rgb8(c))
        }
    }

    @Test func rgbIsLossless() { roundTrip(.rgb, tolerance: 0.003) }
    @Test func hslWithinRounding() { roundTrip(.hsl, tolerance: 0.02) }
    @Test func hsbWithinRounding() { roundTrip(.hsb, tolerance: 0.02) }
    @Test func cmykWithinRounding() { roundTrip(.cmyk, tolerance: 0.02, alpha: false) }
    @Test func swiftUIWithinThreeDecimals() { roundTrip(.swiftUI, tolerance: 0.001) }
    @Test func nsColorWithinThreeDecimals() { roundTrip(.nsColor, tolerance: 0.001) }
    @Test func uiColorWithinThreeDecimals() { roundTrip(.uiColor, tolerance: 0.001) }
    @Test func oklchRoundTrip() { roundTrip(.oklch, tolerance: 0.003) }
    @Test func labRoundTrip() { roundTrip(.lab, tolerance: 0.003) }
    @Test func displayP3CssRoundTrip() { roundTrip(.cssP3, tolerance: 0.002) }

    @Test func conversionsAreInverse() {
        for c in samples {
            #expect(RGBAColor(hsl: c.hsl).approximatelyEquals(c, tolerance: 1e-9))
            #expect(RGBAColor(hsb: c.hsb).approximatelyEquals(c, tolerance: 1e-9))
            #expect(RGBAColor(cmyk: c.cmyk).approximatelyEquals(c, tolerance: 1e-9))
            #expect(RGBAColor(lab: c.lab).approximatelyEquals(c, tolerance: 1e-6))
            #expect(RGBAColor(oklch: c.oklch).approximatelyEquals(c, tolerance: 1e-4))
        }
    }
}

@Suite struct ColorSpaceTests {
    @Test func srgbWhiteStaysWhiteInP3() {
        let p3 = RGBAColor.white.converted(to: .displayP3)
        #expect(abs(p3.r - 1) < 1e-6 && abs(p3.g - 1) < 1e-6 && abs(p3.b - 1) < 1e-6)
    }

    @Test func greysAreSharedBetweenSpaces() {
        let g = RGBAColor(r: 0.37, g: 0.37, b: 0.37)
        let p3 = g.converted(to: .displayP3)
        #expect(abs(p3.r - 0.37) < 1e-6 && abs(p3.g - 0.37) < 1e-6)
    }

    @Test func srgbRedInP3MatchesReference() {
        let p3 = RGBAColor(r: 1, g: 0, b: 0).converted(to: .displayP3)
        #expect(abs(p3.r - 0.9175) < 0.002 && abs(p3.g - 0.2003) < 0.002 && abs(p3.b - 0.1386) < 0.002)
        #expect(p3.space == .displayP3)
    }

    @Test func p3GreenIsOutsideSrgbGamut() {
        let g = RGBAColor(r: 0, g: 1, b: 0, space: .displayP3)
        #expect(g.isInGamut)
        #expect(!g.converted(to: .srgb).isInGamut)
        #expect(g.converted(to: .srgb).clamped.isInGamut)
    }

    @Test func roundTripBetweenSpacesIsExact() {
        let c = RGBAColor(r: 0.3, g: 0.6, b: 0.9)
        #expect(c.converted(to: .displayP3).converted(to: .srgb).approximatelyEquals(c, tolerance: 1e-9))
        #expect(c.converted(to: .srgb) == c)
    }

    @Test func approximateEqualityComparesInTheSameSpace() {
        let c = RGBAColor(r: 1, g: 0, b: 0)
        #expect(c.approximatelyEquals(c.converted(to: .displayP3), tolerance: 1e-9))
    }

    @Test func transferFunctionIsInvertible() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) { #expect(abs(ColorTransfer.encode(ColorTransfer.decode(v)) - v) < 1e-12) }
        #expect(abs(ColorTransfer.decode(0.5) - 0.2140) < 0.001)
    }
}
