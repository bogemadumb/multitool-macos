import Testing
import Foundation
@testable import MultitulCore

@Suite struct IslLrcParserTests {
    @Test func parsesSimpleTimestamps() {
        let l = IslLrcParser.parse("[00:12.00]Hello\n[00:15.50]World")
        #expect(l.isSynced && l.lines.map(\.text) == ["Hello", "World"] && l.lines.map(\.time) == [12, 15.5])
    }

    @Test func multipleTimestampsPerLineExpandIntoSeveralLines() {
        let l = IslLrcParser.parse("[00:10.00][01:30.00][02:50.00]Chorus\n[00:20.00]Verse")
        #expect(l.lines.map(\.time) == [10, 20, 90, 170])
        #expect(l.lines.map(\.text) == ["Chorus", "Verse", "Chorus", "Chorus"])
    }

    @Test func fractionDigitsMeanDecimals() {
        let l = IslLrcParser.parse("[00:01.5]a\n[00:02.05]b\n[00:03.250]c\n[00:04]d")
        #expect(l.lines.map(\.time) == [1.5, 2.05, 3.25, 4])
    }

    @Test func colonFractionSeparatorIsAccepted() {
        #expect(IslLrcParser.parse("[00:12:50]x").lines.first?.time == 12.5)
    }

    @Test func minutesAboveSixtyAreAllowed() {
        #expect(IslLrcParser.parse("[75:00.00]long").lines.first?.time == 4500)
    }

    @Test func secondsOverSixtyAreRejected() {
        let l = IslLrcParser.parse("[00:75.00]bad\n[00:05.00]good")
        #expect(l.lines.map(\.text) == ["good"])
    }

    @Test func linesAreSortedByTime() {
        let l = IslLrcParser.parse("[00:30.00]c\n[00:10.00]a\n[00:20.00]b")
        #expect(l.lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func equalTimesKeepTheirFileOrder() {
        let l = IslLrcParser.parse("[00:10.00]first\n[00:10.00]second")
        #expect(l.lines.map(\.text) == ["first", "second"])
    }

    @Test func metadataTagsAreCollected() {
        let l = IslLrcParser.parse("[ti:Song]\n[ar:Artist]\n[al:Album]\n[by:me]\n[00:01.00]x")
        #expect(l.metadata["ti"] == "Song" && l.metadata["ar"] == "Artist" && l.metadata["al"] == "Album" && l.metadata["by"] == "me")
        #expect(l.lines.count == 1)
    }

    @Test func positiveOffsetMakesLyricsAppearSooner() {
        let l = IslLrcParser.parse("[offset:+500]\n[00:10.00]x")
        #expect(l.offset == 0.5 && l.lines[0].time == 9.5)
    }

    @Test func negativeOffsetDelaysLyrics() {
        #expect(IslLrcParser.parse("[offset:-1000]\n[00:10.00]x").lines[0].time == 11)
    }

    @Test func offsetNeverGoesBelowZero() {
        #expect(IslLrcParser.parse("[offset:5000]\n[00:01.00]x").lines[0].time == 0)
    }

    @Test func garbageOffsetIsIgnored() {
        let l = IslLrcParser.parse("[offset:abc]\n[00:10.00]x")
        #expect(l.offset == 0 && l.lines[0].time == 10)
    }

    @Test func enhancedWordTimingsAreExtracted() {
        let l = IslLrcParser.parse("[00:10.00]<00:10.00>Hello <00:10.60>big <00:11.20>world")
        #expect(l.hasWordTiming)
        #expect(l.lines[0].text == "Hello big world")
        #expect(l.lines[0].words == [IslLrcWord(time: 10, text: "Hello"), IslLrcWord(time: 10.6, text: "big"), IslLrcWord(time: 11.2, text: "world")])
    }

    @Test func offsetShiftsWordTimesToo() {
        let l = IslLrcParser.parse("[offset:1000]\n[00:10.00]<00:10.00>a <00:11.00>b")
        #expect(l.lines[0].words.map(\.time) == [9, 10])
    }

    @Test func plainLinesWithoutWordTagsHaveNoWords() {
        #expect(!IslLrcParser.parse("[00:10.00]plain").hasWordTiming)
    }

    @Test func malformedLinesAreSkippedWithoutBreakingTheRest() {
        let l = IslLrcParser.parse("garbage\n[00:xx.00]bad\n[00:10.00]ok\n[broken\n[00:20.00]fine")
        #expect(l.isSynced && l.lines.map(\.text) == ["ok", "fine"])
    }

    @Test func emptyTextLinesAreKeptAsGaps() {
        let l = IslLrcParser.parse("[00:10.00]a\n[00:15.00]\n[00:20.00]b")
        #expect(l.lines.map(\.text) == ["a", "", "b"] && l.lines[1].isBlank)
    }

    @Test func windowsLineEndingsAndBomAreHandled() {
        let l = IslLrcParser.parse("\u{FEFF}[00:10.00]a\r\n[00:20.00]b\r\n")
        #expect(l.lines.map(\.text) == ["a", "b"])
    }

    @Test func textWithoutTimestampsBecomesUnsyncedLines() {
        let l = IslLrcParser.parse("first line\n\nsecond line")
        #expect(!l.isSynced && l.lines.map(\.text) == ["first line", "second line"])
        #expect(l.index(at: 50) == nil)
    }

    @Test func emptyInputIsEmpty() {
        #expect(IslLrcParser.parse("").isEmpty && IslLrcParser.parse("\n\n").isEmpty)
    }

    @Test func cyrillicTextSurvives() {
        #expect(IslLrcParser.parse("[00:01.00]Привет, мир").lines[0].text == "Привет, мир")
    }
}

@Suite struct IslLrcLookupTests {
    private let lrc = IslLrcParser.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")

    @Test func beforeTheFirstLineThereIsNoCurrentLine() {
        #expect(lrc.index(at: 9.99) == nil && lrc.index(at: 0) == nil)
    }

    @Test func exactTimestampSelectsThatLine() {
        #expect(lrc.index(at: 10) == 0 && lrc.index(at: 20) == 1 && lrc.index(at: 30) == 2)
    }

    @Test func betweenLinesKeepsThePreviousOne() {
        #expect(lrc.index(at: 19.99) == 0 && lrc.index(at: 25) == 1)
    }

    @Test func afterTheLastLineStaysOnTheLast() {
        #expect(lrc.index(at: 9999) == 2)
    }

    @Test func leadMovesTheSwitchEarlier() {
        #expect(lrc.index(at: 19.8, lead: 0.3) == 1 && lrc.index(at: 19.8) == 0)
    }

    @Test func nonFiniteElapsedGivesNothing() {
        #expect(lrc.index(at: .nan) == nil && lrc.index(at: .infinity) == nil)
    }

    @Test func lineEndAndProgress() {
        #expect(lrc.lineEnd(0) == 20 && lrc.lineEnd(2) == 36)
        #expect(lrc.progress(in: 0, at: 15) == 0.5 && lrc.progress(in: 0, at: 5) == 0 && lrc.progress(in: 0, at: 99) == 1)
    }

    @Test func wordIndexFollowsWordTimes() {
        let e = IslLrcParser.parse("[00:10.00]<00:10.00>a <00:11.00>b <00:12.00>c")
        #expect(e.wordIndex(in: 0, at: 9) == nil && e.wordIndex(in: 0, at: 10.5) == 0 && e.wordIndex(in: 0, at: 12.5) == 2)
        #expect(lrc.wordIndex(in: 0, at: 11) == nil)
    }

    @Test func windowAroundTheCurrentLine() {
        let w = lrc.window(around: 1, before: 1, after: 1)
        #expect(w.map(\.index) == [0, 1, 2])
        #expect(lrc.window(around: 0, before: 2, after: 0).map(\.index) == [0])
        #expect(lrc.window(around: nil, before: 1, after: 1).map(\.index) == [0])
        #expect(IslLrc().window(around: 0, before: 1, after: 1).isEmpty)
    }

    @Test func emptyLyricsNeverMatch() {
        #expect(IslLrc().index(at: 5) == nil)
    }
}

final class ExtFakeLyricsProvider: IslLyricsProviding {
    var queue: [(IslLyricsQuery, (IslLyricsResult) -> Void)] = []
    var calls: [IslLyricsQuery] = []
    func fetch(_ query: IslLyricsQuery, completion: @escaping (IslLyricsResult) -> Void) {
        calls.append(query)
        queue.append((query, completion))
    }
    func answer(_ i: Int, _ r: IslLyricsResult) { queue[i].1(r) }
}

final class ExtFakeLyricsStore: IslLyricsStoring {
    var files: [String: String] = [:]
    func load(_ key: String) -> String? { files[key] }
    func save(_ key: String, text: String) { files[key] = text }
    func remove(_ key: String) { files[key] = nil }
}

final class ExtFakeHTTP: IslHTTPFetching {
    var responses: [(Int, String)] = []
    var urls: [URL] = []
    var headers: [[String: String]] = []
    func get(_ url: URL, headers: [String: String], completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void) {
        urls.append(url)
        self.headers.append(headers)
        let r = responses.isEmpty ? (500, "") : responses.removeFirst()
        completion(.success((r.0, Data(r.1.utf8))))
    }
}

private let query = IslLyricsQuery(title: "Song", artist: "Band", album: "Album", duration: 200)

@Suite struct IslLyricsEngineTests {
    private func make(_ s: IslLyrSettings = IslLyrSettings()) -> (IslLyricsEngine, ExtFakeLyricsProvider, ExtFakeLyricsStore) {
        let p = ExtFakeLyricsProvider(), st = ExtFakeLyricsStore()
        let e = IslLyricsEngine(provider: p, store: st, clock: { ExtFix.now })
        e.settings = s
        return (e, p, st)
    }

    @Test func newTrackStartsLoadingAndStoresTheAnswer() {
        let (e, p, st) = make()
        e.trackChanged(query)
        #expect(e.state == .loading && p.calls == [query])
        p.answer(0, .synced(IslLrcParser.parse("[00:10.00]a")))
        if case .ready(let l) = e.state { #expect(l.lines.count == 1) } else { Issue.record("not ready") }
        #expect(st.files[query.key]?.contains("[00:10.00]a") == true)
    }

    @Test func cachedLyricsSkipTheProvider() {
        let (e, p, st) = make()
        st.files[query.key] = "[00:10.00]cached"
        e.trackChanged(query)
        #expect(p.calls.isEmpty)
        if case .ready(let l) = e.state { #expect(l.lines[0].text == "cached") } else { Issue.record("not ready") }
    }

    @Test func staleAnswersAreIgnored() {
        let (e, p, _) = make()
        e.trackChanged(query)
        e.trackChanged(IslLyricsQuery(title: "Other", artist: "Band"))
        p.answer(0, .synced(IslLrcParser.parse("[00:10.00]old")))
        #expect(e.state == .loading)
        p.answer(1, .instrumental)
        #expect(e.state == .instrumental)
    }

    @Test func sameTrackTwiceDoesNotRefetch() {
        let (e, p, _) = make()
        e.trackChanged(query)
        e.trackChanged(query)
        #expect(p.calls.count == 1)
    }

    @Test func noTrackMeansIdle() {
        let (e, _, _) = make()
        e.trackChanged(query)
        e.trackChanged(nil)
        #expect(e.state == .idle && e.frame(at: 5) == nil)
    }

    @Test func offlineModeNeverCallsTheProvider() {
        var s = IslLyrSettings()
        s.fetchOnline = false
        let (e, p, _) = make(s)
        e.trackChanged(query)
        #expect(p.calls.isEmpty && e.state == .notFound)
    }

    @Test func notFoundIsCachedForADay() {
        let (e, p, st) = make()
        e.trackChanged(query)
        p.answer(0, .notFound)
        #expect(st.files[query.key]?.hasPrefix("#notfound") == true)
        e.trackChanged(nil)
        e.trackChanged(query)
        #expect(p.calls.count == 1 && e.state == .notFound)
    }

    @Test func staleNotFoundIsRetried() {
        let (e, p, st) = make()
        st.files[query.key] = "#notfound \(Int(ExtFix.now.timeIntervalSince1970) - 90_000)"
        e.trackChanged(query)
        #expect(p.calls.count == 1)
    }

    @Test func failuresAreNotCached() {
        let (e, p, st) = make()
        e.trackChanged(query)
        p.answer(0, .failed("net"))
        #expect(e.state == .failed("net") && st.files.isEmpty)
    }

    @Test func plainLyricsAreReadyButHaveNoFrame() {
        let (e, p, _) = make()
        e.trackChanged(query)
        p.answer(0, .plain(IslLrcParser.parse("one\ntwo")))
        if case .ready(let l) = e.state { #expect(!l.isSynced) } else { Issue.record("not ready") }
        #expect(e.frame(at: 10) == nil)
    }

    @Test func frameFollowsTheElapsedTime() {
        let (e, p, _) = make()
        e.settings.lead = 0
        e.trackChanged(query)
        p.answer(0, .synced(IslLrcParser.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")))
        #expect(e.frame(at: 5)?.index == nil && e.frame(at: 5)?.next == "a")
        let f = e.frame(at: 25)
        #expect(f?.index == 1 && f?.line == "b" && f?.next == "c" && f?.progress == 0.5)
        #expect(e.frame(at: 100)?.next == nil)
    }

    @Test func userOffsetAndLeadShiftTheFrame() {
        let (e, p, _) = make()
        e.settings.lead = 0
        e.settings.userOffset = 2
        e.trackChanged(query)
        p.answer(0, .synced(IslLrcParser.parse("[00:10.00]a\n[00:20.00]b")))
        #expect(e.frame(at: 8)?.line == "a")
        e.settings.userOffset = 0
        e.settings.lead = 0.5
        #expect(e.frame(at: 19.6)?.line == "b")
    }

    @Test func importedTextReplacesTheLyricsAndIsStored() {
        let (e, _, st) = make()
        e.trackChanged(query)
        #expect(e.importText("[00:05.00]mine"))
        if case .ready(let l) = e.state { #expect(l.lines[0].text == "mine") } else { Issue.record("not ready") }
        #expect(st.files[query.key] == "[00:05.00]mine")
    }

    @Test func importOfEmptyTextIsRejected() {
        let (e, _, _) = make()
        e.trackChanged(query)
        #expect(!e.importText("   \n"))
        let (idle, _, _) = make()
        #expect(!idle.importText("[00:05.00]x"))
    }

    @Test func clearingTheCurrentLyricsRefetches() {
        let (e, p, st) = make()
        st.files[query.key] = "[00:10.00]cached"
        e.trackChanged(query)
        e.clearCurrent()
        #expect(st.files[query.key] == nil && p.calls.count == 1 && e.state == .loading)
    }

    @Test func onChangeFiresOnEveryStateChange() {
        let (e, p, _) = make()
        var n = 0
        e.onChange = { n += 1 }
        e.trackChanged(query)
        p.answer(0, .instrumental)
        #expect(n == 2)
    }
}

@Suite struct IslLyricsCodecAndKeyTests {
    @Test func codecRoundTripsSyncedLyrics() {
        let lrc = IslLrcParser.parse("[00:10.50]a\n[01:00.00]b")
        let text = IslLyricsCodec.encode(.synced(lrc), now: ExtFix.now)!
        guard case .synced(let back)? = IslLyricsCodec.decode(text, now: ExtFix.now) else { Issue.record("decode"); return }
        #expect(back.lines.map(\.text) == ["a", "b"] && back.lines.map(\.time) == [10.5, 60])
    }

    @Test func codecRoundTripsPlainAndInstrumental() {
        let plain = IslLyricsCodec.encode(.plain(IslLrcParser.parse("x\ny")), now: ExtFix.now)!
        guard case .plain(let l)? = IslLyricsCodec.decode(plain, now: ExtFix.now) else { Issue.record("plain"); return }
        #expect(l.lines.map(\.text) == ["x", "y"])
        #expect(IslLyricsCodec.decode(IslLyricsCodec.encode(.instrumental, now: ExtFix.now)!, now: ExtFix.now) == .instrumental)
        #expect(IslLyricsCodec.encode(.failed("x"), now: ExtFix.now) == nil)
    }

    @Test func keyIgnoresCaseSpacesAndAlbum() {
        let a = IslLyricsQuery(title: " Song ", artist: "BAND", album: "One", duration: 100)
        let b = IslLyricsQuery(title: "song", artist: "band", album: "Two", duration: 300)
        #expect(a.key == b.key && a.key.hasPrefix("lyr-"))
        #expect(a.key != IslLyricsQuery(title: "other", artist: "band").key)
    }

    @Test func queryFromTrackRequiresATitle() {
        var i = IslNowPlayingInfo()
        i.title = ""
        i.artist = "x"
        #expect(IslLyricsQuery(track: IslTrack(i)) == nil && IslLyricsQuery(track: nil) == nil)
        i.title = "T"
        i.duration = 120
        #expect(IslLyricsQuery(track: IslTrack(i))?.duration == 120)
    }

    @Test func invalidDurationIsDropped() {
        #expect(IslLyricsQuery(title: "a", artist: "b", duration: -4).duration == nil)
        #expect(IslLyricsQuery(title: "a", artist: "b", duration: .nan).duration == nil)
    }

    @Test func settingsRoundTripAndClamp() {
        let kv = WndMemoryStore()
        var s = IslLyrSettings()
        s.fetchOnline = false
        s.lead = 0.5
        s.userOffset = -1.5
        IslLyrSettingsStore(kv).save(s)
        #expect(IslLyrSettingsStore(kv).load() == s)
        var bad = IslLyrSettings()
        bad.lead = 50
        bad.userOffset = 99
        #expect(bad.sanitized.lead == 2 && bad.sanitized.userOffset == 10)
    }
}

@Suite struct IslLrclibTests {
    @Test func getURLEncodesCyrillicAndSpaces() {
        let q = IslLyricsQuery(title: "Звезда по имени Солнце", artist: "Кино", album: "Группа крови", duration: 225.4)
        let url = IslLrclib.getURL(q)!
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(url.absoluteString.hasPrefix("https://lrclib.net/api/get?"))
        #expect(c.queryItems?.first { $0.name == "track_name" }?.value == "Звезда по имени Солнце")
        #expect(c.queryItems?.first { $0.name == "duration" }?.value == "225")
        #expect(!url.absoluteString.contains(" "))
    }

    @Test func getURLOmitsEmptyAlbumAndDuration() {
        let items = URLComponents(url: IslLrclib.getURL(IslLyricsQuery(title: "a", artist: "b"))!, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)
        #expect(items == ["track_name", "artist_name"])
    }

    @Test func searchURLUsesTrackAndArtist() {
        let u = IslLrclib.searchURL(IslLyricsQuery(title: "a", artist: "b"))!
        #expect(u.absoluteString.hasPrefix("https://lrclib.net/api/search?") && u.absoluteString.contains("track_name=a") && u.absoluteString.contains("artist_name=b"))
    }

    @Test func parseGetPrefersSyncedLyrics() {
        let json = #"{"id":1,"trackName":"a","duration":200,"instrumental":false,"plainLyrics":"x","syncedLyrics":"[00:01.00]x"}"#
        guard case .synced(let l) = IslLrclib.parseGet(Data(json.utf8)) else { Issue.record("not synced"); return }
        #expect(l.lines.count == 1)
    }

    @Test func parseGetFallsBackToPlain() {
        let json = #"{"plainLyrics":"one\ntwo","syncedLyrics":null,"instrumental":false}"#
        guard case .plain(let l) = IslLrclib.parseGet(Data(json.utf8)) else { Issue.record("not plain"); return }
        #expect(l.lines.map(\.text) == ["one", "two"] && !l.isSynced)
    }

    @Test func parseGetRecognizesInstrumentalAndEmpty() {
        #expect(IslLrclib.parseGet(Data(#"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#.utf8)) == .instrumental)
        #expect(IslLrclib.parseGet(Data(#"{"instrumental":false,"plainLyrics":"","syncedLyrics":""}"#.utf8)) == .notFound)
        #expect(IslLrclib.parseGet(Data(#"{"statusCode":404,"name":"TrackNotFound"}"#.utf8)) == .notFound)
    }

    @Test func parseGetRejectsGarbage() {
        if case .failed = IslLrclib.parseGet(Data("<html>".utf8)) {} else { Issue.record("expected failure") }
    }

    @Test func searchPicksTheClosestDurationWithSyncedLyrics() {
        let json = """
        [{"duration":260,"syncedLyrics":"[00:01.00]far"},
         {"duration":199,"syncedLyrics":null,"plainLyrics":"plain only"},
         {"duration":201,"syncedLyrics":"[00:01.00]near","plainLyrics":"x"},
         {"duration":200,"syncedLyrics":"[00:01.00]exact"}]
        """
        guard case .synced(let l) = IslLrclib.parseSearch(Data(json.utf8), query: query) else { Issue.record("not synced"); return }
        #expect(l.lines[0].text == "exact")
    }

    @Test func searchRejectsEverythingOutsideTheTolerance() {
        let json = #"[{"duration":300,"syncedLyrics":"[00:01.00]far"}]"#
        #expect(IslLrclib.parseSearch(Data(json.utf8), query: query) == .notFound)
    }

    @Test func searchWithoutKnownDurationTakesTheFirstSynced() {
        let json = #"[{"duration":300,"syncedLyrics":"[00:01.00]a"}]"#
        guard case .synced = IslLrclib.parseSearch(Data(json.utf8), query: IslLyricsQuery(title: "a", artist: "b")) else { Issue.record("not synced"); return }
    }

    @Test func providerUsesGetThenSearchOnMiss() {
        let http = ExtFakeHTTP()
        http.responses = [(404, #"{"statusCode":404}"#), (200, #"[{"duration":200,"syncedLyrics":"[00:01.00]found"}]"#)]
        let p = IslLrclibProvider(http: http)
        var got: IslLyricsResult?
        p.fetch(query) { got = $0 }
        #expect(http.urls.count == 2 && http.urls[0].path.hasSuffix("/get") && http.urls[1].path.hasSuffix("/search"))
        if case .synced(let l)? = got { #expect(l.lines[0].text == "found") } else { Issue.record("no result") }
        #expect(http.headers.allSatisfy { $0["User-Agent"]?.hasPrefix("Multitul/") == true })
    }

    @Test func providerStopsAfterASuccessfulGet() {
        let http = ExtFakeHTTP()
        http.responses = [(200, #"{"syncedLyrics":"[00:01.00]x"}"#)]
        var got: IslLyricsResult?
        IslLrclibProvider(http: http).fetch(query) { got = $0 }
        #expect(http.urls.count == 1)
        if case .synced? = got {} else { Issue.record("no result") }
    }

    @Test func providerReportsServerErrors() {
        let http = ExtFakeHTTP()
        http.responses = [(503, "")]
        var got: IslLyricsResult?
        IslLrclibProvider(http: http).fetch(query) { got = $0 }
        #expect(got == .failed("Сервер ответил 503"))
    }

    @Test func providerDoesNotTouchTheNetworkWithoutAnInjectedClient() {
        let http = ExtFakeHTTP()
        _ = IslLrclibProvider(http: http)
        #expect(http.urls.isEmpty)
    }
}
