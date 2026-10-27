import Foundation

public enum SmcKeyName {
    public static func isValid(_ s: String) -> Bool {
        s.utf8.count == 4 && s.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    }

    public static func fourCC(_ s: String) -> UInt32? {
        guard isValid(s) else { return nil }
        return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func string(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(decoding: chars, as: UTF8.self)
    }

    public static func fan(_ index: Int, _ suffix: String) -> String { "F\(index)\(suffix)" }
}

public enum SmcCodec {
    public static func normalizedType(_ type: String) -> String {
        var t = type
        while t.hasSuffix(" ") || t.hasSuffix("\0") { t.removeLast() }
        return t
    }

    public static func decode(_ b: [UInt8], type: String) -> Double? {
        let t = normalizedType(type)
        switch t {
        case "flt":
            guard b.count == 4 else { return nil }
            let f = Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            return f.isFinite ? Double(f) : nil
        case "ui8", "flag":
            guard b.count == 1 else { return nil }
            return Double(b[0])
        case "si8":
            guard b.count == 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "ui16":
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "si16":
            guard b.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "ui32":
            guard b.count == 4 else { return nil }
            return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "ioft":
            guard b.count == 8 else { return nil }
            let raw = b.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Double(raw) / 65536
        default:
            guard let f = fixedPoint(t), b.count == 2 else { return nil }
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return (f.signed ? Double(Int16(bitPattern: raw)) : Double(raw)) / Double(1 << f.frac)
        }
    }

    public static func encode(_ v: Double, type: String, size: Int) -> [UInt8]? {
        guard v.isFinite else { return nil }
        let t = normalizedType(type)
        switch t {
        case "flt":
            guard size == 4, abs(v) < Double(Float.greatestFiniteMagnitude) else { return nil }
            let bits = Float(v).bitPattern
            return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)]
        case "ui8", "flag":
            guard size == 1, let n = integer(v, 0...255) else { return nil }
            return [UInt8(n)]
        case "si8":
            guard size == 1, let n = integer(v, -128...127) else { return nil }
            return [UInt8(bitPattern: Int8(n))]
        case "ui16":
            guard size == 2, let n = integer(v, 0...65535) else { return nil }
            return [UInt8(n >> 8), UInt8(n & 0xff)]
        case "si16":
            guard size == 2, let n = integer(v, -32768...32767) else { return nil }
            let u = UInt16(bitPattern: Int16(n))
            return [UInt8(u >> 8), UInt8(u & 0xff)]
        case "ui32":
            guard size == 4, let n = integer(v, 0...Int(UInt32.max)) else { return nil }
            return (0..<4).map { UInt8((n >> (8 * (3 - $0))) & 0xff) }
        case "ioft":
            guard size == 8, v >= 0, v < 1e13 else { return nil }
            let raw = UInt64((v * 65536).rounded())
            return (0..<8).map { UInt8((raw >> (8 * UInt64($0))) & 0xff) }
        default:
            guard size == 2, let f = fixedPoint(t) else { return nil }
            let scaled = (v * Double(1 << f.frac)).rounded()
            if f.signed {
                guard let n = integer(scaled, -32768...32767) else { return nil }
                let u = UInt16(bitPattern: Int16(n))
                return [UInt8(u >> 8), UInt8(u & 0xff)]
            }
            guard let n = integer(scaled, 0...65535) else { return nil }
            return [UInt8(n >> 8), UInt8(n & 0xff)]
        }
    }

    private static func integer(_ v: Double, _ range: ClosedRange<Int>) -> Int? {
        let r = v.rounded()
        guard r >= Double(range.lowerBound), r <= Double(range.upperBound) else { return nil }
        return Int(r)
    }

    private static func fixedPoint(_ t: String) -> (signed: Bool, frac: Int)? {
        let chars = Array(t)
        guard chars.count == 4, chars[2].hexDigitValue != nil, let frac = chars[3].hexDigitValue else { return nil }
        switch String(chars[0..<2]) {
        case "fp": return (false, frac)
        case "sp": return (true, frac)
        default: return nil
        }
    }
}
