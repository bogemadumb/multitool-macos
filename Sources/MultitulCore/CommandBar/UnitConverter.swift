import Foundation

public struct UnitRef: Equatable, Sendable {
    public var id: String
    public var symbol: String
    public var category: UnitCategory
}

public struct ConversionLine: Equatable, Sendable {
    public var from: UnitRef
    public var to: UnitRef
    public var input: Double
    public var output: Double
    public var inputText: String
    public var outputText: String
    public var copyText: String

    public var display: String { "\(outputText) \(to.symbol)" }
    public var expression: String { "\(inputText) \(from.symbol) = \(outputText) \(to.symbol)" }
}

public enum UnitQueryResult: Error, Equatable, Sendable {
    case converted(ConversionLine)
    case suggestions(from: UnitRef, lines: [ConversionLine])
    case incompatible(UnitRef, UnitRef)
    case ratesUnavailable
    case ratesMissing(String)
}

public enum UnitFormat {
    public static func number(_ v: Double, currency: Bool, decimalComma: Bool = true, grouping: Bool = true) -> String {
        if currency {
            let a = abs(v)
            if a >= 1 || a == 0 {
                let rounded = (v * 100).rounded() / 100
                var o = CalcFormatOptions(decimalComma: decimalComma, grouping: grouping, significantDigits: 15)
                o.significantDigits = 15
                var s = CalcFormat.format(rounded, o)
                let sep = decimalComma ? "," : "."
                if let r = s.range(of: sep) {
                    let frac = s[r.upperBound...]
                    if frac.count == 1 { s += "0" }
                } else if !s.contains("e") {
                    s += sep + "00"
                }
                return s
            }
            return CalcFormat.format(v, CalcFormatOptions(decimalComma: decimalComma, grouping: grouping, significantDigits: 4))
        }
        return CalcFormat.format(v, CalcFormatOptions(decimalComma: decimalComma, grouping: grouping, significantDigits: 7))
    }
}

public enum UnitConverter {
    static let separators: Set<String> = ["в", "to", "in", "into", "as", "на", "->", "=>", "→", "="]
    static let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₽", "₴", "₸", "₺", "₹"]
    static let maxLength = 120

    struct Candidate {
        var unit: UnitDef?
        var currency: CurrencyDef?
        var category: UnitCategory { unit?.category ?? .currency }
    }

    static func resolve(_ text: String, rates: CurrencyRateTable?) -> [Candidate] {
        var out: [Candidate] = UnitCatalog.lookup(text).map { Candidate(unit: $0, currency: nil) }
        if let c = CurrencyCatalog.lookup(text), CurrencyCatalog.all.contains(where: { $0.code == c.code }) || (rates?.has(c.code) ?? false) {
            out.append(Candidate(unit: nil, currency: c))
        }
        return out
    }

    static func ref(_ c: Candidate, cyrillic: Bool) -> UnitRef {
        if let u = c.unit { return UnitRef(id: u.id, symbol: u.symbol(cyrillic: cyrillic), category: u.category) }
        let cur = c.currency!
        return UnitRef(id: cur.code, symbol: cur.code, category: .currency)
    }

    static func leadingNumber(_ s: String) -> (value: Double, text: String, rest: String)? {
        let chars = Array(s)
        var i = 0
        var sign = 1.0
        var signText = ""
        if i < chars.count, chars[i] == "-" || chars[i] == "−" || chars[i] == "+" {
            if chars[i] != "+" { sign = -1; signText = "-" }
            i += 1
        }
        guard i < chars.count, CalcLexer.isDigit(chars[i]) || ((chars[i] == "." || chars[i] == ",") && i + 1 < chars.count && CalcLexer.isDigit(chars[i + 1])) else { return nil }
        let lowered = Array(String(chars).lowercased())
        guard let (v, end) = CalcLexer.scanNumber(lowered, i) else { return nil }
        let rest = String(chars[end...])
        return (v * sign, signText + String(chars[i..<end]), rest)
    }

    public static func parse(_ raw: String, rates: CurrencyRateTable?, decimalComma: Bool = true) -> UnitQueryResult? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        while text.hasSuffix("?") || text.hasSuffix("=") { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        if let f = text.first, currencySymbols.contains(f), let lead = leadingNumber(String(text.dropFirst())) {
            text = lead.text + " " + String(f) + lead.rest
        }
        var value = 1.0
        var valueText = "1"
        var explicit = false
        var rest = text
        if let n = leadingNumber(text) {
            value = n.value
            valueText = n.text
            rest = n.rest.trimmingCharacters(in: .whitespaces)
            explicit = true
        }
        guard !rest.isEmpty else { return nil }
        let tokens = rest.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)

        var incompatible: UnitQueryResult?
        var ratesIssue: UnitQueryResult?
        var hadSeparator = false
        for k in tokens.indices where k > 0 && k < tokens.count - 1 && separators.contains(tokens[k].lowercased()) {
            hadSeparator = true
            let left = tokens[..<k].joined(separator: " ")
            let right = tokens[(k + 1)...].joined(separator: " ")
            let l = resolve(left, rates: rates), r = resolve(right, rates: rates)
            if l.isEmpty || r.isEmpty { continue }
            let cyr = UnitText.hasCyrillic(right)
            if let pair = pairUp(l, r) {
                switch finish(value, valueText, pair.0, pair.1, cyr: cyr, rates: rates, decimalComma: decimalComma) {
                case .success(let line): return .converted(line)
                case .failure(let issue): ratesIssue = issue
                }
            } else if incompatible == nil, explicit {
                incompatible = .incompatible(ref(l[0], cyrillic: UnitText.hasCyrillic(left)), ref(r[0], cyrillic: cyr))
            }
        }
        if let i = ratesIssue { return i }
        if let i = incompatible { return i }
        if hadSeparator { return nil }

        guard explicit, rest.count <= 24 else { return nil }
        let cyr = UnitText.hasCyrillic(rest)
        let from = resolve(rest, rates: rates)
        guard let src = from.first(where: { $0.unit != nil }) ?? from.first else { return nil }
        if src.unit == nil {
            guard let t = rates else { return .ratesUnavailable }
            guard t.has(src.currency!.code) else { return .ratesMissing(src.currency!.code) }
            var lines: [ConversionLine] = []
            for code in ["RUB", "USD", "EUR", "GBP", "CNY", "KZT"] where code != src.currency!.code && t.has(code) {
                if let cand = CurrencyCatalog.lookup(code), case .success(let line) = finish(value, valueText, src, Candidate(unit: nil, currency: cand), cyr: cyr, rates: t, decimalComma: decimalComma) {
                    lines.append(line)
                }
            }
            return lines.isEmpty ? nil : .suggestions(from: ref(src, cyrillic: cyr), lines: lines)
        }
        let unit = src.unit!
        var lines: [ConversionLine] = []
        for id in UnitCatalog.defaults(for: unit.category) where id != unit.id {
            guard let target = UnitCatalog.all.first(where: { $0.id == id }) else { continue }
            if case .success(let line) = finish(value, valueText, src, Candidate(unit: target, currency: nil), cyr: cyr, rates: rates, decimalComma: decimalComma) { lines.append(line) }
        }
        return lines.isEmpty ? nil : .suggestions(from: ref(src, cyrillic: cyr), lines: lines)
    }

    static func pairUp(_ l: [Candidate], _ r: [Candidate]) -> (Candidate, Candidate)? {
        for a in l { for b in r where a.category == b.category { return (a, b) } }
        return nil
    }

    static func finish(_ value: Double, _ valueText: String, _ from: Candidate, _ to: Candidate, cyr: Bool, rates: CurrencyRateTable?, decimalComma: Bool) -> Result<ConversionLine, UnitQueryResult> {
        let out: Double
        let isCurrency = from.unit == nil
        if isCurrency {
            guard let t = rates else { return .failure(.ratesUnavailable) }
            let a = from.currency!.code, b = to.currency!.code
            guard t.has(a) else { return .failure(.ratesMissing(a)) }
            guard t.has(b) else { return .failure(.ratesMissing(b)) }
            guard let r = t.convert(value, from: a, to: b) else { return .failure(.ratesMissing(b)) }
            out = r
        } else if from.unit!.category == .temperature {
            out = UnitCatalog.convertTemperature(value, from: from.unit!.id, to: to.unit!.id)
        } else {
            out = value * from.unit!.factor / to.unit!.factor
        }
        guard out.isFinite else { return .failure(.ratesMissing("")) }
        let fromRef = ref(from, cyrillic: cyr), toRef = ref(to, cyrillic: cyr)
        let inText = isCurrency ? UnitFormat.number(value, currency: true, decimalComma: decimalComma) : CalcFormat.format(value, CalcFormatOptions(decimalComma: decimalComma, grouping: true, significantDigits: 12))
        let outText = UnitFormat.number(out, currency: isCurrency, decimalComma: decimalComma)
        let copy = UnitFormat.number(out, currency: isCurrency, decimalComma: decimalComma, grouping: false)
        _ = valueText
        return .success(ConversionLine(from: fromRef, to: toRef, input: value, output: out, inputText: inText, outputText: outText, copyText: copy))
    }
}
