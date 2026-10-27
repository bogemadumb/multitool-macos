import Testing
import Foundation
@testable import MultitulCore

private func sc(_ q: String, _ c: String) -> FuzzyScore? { Fuzzy.score(q, in: c) }

@Suite struct CbFuzzyMatchTests {
    @Test func exactBeatsPrefixBeatsWordBeatsSubstring() {
        let exact = sc("telegram", "Telegram")
        let prefix = sc("tel", "Telegram")
        let word = sc("studio", "Visual Studio Code")
        let sub = sc("gram", "Telegram")
        #expect(exact?.kind == .exact && prefix?.kind == .prefix && word?.kind == .wordPrefix && sub?.kind == .substring)
        #expect(exact!.value > prefix!.value && prefix!.value > word!.value && word!.value > sub!.value)
    }

    @Test func acronymsCoverWordsAndCamelCase() {
        #expect(sc("vsc", "Visual Studio Code")?.kind == .acronym)
        #expect(sc("ps", "PhotoShop")?.kind == .acronym)
        #expect(sc("vs", "Visual Studio Code")?.kind == .acronym)
        #expect(sc("fc", "Final Cut Pro")?.kind == .acronym)
        #expect(sc("vsc", "Visual Studio Code")!.value > sc("vsc", "vscode helper tool")!.value - 30)
    }

    @Test func fullAcronymScoresHigherThanPartialOne() {
        #expect(sc("vsc", "Visual Studio Code")!.value > sc("vs", "Visual Studio Code")!.value)
    }

    @Test func subsequenceIsTheLastResort() {
        let s = sc("tlgrm", "Telegram")
        #expect(s?.kind == .subsequence)
        #expect(s!.value < sc("gram", "Telegram")!.value)
        #expect(sc("xyz", "Telegram") == nil)
        #expect(sc("tgl", "Telegram") == nil)
    }

    @Test func subsequenceMustBeCompact() {
        #expect(sc("abz", "a long long long long long long long long long name with b and z") == nil)
        #expect(sc("sfr", "Safari") != nil)
    }

    @Test func singleCharactersNeverMatchLoosely() {
        #expect(sc("q", "Telegram") == nil)
        #expect(sc("t", "Telegram")?.kind == .prefix)
        #expect(sc("m", "Telegram")?.kind == .substring)
    }

    @Test func caseDiacriticsAndYoAreFolded() {
        #expect(sc("CAFE", "Café")?.kind == .exact)
        #expect(sc("елка", "Ёлка")?.kind == .exact)
        #expect(sc("TELEGRAM", "telegram")?.kind == .exact)
        #expect(sc("cafe", "CAFÉ du Monde")?.kind == .prefix)
    }

    @Test func cyrillicQueries() {
        #expect(sc("тел", "Телеграм")?.kind == .prefix)
        #expect(sc("граф", "Фото графика")?.kind == .wordPrefix)
        #expect(sc("зам", "Заметки")?.kind == .prefix)
    }

    @Test func multiTokenQueriesNeedEveryToken() {
        #expect(sc("visual code", "Visual Studio Code") != nil)
        #expect(sc("code visual", "Visual Studio Code") != nil)
        #expect(sc("visual zzz", "Visual Studio Code") == nil)
        #expect(sc("visual studio", "Visual Studio Code")!.value > sc("visual code", "Visual Studio Code")!.value - 25)
    }

    @Test func digitsSplitWords() {
        #expect(Fuzzy.words("Xcode15Beta") == ["Xcode", "15", "Beta"])
        #expect(Fuzzy.words("iPhone-Backup_2024") == ["i", "Phone", "Backup", "2024"] || Fuzzy.words("iPhone-Backup_2024").count >= 3)
        #expect(Fuzzy.words("hello world") == ["hello", "world"])
        #expect(Fuzzy.words("") == [])
    }

    @Test func normalizeCollapsesWhitespace() {
        #expect(Fuzzy.normalize("  Hello   WORLD ") == "hello world")
        #expect(Fuzzy.normalize("Ёж") == "еж")
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(sc("", "Telegram") == nil)
        #expect(sc("   ", "Telegram") == nil)
        #expect(FuzzyQuery("  ").isEmpty)
    }
}

@Suite struct CbFuzzyLayoutTests {
    @Test func russianTextTypedOnEnglishLayout() {
        let s = sc("ntktuhfv", "Телеграм")
        #expect(s?.kind == .exact)
        #expect(sc("ntkt", "Телеграм")?.kind == .prefix)
        #expect(s!.value < sc("телеграм", "Телеграм")!.value)
    }

    @Test func englishTextTypedOnRussianLayout() {
        #expect(sc("ыфафкш", "Safari")?.kind == .exact)
        #expect(sc("ыфаф", "Safari")?.kind == .prefix)
        #expect(sc("руддщ", "Hello")?.kind == .exact)
    }

    @Test func swappedMatchIsPenalised() {
        let direct = sc("safari", "Safari")!.value
        let swapped = sc("ыфафкш", "Safari")!.value
        #expect(abs(swapped - direct * Fuzzy.layoutPenalty) < 1e-9 || swapped < direct)
    }

    @Test func layoutSwapRoundTrips() {
        #expect(KeyboardLayoutSwap.swapped("ghbdtn") == "привет")
        #expect(KeyboardLayoutSwap.swapped("привет") == "ghbdtn")
        #expect(KeyboardLayoutSwap.swapped("123") == nil)
    }

    @Test func plainDigitsDoNotSwap() {
        #expect(FuzzyQuery("123").swapped == nil)
        #expect(FuzzyQuery("telegram").swapped != nil)
    }

    @Test func aWordThatIsReallyBothScriptsKeepsTheDirectMatch() {
        #expect(sc("tel", "Telegram")?.kind == .prefix)
    }
}

@Suite struct CbFuzzyRankingTests {
    private func ranked(_ q: String, _ names: [String]) -> [String] {
        let fq = FuzzyQuery(q)
        let keys = names.map { FuzzyKey($0) }
        return names.indices.compactMap { i in Fuzzy.score(fq, keys[i]).map { (i, $0.value) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map { names[$0.0] }
    }

    @Test func prefixWinsOverEverythingElse() {
        #expect(ranked("tel", ["Skype Telephone", "Telegram", "Intel Power Gadget", "Terminal"]).first == "Telegram")
    }

    @Test func tiesKeepTheOriginalOrder() {
        #expect(ranked("app", ["Apple Mail", "Apple Maps", "Apple Wave"]) == ["Apple Mail", "Apple Maps", "Apple Wave"])
        #expect(ranked("app", ["Apple Wave", "Apple Maps", "Apple Mail"]) == ["Apple Wave", "Apple Maps", "Apple Mail"])
    }

    @Test func shorterNameWinsAmongPrefixMatches() {
        #expect(ranked("safari", ["Safari Technology Preview", "Safari"]).first == "Safari")
        #expect(ranked("note", ["Notes Pro Edition", "Notes"]).first == "Notes")
    }

    @Test func nonMatchesAreDropped() {
        #expect(ranked("zzz", ["Safari", "Notes"]) == [])
    }

    @Test func secondaryKeysCountALittleLess() {
        let q = FuzzyQuery("tg")
        let direct = Fuzzy.best(q, [FuzzyKey("tg"), FuzzyKey("Telegram")])!.value
        let viaAlias = Fuzzy.best(q, [FuzzyKey("Telegram"), FuzzyKey("tg")])!.value
        #expect(direct > viaAlias)
        #expect(abs(viaAlias - 100 * Fuzzy.secondaryKeyPenalty) < 1e-9)
    }

    @Test func bestPicksTheStrongestKey() {
        let q = FuzzyQuery("code")
        #expect(Fuzzy.best(q, [FuzzyKey("Visual Studio"), FuzzyKey("Code Editor")])?.kind == .prefix)
        #expect(Fuzzy.best(q, []) == nil)
    }
}

@Suite struct CbFrecencyTests {
    private func index(_ clock: WndBox<Date>, _ store: FrecencyStoring = MemoryFrecencyStore(), _ cfg: FrecencyConfig = FrecencyConfig()) -> FrecencyIndex {
        FrecencyIndex(store: store, config: cfg) { clock.value }
    }

    @Test func unknownKeysHaveNoBoost() {
        let f = index(WndBox(Date()))
        #expect(f.boost("app:x") == 0 && f.score("app:x") == 0 && f.useCount("app:x") == 0)
    }

    @Test func firstUseGivesTheBaseBoost() {
        let f = index(WndBox(Date()))
        f.record("a")
        #expect(abs(f.boost("a") - f.config.weight) < 1e-3)
    }

    @Test func boostGrowsWithUsesButSaturates() {
        let f = index(WndBox(Date()))
        var last = 0.0
        for _ in 0..<20 {
            f.record("a")
            let b = f.boost("a")
            #expect(b >= last)
            last = b
        }
        #expect(last == f.config.maxBoost)
    }

    @Test func usesDecayWithHalfLife() {
        let clock = WndBox(Date(timeIntervalSince1970: 1_000_000))
        let f = index(clock)
        f.record("a")
        let fresh = f.score("a")
        clock.value = clock.value.addingTimeInterval(14 * 86400)
        #expect(abs(f.score("a") - fresh / 2) < 1e-6)
        clock.value = clock.value.addingTimeInterval(14 * 86400)
        #expect(abs(f.score("a") - fresh / 4) < 1e-6)
    }

    @Test func recentUseBeatsManyOldUses() {
        let clock = WndBox(Date(timeIntervalSince1970: 10_000_000))
        let f = index(clock)
        for _ in 0..<3 { f.record("old") }
        clock.value = clock.value.addingTimeInterval(60 * 86400)
        f.record("new")
        #expect(f.boost("new") > f.boost("old"))
    }

    @Test func historyPerKeyIsCapped() {
        let store = MemoryFrecencyStore()
        let f = index(WndBox(Date()), store)
        for _ in 0..<60 { f.record("a") }
        #expect(f.useCount("a") == f.config.maxPerKey && store.data["a"]?.count == f.config.maxPerKey)
    }

    @Test func forgetAndClear() {
        let store = MemoryFrecencyStore()
        let f = index(WndBox(Date()), store)
        f.record("a"); f.record("b")
        f.forget("a")
        #expect(f.boost("a") == 0 && f.boost("b") > 0 && store.data["a"] == nil)
        f.clear()
        #expect(f.knownKeys.isEmpty && store.data.isEmpty)
    }

    @Test func emptyKeysAreIgnored() {
        let f = index(WndBox(Date()))
        f.record("")
        #expect(f.knownKeys.isEmpty)
    }

    @Test func indexLoadsWhatTheStoreHolds() {
        let now = Date().timeIntervalSince1970
        let f = index(WndBox(Date()), MemoryFrecencyStore(["a": [now - 10, now - 5]]))
        #expect(f.useCount("a") == 2 && f.boost("a") > 0)
    }

    @Test func sqliteStoreRoundTripAndCap() throws {
        let path = tempDBPath()
        let s = try SQLiteFrecencyStore.open(path: path)
        for i in 0..<30 { s.append(key: "a", at: 1_000_000 + Double(i), keep: 20) }
        s.append(key: "b", at: 5, keep: 20)
        let loaded = SQLiteFrecencyStore(store: try CommandBarSchema.openStore(path: path)).load()
        #expect(loaded["a"]?.count == 20 && loaded["a"]?.first == 1_000_010 && loaded["b"] == [5])
        s.remove(key: "a")
        #expect(s.load()["a"] == nil && s.load()["b"] != nil)
        s.removeAll()
        #expect(s.load().isEmpty)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    @Test func schemaIsLatinAndRetained() {
        #expect(CommandBarSchema.migrations.allSatisfy { $0.sql.allSatisfy(\.isASCII) && $0.scope == "commandbar" })
        #expect(CommandBarSchema.retention.first?.table == "cb_usage")
    }
}

@Suite struct CbEmojiTests {
    @Test func tableIsBigEnoughAndUnique() {
        #expect(EmojiTable.all.count >= 250)
        #expect(Set(EmojiTable.all.map(\.emoji)).count == EmojiTable.all.count)
        #expect(EmojiTable.all.allSatisfy { !$0.ru.isEmpty && !$0.en.isEmpty })
    }

    @Test(arguments: [("улыбка", "😀"), ("smile", "😀"), ("огонь", "🔥"), ("fire", "🔥"), ("сердце", "❤️"), ("heart", "❤️"), ("кот", "🐱"), ("cat", "🐱"), ("пицца", "🍕"),
                      ("rocket", "🚀"), ("ракета", "🚀"), ("лайк", "👍"), ("thumbs", "👍"), ("череп", "💀"), ("робот", "🤖"), ("кофе", "☕")])
    func findsByRussianAndEnglishKeyword(_ q: String, _ expected: String) {
        let found = EmojiTable.search(q).map(\.emoji)
        #expect(found.contains(expected), "\(q) -> \(found)")
    }

    @Test func primaryKeywordRanksFirst() {
        #expect(EmojiTable.search("огонь").first?.emoji == "🔥")
        #expect(EmojiTable.search("pizza").first?.emoji == "🍕")
    }

    @Test func prefixOfAKeywordMatches() {
        #expect(EmojiTable.search("раке").map(\.emoji).contains("🚀"))
        #expect(EmojiTable.search("rock").map(\.emoji).contains("🚀") || EmojiTable.search("rock").map(\.emoji).contains("🤘"))
    }

    @Test func wrongLayoutStillFindsTheEmoji() {
        #expect(EmojiTable.search("jujym").map(\.emoji).contains("🔥"))
    }

    @Test func pastedEmojiFindsItself() {
        #expect(EmojiTable.search("🔥").first?.emoji == "🔥")
    }

    @Test func unrelatedTextFindsNothing() {
        #expect(EmojiTable.search("qwertyzxcv").isEmpty)
        #expect(EmojiTable.search("").isEmpty)
    }

    @Test func limitIsRespected() {
        #expect(EmojiTable.search("е", limit: 5).count <= 5)
        #expect(EmojiTable.scored("сердце", limit: 3).count <= 3)
    }

    @Test func scoresAreBounded() {
        for hit in EmojiTable.scored("сердце") { #expect(hit.score > 0 && hit.score <= 100) }
    }

    @Test func titlesAreCapitalisedRussianNames() {
        #expect(EmojiTable.all.first { $0.emoji == "🔥" }?.title == "Огонь")
        #expect(EmojiEntry(emoji: "x", ru: [], en: ["only"]).title == "only")
    }
}
