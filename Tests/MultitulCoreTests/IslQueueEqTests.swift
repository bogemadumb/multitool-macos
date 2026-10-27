import Testing
import Foundation
@testable import MultitulCore

private let RS = String(IslQueueScripts.recordSeparator)
private let FS = String(IslQueueScripts.fieldSeparator)

private func record(_ parts: String...) -> String { parts.joined(separator: FS) }

private func answer(idx: Int = 3, total: Int = 20, shuffle: Bool = false, tracks: [(Int, String, String, String, String)]) -> String {
    var out = [record("META", "\(idx)", "\(total)", shuffle ? "1" : "0", "Мой плейлист")]
    for t in tracks { out.append(record("TRK", "\(t.0)", t.1, t.2, t.3, t.4)) }
    return out.joined(separator: RS)
}

final class ExtFakeRunner: IslScriptRunning {
    var outputs: [IslScriptOutput] = []
    var scripts: [String] = []
    func run(_ source: String) -> IslScriptOutput {
        scripts.append(source)
        return outputs.isEmpty ? .failure(code: -1, message: "no output") : outputs.removeFirst()
    }
}

@Suite struct IslQueueParserTests {
    @Test func parsesMetaAndTracks() {
        let raw = answer(tracks: [(4, "Next", "Band", "Album", "215.5"), (5, "After", "Other", "", "180")])
        guard case .items(let items, let meta) = IslQueueParser.parse(raw) else { Issue.record("not items"); return }
        #expect(items.map(\.title) == ["Next", "After"] && items.map(\.position) == [4, 5] && items[0].duration == 215.5)
        #expect(meta == IslQueueMeta(currentIndex: 3, total: 20, shuffle: false, playlist: "Мой плейлист"))
    }

    @Test func commaDecimalsAreAccepted() {
        guard case .items(let items, _) = IslQueueParser.parse(answer(tracks: [(4, "A", "B", "C", "215,5")])) else { Issue.record("not items"); return }
        #expect(items[0].duration == 215.5)
    }

    @Test func zeroDurationBecomesUnknown() {
        guard case .items(let items, _) = IslQueueParser.parse(answer(tracks: [(4, "A", "B", "C", "0")])) else { Issue.record("not items"); return }
        #expect(items[0].duration == nil)
    }

    @Test func metaWithoutTracksMeansTheEndOfTheList() {
        guard case .empty(let meta) = IslQueueParser.parse(answer(idx: 20, tracks: [])) else { Issue.record("not empty"); return }
        #expect(meta?.currentIndex == 20)
    }

    @Test func shuffleFlagIsRead() {
        guard case .items(_, let meta) = IslQueueParser.parse(answer(shuffle: true, tracks: [(4, "A", "B", "C", "10")])) else { Issue.record("not items"); return }
        #expect(meta.shuffle)
    }

    @Test func errorRecords() {
        #expect(IslQueueParser.parse("ERR\(FS)notrunning") == .notRunning)
        #expect(IslQueueParser.parse("ERR\(FS)stopped") == .stopped)
        #expect(IslQueueParser.parse("ERR\(FS)boom") == .failed("boom"))
    }

    @Test func garbageAndEmptyAnswersFail() {
        if case .failed = IslQueueParser.parse("") {} else { Issue.record("empty") }
        if case .failed = IslQueueParser.parse("hello") {} else { Issue.record("garbage") }
        if case .failed = IslQueueParser.parse(record("META", "x", "y", "0", "p")) {} else { Issue.record("bad numbers") }
    }

    @Test func malformedTrackRecordsAreSkipped() {
        let raw = [record("META", "1", "5", "0", "p"), record("TRK", "2", "ok", "a", "b", "10"), record("TRK", "x", "bad", "a", "b", "10"), record("TRK", "3", "short")].joined(separator: RS)
        guard case .items(let items, _) = IslQueueParser.parse(raw) else { Issue.record("not items"); return }
        #expect(items.map(\.title) == ["ok"])
    }

    @Test func titlesWithPunctuationAndCyrillicSurvive() {
        guard case .items(let items, _) = IslQueueParser.parse(answer(tracks: [(4, "Группа крови: часть 1 | live", "Кино", "Альбом", "300")])) else { Issue.record("not items"); return }
        #expect(items[0].title == "Группа крови: часть 1 | live")
    }
}

@Suite struct IslQueueProviderTests {
    @Test func musicScriptTargetsTheMusicAppAndTheLimit() throws {
        let s = try #require(IslQueueScripts.upNext(.music, limit: 5))
        #expect(s.contains("com.apple.Music") && s.contains("idx + 5") && s.contains("current playlist") && s.contains("shuffle enabled"))
    }

    @Test func scriptNeverLaunchesAClosedPlayer() throws {
        let s = try #require(IslQueueScripts.upNext(.music, limit: 5))
        let check = s.range(of: "is not running")
        let tell = s.range(of: "tell application")
        #expect(check != nil && tell != nil && check!.lowerBound < tell!.lowerBound)
    }

    @Test func limitIsClamped() throws {
        #expect(try #require(IslQueueScripts.upNext(.music, limit: 999)).contains("idx + 20"))
        #expect(try #require(IslQueueScripts.upNext(.music, limit: -4)).contains("idx + 1"))
    }

    @Test func spotifyHasNoQueueScript() {
        #expect(IslQueueScripts.upNext(.spotify, limit: 5) == nil)
        #expect(IslQueueScripts.play(.spotify, position: 3) == nil)
    }

    @Test func playScriptValidatesThePosition() {
        #expect(IslQueueScripts.play(.music, position: 7)?.contains("play track 7 of current playlist") == true)
        #expect(IslQueueScripts.play(.music, position: 0) == nil && IslQueueScripts.play(.music, position: -2) == nil)
    }

    @Test func providerParsesTheRunnerOutput() {
        let r = ExtFakeRunner()
        r.outputs = [.text(answer(tracks: [(4, "A", "B", "C", "10")]))]
        let result = IslQueueProvider(runner: r).upNext(app: .music, limit: 3)
        if case .items(let i, _) = result { #expect(i.count == 1) } else { Issue.record("not items") }
        #expect(r.scripts.count == 1)
    }

    @Test func spotifyIsReportedAsUnsupportedWithoutRunningAScript() {
        let r = ExtFakeRunner()
        if case .unsupported(let m) = IslQueueProvider(runner: r).upNext(app: .spotify, limit: 3) { #expect(m.contains("Spotify")) } else { Issue.record("expected unsupported") }
        #expect(r.scripts.isEmpty)
    }

    @Test func automationDeniedIsRecognized() {
        let r = ExtFakeRunner()
        r.outputs = [.failure(code: -1743, message: "Not authorized")]
        #expect(IslQueueProvider(runner: r).upNext(app: .music, limit: 3) == .needsAutomation)
    }

    @Test func applicationNotRunningErrors() {
        let r = ExtFakeRunner()
        r.outputs = [.failure(code: -600, message: ""), .failure(code: -609, message: "")]
        let p = IslQueueProvider(runner: r)
        #expect(p.upNext(app: .music, limit: 3) == .notRunning && p.upNext(app: .music, limit: 3) == .notRunning)
    }

    @Test func otherErrorsCarryTheirMessage() {
        let r = ExtFakeRunner()
        r.outputs = [.failure(code: -1728, message: "Can't get track"), .failure(code: -50, message: "")]
        let p = IslQueueProvider(runner: r)
        #expect(p.upNext(app: .music, limit: 3) == .failed("Can't get track") && p.upNext(app: .music, limit: 3) == .failed("Ошибка -50"))
    }

    @Test func playReturnsTheOutcome() {
        let r = ExtFakeRunner()
        r.outputs = [.text(""), .failure(code: -1, message: "x")]
        let p = IslQueueProvider(runner: r)
        #expect(p.play(app: .music, position: 4) && !p.play(app: .music, position: 4) && !p.play(app: .spotify, position: 4))
    }

    @Test func appsAreResolvedFromBundleIDs() {
        #expect(IslQueueApp(bundleID: "com.apple.Music") == .music && IslQueueApp(bundleID: "com.spotify.client") == .spotify)
        #expect(IslQueueApp(bundleID: "org.videolan.vlc") == nil && IslQueueApp(bundleID: nil) == nil)
    }

    @Test func notesExplainTheStates() {
        let meta = IslQueueMeta(currentIndex: 1, total: 5, shuffle: true, playlist: "p")
        #expect(IslQueueFormat.note(.items([IslQueueItem(position: 2, title: "a")], meta), app: .music)?.contains("перемешивание") == true)
        #expect(IslQueueFormat.note(.items([IslQueueItem(position: 2, title: "a")], IslQueueMeta(currentIndex: 1, total: 5, shuffle: false, playlist: "p")), app: .music) == nil)
        #expect(IslQueueFormat.note(.needsAutomation, app: .music)?.contains("Автоматизация") == true)
        #expect(IslQueueFormat.note(.notRunning, app: nil) == "Плеер не запущен")
    }

    @Test func settingsAreClampedAndRoundTrip() {
        var s = IslQueueSettings()
        s.limit = 100
        s.refreshSeconds = 0
        #expect(s.sanitized.limit == 20 && s.sanitized.refreshSeconds == 2)
        let kv = WndMemoryStore()
        var custom = IslQueueSettings()
        custom.limit = 12
        IslQueueSettingsStore(kv).save(custom)
        #expect(IslQueueSettingsStore(kv).load() == custom)
        IslQueueSettingsStore(kv).save(IslQueueSettings())
        #expect(kv.values.isEmpty)
    }
}

@Suite struct IslEqMapperTests {
    @Test func sameCountPassesThrough() {
        #expect(IslEqMapper.resample([0.1, 0.5, 1], to: 3) == [0.1, 0.5, 1])
    }

    @Test func shrinkingKeepsPeaksVisible() {
        let out = IslEqMapper.resample([0, 0, 1, 0], to: 2)
        #expect(out.count == 2 && out[0] == 0 && out[1] > 0.6)
    }

    @Test func growingInterpolates() {
        let out = IslEqMapper.resample([0, 1], to: 5)
        #expect(out == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test func twelveBandsToFour() {
        let bands: [Float] = (0..<12).map { Float($0) / 11 }
        let out = IslEqMapper.resample(bands, to: 4)
        #expect(out.count == 4 && out == out.sorted() && out.last! > out.first!)
    }

    @Test func singleBarTakesTheLoudestBand() {
        #expect(IslEqMapper.resample([0.2, 0.9, 0.4], to: 1)[0] > 0.5)
    }

    @Test func emptyInputGivesSilence() {
        #expect(IslEqMapper.resample([], to: 4) == [0, 0, 0, 0] && IslEqMapper.resample([0.5], to: 0).isEmpty)
    }

    @Test func nonFiniteAndOutOfRangeValuesAreCleaned() {
        let out = IslEqMapper.resample([.nan, 5, -3, .infinity], to: 4)
        #expect(out == [0, 1, 0, 0])
    }

    @Test func shapingAppliesFloorAndGain() {
        #expect(IslEqMapper.shaped(0.03, gain: 1) == 0)
        #expect(IslEqMapper.shaped(1, gain: 1) == 1)
        #expect(IslEqMapper.shaped(0.6, gain: 2) == 1)
        #expect(IslEqMapper.shaped(0.5, gain: 0.5) < 0.3)
    }

    @Test func mixerKeyResolution() {
        let keys: Set<String> = ["com.spotify.client", "com.google.Chrome"]
        #expect(IslEqSource.key(forBundle: "com.spotify.client", available: keys) == "com.spotify.client")
        #expect(IslEqSource.key(forBundle: "com.google.Chrome.helper", available: keys) == "com.google.Chrome")
        #expect(IslEqSource.key(forBundle: "com.apple.Music", available: keys) == nil)
        #expect(IslEqSource.key(forBundle: nil, available: keys) == nil && IslEqSource.key(forBundle: "", available: keys) == nil)
    }
}

@Suite struct IslEqSmootherTests {
    @Test func attackIsFasterThanRelease() {
        var s = IslEqSmoother(count: 1)
        s.step([1], dt: 0.05)
        let up = s.values[0]
        s.step([0], dt: 0.05)
        let down = s.values[0]
        #expect(up > 0.6 && (up - down) < up * 0.5)
    }

    @Test func barsConvergeToASteadyInput() {
        var s = IslEqSmoother(count: 2)
        for _ in 0..<60 { s.step([0.8, 0.3], dt: 0.05) }
        #expect(abs(s.values[0] - 0.8) < 0.01 && abs(s.values[1] - 0.3) < 0.01)
    }

    @Test func emptyInputDecaysToExactSilence() {
        var s = IslEqSmoother(count: 3)
        s.step([1, 1, 1], dt: 0.2)
        for _ in 0..<80 { s.step([], dt: 0.1) }
        #expect(s.values == [0, 0, 0] && s.peak == 0)
    }

    @Test func largeTimeStepsAreCapped() {
        var a = IslEqSmoother(count: 1)
        var b = IslEqSmoother(count: 1)
        a.step([1], dt: 0.5)
        b.step([1], dt: 60)
        #expect(a.values == b.values)
    }

    @Test func resizeKeepsExistingBars() {
        var s = IslEqSmoother(count: 2)
        s.step([1, 1], dt: 0.5)
        let first = s.values[0]
        s.resize(4)
        #expect(s.values.count == 4 && s.values[0] == first && s.values[3] == 0)
        s.resize(1)
        #expect(s.values.count == 1)
    }

    @Test func resetZeroesTheBars() {
        var s = IslEqSmoother(count: 2)
        s.step([1, 1], dt: 0.5)
        s.reset()
        #expect(s.values == [0, 0])
    }

    @Test func negativeTimeStepDoesNothing() {
        var s = IslEqSmoother(count: 1)
        s.step([1], dt: -3)
        #expect(s.values == [0])
    }
}

@Suite struct IslEqFeedTests {
    @Test func liveDataMakesTheFeedLiveForAShortWhile() {
        var f = IslEqFeed()
        #expect(!f.isLive(at: ExtFix.now))
        f.update(bands: [0.5, 0.5, 0.5, 0.5], bars: 2, now: ExtFix.now, dt: 0.05)
        #expect(f.isLive(at: ExtFix.at(1)) && !f.isLive(at: ExtFix.at(2)))
        #expect(f.values.count == 2 && f.values[0] > 0)
    }

    @Test func missingDataDecaysTheBars() {
        var f = IslEqFeed()
        f.update(bands: Array(repeating: 1, count: 12), bars: 4, now: ExtFix.now, dt: 0.5)
        let peak = f.smoother.peak
        f.update(bands: nil, bars: 4, now: ExtFix.at(0.5), dt: 0.5)
        #expect(f.smoother.peak < peak)
    }

    @Test func barCountFollowsTheRequest() {
        var f = IslEqFeed()
        f.update(bands: [1, 1], bars: 8, now: ExtFix.now, dt: 0.05)
        #expect(f.values.count == 8)
        f.update(bands: [1, 1], bars: 3, now: ExtFix.now, dt: 0.05)
        #expect(f.values.count == 3)
    }

    @Test func quietBandsStayBelowTheNoiseFloor() {
        var f = IslEqFeed()
        f.update(bands: Array(repeating: 0.02, count: 12), bars: 4, now: ExtFix.now, dt: 0.5)
        #expect(f.smoother.peak == 0)
    }

    @Test func gainRaisesTheBars() {
        var lo = IslEqFeed(), hi = IslEqFeed()
        hi.gain = 2
        for f in [0, 1] {
            if f == 0 { lo.update(bands: Array(repeating: 0.3, count: 12), bars: 4, now: ExtFix.now, dt: 0.5) } else { hi.update(bands: Array(repeating: 0.3, count: 12), bars: 4, now: ExtFix.now, dt: 0.5) }
        }
        #expect(hi.smoother.peak > lo.smoother.peak)
    }

    @Test func settingsClampAndRoundTrip() {
        var s = IslEqSettings()
        s.compactBars = 1
        s.expandedBars = 99
        s.sensitivity = 10
        let c = s.sanitized
        #expect(c.compactBars == 3 && c.expandedBars == 16 && c.sensitivity == 3)
        let kv = WndMemoryStore()
        var custom = IslEqSettings()
        custom.compactBars = 6
        custom.showInMusic = false
        IslEqSettingsStore(kv).save(custom)
        #expect(IslEqSettingsStore(kv).load() == custom)
        IslEqSettingsStore(kv).save(IslEqSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func mixerBandCountMatchesTheMapperInput() {
        #expect(MixBandAnalyzer.defaultBandCount == 12)
        #expect(IslEqMapper.resample(Array(repeating: 0.5, count: MixBandAnalyzer.defaultBandCount), to: 4).count == 4)
    }
}
