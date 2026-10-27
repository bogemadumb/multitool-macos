import Foundation

public enum ColorParser {
    private struct Num {
        var value: Double
        var percent: Bool
        var unit: String
    }

    public static func parse(_ input: String) -> RGBAColor? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let open = s.firstIndex(of: "("), let close = matchingParen(s, open) {
            let raw = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            let body = String(s[s.index(after: open)..<close])
            let tail = String(s[s.index(after: close)...])
            if Self.swiftTypes.contains(raw) { return parseSwift(body: body, tail: tail) }
            return parseCall(name: raw.lowercased(), body: body)
        }
        if let h = parseHex(s) { return h }
        return ColorNames.color(named: s)
    }

    private static func matchingParen(_ s: String, _ open: String.Index) -> String.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    public static func parseHex(_ input: String) -> RGBAColor? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() } else if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let digits = s.compactMap { $0.hexDigitValue }
        func pair(_ i: Int) -> Int { digits[i] * 16 + digits[i + 1] }
        switch digits.count {
        case 3: return RGBAColor(red8: digits[0] * 17, green8: digits[1] * 17, blue8: digits[2] * 17)
        case 4: return RGBAColor(red8: digits[0] * 17, green8: digits[1] * 17, blue8: digits[2] * 17, alpha8: digits[3] * 17)
        case 6: return RGBAColor(red8: pair(0), green8: pair(2), blue8: pair(4))
        default: return RGBAColor(red8: pair(0), green8: pair(2), blue8: pair(4), alpha8: pair(6))
        }
    }

    private static func number(_ token: String) -> Num? {
        let t = token.lowercased()
        if t == "none" { return Num(value: 0, percent: false, unit: "") }
        for unit in ["deg", "grad", "rad", "turn", "%"] where t.hasSuffix(unit) {
            guard let v = Double(t.dropLast(unit.count)) else { return nil }
            return Num(value: v, percent: unit == "%", unit: unit == "%" ? "" : unit)
        }
        guard let v = Double(t) else { return nil }
        return Num(value: v, percent: false, unit: "")
    }

    private static func degrees(_ n: Num) -> Double {
        switch n.unit {
        case "rad": return n.value * 180 / .pi
        case "grad": return n.value * 0.9
        case "turn": return n.value * 360
        default: return n.value
        }
    }

    private static func split(_ body: String) -> (main: [Num], alpha: Num?)? {
        let normalized = body.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " / ")
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var main: [Num] = []
        var alpha: Num?
        var afterSlash = false
        for t in tokens {
            if t == "/" { afterSlash = true; continue }
            guard let n = number(t) else { return nil }
            if afterSlash { alpha = n } else { main.append(n) }
        }
        if alpha == nil, main.count == 4 { alpha = main.removeLast() }
        return (main, alpha)
    }

    private static func alphaValue(_ n: Num?) -> Double {
        guard let n else { return 1 }
        return ToolsClamp.double(n.percent ? n.value / 100 : n.value, 0...1)
    }

    private static func channel(_ n: Num, scale: Double) -> Double {
        ToolsClamp.double(n.percent ? n.value / 100 : n.value / scale, 0...1)
    }

    private static let swiftTypes: Set<String> = ["Color", "SwiftUI.Color", "NSColor", "UIColor", "CGColor", "Color.init", "NSColor.init", "UIColor.init"]

    private static func parseCall(name: String, body: String) -> RGBAColor? {
        switch name {
        case "rgb", "rgba":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            return RGBAColor(r: channel(m[0], scale: 255), g: channel(m[1], scale: 255), b: channel(m[2], scale: 255), a: alphaValue(a))
        case "hsl", "hsla":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            return RGBAColor(hsl: HSLColor(h: degrees(m[0]), s: ToolsClamp.double(m[1].value / 100, 0...1), l: ToolsClamp.double(m[2].value / 100, 0...1), a: alphaValue(a)))
        case "hsb", "hsba", "hsv", "hsva":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            return RGBAColor(hsb: HSBColor(h: degrees(m[0]), s: ToolsClamp.double(m[1].value / 100, 0...1), b: ToolsClamp.double(m[2].value / 100, 0...1), a: alphaValue(a)))
        case "cmyk":
            guard let (m, a) = split(body), m.count == 4 || (m.count == 3 && a != nil) else { return nil }
            let all = m.count == 4 ? m : m + [a!]
            let fractional = !all.contains { $0.percent } && all.allSatisfy { $0.value <= 1 }
            let v = all.map { ToolsClamp.double(fractional ? $0.value : $0.value / 100, 0...1) }
            return RGBAColor(cmyk: CMYKColor(c: v[0], m: v[1], y: v[2], k: v[3]))
        case "lab":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            return RGBAColor(lab: LabColor(l: ToolsClamp.double(m[0].value, 0...100), a: m[1].percent ? m[1].value * 1.25 : m[1].value, b: m[2].percent ? m[2].value * 1.25 : m[2].value), alpha: alphaValue(a))
        case "oklch":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            let l = m[0].percent ? m[0].value / 100 : m[0].value
            let c = m[1].percent ? m[1].value * 0.4 / 100 : m[1].value
            return RGBAColor(oklch: OKLCHColor(l: ToolsClamp.double(l, 0...1), c: max(c, 0), h: degrees(m[2])), alpha: alphaValue(a))
        case "oklab":
            guard let (m, a) = split(body), m.count == 3 else { return nil }
            let l = m[0].percent ? m[0].value / 100 : m[0].value
            let ab = { (n: Num) in n.percent ? n.value * 0.4 / 100 : n.value }
            return RGBAColor(oklabL: ToolsClamp.double(l, 0...1), a: ab(m[1]), b: ab(m[2]), alpha: alphaValue(a))
        case "color":
            return parseColorFunction(body)
        default:
            return nil
        }
    }

    private static func parseColorFunction(_ body: String) -> RGBAColor? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let space: ColorSpaceKind
        let rest: String
        if trimmed.lowercased().hasPrefix("display-p3") { space = .displayP3; rest = String(trimmed.dropFirst("display-p3".count)) }
        else if trimmed.lowercased().hasPrefix("srgb") { space = .srgb; rest = String(trimmed.dropFirst("srgb".count)) }
        else { return nil }
        guard let (m, a) = split(rest), m.count == 3 else { return nil }
        return RGBAColor(r: channel(m[0], scale: 1), g: channel(m[1], scale: 1), b: channel(m[2], scale: 1), a: alphaValue(a), space: space)
    }

    private static func topLevelSplit(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var cur = ""
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func swiftValue(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for wrapper in ["CGFloat(", "Double(", "Float("] where t.hasPrefix(wrapper) && t.hasSuffix(")") {
            t = String(t.dropFirst(wrapper.count).dropLast())
        }
        t = t.replacingOccurrences(of: "_", with: "")
        if let slash = t.firstIndex(of: "/") {
            guard let a = Double(t[..<slash].trimmingCharacters(in: .whitespaces)), let b = Double(t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces)), b != 0 else { return nil }
            return a / b
        }
        return Double(t)
    }

    private static func parseSwift(body: String, tail: String) -> RGBAColor? {
        var space = ColorSpaceKind.srgb
        var values: [String: Double] = [:]
        var positional: [Double] = []
        for arg in topLevelSplit(body) {
            let lower = arg.lowercased()
            if lower == ".displayp3" || lower == "colorspace.displayp3" { space = .displayP3; continue }
            if lower == ".srgb" || lower == "colorspace.srgb" { space = .srgb; continue }
            if lower.hasPrefix(".") && swiftValue(arg) == nil { return nil }
            if let colon = arg.firstIndex(of: ":") {
                let label = String(arg[..<colon]).trimmingCharacters(in: .whitespaces)
                guard let v = swiftValue(String(arg[arg.index(after: colon)...])) else { return nil }
                if label == "displayP3Red" { space = .displayP3; values["red"] = v }
                else if label == "srgbRed" || label == "calibratedRed" || label == "deviceRed" { values["red"] = v }
                else { values[label] = v }
            } else if let v = swiftValue(arg) {
                positional.append(v)
            } else { return nil }
        }
        if values["red"] == nil, positional.count >= 3 {
            values["red"] = positional[0]; values["green"] = positional[1]; values["blue"] = positional[2]
            if positional.count > 3 { values["alpha"] = positional[3] }
        }
        guard let r = values["red"], let g = values["green"], let b = values["blue"] else { return nil }
        var a = values["alpha"] ?? values["opacity"] ?? 1
        let t = tail.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(".opacity("), t.hasSuffix(")"), let v = swiftValue(String(t.dropFirst(".opacity(".count).dropLast())) { a = v }
        else if !t.isEmpty { return nil }
        return RGBAColor(r: ToolsClamp.double(r, 0...1), g: ToolsClamp.double(g, 0...1), b: ToolsClamp.double(b, 0...1), a: ToolsClamp.double(a, 0...1), space: space)
    }
}
