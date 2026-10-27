import Testing
import Foundation
@testable import MultitulCore

private func world(_ configure: (inout CbRig) -> Void = { _ in }) -> CbWorld {
    var rig = CbRig()
    configure(&rig)
    return CbWorld(rig)
}

private let sampleApps = [CbFix.app("Telegram", bundle: "ru.keepcoder.Telegram"), CbFix.app("Terminal", bundle: "com.apple.Terminal", dir: "/System/Applications/Utilities"),
                          CbFix.app("System Settings", bundle: "com.apple.systempreferences", dir: "/System/Applications"), CbFix.app("Safari", bundle: "com.apple.Safari"),
                          CbFix.app("Sublime Text", bundle: "com.sublimetext.4"), CbFix.app("Notes", bundle: "com.apple.Notes"), CbFix.app("Notion", bundle: "notion.id")]

@Suite struct CbTriggerParseTests {
    @Test(arguments: [
        ("win safari", CbProviderID.windows, "safari"), ("w chrome", .windows, "chrome"), ("окно заметки", .windows, "заметки"), ("f report", .files, "report"),
        ("  f   report  ", .files, "report"), ("файл отчёт", .files, "отчёт"), ("clip hello", .clipboard, "hello"), ("буфер пароль", .clipboard, "пароль"), ("menu save", .menu, "save"),
        ("меню сохранить", .menu, "сохранить"), ("emoji fire", .emoji, "fire"), ("эмодзи огонь", .emoji, "огонь"), ("snip sig", .snippets, "sig"), ("kill zoom", .processes, "zoom"),
        ("убить зум", .processes, "зум"), ("завершить хром", .processes, "хром"), ("rm telegram", .uninstall, "telegram"), ("удалить телеграм", .uninstall, "телеграм"),
        ("uninstall slack", .uninstall, "slack"), ("run backup", .scripts, "backup"), ("скрипт бэкап", .scripts, "бэкап"), ("cmd lock", .commands, "lock"), ("WIN Safari", .windows, "Safari"),
        ("app note", .apps, "note")
    ])
    func wordTriggers(_ raw: String, _ p: CbProviderID, _ text: String) {
        let t = CbTriggers.parse(raw)
        #expect(t.provider == p && t.text == text, "\(raw) -> \(String(describing: t.provider)) \(t.text)")
    }

    @Test(arguments: [("= 2+2", CbProviderID.calculator, "2+2"), ("=2+2", .calculator, "2+2"), ("> lock", .commands, "lock"), (">lock", .commands, "lock"), (":smile", .emoji, "smile"),
                      (": огонь", .emoji, "огонь"), ("? swift ui", .web, "swift ui"), ("?swift", .web, "swift")])
    func symbolTriggers(_ raw: String, _ p: CbProviderID, _ text: String) {
        let t = CbTriggers.parse(raw)
        #expect(t.provider == p && t.text == text)
    }

    @Test(arguments: ["win", "w", "window safari", "files", "kill", "", "  ", "telegram", "2+2", "5 км в мили", "winner"])
    func notTriggers(_ raw: String) {
        let t = CbTriggers.parse(raw)
        #expect(t.provider == nil, "\(raw)")
        #expect(t.text == raw.trimmingCharacters(in: .whitespaces))
    }

    @Test func queryExposesForcedProviderAndFuzzyText() {
        let q = CbQuery.parse("win Safari")
        #expect(q.forced == .windows && q.text == "Safari" && !q.isEmpty && q.fuzzy.tokens == ["safari"])
        #expect(CbQuery.parse("win ").isEmpty)
    }

    @Test func providerCatalogIsConsistent() {
        for p in CbProviderID.allCases {
            #expect(p.rawValue.allSatisfy(\.isASCII) && !p.title.isEmpty && !p.symbol.isEmpty && p.weight > 0 && p.weight <= 1 && p.globalMinLength >= 1)
        }
        #expect(CbProviderID.apps.weight > CbProviderID.files.weight)
        #expect(!CbProviderID.uninstall.globalByDefault && CbProviderID.apps.globalByDefault)
    }
}

@Suite struct CbEngineRankingTests {
    @Test func appsAreRankedByMatchQuality() {
        let w = world { $0.apps.list = sampleApps }
        let t = w.titles("tel")
        #expect(t.first == "Telegram")
        #expect(t.contains("Terminal"))
    }

    @Test func russianAndAliasQueriesFindTheApp() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.titles("тг").first == "Telegram")
        #expect(w.titles("телеграм").first == "Telegram")
        #expect(w.titles("сафари").first == "Safari")
    }

    @Test func wrongLayoutFindsTheApp() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.titles("ыфафкш").first == "Safari")
        #expect(w.titles("ntktuhfv").first == "Telegram")
    }

    @Test func acronymFindsMultiWordApps() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.titles("ss").first == "System Settings")
        #expect(w.titles("st").first == "Sublime Text")
    }

    @Test func providerWeightLetsAnAppBeatAFileWithTheSameName() {
        let w = world {
            $0.apps.list = [CbFix.app("Report App")]
            $0.settings.fileFolders = ["/tmp/x"]
        }
        _ = w.search("report")
        w.rig.files.answer([CbFileHit(path: "/tmp/x/report.txt")])
        let r = w.search("report")
        #expect(r.map(\.title).prefix(2) == ["Report App", "report.txt"])
        #expect(r[0].score > r[1].score)
    }

    @Test func frecencyBreaksCloseMatches() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.titles("not").prefix(2) == ["Notes", "Notion"])
        let notion = w.search("not")[1]
        for _ in 0..<3 { w.engine.recordUse(notion) }
        #expect(w.titles("not").first == "Notion")
    }

    @Test func frecencyNeverResurrectsANonMatch() {
        let w = world { $0.apps.list = sampleApps }
        for _ in 0..<10 { w.engine.recordUse(w.search("notion")[0]) }
        #expect(!w.titles("sa").contains("Notion"))
    }

    @Test func frecencyCanBeSwitchedOff() {
        let w = world { $0.apps.list = sampleApps }
        let notion = w.search("not")[1]
        for _ in 0..<3 { w.engine.recordUse(notion) }
        w.box.value.useFrecency = false
        #expect(w.titles("not").first == "Notes")
        w.engine.recordUse(w.search("not")[0])
        #expect(w.frecency.useCount("app:com.apple.Notes") == 0)
    }

    @Test func ordinarilyRecentUseOutranksOldHeavyUse() {
        let w = world { $0.apps.list = sampleApps }
        let notes = w.search("notes")[0], notion = w.search("notion")[0]
        for _ in 0..<5 { w.engine.recordUse(notes) }
        w.rig.clock.value = CbFix.now.addingTimeInterval(90 * 86400)
        w.engine.recordUse(notion)
        #expect(w.titles("not").first == "Notion")
    }

    @Test func emptyQueryShowsOnlyWhatYouUsed() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.search("").isEmpty)
        w.engine.recordUse(w.search("safari")[0])
        #expect(w.titles("") == ["Safari"])
    }

    @Test func forcedProviderListsEverythingForAnEmptyText() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.search("app ").count == sampleApps.count)
    }

    @Test func tiesKeepSourceOrder() {
        let w = world { $0.apps.list = [CbFix.app("Alpha One"), CbFix.app("Alpha Two"), CbFix.app("Alpha Six")] }
        #expect(w.search("alpha").filter { $0.provider == .apps }.map(\.title) == ["Alpha One", "Alpha Two", "Alpha Six"])
    }

    @Test func resultsAreCappedAtMaxResults() {
        let w = world {
            $0.apps.list = (0..<30).map { CbFix.app("App \($0)") }
            $0.settings.maxResults = 7
        }
        #expect(w.search("app").count == 7)
    }

    @Test func eachResultKeepsItsScore() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("tel")
        #expect(r == r.sorted { $0.score > $1.score } || r.map(\.score) == r.map(\.score).sorted(by: >))
    }

    @Test func identicalActionsAreShownOnce() {
        let w = world {
            $0.apps.list = [CbFix.app("Notes", bundle: "com.apple.Notes")]
            $0.settings.userEntries = [CbUserEntry(title: "Мои заметки", aliases: ["notes"], target: .app("/Applications/Notes.app"))]
        }
        let r = w.search("notes")
        #expect(r.filter { $0.action.key == "openApp:/Applications/Notes.app" }.count == 1)
    }

    @Test func disabledProvidersStaySilent() {
        let w = world {
            $0.apps.list = sampleApps
            $0.settings.disabledProviders = [.apps]
        }
        #expect(w.search("telegram").allSatisfy { $0.provider != .apps })
    }

    @Test func providersOutsideTheGlobalSearchAnswerOnlyWithAPrefix() {
        let w = world {
            $0.clip.items = [CbFix.clip(1, "invoice 2024")]
            $0.settings.excludedFromGlobal = [.clipboard]
        }
        #expect(w.search("invoice").allSatisfy { $0.provider != .clipboard })
        #expect(w.search("clip invoice").contains { $0.provider == .clipboard })
    }

    @Test func prefixNeverLeaksOtherProviders() {
        let w = world {
            $0.apps.list = [CbFix.app("Telegram")]
            $0.windows.list = [CbFix.window(1, app: "Telegram", title: "Chat")]
        }
        #expect(w.search("win tel").allSatisfy { $0.provider == .windows })
        #expect(w.search("app tel").allSatisfy { $0.provider == .apps })
    }

    @Test func webFallbackComesLastAndOnlyOnce() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("tel")
        #expect(r.last?.provider == .web && r.filter { $0.provider == .web }.count == 1)
        #expect(r.last?.action == .launcher(.url("https://www.google.com/search?q=tel")))
    }

    @Test func webFallbackSurvivesTheCap() {
        let w = world {
            $0.apps.list = (0..<30).map { CbFix.app("App \($0)") }
            $0.settings.maxResults = 5
        }
        let r = w.search("app")
        #expect(r.count == 5 && r.last?.provider == .web)
    }

    @Test func webFallbackCanBeDisabledOrReplaced() {
        let w = world { $0.settings.webFallback = false }
        #expect(w.search("qwertyzx").isEmpty)
        w.box.value.webFallback = true
        w.box.value.webEngineID = "ddg"
        #expect(w.search("qwertyzx").first?.action == .launcher(.url("https://duckduckgo.com/?q=qwertyzx")))
    }

    @Test func questionMarkForcesTheWebSearch() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("? swift ui")
        #expect(r.count == 1 && r[0].action == .launcher(.url("https://www.google.com/search?q=swift%20ui")))
    }

    @Test func queryWithRussianTextIsPercentEncoded() {
        let w = world()
        let r = w.search("? привет мир")
        guard case .launcher(.url(let u))? = r.first?.action else { Issue.record("no url"); return }
        #expect(u == "https://www.google.com/search?q=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82%20%D0%BC%D0%B8%D1%80")
    }

    @Test func queryCharactersThatBreakUrlsAreEscaped() {
        let w = world()
        guard case .launcher(.url(let u))? = w.search("? a&b=c#d?e+f").first?.action else { Issue.record("no url"); return }
        #expect(u == "https://www.google.com/search?q=a%26b%3Dc%23d%3Fe%2Bf")
    }
}

@Suite struct CbCalcInTheBarTests {
    @Test func calculatorAnswersFirst() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("2+2")
        #expect(r.first?.provider == .calculator && r.first?.title == "4" && r.first?.action == .copyText("4"))
    }

    @Test func calculatorUsesTheSettings() {
        let w = world()
        #expect(w.search("1/4").first?.title == "0,25")
        w.box.value.decimalComma = false
        #expect(w.search("1/4").first?.title == "0.25")
        #expect(w.search("2000*3").first?.title == "6\u{00A0}000")
        w.box.value.grouping = false
        #expect(w.search("2000*3").first?.title == "6000")
        w.box.value.calcAngle = .degrees
        #expect(w.search("sin(90)").first?.title == "1")
    }

    @Test func calculatorOffsersPasteAndDotCopy() {
        let w = world()
        let r = w.search("1/4")[0]
        #expect(r.secondary.map(\.action) == [.pasteText("0,25"), .copyText("0.25")])
    }

    @Test func plainWordsAndNumbersAreNotCalculations() {
        let w = world { $0.apps.list = sampleApps }
        #expect(w.search("telegram").allSatisfy { $0.provider != .calculator })
        #expect(w.search("42").allSatisfy { $0.provider != .calculator })
    }

    @Test func equalsSignForcesTheCalculatorAndShowsErrors() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("= 1/0")
        #expect(r.count == 1 && r[0].title == "Деление на ноль" && r[0].action == .noop)
        #expect(w.search("= 42").first?.title == "42")
    }

    @Test func calculatorDisabled() {
        let w = world { $0.settings.disabledProviders = [.calculator] }
        #expect(w.search("2+2").allSatisfy { $0.provider != .calculator })
    }
}

@Suite struct CbUnitsInTheBarTests {
    @Test func conversionComesFirst() {
        let w = world { $0.apps.list = sampleApps }
        let r = w.search("5 км в мили")
        #expect(r.first?.provider == .units && r.first?.title == "3,106856 миль" && r.first?.action == .copyText("3,106856"))
        #expect(r.first?.subtitle.hasPrefix("Длина") == true)
    }

    @Test func suggestionsAreListedBelowTheirMainResult() {
        let w = world()
        let r = w.search("5 km").filter { $0.provider == .units }
        #expect(r.count >= 3 && r.allSatisfy { $0.title.contains(",") || $0.title.first?.isNumber == true })
    }

    @Test func currencyNeedsRatesAndSaysSo() {
        let w = world()
        let r = w.search("100 usd to eur")
        #expect(r.first?.id == "unit:rates" && r.first?.action == .refreshRates)
        w.box.value.currencyOnline = false
        #expect(w.search("100 usd to eur").first?.action == .noop)
    }

    @Test func currencyWithRates() {
        let table = CurrencyRateTable(base: "RUB", rates: ["USD": 90, "EUR": 100], date: "2026-10-22")
        let w = world { $0.rates = table }
        let r = w.search("100 usd to eur")
        #expect(r.first?.title == "90,00 EUR" && r.first?.subtitle.contains("курс на 2026-10-22") == true)
    }

    @Test func incompatibleUnitsExplainThemselves() {
        let w = world()
        let r = w.search("5 km to kg")
        #expect(r.first?.id == "unit:incompatible" && r.first?.action == .noop)
    }

    @Test func missingCurrencyIsReported() {
        let table = CurrencyRateTable(base: "RUB", rates: ["USD": 90])
        let w = world { $0.rates = table }
        #expect(w.search("100 usd to gel").first?.title == "Нет курса для GEL")
    }

    @Test func nothingFiresForPrefixedQueries() {
        let w = world()
        #expect(w.search("win 5 km to m").allSatisfy { $0.provider != .units })
    }
}

@Suite struct CbQuicklinkTests {
    @Test func keywordPlusTextSearchesTheSite() {
        let w = world()
        let r = w.search("g swift concurrency")
        #expect(r.first?.id == "ql:google:query" && r.first?.title == "Искать «swift concurrency» — Google")
        #expect(r.first?.action == .launcher(.url("https://www.google.com/search?q=swift%20concurrency")))
    }

    @Test func eachDefaultEngineBuildsAUrl() {
        for l in CbQuicklink.defaults {
            #expect(l.takesQuery && l.url(for: "test")?.absoluteString.hasSuffix("test") == true, "\(l.name)")
        }
    }

    @Test func yandexAndYoutube() {
        let w = world()
        #expect(w.search("ya погода").first?.action == .launcher(.url("https://yandex.ru/search/?text=%D0%BF%D0%BE%D0%B3%D0%BE%D0%B4%D0%B0")))
        #expect(w.search("yt lofi").first?.action == .launcher(.url("https://www.youtube.com/results?search_query=lofi")))
    }

    @Test func nameMatchOpensTheSiteItself() {
        let w = world()
        let r = w.search("youtube")
        #expect(r.first?.provider == .quicklinks && r.first?.title == "YouTube")
    }

    @Test func plainBookmarkWithoutPlaceholder() {
        let w = world { $0.settings.quicklinks.append(CbQuicklink(id: "docs", name: "Документация", keyword: "docs", template: "https://developer.apple.com/documentation")) }
        let r = w.search("документ")
        #expect(r.first?.action == .launcher(.url("https://developer.apple.com/documentation")))
    }

    @Test func templateWithBlockedSchemeIsRejected() {
        #expect(CbQuicklink(name: "x", keyword: "x", template: "javascript:alert({query})").url(for: "1") == nil)
        #expect(CbQuicklink(name: "x", keyword: "x", template: "file:///etc/{query}").url(for: "passwd") == nil)
        #expect(CbQuicklink(name: "x", keyword: "x", template: "not a url {query}").url(for: "a") == nil)
    }

    @Test func customSchemesAreAllowed() {
        #expect(CbQuicklink(name: "t", keyword: "t", template: "tg://resolve?domain={query}").url(for: "durov")?.absoluteString == "tg://resolve?domain=durov")
    }
}

@Suite struct CbSpeedTests {
    @Test func searchStaysFastOnABigIndex() {
        var rig = CbRig()
        rig.apps.list = (0..<400).map { CbFix.app("Application Number \($0) Pro") } + [CbFix.app("Telegram", bundle: "ru.keepcoder.Telegram"), CbFix.app("Safari", bundle: "com.apple.Safari")]
        rig.windows.list = (0..<80).map { CbFix.window($0, app: "App\($0 % 9)", title: "Document \($0) — draft", pid: Int32($0 % 9)) }
        rig.clip.items = (0..<50).map { CbFix.clip(Int64($0), "copied text number \($0)") }
        let w = CbWorld(rig)
        let queries = ["t", "te", "tel", "tele", "safari", "doc", "draft 5", "2+2", "5 km in mi", "тг", "ntktuhfv", "number 1", "app", "pro", "zzz"]
        _ = w.search("warm")
        let start = Date()
        let rounds = 8
        for _ in 0..<rounds { for q in queries { _ = w.search(q) } }
        let avg = Date().timeIntervalSince(start) / Double(rounds * queries.count)
        #expect(avg < 0.05, "average \(avg * 1000) ms per search")
    }

    @Test func resultsAreDeterministic() {
        var rig = CbRig()
        rig.apps.list = (0..<50).map { CbFix.app("Tool \($0 % 7) Suite") }
        let w = CbWorld(rig)
        let a = w.search("tool"), b = w.search("tool")
        #expect(a == b)
    }
}
