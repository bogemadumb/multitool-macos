import Foundation
import CoreGraphics

public enum RecDither: String, CaseIterable, Codable, Sendable {
    case none, ordered, floyd

    public var title: String {
        switch self {
        case .none: "Без сглаживания"
        case .ordered: "Узор"
        case .floyd: "Диффузия"
        }
    }
}

public struct RecGifOptions: Equatable, Codable, Sendable {
    public static let fpsChoices = [5, 8, 10, 12, 15, 20, 25]
    public static let widthChoices = [0, 320, 480, 640, 800, 1024]
    public static let maxFramesLimit = 1500

    public var fps = 12
    public var maxWidth = 640
    public var colors = 256
    public var dither = RecDither.floyd
    public var loop = 0
    public var maxFrames = 600

    public init() {}

    public var sanitized: RecGifOptions {
        var o = self
        o.fps = ToolsClamp.int(fps, 1...30)
        o.maxWidth = maxWidth <= 0 ? 0 : ToolsClamp.int(maxWidth, 64...4096)
        o.colors = ToolsClamp.int(colors, 2...256)
        o.loop = ToolsClamp.int(loop, 0...65535)
        o.maxFrames = ToolsClamp.int(maxFrames, 1...Self.maxFramesLimit)
        return o
    }
}

public struct RecGifPlan: Equatable, Sendable {
    public var times: [Double]
    public var delays: [Int]
    public var width: Int
    public var height: Int
    public var fps: Double
    public var truncated: Bool
}

public enum RecGifPlanner {
    public static func targetSize(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        guard maxWidth > 0, width > maxWidth else { return (width, height) }
        let k = Double(maxWidth) / Double(width)
        return (maxWidth, max(Int((Double(height) * k).rounded()), 1))
    }

    // delays in centiseconds, the rounding error is carried so the total length stays exact
    public static func delays(count: Int, fps: Double) -> [Int] {
        guard count > 0, fps > 0 else { return [] }
        var out: [Int] = []
        var prev = 0
        for i in 1...count {
            let edge = Int((Double(i) * 100 / fps).rounded())
            out.append(max(edge - prev, 2))
            prev = max(edge, prev + 2)
        }
        return out
    }

    public static func plan(outputDuration: Double, sourceWidth: Int, sourceHeight: Int, options raw: RecGifOptions) -> RecGifPlan {
        let o = raw.sanitized
        let size = targetSize(width: sourceWidth, height: sourceHeight, maxWidth: o.maxWidth)
        guard outputDuration > 0 else { return RecGifPlan(times: [], delays: [], width: size.width, height: size.height, fps: Double(o.fps), truncated: false) }
        var count = max(Int((outputDuration * Double(o.fps)).rounded(.down)), 1)
        var truncated = false
        if count > o.maxFrames {
            count = o.maxFrames
            truncated = true
        }
        let times = (0..<count).map { min(Double($0) / Double(o.fps), max(outputDuration - 0.001, 0)) }
        return RecGifPlan(times: times, delays: delays(count: count, fps: Double(o.fps)), width: size.width, height: size.height, fps: Double(o.fps), truncated: truncated)
    }

    // fps that fits the whole clip into maxFrames
    public static func fittingFPS(outputDuration: Double, wanted: Int, maxFrames: Int) -> Int {
        guard outputDuration > 0 else { return wanted }
        let cap = Int((Double(maxFrames) / outputDuration).rounded(.down))
        return max(min(wanted, cap), 1)
    }
}

public struct RecPalette: Equatable, Sendable {
    public var rgb: [UInt8]
    public var count: Int { rgb.count / 3 }

    public func color(_ i: Int) -> (UInt8, UInt8, UInt8) { (rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]) }

    public var tableBits: Int {
        var b = 1
        while (1 << b) < count { b += 1 }
        return min(b, 8)
    }

    public var padded: [UInt8] {
        let size = 1 << tableBits
        return rgb + [UInt8](repeating: 0, count: max(size * 3 - rgb.count, 0))
    }
}

public struct RecPaletteBuilder {
    private var counts = [Int](repeating: 0, count: 32768)
    private var sumR = [Int](repeating: 0, count: 32768)
    private var sumG = [Int](repeating: 0, count: 32768)
    private var sumB = [Int](repeating: 0, count: 32768)
    public private(set) var samples = 0

    public init() {}

    @inline(__always) static func key(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int { (Int(r >> 3) << 10) | (Int(g >> 3) << 5) | Int(b >> 3) }

    public mutating func add(_ bmp: ShotBitmap, stride: Int = 1) {
        let step = max(stride, 1)
        var i = 0
        let n = bmp.width * bmp.height
        bmp.bytes.withUnsafeBufferPointer { p in
            while i < n {
                let o = i * 4
                let k = Self.key(p[o], p[o + 1], p[o + 2])
                counts[k] += 1
                sumR[k] += Int(p[o])
                sumG[k] += Int(p[o + 1])
                sumB[k] += Int(p[o + 2])
                samples += 1
                i += step
            }
        }
    }

    private struct Entry {
        var key: Int
        var count: Int
        var r: Int
        var g: Int
        var b: Int
    }

    private struct Box {
        var entries: [Entry]
        var pop: Int { entries.reduce(0) { $0 + $1.count } }

        func ranges() -> (r: Int, g: Int, b: Int) {
            var lo = (255, 255, 255), hi = (0, 0, 0)
            for e in entries {
                let r = e.r / e.count, g = e.g / e.count, b = e.b / e.count
                lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
                hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
            }
            return (hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2)
        }

        func average() -> (UInt8, UInt8, UInt8) {
            var n = 0, r = 0, g = 0, b = 0
            for e in entries { n += e.count; r += e.r; g += e.g; b += e.b }
            guard n > 0 else { return (0, 0, 0) }
            return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
        }
    }

    public func build(maxColors: Int) -> RecPalette {
        let limit = ToolsClamp.int(maxColors, 2...256)
        var entries: [Entry] = []
        for k in 0..<32768 where counts[k] > 0 { entries.append(Entry(key: k, count: counts[k], r: sumR[k], g: sumG[k], b: sumB[k])) }
        guard !entries.isEmpty else { return RecPalette(rgb: [0, 0, 0, 255, 255, 255]) }
        var boxes = [Box(entries: entries)]
        while boxes.count < limit {
            var pick = -1
            var best = -1
            for (i, b) in boxes.enumerated() where b.entries.count > 1 {
                let rg = b.ranges()
                let score = b.pop * (max(rg.r, rg.g, rg.b) + 1)
                if score > best { best = score; pick = i }
            }
            if pick < 0 { break }
            var box = boxes[pick]
            let rg = box.ranges()
            let channel = rg.r >= rg.g && rg.r >= rg.b ? 0 : (rg.g >= rg.b ? 1 : 2)
            box.entries.sort { a, b in
                let va = channel == 0 ? a.r / a.count : (channel == 1 ? a.g / a.count : a.b / a.count)
                let vb = channel == 0 ? b.r / b.count : (channel == 1 ? b.g / b.count : b.b / b.count)
                return va != vb ? va < vb : a.key < b.key
            }
            let half = box.pop / 2
            var acc = 0
            var cut = box.entries.count - 1
            for (i, e) in box.entries.enumerated() {
                acc += e.count
                if acc >= half { cut = min(max(i + 1, 1), box.entries.count - 1); break }
            }
            let left = Box(entries: Array(box.entries[..<cut])), right = Box(entries: Array(box.entries[cut...]))
            boxes[pick] = left
            boxes.append(right)
        }
        var rgb: [UInt8] = []
        for b in boxes.sorted(by: { $0.pop > $1.pop }) {
            let c = b.average()
            rgb += [c.0, c.1, c.2]
        }
        return RecPalette(rgb: rgb)
    }
}

public struct RecQuantizer {
    public let palette: RecPalette
    private var cache = [Int16](repeating: -1, count: 32768)

    public init(palette: RecPalette) { self.palette = palette }

    private mutating func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let k = (min(max(r, 0), 255) >> 3) << 10 | (min(max(g, 0), 255) >> 3) << 5 | (min(max(b, 0), 255) >> 3)
        if cache[k] >= 0 { return Int(cache[k]) }
        let cr = (k >> 10) << 3 | 4, cg = ((k >> 5) & 31) << 3 | 4, cb = (k & 31) << 3 | 4
        var best = 0, bestD = Int.max
        for i in 0..<palette.count {
            let c = palette.color(i)
            let dr = Int(c.0) - cr, dg = Int(c.1) - cg, db = Int(c.2) - cb
            let d = dr * dr * 3 + dg * dg * 4 + db * db * 2
            if d < bestD { bestD = d; best = i }
        }
        cache[k] = Int16(best)
        return best
    }

    private static let bayer: [Int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    public mutating func index(_ bmp: ShotBitmap, dither: RecDither) -> [UInt8] {
        let w = bmp.width, h = bmp.height
        var out = [UInt8](repeating: 0, count: w * h)
        guard w > 0, h > 0, palette.count > 0 else { return out }
        switch dither {
        case .none:
            for i in 0..<(w * h) {
                out[i] = UInt8(nearest(Int(bmp.bytes[i * 4]), Int(bmp.bytes[i * 4 + 1]), Int(bmp.bytes[i * 4 + 2])))
            }
        case .ordered:
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let t = (Self.bayer[(y & 3) * 4 + (x & 3)] - 8) * 2
                    out[y * w + x] = UInt8(nearest(Int(bmp.bytes[o]) + t, Int(bmp.bytes[o + 1]) + t, Int(bmp.bytes[o + 2]) + t))
                }
            }
        case .floyd:
            var cur = [Int](repeating: 0, count: (w + 2) * 3)
            var nxt = [Int](repeating: 0, count: (w + 2) * 3)
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let e = (x + 1) * 3
                    let r = Int(bmp.bytes[o]) + cur[e] / 16
                    let g = Int(bmp.bytes[o + 1]) + cur[e + 1] / 16
                    let b = Int(bmp.bytes[o + 2]) + cur[e + 2] / 16
                    let idx = nearest(r, g, b)
                    out[y * w + x] = UInt8(idx)
                    let c = palette.color(idx)
                    let er = min(max(r, 0), 255) - Int(c.0), eg = min(max(g, 0), 255) - Int(c.1), eb = min(max(b, 0), 255) - Int(c.2)
                    let errs = [er, eg, eb]
                    for ch in 0..<3 {
                        cur[e + 3 + ch] += errs[ch] * 7
                        nxt[e - 3 + ch] += errs[ch] * 3
                        nxt[e + ch] += errs[ch] * 5
                        nxt[e + 3 + ch] += errs[ch]
                    }
                }
                swap(&cur, &nxt)
                for i in nxt.indices { nxt[i] = 0 }
            }
        }
        return out
    }
}

public enum RecLZW {
    public static func compress(_ indices: [UInt8], minCodeSize: Int) -> [UInt8] {
        let initBits = minCodeSize + 1
        let clearCode = 1 << minCodeSize
        let eofCode = clearCode + 1
        var bits = initBits
        var maxCode = (1 << bits) - 1
        var freeEnt = clearCode + 2
        var dict: [Int: Int] = [:]
        var out: [UInt8] = []
        var acc = 0, accBits = 0

        func put(_ code: Int) {
            acc |= code << accBits
            accBits += bits
            while accBits >= 8 {
                out.append(UInt8(acc & 255))
                acc >>= 8
                accBits -= 8
            }
        }

        func emit(_ code: Int, clearing: Bool = false) {
            put(code)
            if clearing {
                bits = initBits
                maxCode = (1 << bits) - 1
            } else if freeEnt > maxCode, bits < 12 {
                bits += 1
                maxCode = (1 << bits) - 1
            }
        }

        emit(clearCode, clearing: true)
        guard var ent = indices.first.map(Int.init) else {
            emit(eofCode)
            if accBits > 0 { out.append(UInt8(acc & 255)) }
            return out
        }
        for byte in indices.dropFirst() {
            let c = Int(byte)
            let key = (c << 12) | ent
            if let code = dict[key] {
                ent = code
                continue
            }
            emit(ent)
            ent = c
            if freeEnt < 4096 {
                dict[key] = freeEnt
                freeEnt += 1
            } else {
                dict.removeAll(keepingCapacity: true)
                freeEnt = clearCode + 2
                emit(clearCode, clearing: true)
            }
        }
        emit(ent)
        emit(eofCode)
        if accBits > 0 { out.append(UInt8(acc & 255)) }
        return out
    }
}

public struct RecGifFrame: Equatable, Sendable {
    public var indices: [UInt8]
    public var delay: Int

    public init(indices: [UInt8], delay: Int) {
        self.indices = indices
        self.delay = delay
    }
}

public enum RecGifEncoder {
    public static func merged(_ frames: [RecGifFrame]) -> [RecGifFrame] {
        var out: [RecGifFrame] = []
        for f in frames {
            if var last = out.last, last.indices == f.indices, last.delay + f.delay <= 65535 {
                last.delay += f.delay
                out[out.count - 1] = last
            } else {
                out.append(f)
            }
        }
        return out
    }

    public static func encode(width: Int, height: Int, palette: RecPalette, frames: [RecGifFrame], loop: Int = 0) -> Data {
        var stream = RecGifStream(width: width, height: height, palette: palette, loop: loop)
        for f in frames { stream.add(f) }
        return stream.finish()
    }

    public static func build(frames: [ShotBitmap], delays: [Int], options raw: RecGifOptions) -> Data? {
        let o = raw.sanitized
        guard let first = frames.first, !first.isEmpty, frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return nil }
        var pb = RecPaletteBuilder()
        let stride = max(first.width * first.height / 20_000, 1)
        for f in frames { pb.add(f, stride: stride) }
        let palette = pb.build(maxColors: o.colors)
        var q = RecQuantizer(palette: palette)
        var gf: [RecGifFrame] = []
        for (i, f) in frames.enumerated() {
            gf.append(RecGifFrame(indices: q.index(f, dither: o.dither), delay: i < delays.count ? delays[i] : 8))
        }
        return encode(width: first.width, height: first.height, palette: palette, frames: merged(gf), loop: o.loop)
    }
}

public struct RecGifStream {
    private var data = Data()
    private var pending: RecGifFrame?
    private let width: Int
    private let height: Int
    private let minCode: Int
    public private(set) var frameCount = 0

    private mutating func u16(_ v: Int) {
        data.append(UInt8(v & 255))
        data.append(UInt8((v >> 8) & 255))
    }

    public init(width: Int, height: Int, palette: RecPalette, loop: Int = 0) {
        self.width = width
        self.height = height
        let bits = palette.tableBits
        minCode = max(bits, 2)
        data.append(contentsOf: Array("GIF89a".utf8))
        u16(width)
        u16(height)
        data.append(UInt8(0x80 | ((bits - 1) << 4) | (bits - 1)))
        data.append(0)
        data.append(0)
        data.append(contentsOf: palette.padded)
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(contentsOf: Array("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01])
        u16(loop)
        data.append(0)
    }

    public mutating func add(_ f: RecGifFrame) {
        if var p = pending, p.indices == f.indices, p.delay + f.delay <= 65535 {
            p.delay += f.delay
            pending = p
            return
        }
        flush()
        pending = f
    }

    private mutating func flush() {
        guard let f = pending else { return }
        pending = nil
        frameCount += 1
        data.append(contentsOf: [0x21, 0xF9, 0x04, 0x04])
        u16(min(max(f.delay, 0), 65535))
        data.append(0)
        data.append(0)
        data.append(0x2C)
        u16(0)
        u16(0)
        u16(width)
        u16(height)
        data.append(0)
        data.append(UInt8(minCode))
        let packed = RecLZW.compress(f.indices, minCodeSize: minCode)
        var i = 0
        while i < packed.count {
            let n = min(255, packed.count - i)
            data.append(UInt8(n))
            data.append(contentsOf: packed[i..<(i + n)])
            i += n
        }
        data.append(0)
    }

    public mutating func finish() -> Data {
        flush()
        data.append(0x3B)
        return data
    }

    public var byteCount: Int { data.count }
}
