import Foundation
import CoreGraphics

public struct ShotBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "bitmap size mismatch")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public init(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        var b = [UInt8](repeating: 0, count: max(width, 0) * max(height, 0) * 4)
        for y in 0..<max(height, 0) {
            for x in 0..<max(width, 0) {
                let c = fill(x, y)
                let i = (y * width + x) * 4
                b[i] = c.0; b[i + 1] = c.1; b[i + 2] = c.2; b[i + 3] = c.3
            }
        }
        self.init(width: max(width, 0), height: max(height, 0), bytes: b)
    }

    public init(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)) {
        self.init(width: width, height: height) { _, _ in color }
    }

    public static let empty = ShotBitmap(width: 0, height: 0, bytes: [])

    public var isEmpty: Bool { width == 0 || height == 0 }
    public var rowBytes: Int { width * 4 }

    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    public mutating func setPixel(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) {
        let i = (y * width + x) * 4
        bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = c.3
    }

    public func rows(_ range: Range<Int>) -> ShotBitmap {
        let r = range.clamped(to: 0..<height)
        return ShotBitmap(width: width, height: r.count, bytes: Array(bytes[(r.lowerBound * rowBytes)..<(r.upperBound * rowBytes)]))
    }

    public func cropped(_ rect: CGRect) -> ShotBitmap {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width > 0, r.height > 0 else { return .empty }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        var out = [UInt8]()
        out.reserveCapacity(w * h * 4)
        for y in y0..<(y0 + h) {
            let s = (y * width + x0) * 4
            out.append(contentsOf: bytes[s..<(s + w * 4)])
        }
        return ShotBitmap(width: w, height: h, bytes: out)
    }

    public mutating func append(rows other: ShotBitmap) {
        guard other.width == width, !other.isEmpty else { return }
        self = ShotBitmap(width: width, height: height + other.height, bytes: bytes + other.bytes)
    }

    public init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, bytes: buf)
    }

    public func makeImage() -> CGImage? {
        guard !isEmpty, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var copy = bytes
        return copy.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

public enum ShotEffectMath {
    public static let minBlock = 2
    public static let maxBlock = 96

    public static func clampRegion(_ r: CGRect, width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let bounded = r.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !bounded.isNull, bounded.width >= 1, bounded.height >= 1 else { return nil }
        return (Int(bounded.minX), Int(bounded.minY), Int(bounded.width), Int(bounded.height))
    }

    public static func blockSize(strength: Double, region: CGSize) -> Int {
        let s = min(max(strength, 0), 1)
        let longest = max(region.width, region.height, 1)
        let raw = Int((Double(minBlock) + s * min(Double(maxBlock - minBlock), Double(longest) / 4)).rounded())
        return min(max(raw, minBlock), maxBlock)
    }

    public static func blurRadius(strength: Double, region: CGSize) -> Int {
        let s = min(max(strength, 0), 1)
        let cap = max(1, Int(min(region.width, region.height) / 2) - 1)
        return min(max(Int((1 + s * 29).rounded()), 1), cap)
    }

    public static func blocks(region: (x: Int, y: Int, w: Int, h: Int), block: Int) -> [(x: Int, y: Int, w: Int, h: Int)] {
        let b = max(block, 1)
        var out: [(x: Int, y: Int, w: Int, h: Int)] = []
        var y = 0
        while y < region.h {
            var x = 0
            let bh = min(b, region.h - y)
            while x < region.w {
                out.append((region.x + x, region.y + y, min(b, region.w - x), bh))
                x += b
            }
            y += b
        }
        return out
    }
}

public enum ShotEffects {
    public static func pixelate(_ px: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int, region: CGRect, block: Int) {
        guard let r = ShotEffectMath.clampRegion(region, width: width, height: height) else { return }
        for b in ShotEffectMath.blocks(region: r, block: block) {
            var sum = (0, 0, 0, 0)
            for y in b.y..<(b.y + b.h) {
                for x in b.x..<(b.x + b.w) {
                    let i = (y * width + x) * 4
                    sum.0 += Int(px[i]); sum.1 += Int(px[i + 1]); sum.2 += Int(px[i + 2]); sum.3 += Int(px[i + 3])
                }
            }
            let n = b.w * b.h
            let avg = (UInt8((sum.0 + n / 2) / n), UInt8((sum.1 + n / 2) / n), UInt8((sum.2 + n / 2) / n), UInt8((sum.3 + n / 2) / n))
            for y in b.y..<(b.y + b.h) {
                for x in b.x..<(b.x + b.w) {
                    let i = (y * width + x) * 4
                    px[i] = avg.0; px[i + 1] = avg.1; px[i + 2] = avg.2; px[i + 3] = avg.3
                }
            }
        }
    }

    public static func blur(_ px: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int, region: CGRect, radius: Int, passes: Int = 3) {
        guard let r = ShotEffectMath.clampRegion(region, width: width, height: height), radius >= 1 else { return }
        let rad = min(radius, max(1, min(r.w, r.h) / 2))
        var line = [Int](repeating: 0, count: max(r.w, r.h))
        var out = [Int](repeating: 0, count: max(r.w, r.h))
        for _ in 0..<max(passes, 1) {
            for c in 0..<4 {
                for y in r.y..<(r.y + r.h) {
                    for x in 0..<r.w { line[x] = Int(px[(y * width + r.x + x) * 4 + c]) }
                    boxLine(&line, &out, count: r.w, radius: rad)
                    for x in 0..<r.w { px[(y * width + r.x + x) * 4 + c] = UInt8(out[x]) }
                }
                for x in r.x..<(r.x + r.w) {
                    for y in 0..<r.h { line[y] = Int(px[((r.y + y) * width + x) * 4 + c]) }
                    boxLine(&line, &out, count: r.h, radius: rad)
                    for y in 0..<r.h { px[((r.y + y) * width + x) * 4 + c] = UInt8(out[y]) }
                }
            }
        }
    }

    static func boxLine(_ src: inout [Int], _ dst: inout [Int], count n: Int, radius: Int) {
        guard n > 0 else { return }
        var sum = 0
        for i in -radius...radius { sum += src[min(max(i, 0), n - 1)] }
        let d = radius * 2 + 1
        for i in 0..<n {
            dst[i] = (sum + d / 2) / d
            sum += src[min(i + radius + 1, n - 1)] - src[max(i - radius, 0)]
        }
    }
}

public extension ShotBitmap {
    mutating func pixelate(region: CGRect, block: Int) {
        let w = width, h = height
        bytes.withUnsafeMutableBufferPointer { ShotEffects.pixelate($0, width: w, height: h, region: region, block: block) }
    }

    mutating func blur(region: CGRect, radius: Int, passes: Int = 3) {
        let w = width, h = height
        bytes.withUnsafeMutableBufferPointer { ShotEffects.blur($0, width: w, height: h, region: region, radius: radius, passes: passes) }
    }
}
