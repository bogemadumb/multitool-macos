import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import MultitulCore

private func lzwDecode(_ data: [UInt8], minCodeSize: Int) -> [UInt8] {
    let clear = 1 << minCodeSize, eoi = clear + 1
    var codeSize = minCodeSize + 1
    func fresh() -> [[UInt8]] { (0..<(clear + 2)).map { $0 < clear ? [UInt8($0)] : [] } }
    var table = fresh()
    var out: [UInt8] = []
    var prev: [UInt8]?
    var acc = 0, accBits = 0, pos = 0
    while true {
        while accBits < codeSize, pos < data.count {
            acc |= Int(data[pos]) << accBits
            accBits += 8
            pos += 1
        }
        if accBits < codeSize { break }
        let code = acc & ((1 << codeSize) - 1)
        acc >>= codeSize
        accBits -= codeSize
        if code == clear {
            table = fresh()
            codeSize = minCodeSize + 1
            prev = nil
            continue
        }
        if code == eoi { break }
        var entry: [UInt8]
        if let p = prev {
            entry = code < table.count ? table[code] : p + [p[0]]
            out += entry
            if table.count < 4096 { table.append(p + [entry[0]]) }
            if table.count == (1 << codeSize), codeSize < 12 { codeSize += 1 }
        } else {
            entry = table[code]
            out += entry
        }
        prev = entry
    }
    return out
}

private struct Lcg {
    var s: UInt64
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s >> 33
    }
}

private func bitmap(_ w: Int, _ h: Int, _ f: @escaping (Int, Int) -> (UInt8, UInt8, UInt8)) -> ShotBitmap {
    ShotBitmap(width: w, height: h) { x, y in let c = f(x, y); return (c.0, c.1, c.2, 255) }
}

private func frames(of data: Data) -> [CGImage] {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
    return (0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
}

private func delays(of data: Data) -> [Double] {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
    return (0..<CGImageSourceGetCount(src)).map { i in
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1
    }
}

@Suite struct RecLZWTests {
    @Test func smallRoundTrip() {
        let d: [UInt8] = [1, 2, 3, 1, 2, 3, 1, 2, 3, 3, 3, 3, 0]
        #expect(lzwDecode(RecLZW.compress(d, minCodeSize: 2), minCodeSize: 2) == d)
    }

    @Test func emptyInputProducesOnlyClearAndEnd() {
        let c = RecLZW.compress([], minCodeSize: 2)
        #expect(lzwDecode(c, minCodeSize: 2).isEmpty && !c.isEmpty)
    }

    @Test func singleByte() {
        #expect(lzwDecode(RecLZW.compress([5], minCodeSize: 3), minCodeSize: 3) == [5])
    }

    @Test func longRunCompressesWell() {
        let d = [UInt8](repeating: 0, count: 20_000)
        let c = RecLZW.compress(d, minCodeSize: 2)
        #expect(c.count < 400 && lzwDecode(c, minCodeSize: 2) == d)
    }

    @Test func randomEightBitDataSurvivesTableOverflow() {
        var g = Lcg(s: 42)
        let d = (0..<60_000).map { _ in UInt8(truncatingIfNeeded: g.next()) }
        #expect(lzwDecode(RecLZW.compress(d, minCodeSize: 8), minCodeSize: 8) == d)
    }

    @Test func fourColorRandomData() {
        var g = Lcg(s: 7)
        let d = (0..<40_000).map { _ in UInt8(g.next() % 4) }
        #expect(lzwDecode(RecLZW.compress(d, minCodeSize: 2), minCodeSize: 2) == d)
    }

    @Test func sixteenColorStructuredData() {
        let d = (0..<30_000).map { UInt8(($0 / 7 + $0 % 5) % 16) }
        #expect(lzwDecode(RecLZW.compress(d, minCodeSize: 4), minCodeSize: 4) == d)
    }

    @Test func everyMinCodeSizeRoundTrips() {
        var g = Lcg(s: 99)
        for m in 2...8 {
            let d = (0..<9_000).map { _ in UInt8(g.next() % UInt64(1 << m)) }
            #expect(lzwDecode(RecLZW.compress(d, minCodeSize: m), minCodeSize: m) == d)
        }
    }
}

@Suite struct RecGifPlannerTests {
    @Test func delaysAreCentisecondsAndKeepTotalLength() {
        for fps in [5, 8, 10, 12, 15, 20, 25] {
            let d = RecGifPlanner.delays(count: fps * 4, fps: Double(fps))
            let total = d.reduce(0, +)
            #expect(abs(total - 400) <= 2 && d.allSatisfy { $0 >= 2 })
        }
    }

    @Test func twelveFpsDelaysCarryTheRemainder() {
        let d = RecGifPlanner.delays(count: 12, fps: 12)
        #expect(Set(d) == [8, 9] && d.reduce(0, +) == 100)
    }

    @Test func tenFpsIsExactlyTen() {
        #expect(RecGifPlanner.delays(count: 5, fps: 10) == [10, 10, 10, 10, 10])
    }

    @Test func tooFastFpsFloorsAtTwoCentiseconds() {
        #expect(RecGifPlanner.delays(count: 4, fps: 100).allSatisfy { $0 == 2 })
    }

    @Test func emptyAndInvalidInput() {
        #expect(RecGifPlanner.delays(count: 0, fps: 10).isEmpty && RecGifPlanner.delays(count: 5, fps: 0).isEmpty)
    }

    @Test func targetSizeKeepsAspect() {
        let s = RecGifPlanner.targetSize(width: 1920, height: 1080, maxWidth: 640)
        #expect(s.width == 640 && s.height == 360)
        let t = RecGifPlanner.targetSize(width: 400, height: 300, maxWidth: 640)
        #expect(t.width == 400 && t.height == 300)
        let u = RecGifPlanner.targetSize(width: 1000, height: 500, maxWidth: 0)
        #expect(u.width == 1000)
    }

    @Test func planSamplesAtEvenSteps() {
        var o = RecGifOptions()
        o.fps = 10
        let p = RecGifPlanner.plan(outputDuration: 2, sourceWidth: 1280, sourceHeight: 720, options: o)
        #expect(p.times.count == 20 && p.times[0] == 0 && abs(p.times[10] - 1) < 1e-9 && p.times.allSatisfy { $0 < 2 })
        #expect(p.delays.count == 20 && p.width == 640 && p.height == 360 && !p.truncated)
    }

    @Test func planTruncatesLongClips() {
        var o = RecGifOptions()
        o.fps = 25
        o.maxFrames = 100
        let p = RecGifPlanner.plan(outputDuration: 60, sourceWidth: 800, sourceHeight: 600, options: o)
        #expect(p.times.count == 100 && p.truncated)
    }

    @Test func tinyClipStillGivesAFrame() {
        let p = RecGifPlanner.plan(outputDuration: 0.03, sourceWidth: 800, sourceHeight: 600, options: RecGifOptions())
        #expect(p.times.count == 1)
        #expect(RecGifPlanner.plan(outputDuration: 0, sourceWidth: 800, sourceHeight: 600, options: RecGifOptions()).times.isEmpty)
    }

    @Test func fittingFpsFitsTheFrameBudget() {
        #expect(RecGifPlanner.fittingFPS(outputDuration: 120, wanted: 15, maxFrames: 600) == 5)
        #expect(RecGifPlanner.fittingFPS(outputDuration: 10, wanted: 15, maxFrames: 600) == 15)
        #expect(RecGifPlanner.fittingFPS(outputDuration: 10_000, wanted: 15, maxFrames: 600) == 1)
    }

    @Test func optionsSanitize() {
        var o = RecGifOptions()
        o.fps = 99
        o.colors = 1
        o.maxWidth = 10
        o.maxFrames = 99_999
        let c = o.sanitized
        #expect(c.fps == 30 && c.colors == 2 && c.maxWidth == 64 && c.maxFrames == RecGifOptions.maxFramesLimit)
    }
}

@Suite struct RecPaletteTests {
    @Test func threeFlatColorsGiveThreePaletteEntries() {
        var b = RecPaletteBuilder()
        let bmp = bitmap(30, 30) { x, _ in x < 10 ? (255, 0, 0) : (x < 20 ? (0, 255, 0) : (0, 0, 255)) }
        b.add(bmp)
        let p = b.build(maxColors: 256)
        #expect(p.count == 3)
        let colors = Set((0..<3).map { "\(p.color($0).0),\(p.color($0).1),\(p.color($0).2)" })
        #expect(colors.count == 3)
    }

    @Test func colorCountIsCapped() {
        var b = RecPaletteBuilder()
        b.add(bitmap(256, 16) { x, y in (UInt8(x), UInt8(y * 16), UInt8((x * 7) & 255)) })
        let h1 = b.build(maxColors: 16)
        #expect(h1.count == 16)
        let h2 = b.build(maxColors: 2)
        #expect(h2.count == 2)
    }

    @Test func twoColorImageGetsAnExactPalette() {
        var b = RecPaletteBuilder()
        b.add(bitmap(20, 20) { x, _ in x < 10 ? (10, 20, 30) : (200, 210, 220) })
        let p = b.build(maxColors: 2)
        let all = Set((0..<p.count).map { [p.color($0).0, p.color($0).1, p.color($0).2] })
        #expect(all == [[10, 20, 30], [200, 210, 220]])
    }

    @Test func dominantColorComesFirst() {
        var b = RecPaletteBuilder()
        b.add(bitmap(10, 10) { x, _ in x < 9 ? (50, 50, 50) : (250, 0, 0) })
        let p = b.build(maxColors: 4)
        #expect(p.color(0) == (50, 50, 50))
    }

    @Test func emptyBuilderGivesBlackAndWhite() {
        let p = RecPaletteBuilder().build(maxColors: 256)
        #expect(p.count == 2 && p.color(0) == (0, 0, 0) && p.color(1) == (255, 255, 255))
    }

    @Test func gradientQuantizationErrorIsSmall() {
        let bmp = bitmap(256, 8) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        var b = RecPaletteBuilder()
        b.add(bmp)
        var q = RecQuantizer(palette: b.build(maxColors: 32))
        let idx = q.index(bmp, dither: .none)
        var worst = 0
        for x in 0..<256 { worst = max(worst, abs(Int(q.palette.color(Int(idx[x])).0) - x)) }
        #expect(worst <= 12)
    }

    @Test func tableBitsAndPadding() {
        #expect(RecPalette(rgb: [0, 0, 0, 1, 1, 1]).tableBits == 1)
        #expect(RecPalette(rgb: [UInt8](repeating: 0, count: 9)).tableBits == 2)
        #expect(RecPalette(rgb: [UInt8](repeating: 0, count: 9)).padded.count == 12)
        #expect(RecPalette(rgb: [UInt8](repeating: 0, count: 256 * 3)).tableBits == 8)
    }

    @Test func samplingStrideStillFindsAllColors() {
        var b = RecPaletteBuilder()
        b.add(bitmap(100, 100) { x, _ in x < 50 ? (255, 0, 0) : (0, 0, 255) }, stride: 7)
        let h3 = b.build(maxColors: 8)
        #expect(h3.count == 2 && b.samples > 1000)
    }

    @Test func buildIsDeterministic() {
        let bmp = bitmap(64, 64) { x, y in (UInt8(x * 4), UInt8(y * 4), UInt8((x * y) & 255)) }
        var a = RecPaletteBuilder(), c = RecPaletteBuilder()
        a.add(bmp); c.add(bmp)
        let h4 = a.build(maxColors: 64)
        #expect(h4 == c.build(maxColors: 64))
    }
}

@Suite struct RecQuantizerTests {
    private let bw = RecPalette(rgb: [0, 0, 0, 255, 255, 255])

    @Test func paletteColorsMapToThemselves() {
        var q = RecQuantizer(palette: RecPalette(rgb: [255, 0, 0, 0, 255, 0, 0, 0, 255]))
        let idx = q.index(bitmap(3, 1) { x, _ in x == 0 ? (255, 0, 0) : (x == 1 ? (0, 255, 0) : (0, 0, 255)) }, dither: .none)
        #expect(idx == [0, 1, 2])
    }

    @Test func nearestColorWins() {
        var q = RecQuantizer(palette: bw)
        let idx = q.index(bitmap(2, 1) { x, _ in x == 0 ? (40, 40, 40) : (210, 210, 210) }, dither: .none)
        #expect(idx == [0, 1])
    }

    @Test func allDithersStayInsideThePalette() {
        let bmp = bitmap(40, 40) { x, y in (UInt8(x * 6), UInt8(y * 6), 128) }
        for d in RecDither.allCases {
            var q = RecQuantizer(palette: RecPalette(rgb: [0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255]))
            let h5 = q.index(bmp, dither: d)
            #expect(h5.allSatisfy { $0 < 4 })
        }
    }

    @Test func floydDitherApproximatesMidGray() {
        var q = RecQuantizer(palette: bw)
        let idx = q.index(bitmap(64, 64) { _, _ in (128, 128, 128) }, dither: .floyd)
        let white = Double(idx.filter { $0 == 1 }.count) / Double(idx.count)
        #expect(white > 0.4 && white < 0.6)
    }

    @Test func orderedDitherApproximatesMidGrayAndIsPatterned() {
        var q = RecQuantizer(palette: bw)
        let idx = q.index(bitmap(64, 64) { _, _ in (128, 128, 128) }, dither: .ordered)
        let white = Double(idx.filter { $0 == 1 }.count) / Double(idx.count)
        #expect(white > 0.35 && white < 0.65)
        #expect(Array(idx[0..<4]) == Array(idx[4 * 64 ..< 4 * 64 + 4]))
    }

    @Test func noDitherGivesFlatResultOnFlatInput() {
        var q = RecQuantizer(palette: bw)
        let idx = q.index(bitmap(10, 10) { _, _ in (128, 128, 128) }, dither: .none)
        #expect(Set(idx).count == 1)
    }

    @Test func ditherIsDeterministic() {
        let bmp = bitmap(30, 30) { x, y in (UInt8(x * 8), UInt8(y * 8), 90) }
        var a = RecQuantizer(palette: bw), b = RecQuantizer(palette: bw)
        let h6 = a.index(bmp, dither: .floyd)
        let h7 = b.index(bmp, dither: .floyd)
        #expect(h6 == h7)
    }

    @Test func emptyBitmapGivesEmptyIndices() {
        var q = RecQuantizer(palette: bw)
        let h8 = q.index(.empty, dither: .floyd)
        #expect(h8.isEmpty)
    }
}

@Suite struct RecGifEncoderTests {
    private let pal = RecPalette(rgb: [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])

    @Test func headerAndTrailer() {
        let d = RecGifEncoder.encode(width: 4, height: 2, palette: pal, frames: [RecGifFrame(indices: [UInt8](repeating: 0, count: 8), delay: 10)])
        #expect(Array(d.prefix(6)) == Array("GIF89a".utf8) && d.last == 0x3B)
        #expect(d[6] == 4 && d[7] == 0 && d[8] == 2 && d[9] == 0)
    }

    @Test func loopExtensionIsPresent() {
        let d = RecGifEncoder.encode(width: 2, height: 2, palette: pal, frames: [RecGifFrame(indices: [0, 1, 2, 3], delay: 5)], loop: 3)
        let text = String(decoding: d.prefix(64), as: UTF8.self)
        #expect(text.contains("NETSCAPE2.0"))
    }

    @Test func imageIODecodesFramesSizeAndDelays() {
        let d = RecGifEncoder.encode(width: 4, height: 2, palette: pal, frames: [
            RecGifFrame(indices: [0, 0, 1, 1, 2, 2, 3, 3], delay: 10), RecGifFrame(indices: [3, 3, 2, 2, 1, 1, 0, 0], delay: 25)
        ])
        let f = frames(of: d)
        #expect(f.count == 2 && f[0].width == 4 && f[0].height == 2)
        let dl = delays(of: d)
        #expect(dl.count == 2 && abs(dl[0] - 0.10) < 0.001 && abs(dl[1] - 0.25) < 0.001)
    }

    @Test func imageIOPixelsMatchThePalette() {
        let d = RecGifEncoder.encode(width: 4, height: 1, palette: pal, frames: [RecGifFrame(indices: [0, 1, 2, 3], delay: 10)])
        let bmp = ShotBitmap(image: frames(of: d)[0])!
        #expect(bmp.pixel(0, 0).0 == 255 && bmp.pixel(0, 0).1 == 0)
        #expect(bmp.pixel(1, 0).1 == 255 && bmp.pixel(2, 0).2 == 255)
        #expect(bmp.pixel(3, 0).0 == 255 && bmp.pixel(3, 0).1 == 255 && bmp.pixel(3, 0).2 == 255)
    }

    @Test func identicalNeighbourFramesAreMerged() {
        let same = RecGifFrame(indices: [0, 1, 2, 3], delay: 10)
        let d = RecGifEncoder.encode(width: 2, height: 2, palette: pal, frames: [same, same, RecGifFrame(indices: [3, 3, 3, 3], delay: 10)])
        let dl = delays(of: d)
        #expect(dl.count == 2 && abs(dl[0] - 0.20) < 0.001)
    }

    @Test func mergedHelperCapsDelayAtSixteenBits() {
        let f = RecGifFrame(indices: [0], delay: 40_000)
        #expect(RecGifEncoder.merged([f, f]).count == 2)
        #expect(RecGifEncoder.merged([RecGifFrame(indices: [0], delay: 5), RecGifFrame(indices: [0], delay: 6)]).map(\.delay) == [11])
    }

    @Test func largeFrameWithManyColorsDecodes() {
        var rgb: [UInt8] = []
        for i in 0..<256 {
            rgb.append(UInt8(i))
            rgb.append(UInt8(255 - i))
            rgb.append(UInt8((i * 3) & 255))
        }
        var q = RecQuantizer(palette: RecPalette(rgb: rgb))
        let bmp = bitmap(200, 150) { x, y in
            let r = UInt8((x * 5) & 255)
            let g = UInt8((y * 7) & 255)
            let b = UInt8((x + y) & 255)
            return (r, g, b)
        }
        let idx = q.index(bmp, dither: .none)
        let d = RecGifEncoder.encode(width: 200, height: 150, palette: q.palette, frames: [RecGifFrame(indices: idx, delay: 4)])
        let f = frames(of: d)
        #expect(f.count == 1 && f[0].width == 200 && f[0].height == 150)
    }

    @Test func streamCountsFlushedFrames() {
        var s = RecGifStream(width: 2, height: 2, palette: pal)
        s.add(RecGifFrame(indices: [0, 0, 0, 0], delay: 5))
        s.add(RecGifFrame(indices: [0, 0, 0, 0], delay: 5))
        s.add(RecGifFrame(indices: [1, 1, 1, 1], delay: 5))
        let data = s.finish()
        #expect(s.frameCount == 2 && data.count == s.byteCount)
    }

    @Test func buildFromBitmapsEndToEnd() {
        let red = bitmap(32, 24) { _, _ in (250, 10, 10) }
        let blue = bitmap(32, 24) { x, _ in x < 16 ? (10, 10, 250) : (250, 250, 10) }
        var o = RecGifOptions()
        o.colors = 16
        o.dither = .none
        let data = RecGifEncoder.build(frames: [red, blue, blue], delays: [10, 10, 10], options: o)!
        let f = frames(of: data)
        #expect(f.count == 2)
        let b0 = ShotBitmap(image: f[0])!, b1 = ShotBitmap(image: f[1])!
        #expect(b0.pixel(5, 5).0 > 200 && b0.pixel(5, 5).2 < 60)
        #expect(b1.pixel(2, 2).2 > 200 && b1.pixel(30, 2).0 > 200 && b1.pixel(30, 2).1 > 200)
        let dl = delays(of: data)
        #expect(abs(dl[1] - 0.20) < 0.001)
    }

    @Test func buildRejectsMismatchedOrEmptyFrames() {
        #expect(RecGifEncoder.build(frames: [], delays: [], options: RecGifOptions()) == nil)
        #expect(RecGifEncoder.build(frames: [bitmap(4, 4) { _, _ in (0, 0, 0) }, bitmap(5, 4) { _, _ in (0, 0, 0) }], delays: [5, 5], options: RecGifOptions()) == nil)
    }

    @Test func fewerColorsGiveSmallerFiles() {
        let bmp = bitmap(80, 60) { x, y in (UInt8((x * 3) & 255), UInt8((y * 4) & 255), UInt8(((x ^ y) * 5) & 255)) }
        var big = RecGifOptions(), small = RecGifOptions()
        big.colors = 256; small.colors = 8
        big.dither = .none; small.dither = .none
        let a = RecGifEncoder.build(frames: [bmp], delays: [10], options: big)!
        let b = RecGifEncoder.build(frames: [bmp], delays: [10], options: small)!
        #expect(b.count < a.count)
    }
}
