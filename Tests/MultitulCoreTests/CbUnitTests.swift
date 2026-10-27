import Testing
import Foundation
@testable import MultitulCore

private let rates = CurrencyRateTable(base: "RUB", rates: ["USD": 90, "EUR": 100, "GBP": 120, "CNY": 12.5, "KZT": 0.18], date: "2026-10-22", fetchedAt: 1)

private func conv(_ s: String, rates r: CurrencyRateTable? = nil) -> ConversionLine? {
    if case .converted(let l)? = UnitConverter.parse(s, rates: r) { return l }
    return nil
}

private func out(_ s: String, rates r: CurrencyRateTable? = nil) -> Double? { conv(s, rates: r)?.output }

@Suite struct CbUnitLengthMassTests {
    @Test(arguments: [("5 км в мили", 3.1068559611866697), ("1 mi to km", 1.609344), ("10 m to ft", 32.8083989501312), ("12 in to cm", 30.48), ("100 cm to m", 1.0),
                      ("1 km to m", 1000.0), ("1 yd to ft", 3.0), ("2 дюйма в мм", 50.8), ("1 морская миля в метры", 1852.0), ("5 kilometers to meters", 5000.0)])
    func length(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test(arguments: [("10 kg to lb", 22.046226218487757), ("1 lb to oz", 16.0), ("1 т в кг", 1000.0), ("500 g to kg", 0.5), ("2 фунта в кг", 0.90718474), ("1 oz to g", 28.349523125),
                      ("1000 mg to g", 1.0), ("5 кг в г", 5000.0), ("1 stone to kg", 6.35029318)])
    func mass(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test func formatsLikeAPersonWouldRead() {
        let l = conv("5 км в мили")
        #expect(l?.outputText == "3,106856")
        #expect(l?.to.symbol == "миль")
        #expect(l?.display == "3,106856 миль")
        #expect(conv("10 kg to lb")?.display == "22,04623 lb")
    }

    @Test func largeNumbersAreGrouped() {
        #expect(conv("5 km to mm")?.outputText == "5\u{00A0}000\u{00A0}000")
        #expect(conv("1 000 km to m")?.output == 1_000_000)
    }

    @Test func decimalCommaInput() {
        #expect(abs((out("1,5 km to m") ?? 0) - 1500) < 1e-9)
        #expect(abs((out("2.5 kg to g") ?? 0) - 2500) < 1e-9)
    }

    @Test func defaultsToOneWithoutANumber() {
        #expect(out("km to m") == 1000)
        #expect(out("кг в г") == 1000)
    }
}

@Suite struct CbUnitTemperatureTests {
    @Test(arguments: [("100 f в c", 37.77777777777778), ("0 c to f", 32.0), ("-40 c to f", -40.0), ("100 c to k", 373.15), ("300 k to c", 26.85), ("32 f to c", 0.0),
                      ("212 f to k", 373.15), ("20 °C to °F", 68.0), ("0 градусов цельсия в фаренгейты", 32.0), ("98.6 f to c", 37.0)])
    func temperature(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6, "\(q) -> \(String(describing: v))")
    }

    @Test func negativeAndSignedInput() {
        #expect(abs((out("-10 c to f") ?? 0) - 14) < 1e-9)
        #expect(abs((out("+10 c to f") ?? 0) - 50) < 1e-9)
    }

    @Test func cyrillicLookalikeLettersStillMeanTheTemperature() {
        let v = out("100 f в с")
        #expect(v != nil && abs(v! - 37.7777777) < 1e-4)
    }

    @Test func temperatureIsNotLinear() {
        let a = out("10 c to f") ?? 0, b = out("20 c to f") ?? 0
        #expect(abs((b - a) - 18) < 1e-9)
        #expect(abs(a - 50) < 1e-9)
    }
}

@Suite struct CbUnitOtherCategoriesTests {
    @Test(arguments: [("1 gal to l", 3.785411784), ("1 l в ml", 1000.0), ("2 cup to ml", 473.176473), ("1 tbsp to tsp", 3.0), ("1 m3 to l", 1000.0), ("1 qt to pt", 2.0), ("500 мл в л", 0.5),
                      ("1 fl oz to ml", 29.5735295625)])
    func volume(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test(arguments: [("1 acre to m2", 4046.8564224), ("1 га в м2", 10000.0), ("100 m2 to sqft", 1076.3910416709722), ("1 km2 to ha", 100.0), ("1 сотка в м2", 100.0), ("1 mi2 to km2", 2.589988110336)])
    func area(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test(arguments: [("60 mph to km/h", 96.56064), ("100 км/ч в м/с", 27.77777777777778), ("10 kn to kmh", 18.52), ("1 m/s to km/h", 3.6), ("100 kph to mph", 62.13711922373339), ("1 mach to m/s", 340.29)])
    func speed(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-6 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test(arguments: [("1 gb to mb", 1000.0), ("1 gib to mib", 1024.0), ("8 bit to byte", 1.0), ("100 mbit to mb", 12.5), ("1 мб в кб", 1000.0), ("2 TB to GB", 2000.0),
                      ("1 KiB to B", 1024.0), ("1 byte to bit", 8.0), ("1 gbit to mbit", 1000.0)])
    func data(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-9 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test(arguments: [("2 h to min", 120.0), ("1 день в часы", 24.0), ("1 week to days", 7.0), ("90 мин в часы", 1.5), ("1,5 h to s", 5400.0), ("1 year to days", 365.0),
                      ("1 месяц в дни", 30.0), ("1000 ms to s", 1.0), ("2 суток в часы", 48.0), ("3600 sec to hours", 1.0)])
    func time(_ q: String, _ expected: Double) {
        let v = out(q)
        #expect(v != nil && abs(v! - expected) < 1e-9 * max(1, abs(expected)), "\(q) -> \(String(describing: v))")
    }

    @Test func uppercaseBIsBytesButLowercaseIsNot() {
        #expect(out("1 KB to B") == 1000)
        #expect(out("1 kB to b") == nil)
    }
}

@Suite struct CbUnitParsingTests {
    @Test(arguments: ["в", "to", "in", "на", "->", "→"])
    func separatorsWork(_ sep: String) {
        #expect(out("5 km \(sep) m") == 5000)
    }

    @Test func unitNamedInIsNotConfusedWithTheSeparator() {
        let v = out("5 in in cm")
        #expect(v != nil && abs(v! - 12.7) < 1e-9)
    }

    @Test func noSpaceBetweenNumberAndUnit() {
        #expect(out("5km to m") == 5000)
        #expect(out("5км в м") == 5000)
    }

    @Test func trailingEqualsAndQuestionMarkAreIgnored() {
        #expect(out("5 km to m =") == 5000)
        #expect(out("5 km to m?") == 5000)
    }

    @Test func incompatibleCategories() {
        if case .incompatible(let a, let b)? = UnitConverter.parse("5 km to kg", rates: nil) {
            #expect(a.category == .length && b.category == .mass)
        } else { Issue.record("expected incompatible") }
    }

    @Test func nonsenseGivesNothing() {
        #expect(UnitConverter.parse("hello world", rates: nil) == nil)
        #expect(UnitConverter.parse("5 foo to bar", rates: nil) == nil)
        #expect(UnitConverter.parse("", rates: nil) == nil)
        #expect(UnitConverter.parse("42", rates: nil) == nil)
        #expect(UnitConverter.parse("km", rates: nil) == nil)
        #expect(UnitConverter.parse(String(repeating: "5 km ", count: 40), rates: nil) == nil)
    }

    @Test func incompatibleNeedsAnExplicitNumber() {
        #expect(UnitConverter.parse("km to kg", rates: nil) == nil)
    }

    @Test func bareUnitListsNeighbours() {
        guard case .suggestions(let from, let lines)? = UnitConverter.parse("5 km", rates: nil) else { Issue.record("expected suggestions"); return }
        #expect(from.id == "km")
        #expect(lines.contains { $0.to.id == "mi" } && lines.contains { $0.to.id == "m" })
        #expect(!lines.contains { $0.to.id == "km" })
        #expect(lines.allSatisfy { $0.from.category == .length })
    }

    @Test func bareTemperatureListsTheOtherTwo() {
        guard case .suggestions(_, let lines)? = UnitConverter.parse("100 c", rates: nil) else { Issue.record("expected suggestions"); return }
        #expect(Set(lines.map(\.to.id)) == ["f", "k"])
    }

    @Test func englishPluralsAndCase() {
        #expect(out("5 KM to METERS") == 5000)
        #expect(out("3 Hours to Minutes") == 180)
    }

    @Test func everyUnitAliasIsUniqueWithinItsCategory() {
        for cat in UnitCategory.allCases where cat != .currency {
            var seen: [String: String] = [:]
            for u in UnitCatalog.all where u.category == cat {
                for a in u.aliases {
                    let k = UnitText.fold(a)
                    if let prev = seen[k], prev != u.id { Issue.record("alias \(k) used by \(prev) and \(u.id) in \(cat)") }
                    seen[k] = u.id
                }
            }
        }
    }

    @Test func catalogIdsAreUniqueAsciiAndPositive() {
        let ids = UnitCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.allSatisfy(\.isASCII) })
        #expect(UnitCatalog.all.allSatisfy { $0.factor > 0 && !$0.symbolEn.isEmpty && !$0.symbolRu.isEmpty })
        for cat in UnitCategory.allCases where cat != .currency { #expect(UnitCatalog.all.contains { $0.category == cat }, "\(cat)") }
    }

    @Test func defaultsPointAtRealUnitsOfTheSameCategory() {
        for cat in UnitCategory.allCases {
            for id in UnitCatalog.defaults(for: cat) { #expect(UnitCatalog.all.first { $0.id == id }?.category == cat, "\(id)") }
        }
    }
}

@Suite struct CbCurrencyTests {
    @Test func convertsThroughTheBaseCurrency() {
        #expect(out("100 usd to eur", rates: rates) == 90)
        #expect(out("100 usd в rub", rates: rates) == 9000)
        #expect(out("1000 rub to usd", rates: rates).map { abs($0 - 11.11111111) < 1e-6 } == true)
        #expect(out("10 gbp to eur", rates: rates) == 12)
    }

    @Test func russianNamesAndSymbols() {
        #expect(out("100 долларов в евро", rates: rates) == 90)
        #expect(out("$100 в eur", rates: rates) == 90)
        #expect(out("100$ to rub", rates: rates) == 9000)
        #expect(out("50 евро в рубли", rates: rates) == 5000)
        #expect(out("1000 ₽ to $", rates: rates).map { abs($0 - 11.1111111) < 1e-4 } == true)
        #expect(out("10 юаней в рубли", rates: rates) == 125)
        #expect(out("100 тенге в рубли", rates: rates).map { abs($0 - 18) < 1e-9 } == true)
    }

    @Test func currencyIsFormattedWithTwoDecimals() {
        #expect(conv("100 usd to eur", rates: rates)?.outputText == "90,00")
        #expect(conv("100 usd to rub", rates: rates)?.outputText == "9\u{00A0}000,00")
        #expect(conv("1 rub to usd", rates: rates)?.outputText == "0,01111")
        #expect(conv("100 usd to eur", rates: rates)?.copyText == "90,00")
        #expect(conv("1 000 usd to rub", rates: rates)?.copyText == "90000,00")
    }

    @Test func withoutRatesTheAnswerIsExplicit() {
        #expect(UnitConverter.parse("100 usd to eur", rates: nil) == .ratesUnavailable)
        #expect(UnitConverter.parse("100 usd", rates: nil) == .ratesUnavailable)
    }

    @Test func aKnownCurrencyMissingFromTheTableIsReported() {
        #expect(UnitConverter.parse("100 usd to gel", rates: rates) == .ratesMissing("GEL"))
        #expect(UnitConverter.parse("100 gel to usd", rates: rates) == .ratesMissing("GEL"))
    }

    @Test func unknownThreeLetterWordsAreNotCurrencies() {
        #expect(UnitConverter.parse("100 usd to xyz", rates: rates) == nil)
        #expect(UnitConverter.parse("5 the to usd", rates: rates) == nil)
    }

    @Test func aCodeFromTheTableWorksEvenWithoutAnAlias() {
        let t = CurrencyRateTable(base: "RUB", rates: ["USD": 90, "ZZZ": 3])
        #expect(out("10 zzz to rub", rates: t) == 30)
    }

    @Test func bareCurrencyListsMajorOnes() {
        guard case .suggestions(let from, let lines)? = UnitConverter.parse("100 usd", rates: rates) else { Issue.record("expected suggestions"); return }
        #expect(from.id == "USD" && from.category == .currency)
        let ids = Set(lines.map(\.to.id))
        #expect(ids.isSubset(of: ["RUB", "EUR", "GBP", "CNY", "KZT"]) && ids.contains("RUB") && !ids.contains("USD"))
    }

    @Test func tableConvertEdgeCases() {
        #expect(rates.convert(1, from: "usd", to: "USD") == 1)
        #expect(rates.convert(1, from: "USD", to: "ABC") == nil)
        #expect(rates.has("eur") && !rates.has("abc"))
        #expect(rates.rates["RUB"] == 1)
        #expect(rates.codes.contains("USD"))
    }

    @Test func poundMassBeatsPoundSterlingByDefault() {
        #expect(conv("1 фунт в кг", rates: rates)?.output != nil)
        #expect(out("1 фунт стерлингов в рубли", rates: rates) == 120)
    }

    @Test func catalogAliasesAreFoldedAndCodesAreUnique() {
        let codes = CurrencyCatalog.all.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isASCII) })
        #expect(CurrencyCatalog.lookup("ДОЛЛАР")?.code == "USD")
        #expect(CurrencyCatalog.lookup("€")?.code == "EUR")
        #expect(CurrencyCatalog.lookup("¥")?.code == "JPY")
        #expect(CurrencyCatalog.lookup("")?.code == nil)
    }
}

private let cbrFixture = """
{"Date":"2026-10-22T11:30:00+03:00","PreviousDate":"2026-10-21T11:30:00+03:00","Timestamp":"2026-10-21T20:00:00+03:00","Valute":{
"USD":{"ID":"R01235","NumCode":"840","CharCode":"USD","Nominal":1,"Name":"Доллар США","Value":90.5,"Previous":90.1},
"KZT":{"ID":"R01335","NumCode":"398","CharCode":"KZT","Nominal":100,"Name":"Тенге","Value":18.0,"Previous":17.9},
"JPY":{"ID":"R01820","NumCode":"392","CharCode":"JPY","Nominal":100,"Name":"Иен","Value":60.0,"Previous":59.0},
"BAD":{"ID":"X","NumCode":"1","CharCode":"BADCODE","Nominal":1,"Name":"x","Value":5,"Previous":5},
"ZERO":{"ID":"Y","NumCode":"2","CharCode":"ZER","Nominal":1,"Name":"x","Value":0,"Previous":0}}}
"""

private final class CbFakeFetcher: CurrencyRatesFetching {
    var calls = 0
    var failNext = false
    var table = CurrencyRateTable(base: "RUB", rates: ["USD": 91])

    func fetch() async throws -> CurrencyRateTable {
        calls += 1
        if failNext { throw CurrencyFetchError.badResponse }
        return table
    }
}

private final class CbMemoryRatesStore: CurrencyRatesStoring {
    var saved: CurrencyRateTable?
    func load() -> CurrencyRateTable? { saved }
    func save(_ table: CurrencyRateTable) { saved = table }
}

@Suite struct CbCurrencyServiceTests {
    @Test func cbrParserDividesByNominal() throws {
        let t = try #require(CbrDailyParser.parse(Data(cbrFixture.utf8), fetchedAt: 5))
        #expect(t.rates["USD"] == 90.5)
        #expect(abs((t.rates["KZT"] ?? 0) - 0.18) < 1e-12)
        #expect(abs((t.rates["JPY"] ?? 0) - 0.6) < 1e-12)
        #expect(t.rates["RUB"] == 1)
        #expect(t.rates["BADCODE"] == nil && t.rates["ZER"] == nil)
        #expect(t.date == "2026-10-22" && t.fetchedAt == 5 && t.base == "RUB")
    }

    @Test func cbrParserRejectsGarbage() {
        #expect(CbrDailyParser.parse(Data("not json".utf8)) == nil)
        #expect(CbrDailyParser.parse(Data("{}".utf8)) == nil)
        #expect(CbrDailyParser.parse(Data("{\"Valute\":{}}".utf8)) == nil)
    }

    @Test func kvStoreRoundTrip() {
        let kv = WndMemoryStore()
        let s = KVCurrencyRatesStore(kv)
        #expect(s.load() == nil)
        s.save(rates)
        #expect(KVCurrencyRatesStore(kv).load() == rates)
        #expect(kv.values.keys.allSatisfy { $0.allSatisfy(\.isASCII) })
        kv.values[KVCurrencyRatesStore.key] = "{broken"
        #expect(s.load() == nil)
    }

    @Test func freshTableIsNotFetchedAgain() async {
        let f = CbFakeFetcher(), st = CbMemoryRatesStore()
        var t = rates
        t.fetchedAt = 1000
        st.saved = t
        let svc = CurrencyRatesService(fetcher: f, store: st, ttl: 3600) { Date(timeIntervalSince1970: 1500) }
        #expect(!svc.isStale)
        #expect(await svc.refresh() == .fresh)
        #expect(f.calls == 0)
    }

    @Test func staleOrMissingTableIsFetchedAndPersisted() async {
        let f = CbFakeFetcher(), st = CbMemoryRatesStore()
        let now = Date(timeIntervalSince1970: 100_000)
        let svc = CurrencyRatesService(fetcher: f, store: st, ttl: 3600) { now }
        #expect(svc.isStale && svc.table == nil)
        #expect(await svc.refresh() == .updated)
        #expect(f.calls == 1)
        #expect(svc.table?.rates["USD"] == 91 && svc.table?.fetchedAt == 100_000)
        #expect(st.saved?.fetchedAt == 100_000)
        #expect(!svc.isStale)
    }

    @Test func failureBacksOffForTenMinutes() async {
        let f = CbFakeFetcher(), st = CbMemoryRatesStore()
        let clock = WndBox(Date(timeIntervalSince1970: 0))
        let svc = CurrencyRatesService(fetcher: f, store: st, ttl: 3600) { clock.value }
        f.failNext = true
        guard case .failed = await svc.refresh() else { Issue.record("expected failure"); return }
        clock.value = Date(timeIntervalSince1970: 300)
        #expect(await svc.refresh() == .backingOff)
        #expect(f.calls == 1)
        clock.value = Date(timeIntervalSince1970: 700)
        f.failNext = false
        #expect(await svc.refresh() == .updated)
        #expect(f.calls == 2)
    }

    @Test func forceIgnoresTtlAndBackoff() async {
        let f = CbFakeFetcher(), st = CbMemoryRatesStore()
        let svc = CurrencyRatesService(fetcher: f, store: st, ttl: 3600) { Date(timeIntervalSince1970: 10) }
        _ = await svc.refresh()
        #expect(await svc.refresh() == .fresh)
        #expect(await svc.refresh(force: true) == .updated)
        #expect(f.calls == 2)
    }

    @Test func emptyTableFromTheFetcherIsAFailure() async {
        let f = CbFakeFetcher(), st = CbMemoryRatesStore()
        f.table = CurrencyRateTable(base: "RUB", rates: [:])
        f.table.rates = [:]
        let svc = CurrencyRatesService(fetcher: f, store: st) { Date(timeIntervalSince1970: 10) }
        guard case .failed = await svc.refresh() else { Issue.record("expected failure"); return }
        #expect(st.saved == nil)
    }

    @Test func serviceLoadsThePersistedTableAtStart() {
        let st = CbMemoryRatesStore()
        st.saved = rates
        let svc = CurrencyRatesService(fetcher: CbFakeFetcher(), store: st) { Date(timeIntervalSince1970: 1_000_000) }
        #expect(svc.table == rates && svc.isStale)
        #expect(svc.age == 999_999)
    }
}
