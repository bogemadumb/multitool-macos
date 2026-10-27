import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

@Suite struct ColorContrastTests {
    private func c(_ hex: String) -> RGBAColor { ColorParser.parse(hex)! }

    @Test func blackOnWhiteIs21() {
        #expect(abs(ColorContrast.ratio(.black, .white) - 21) < 1e-9)
        #expect(abs(ColorContrast.ratio(.white, .black) - 21) < 1e-9)
    }

    @Test func sameColorIs1() {
        #expect(abs(ColorContrast.ratio(c("#336699"), c("#336699")) - 1) < 1e-9)
    }

    @Test func knownReferenceValues() {
        #expect(abs(ColorContrast.ratio(c("#777777"), .white) - 4.48) < 0.01)
        #expect(abs(ColorContrast.ratio(c("#767676"), .white) - 4.54) < 0.01)
        #expect(abs(ColorContrast.ratio(c("#0000FF"), .white) - 8.59) < 0.01)
    }

    @Test func luminanceExtremes() {
        #expect(ColorContrast.luminance(.black) == 0)
        #expect(abs(ColorContrast.luminance(.white) - 1) < 1e-9)
        #expect(abs(ColorContrast.luminance(c("#FF0000")) - 0.2126) < 1e-4)
    }

    @Test func levelThresholds() {
        #expect(ColorContrast.level(forRatio: 7) == .aaa)
        #expect(ColorContrast.level(forRatio: 6.99) == .aa)
        #expect(ColorContrast.level(forRatio: 4.5) == .aa)
        #expect(ColorContrast.level(forRatio: 3) == .aaLarge)
        #expect(ColorContrast.level(forRatio: 2.99) == .fail)
    }

    @Test func passesDependsOnTextSize() {
        #expect(!ColorContrast.passes(ratio: 4.0, level: .aa, largeText: false))
        #expect(ColorContrast.passes(ratio: 4.0, level: .aa, largeText: true))
        #expect(!ColorContrast.passes(ratio: 6, level: .aaa, largeText: false))
        #expect(ColorContrast.passes(ratio: 4.5, level: .aaa, largeText: true))
    }

    @Test func translucentColorCompositesOverWhite() {
        let half = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        let flat = ColorContrast.composite(half, over: .white)
        #expect(abs(flat.r - 0.5) < 1e-9 && flat.a == 1)
        #expect(ColorContrast.ratio(half, .white) < 21)
    }

    @Test func readableTextPicksTheBetterOne() {
        #expect(ColorContrast.readableText(on: c("#101010")) == .white)
        #expect(ColorContrast.readableText(on: c("#F5F5F5")) == .black)
    }

    @Test func describeFormatsRatio() {
        #expect(ColorContrast.describe(4.5) == "4.50:1")
    }
}

@Suite struct ColorHistoryTests {
    private func store(_ kv: WndMemoryStore = WndMemoryStore(), limit: Int = 30) -> (ColorHistoryStore, WndMemoryStore, TlsClock) {
        let clock = TlsClock()
        return (ColorHistoryStore(kv, limit: limit, clock: clock), kv, clock)
    }

    private let red = RGBAColor(red8: 255, green8: 0, blue8: 0)
    private let green = RGBAColor(red8: 0, green8: 255, blue8: 0)
    private let blue = RGBAColor(red8: 0, green8: 0, blue8: 255)

    @Test func newestFirstWithoutDuplicates() {
        let (s, _, _) = store()
        s.record(red); s.record(green); s.record(red)
        #expect(s.history.compactMap { $0.color?.red8 } == [255, 0])
        #expect(s.history.count == 2)
    }

    @Test func sameValueInOtherSpaceIsADifferentEntry() {
        let (s, _, _) = store()
        s.record(red)
        s.record(RGBAColor(r: 1, g: 0, b: 0, space: .displayP3))
        #expect(s.history.count == 2)
    }

    @Test func limitTrimsOldest() {
        let (s, _, _) = store(limit: 5)
        for i in 0..<9 { s.record(RGBAColor(red8: i * 20, green8: 0, blue8: 0)) }
        #expect(s.history.count == 5)
        #expect(s.history.first?.color?.red8 == 160)
        s.limit = 5
        s.limit = 2
        #expect(s.history.count == 5)
    }

    @Test func limitIsClamped() {
        let (s, _, _) = store(limit: 1)
        #expect(s.limit == ColorHistoryStore.limitRange.lowerBound)
        s.limit = 10_000
        #expect(s.limit == ColorHistoryStore.limitRange.upperBound)
    }

    @Test func persistsAcrossInstances() {
        let kv = WndMemoryStore()
        let (a, _, _) = store(kv)
        a.record(red); a.record(blue)
        a.toggleFavorite(green, name: "Зелёный")
        let (b, _, _) = store(kv)
        #expect(b.history.count == 2)
        #expect(b.favorites.first?.name == "Зелёный")
        #expect(b.isFavorite(green))
    }

    @Test func favoritesToggleRenameMove() {
        let (s, _, _) = store()
        #expect(s.toggleFavorite(red))
        #expect(s.toggleFavorite(green))
        #expect(s.favorites.compactMap { $0.color?.green8 } == [255, 0])
        s.rename(favorite: red, to: "  Красный ")
        #expect(s.favorites.last?.name == "Красный")
        s.moveFavorite(from: 1, to: 0)
        #expect(s.favorites.first?.color?.red8 == 255)
        #expect(!s.toggleFavorite(red))
        #expect(!s.isFavorite(red))
    }

    @Test func favoritesSurviveHistoryClear() {
        let (s, kv, _) = store()
        s.record(red)
        s.toggleFavorite(red)
        s.clearHistory()
        #expect(s.history.isEmpty && s.favorites.count == 1)
        #expect(kv.object(forKey: ColorHistoryStore.historyKey) == nil)
        #expect(kv.object(forKey: ColorHistoryStore.favoritesKey) != nil)
    }

    @Test func removeSingleHistoryEntry() {
        let (s, _, _) = store()
        s.record(red); s.record(green)
        s.remove(historyAt: 0)
        #expect(s.history.count == 1 && s.history[0].color?.red8 == 255)
        s.remove(historyAt: 9)
        #expect(s.history.count == 1)
    }

    @Test func corruptStorageIsIgnored() {
        let kv = WndMemoryStore()
        kv.set("не json", forKey: ColorHistoryStore.historyKey)
        let (s, _, _) = store(kv)
        #expect(s.history.isEmpty)
    }

    @Test func entriesRememberTime() {
        let (s, _, clock) = store()
        s.record(red)
        #expect(s.history[0].stamp == clock.now.timeIntervalSince1970)
    }

    @Test func alphaIsKept() {
        let (s, _, _) = store()
        s.record(RGBAColor(red8: 10, green8: 20, blue8: 30, alpha8: 100))
        #expect(s.history[0].color?.alpha8 == 100)
    }
}

@Suite struct ColorPickerSettingsTests {
    @Test func defaultsMatchTheCatalog() {
        let s = ColorPickerSettings()
        #expect(s.format == .hex && !s.withoutHash && s.outputSpace == .srgb)
        #expect(s.options == ColorFormatOptions(withoutHash: false, uppercaseHex: true))
    }

    @Test func sanitizeClamps() {
        var s = ColorPickerSettings()
        s.loupeRadius = 99
        s.historyLimit = 1
        let c = s.sanitized
        #expect(c.loupeRadius == ColorPickerSettings.loupeRange.upperBound)
        #expect(c.historyLimit == ColorHistoryStore.limitRange.lowerBound)
    }

    @Test func storeRoundTripWritesOnlyDifferences() {
        let kv = WndMemoryStore()
        let store = ColorPickerSettingsStore(kv)
        store.save(ColorPickerSettings())
        #expect(kv.values.isEmpty)
        var s = ColorPickerSettings()
        s.format = .swiftUI
        s.withoutHash = true
        s.outputSpace = .displayP3
        s.loupeRadius = 8
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("colorPicker.") && $0.allSatisfy(\.isASCII) })
    }

    @Test func unknownStoredValuesFallBack() {
        let kv = WndMemoryStore()
        kv.set("nope", forKey: "colorPicker.format")
        kv.set(500, forKey: "colorPicker.loupeRadius")
        let s = ColorPickerSettingsStore(kv).load()
        #expect(s.format == .hex && s.loupeRadius == ColorPickerSettings.loupeRange.upperBound)
    }
}

@Suite struct ColorPickerSessionTests {
    private func rig(_ w: Int = 20, _ h: Int = 10, settings: ColorPickerSettings = ColorPickerSettings(), history: Bool = true) -> (ColorPickerSession, TlsTextSink, ColorHistoryStore) {
        let sink = TlsTextSink()
        let hist = ColorHistoryStore(WndMemoryStore())
        let s = ColorPickerSession(source: TlsPixels(w, h), settings: settings, clipboard: sink, history: history ? hist : nil)
        return (s, sink, hist)
    }

    @Test func keyMapping() {
        #expect(PickerKeys.action(keyCode: Keys.left, shift: false) == .move(dx: -1, dy: 0))
        #expect(PickerKeys.action(keyCode: Keys.right, shift: false) == .move(dx: 1, dy: 0))
        #expect(PickerKeys.action(keyCode: Keys.up, shift: false) == .move(dx: 0, dy: -1))
        #expect(PickerKeys.action(keyCode: Keys.down, shift: false) == .move(dx: 0, dy: 1))
        #expect(PickerKeys.action(keyCode: Keys.right, shift: true) == .move(dx: 10, dy: 0))
        #expect(PickerKeys.action(keyCode: Keys.returnKey, shift: false) == .copyAndClose)
        #expect(PickerKeys.action(keyCode: Keys.enterKey, shift: false) == .copyAndClose)
        #expect(PickerKeys.action(keyCode: 8, shift: false) == .copyAndKeep)
        #expect(PickerKeys.action(keyCode: Keys.escape, shift: false) == .cancel)
        #expect(PickerKeys.action(keyCode: 0, shift: false) == nil)
    }

    @Test func movingIsClampedToTheImage() {
        let (s, _, _) = rig(20, 10)
        s.handle(.move(dx: -5, dy: -5))
        #expect(s.x == 0 && s.y == 0)
        s.handle(.move(dx: 500, dy: 500))
        #expect(s.x == 19 && s.y == 9)
        s.moveTo(x: 7, y: 3)
        #expect(s.x == 7 && s.y == 3)
    }

    @Test func startPositionIsClamped() {
        let s = ColorPickerSession(source: TlsPixels(4, 4), settings: ColorPickerSettings(), clipboard: TlsTextSink(), history: nil, startX: 99, startY: -4)
        #expect(s.x == 3 && s.y == 0)
    }

    @Test func copyAndCloseWritesFormattedTextAndCloses() {
        let (s, sink, hist) = rig()
        s.moveTo(x: 5, y: 2)
        let out = s.handle(.copyAndClose)
        #expect(out == .copied(text: "#321407", closes: true))
        #expect(sink.writes == ["#321407"])
        #expect(hist.history.count == 1)
    }

    @Test func copyAndKeepDoesNotClose() {
        let (s, sink, _) = rig()
        #expect(s.handle(.copyAndKeep) == .copied(text: "#000007", closes: false))
        s.handle(.move(dx: 1, dy: 0))
        #expect(s.handle(.copyAndKeep) == .copied(text: "#0A0007", closes: false))
        #expect(sink.writes.count == 2)
    }

    @Test func withoutHashAndFormatSettingsApply() {
        var set = ColorPickerSettings()
        set.withoutHash = true
        let (a, sa, _) = rig(settings: set)
        a.handle(.copyAndClose)
        #expect(sa.writes == ["000007"])
        set.format = .rgb
        let (b, sb, _) = rig(settings: set)
        b.moveTo(x: 1, y: 1)
        b.handle(.copyAndClose)
        #expect(sb.writes == ["rgb(10, 10, 7)"])
    }

    @Test func historyCanBeSwitchedOff() {
        var set = ColorPickerSettings()
        set.recordHistory = false
        let (s, sink, hist) = rig(settings: set)
        s.handle(.copyAndClose)
        #expect(sink.writes.count == 1 && hist.history.isEmpty)
    }

    @Test func cancelWritesNothing() {
        let (s, sink, hist) = rig()
        #expect(s.handle(.cancel) == .cancelled)
        #expect(sink.writes.isEmpty && hist.history.isEmpty)
    }

    @Test func outputSpaceConvertsBeforeFormatting() {
        let src = TlsPixels(2, 2) { _, _ in RGBAColor(r: 1, g: 0, b: 0, space: .displayP3) }
        let sink = TlsTextSink()
        var set = ColorPickerSettings()
        set.format = .swiftUI
        set.outputSpace = .displayP3
        let p3 = ColorPickerSession(source: src, settings: set, clipboard: sink, history: nil)
        p3.handle(.copyAndKeep)
        #expect(sink.writes == ["Color(.displayP3, red: 1, green: 0, blue: 0)"])
        set.outputSpace = .srgb
        set.format = .hex
        let srgb = ColorPickerSession(source: src, settings: set, clipboard: sink, history: nil)
        srgb.handle(.copyAndKeep)
        #expect(sink.writes.last == "#FF0000")
    }

    @Test func loupeIsSquareAroundTheCursorAndNilOutside() {
        let (s, _, _) = rig(20, 10)
        s.moveTo(x: 0, y: 0)
        let grid = s.loupe()
        let n = ColorPickerSettings().loupeRadius * 2 + 1
        #expect(grid.count == n && grid.allSatisfy { $0.count == n })
        let mid = n / 2
        #expect(grid[mid][mid] != nil)
        #expect(grid[0][0] == nil)
        #expect(grid[mid][mid] == s.current)
        #expect(grid[mid][mid + 1] != nil)
    }

    @Test func loupeSizeFollowsSettings() {
        var set = ColorPickerSettings()
        set.loupeRadius = 3
        let (s, _, _) = rig(settings: set)
        #expect(s.loupe().count == 7)
    }

    @Test func emptySourceCopiesNothing() {
        let sink = TlsTextSink()
        let s = ColorPickerSession(source: TlsPixels(0, 0), settings: ColorPickerSettings(), clipboard: sink, history: nil)
        #expect(s.handle(.copyAndClose) == .nothing)
        #expect(sink.writes.isEmpty)
    }
}

@Suite struct BitmapPixelSourceTests {
    @Test func readsKnownPixels() throws {
        let src = try #require(BitmapPixelSource(image: tlsImage(8, 8)))
        #expect(src.pixelWidth == 8 && src.pixelHeight == 8)
        let top = src.color(atX: 3, y: 0)
        let bottom = src.color(atX: 3, y: 7)
        #expect([top?.red8, top?.green8, top?.blue8] == [255, 0, 0])
        #expect([bottom?.red8, bottom?.green8, bottom?.blue8] == [0, 0, 255])
        #expect(top?.space == .srgb)
    }

    @Test func outOfBoundsIsNil() throws {
        let src = try #require(BitmapPixelSource(image: tlsImage(4, 4)))
        #expect(src.color(atX: -1, y: 0) == nil)
        #expect(src.color(atX: 0, y: 4) == nil)
        #expect(src.color(atX: 4, y: 0) == nil)
    }

    @Test func pickerSessionWorksOnARealBitmap() throws {
        let src = try #require(BitmapPixelSource(image: tlsImage(6, 6)))
        let sink = TlsTextSink()
        let s = ColorPickerSession(source: src, settings: ColorPickerSettings(), clipboard: sink, history: nil, startX: 2, startY: 5)
        s.handle(.copyAndKeep)
        #expect(sink.writes == ["#0000FF"])
    }
}
