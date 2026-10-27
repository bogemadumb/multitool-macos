import Foundation

public struct CurrencyRateTable: Equatable, Sendable, Codable {
    public var base: String
    public var rates: [String: Double]
    public var date: String?
    public var fetchedAt: Double

    public init(base: String = "RUB", rates: [String: Double], date: String? = nil, fetchedAt: Double = 0) {
        self.base = base
        var r = rates
        r[base] = 1
        self.rates = r
        self.date = date
        self.fetchedAt = fetchedAt
    }

    public func has(_ code: String) -> Bool { rates[code.uppercased()] != nil }

    public var codes: [String] { rates.keys.sorted() }

    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let a = rates[from.uppercased()], let b = rates[to.uppercased()], a > 0, b > 0 else { return nil }
        let r = amount * a / b
        return r.isFinite ? r : nil
    }
}

public enum CbrDailyParser {
    // Shape of the cbr-xml-daily.ru mirror: {"Date": ..., "Valute": {"USD": {"CharCode": "USD", "Nominal": 1, "Value": 90.1}}}.
    public static func parse(_ data: Data, fetchedAt: Double = 0) -> CurrencyRateTable? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let valute = root["Valute"] as? [String: Any], !valute.isEmpty else { return nil }
        var rates: [String: Double] = [:]
        for (key, raw) in valute {
            guard let d = raw as? [String: Any] else { continue }
            let code = ((d["CharCode"] as? String) ?? key).uppercased()
            let nominal = (d["Nominal"] as? NSNumber)?.doubleValue ?? 1
            guard let value = (d["Value"] as? NSNumber)?.doubleValue, value > 0, nominal > 0, code.count == 3 else { continue }
            rates[code] = value / nominal
        }
        guard !rates.isEmpty else { return nil }
        var date: String?
        if let raw = root["Date"] as? String { date = String(raw.prefix(10)) }
        return CurrencyRateTable(base: "RUB", rates: rates, date: date, fetchedAt: fetchedAt)
    }
}

public protocol CurrencyRatesFetching: AnyObject {
    func fetch() async throws -> CurrencyRateTable
}

public protocol CurrencyRatesStoring: AnyObject {
    func load() -> CurrencyRateTable?
    func save(_ table: CurrencyRateTable)
}

public final class KVCurrencyRatesStore: CurrencyRatesStoring {
    public static let key = "commandBar.currencyRates"
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    public func load() -> CurrencyRateTable? {
        guard let s = kv.object(forKey: Self.key) as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CurrencyRateTable.self, from: d)
    }

    public func save(_ table: CurrencyRateTable) {
        guard let d = try? JSONEncoder().encode(table), let s = String(data: d, encoding: .utf8) else { return }
        kv.set(s, forKey: Self.key)
    }
}

public enum CurrencyRefreshOutcome: Equatable, Sendable {
    case fresh
    case updated
    case backingOff
    case busy
    case failed(String)
}

public final class CurrencyRatesService {
    public static let defaultTTL: TimeInterval = 6 * 3600
    public static let retryDelay: TimeInterval = 600

    private let fetcher: CurrencyRatesFetching
    private let store: CurrencyRatesStoring
    private let clock: () -> Date
    private let ttl: TimeInterval
    private var inFlight = false
    private var lastFailure: Date?
    public private(set) var table: CurrencyRateTable?

    public init(fetcher: CurrencyRatesFetching, store: CurrencyRatesStoring, ttl: TimeInterval = CurrencyRatesService.defaultTTL, clock: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        self.store = store
        self.ttl = ttl
        self.clock = clock
        table = store.load()
    }

    public var age: TimeInterval? { table.map { clock().timeIntervalSince1970 - $0.fetchedAt } }

    public var isStale: Bool { age.map { $0 >= ttl } ?? true }

    public func refresh(force: Bool = false) async -> CurrencyRefreshOutcome {
        if inFlight { return .busy }
        if !force {
            if !isStale { return .fresh }
            if let f = lastFailure, clock().timeIntervalSince(f) < Self.retryDelay { return .backingOff }
        }
        inFlight = true
        defer { inFlight = false }
        do {
            var t = try await fetcher.fetch()
            t.fetchedAt = clock().timeIntervalSince1970
            guard !t.rates.isEmpty else { throw CurrencyFetchError.empty }
            table = t
            store.save(t)
            lastFailure = nil
            return .updated
        } catch {
            lastFailure = clock()
            return .failed("\(error)")
        }
    }
}

public enum CurrencyFetchError: Error, Equatable {
    case empty
    case badResponse
}

public struct CurrencyDef: Equatable, Sendable {
    public var code: String
    public var symbol: String
    public var aliases: [String]
}

public enum CurrencyCatalog {
    private static func c(_ code: String, _ symbol: String, _ aliases: String) -> CurrencyDef {
        CurrencyDef(code: code, symbol: symbol, aliases: aliases.split(separator: "|").map(String.init))
    }

    public static let all: [CurrencyDef] = [
        c("USD", "$", "usd|$|us$|доллар|доллара|долларов|доллары|долл|dollar|dollars|бакс|баксов|баксы|bucks"),
        c("EUR", "€", "eur|€|евро|euro|euros"),
        c("RUB", "₽", "rub|₽|руб|рубль|рубля|рублей|рубли|ruble|rubles|rouble|roubles|р"),
        c("GBP", "£", "gbp|£|фунт стерлингов|фунта стерлингов|фунты стерлингов|pound sterling|pounds sterling|sterling|британский фунт"),
        c("CNY", "¥", "cny|rmb|юань|юаня|юаней|юани|yuan|renminbi"),
        c("JPY", "¥", "jpy|иена|иены|иен|йена|йены|йен|yen|¥"),
        c("CHF", "CHF", "chf|франк|франка|франков|франки|швейцарский франк|swiss franc|franc|francs"),
        c("KZT", "₸", "kzt|₸|тенге|tenge"),
        c("UAH", "₴", "uah|₴|гривна|гривны|гривен|гривну|hryvnia"),
        c("BYN", "Br", "byn|белорусский рубль|белорусских рублей|белорусские рубли"),
        c("TRY", "₺", "try|₺|лира|лиры|лир|турецкая лира|turkish lira|lira"),
        c("INR", "₹", "inr|₹|рупия|рупии|рупий|indian rupee|rupee|rupees"),
        c("AED", "AED", "aed|дирхам|дирхама|дирхамов|dirham|dirhams"),
        c("PLN", "zł", "pln|zł|злотый|злотых|злотого|zloty"),
        c("CZK", "Kč", "czk|kč|чешская крона|чешских крон|крона|кроны|крон"),
        c("SEK", "kr", "sek|шведская крона|шведских крон"),
        c("NOK", "kr", "nok|норвежская крона|норвежских крон"),
        c("DKK", "kr", "dkk|датская крона|датских крон"),
        c("KRW", "₩", "krw|₩|вона|воны|вон|won"),
        c("THB", "฿", "thb|฿|бат|бата|батов|baht"),
        c("BRL", "R$", "brl|r$|реал|реала|реалов|real|reais"),
        c("CAD", "C$", "cad|канадский доллар|канадских долларов|canadian dollar"),
        c("AUD", "A$", "aud|австралийский доллар|австралийских долларов|australian dollar"),
        c("HKD", "HK$", "hkd|гонконгский доллар|гонконгских долларов|hong kong dollar"),
        c("SGD", "S$", "sgd|сингапурский доллар|сингапурских долларов|singapore dollar"),
        c("GEL", "₾", "gel|₾|лари"),
        c("AMD", "֏", "amd|драм|драма|драмов|dram"),
        c("AZN", "₼", "azn|₼|манат|маната|манатов|manat"),
        c("UZS", "so'm", "uzs|узбекский сум|узбекских сумов|сум|сума|сумов"),
        c("KGS", "с", "kgs|киргизский сом|киргизских сомов|сом|сома|сомов"),
        c("MDL", "L", "mdl|молдавский лей|молдавских лей|лей"),
        c("TJS", "SM", "tjs|сомони"),
        c("BGN", "лв", "bgn|лев|лева|левов|lev"),
        c("RON", "lei", "ron|румынский лей|румынских лей"),
        c("HUF", "Ft", "huf|форинт|форинта|форинтов|forint"),
        c("ZAR", "R", "zar|рэнд|рэнда|рэндов|rand"),
        c("EGP", "E£", "egp|египетский фунт|египетских фунтов"),
        c("IDR", "Rp", "idr|рупия индонезийская|индонезийская рупия|индонезийских рупий"),
        c("VND", "₫", "vnd|₫|донг|донга|донгов|dong"),
        c("MXN", "Mex$", "mxn|мексиканское песо|песо|peso|pesos")
    ]

    static let byAlias: [String: [CurrencyDef]] = {
        var m: [String: [CurrencyDef]] = [:]
        for d in all { for a in d.aliases { m[UnitText.fold(a), default: []].append(d) } }
        return m
    }()

    public static func lookup(_ text: String) -> CurrencyDef? {
        let f = UnitText.fold(text)
        if f.isEmpty { return nil }
        if let r = byAlias[f]?.first { return r }
        if f.count == 3, f.allSatisfy({ $0.isASCII && $0.isLetter }) { return CurrencyDef(code: f.uppercased(), symbol: f.uppercased(), aliases: [f]) }
        return nil
    }

    public static func name(of code: String) -> String { all.first { $0.code == code }?.symbol ?? code }
}
