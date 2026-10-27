import Foundation

public enum CalcError: Error, Equatable, Sendable {
    case empty
    case syntax
    case divisionByZero
    case overflow
    case domain
    case unknownName(String)
    case tooComplex

    public var message: String {
        switch self {
        case .empty: "Пусто"
        case .syntax: "Не удалось разобрать выражение"
        case .divisionByZero: "Деление на ноль"
        case .overflow: "Слишком большое число"
        case .domain: "Вне области определения"
        case .unknownName(let n): "Неизвестное имя «\(n)»"
        case .tooComplex: "Слишком сложное выражение"
        }
    }
}

public enum CalcAngle: String, CaseIterable, Sendable {
    case radians, degrees

    public var title: String { self == .radians ? "Радианы" : "Градусы" }
}

public struct CalcValue: Equatable, Sendable {
    public var number: Double
    public var isPercent = false

    public init(_ number: Double, isPercent: Bool = false) {
        self.number = number
        self.isPercent = isPercent
    }
}

enum CalcToken: Equatable {
    case number(Double)
    case op(Character)
    case ident(String)
    case lparen, rparen, semicolon
    case percent, bang
}

enum CalcLexer {
    static let maxLength = 300
    static let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}"]

    static func normalize(_ s: String) -> [Character] {
        var out: [Character] = []
        for ch in s.lowercased() {
            switch ch {
            case "×", "·", "∙", "⋅", "✕", "∗": out.append("*")
            case "÷", "∕": out.append("/")
            case "−", "–", "—", "‒": out.append("-")
            case "π": out.append("π")
            case "\t", "\n": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    // "1 000", "12 345 678", "1 000,5": space groups of exactly three digits after a first group of 1-3 digits.
    static func scanNumber(_ chars: [Character], _ start: Int) -> (value: Double, end: Int)? {
        var i = start
        var text = ""
        func digits(from k: Int) -> String {
            var r = ""
            var j = k
            while j < chars.count, isDigit(chars[j]) { r.append(chars[j]); j += 1 }
            return r
        }
        let head = digits(from: i)
        if head.isEmpty {
            guard i < chars.count, chars[i] == "." || chars[i] == ",", i + 1 < chars.count, isDigit(chars[i + 1]) else { return nil }
            text = "0"
        } else {
            text = head
            i += head.count
            if head.count <= 3 {
                while i < chars.count, spaces.contains(chars[i]) {
                    let g = digits(from: i + 1)
                    guard g.count == 3 else { break }
                    text += g
                    i += 4
                }
            }
        }
        if i < chars.count, chars[i] == "." || chars[i] == ",", i + 1 < chars.count, isDigit(chars[i + 1]) {
            text += "."
            i += 1
            while i < chars.count, isDigit(chars[i]) { text.append(chars[i]); i += 1 }
        }
        if i < chars.count, chars[i] == "e" {
            var k = i + 1
            var exp = "e"
            if k < chars.count, chars[k] == "+" || chars[k] == "-" { exp.append(chars[k]); k += 1 }
            let ds = digits(from: k)
            if !ds.isEmpty, ds.count <= 4 {
                text += exp + ds
                i = k + ds.count
            }
        }
        guard let v = Double(text) else { return nil }
        return (v, i)
    }

    static func tokenize(_ input: String) -> Result<[CalcToken], CalcError> {
        if input.count > maxLength { return .failure(.tooComplex) }
        let chars = normalize(input)
        var tokens: [CalcToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || spaces.contains(c) { i += 1; continue }
            if isDigit(c) || ((c == "." || c == ",") && i + 1 < chars.count && isDigit(chars[i + 1])) {
                guard let (v, end) = scanNumber(chars, i) else { return .failure(.syntax) }
                tokens.append(.number(v))
                i = end
                continue
            }
            switch c {
            case "+", "-", "/", "^", "*":
                if c == "*", i + 1 < chars.count, chars[i + 1] == "*" { tokens.append(.op("^")); i += 2; continue }
                tokens.append(.op(c)); i += 1
            case ":": tokens.append(.op("/")); i += 1
            case "(", "[": tokens.append(.lparen); i += 1
            case ")", "]": tokens.append(.rparen); i += 1
            case ";": tokens.append(.semicolon); i += 1
            case "%": tokens.append(.percent); i += 1
            case "!": tokens.append(.bang); i += 1
            case "√": tokens.append(.ident("sqrt")); i += 1
            case "π": tokens.append(.ident("pi")); i += 1
            default:
                if c.isLetter {
                    var name = ""
                    var j = i
                    while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                    if name == "log", j < chars.count, chars[j] == "2", !(j + 1 < chars.count && isDigit(chars[j + 1])) { name = "log2"; j += 1 }
                    tokens.append(.ident(name))
                    i = j
                } else {
                    return .failure(.syntax)
                }
            }
        }
        return .success(words(tokens))
    }

    // Russian and English words become operators: "плюс", "умножить на", "в степени", "15 процентов от 200".
    static func words(_ t: [CalcToken]) -> [CalcToken] {
        var out: [CalcToken] = []
        var i = 0
        func name(_ k: Int) -> String? { k < t.count ? { if case .ident(let n) = t[k] { return n } else { return nil } }() : nil }
        while i < t.count {
            guard case .ident(let n) = t[i] else { out.append(t[i]); i += 1; continue }
            switch n {
            case "плюс", "plus": out.append(.op("+")); i += 1
            case "минус", "minus": out.append(.op("-")); i += 1
            case "умножить", "помножить", "times":
                out.append(.op("*")); i += 1
                if name(i) == "на" || name(i) == "by" { i += 1 }
            case "разделить", "делить", "divided":
                out.append(.op("/")); i += 1
                if name(i) == "на" || name(i) == "by" { i += 1 }
            case "в" where name(i + 1) == "степени": out.append(.op("^")); i += 2
            case "процент", "процента", "процентов", "percent":
                if case .number = out.last ?? .lparen { out.append(.percent) } else { out.append(t[i]) }
                i += 1
            case "от", "of":
                if case .percent = out.last ?? .lparen { out.append(.op("*")); i += 1 } else { out.append(t[i]); i += 1 }
            case "mod": out.append(.op("m")); i += 1
            case "корень" where name(i + 1) == "из": out.append(.ident("sqrt")); i += 2
            default: out.append(t[i]); i += 1
            }
        }
        return out
    }
}

public enum CalcEngine {
    public static let constants: [String: Double] = [
        "pi": Double.pi, "пи": Double.pi, "e": M_E, "tau": 2 * Double.pi, "тау": 2 * Double.pi, "phi": 1.618033988749895
    ]

    static let functions: [String: String] = [
        "sin": "sin", "син": "sin", "синус": "sin", "cos": "cos", "кос": "cos", "косинус": "cos",
        "tan": "tan", "tg": "tan", "тан": "tan", "тангенс": "tan", "тг": "tan",
        "asin": "asin", "arcsin": "asin", "acos": "acos", "arccos": "acos", "atan": "atan", "arctan": "atan", "arctg": "atan",
        "sinh": "sinh", "cosh": "cosh", "tanh": "tanh",
        "sqrt": "sqrt", "корень": "sqrt", "кор": "sqrt", "cbrt": "cbrt",
        "log": "log", "lg": "log", "лог": "log", "ln": "ln", "лн": "ln", "log2": "log2", "exp": "exp",
        "abs": "abs", "абс": "abs", "floor": "floor", "ceil": "ceil", "round": "round", "trunc": "trunc",
        "pow": "pow", "max": "max", "min": "min", "hypot": "hypot", "fact": "fact"
    ]

    public static func evaluate(_ input: String, angle: CalcAngle = .radians) -> Result<Double, CalcError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        switch CalcLexer.tokenize(trimmed) {
        case .failure(let e): return .failure(e)
        case .success(let tokens):
            if tokens.isEmpty { return .failure(.empty) }
            var p = CalcParser(tokens: tokens, angle: angle)
            do {
                let v = try p.parseAll()
                guard v.number.isFinite else { return .failure(.overflow) }
                return .success(v.number == 0 ? 0 : v.number)
            } catch let e as CalcError {
                return .failure(e)
            } catch {
                return .failure(.syntax)
            }
        }
    }

    // True when the text is something a person would type into a calculator rather than a plain number or a word.
    public static func looksLikeCalculation(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= CalcLexer.maxLength else { return false }
        if t.range(of: #"^\+?[\d ]+(-\d+){2,}$"#, options: .regularExpression) != nil { return false }
        guard case .success(let tokens) = CalcLexer.tokenize(t), !tokens.isEmpty else { return false }
        var hasOperator = false
        var hasValue = false
        for tok in tokens {
            switch tok {
            case .number: hasValue = true
            case .op, .percent, .bang, .lparen: hasOperator = true
            case .ident(let n):
                if functions[n] != nil { hasOperator = true; hasValue = true }
                else if constants[n] != nil { hasValue = true }
            default: break
            }
        }
        if tokens.count == 1, case .ident(let n) = tokens[0] { return n.count >= 2 && constants[n] != nil }
        if tokens.count == 1, case .number = tokens[0] { return false }
        if case .op(let c) = tokens[0], tokens.count == 2, case .number = tokens[1], c == "-" || c == "+" { return false }
        return hasValue && hasOperator
    }
}

struct CalcParser {
    let tokens: [CalcToken]
    let angle: CalcAngle
    var pos = 0
    var depth = 0
    static let maxDepth = 60

    init(tokens: [CalcToken], angle: CalcAngle) {
        self.tokens = tokens
        self.angle = angle
    }

    var peek: CalcToken? { pos < tokens.count ? tokens[pos] : nil }

    mutating func parseAll() throws -> CalcValue {
        let v = try parseExpression()
        if pos != tokens.count { throw CalcError.syntax }
        return v
    }

    mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw CalcError.tooComplex }
    }

    mutating func leave() { depth -= 1 }

    mutating func parseExpression() throws -> CalcValue {
        try enter()
        defer { leave() }
        var left = try parseTerm()
        while let t = peek, case .op(let c) = t, c == "+" || c == "-" {
            pos += 1
            var right = try parseTerm()
            if right.isPercent { right = CalcValue(left.number * right.number) }
            let r = c == "+" ? left.number + right.number : left.number - right.number
            guard r.isFinite else { throw CalcError.overflow }
            left = CalcValue(r)
        }
        return left
    }

    func startsOperand(_ t: CalcToken?) -> Bool {
        switch t {
        case .lparen, .ident: return true
        default: return false
        }
    }

    mutating func parseTerm() throws -> CalcValue {
        var left = try parseUnary()
        while true {
            if let t = peek, case .op(let c) = t, c == "*" || c == "/" || c == "m" {
                pos += 1
                let right = try parseUnary()
                left = CalcValue(try Self.apply(c, left.number, right.number))
            } else if startsOperand(peek) {
                let right = try parseUnary()
                let r = left.number * right.number
                guard r.isFinite else { throw CalcError.overflow }
                left = CalcValue(r)
            } else {
                return left
            }
        }
    }

    static func apply(_ op: Character, _ a: Double, _ b: Double) throws -> Double {
        let r: Double
        switch op {
        case "*": r = a * b
        case "/":
            if b == 0 { throw CalcError.divisionByZero }
            r = a / b
        case "m":
            if b == 0 { throw CalcError.divisionByZero }
            r = a.truncatingRemainder(dividingBy: b)
        default: throw CalcError.syntax
        }
        guard r.isFinite else { throw CalcError.overflow }
        return r
    }

    mutating func parseUnary() throws -> CalcValue {
        try enter()
        defer { leave() }
        if let t = peek, case .op(let c) = t, c == "-" || c == "+" {
            pos += 1
            let v = try parseUnary()
            return CalcValue(c == "-" ? -v.number : v.number, isPercent: v.isPercent)
        }
        return try parsePower()
    }

    mutating func parsePower() throws -> CalcValue {
        let base = try parsePostfix()
        if let t = peek, case .op("^") = t {
            pos += 1
            let exp = try parseUnary()
            let r = try Self.power(base.number, exp.number)
            return CalcValue(r)
        }
        return base
    }

    static func power(_ a: Double, _ b: Double) throws -> Double {
        if a == 0, b < 0 { throw CalcError.divisionByZero }
        if a < 0, b != b.rounded() { throw CalcError.domain }
        let r = pow(a, b)
        guard r.isFinite else { throw CalcError.overflow }
        return r
    }

    mutating func parsePostfix() throws -> CalcValue {
        var v = try parsePrimary()
        while let t = peek {
            if case .percent = t { pos += 1; v = CalcValue(v.number / 100, isPercent: true) }
            else if case .bang = t {
                pos += 1
                v = CalcValue(try Self.factorial(v.number))
            } else { break }
        }
        return v
    }

    static func factorial(_ x: Double) throws -> Double {
        guard x >= 0, x == x.rounded() else { throw CalcError.domain }
        if x > 170 { throw CalcError.overflow }
        var r = 1.0
        if x >= 2 { for k in 2...Int(x) { r *= Double(k) } }
        return r
    }

    mutating func parsePrimary() throws -> CalcValue {
        guard let t = peek else { throw CalcError.syntax }
        switch t {
        case .number(let v):
            pos += 1
            return CalcValue(v)
        case .lparen:
            pos += 1
            let v = try parseExpression()
            guard let c = peek, case .rparen = c else { throw CalcError.syntax }
            pos += 1
            return CalcValue(v.number)
        case .ident(let name):
            pos += 1
            if let f = CalcEngine.functions[name] { return try parseCall(f) }
            if let c = CalcEngine.constants[name] { return CalcValue(c) }
            throw CalcError.unknownName(name)
        default:
            throw CalcError.syntax
        }
    }

    mutating func parseCall(_ f: String) throws -> CalcValue {
        var args: [Double] = []
        if let t = peek, case .lparen = t {
            pos += 1
            if let n = peek, case .rparen = n { throw CalcError.syntax }
            while true {
                args.append(try parseExpression().number)
                if let n = peek, case .semicolon = n { pos += 1; continue }
                break
            }
            guard let c = peek, case .rparen = c else { throw CalcError.syntax }
            pos += 1
        } else {
            args.append(try parseUnary().number)
        }
        return CalcValue(try call(f, args))
    }

    func toRadians(_ x: Double) -> Double { angle == .degrees ? x * .pi / 180 : x }
    func fromRadians(_ x: Double) -> Double { angle == .degrees ? x * 180 / .pi : x }

    func call(_ f: String, _ a: [Double]) throws -> Double {
        let two: Set<String> = ["pow", "hypot"]
        if two.contains(f) { guard a.count == 2 else { throw CalcError.syntax } }
        else if f == "max" || f == "min" { guard !a.isEmpty else { throw CalcError.syntax } }
        else { guard a.count == 1 else { throw CalcError.syntax } }
        let x = a[0]
        let r: Double
        switch f {
        case "sin": r = sin(toRadians(x))
        case "cos": r = cos(toRadians(x))
        case "tan": r = tan(toRadians(x))
        case "asin": guard abs(x) <= 1 else { throw CalcError.domain }; r = fromRadians(asin(x))
        case "acos": guard abs(x) <= 1 else { throw CalcError.domain }; r = fromRadians(acos(x))
        case "atan": r = fromRadians(atan(x))
        case "sinh": r = sinh(x)
        case "cosh": r = cosh(x)
        case "tanh": r = tanh(x)
        case "sqrt": guard x >= 0 else { throw CalcError.domain }; r = x.squareRoot()
        case "cbrt": r = cbrt(x)
        case "log": guard x > 0 else { throw CalcError.domain }; r = log10(x)
        case "log2": guard x > 0 else { throw CalcError.domain }; r = log2(x)
        case "ln": guard x > 0 else { throw CalcError.domain }; r = log(x)
        case "exp": r = exp(x)
        case "abs": r = abs(x)
        case "floor": r = floor(x)
        case "ceil": r = ceil(x)
        case "round": r = x.rounded(.toNearestOrAwayFromZero)
        case "trunc": r = trunc(x)
        case "fact": r = try Self.factorial(x)
        case "pow": r = try Self.power(a[0], a[1])
        case "hypot": r = hypot(a[0], a[1])
        case "max": r = a.max() ?? 0
        case "min": r = a.min() ?? 0
        default: throw CalcError.syntax
        }
        guard r.isFinite else { throw CalcError.overflow }
        if abs(r) < 1e-15, ["sin", "cos", "tan"].contains(f) { return 0 }
        return r
    }
}

public struct CalcFormatOptions: Equatable, Sendable {
    public var decimalComma = true
    public var grouping = true
    public var significantDigits = 12

    public init(decimalComma: Bool = true, grouping: Bool = true, significantDigits: Int = 12) {
        self.decimalComma = decimalComma
        self.grouping = grouping
        self.significantDigits = significantDigits
    }
}

public enum CalcFormat {
    public static let groupSeparator = "\u{00A0}"

    public static func format(_ value: Double, _ o: CalcFormatOptions = CalcFormatOptions()) -> String {
        guard value.isFinite else { return value.isNaN ? "не число" : (value < 0 ? "−∞" : "∞") }
        if value == 0 { return "0" }
        let neg = value < 0
        let a = abs(value)
        let sig = min(max(o.significantDigits, 3), 15)
        var body: String
        if a >= 1e15 || a < 1e-9 {
            var m = String(format: "%.\(sig - 1)e", a)
            if let r = m.range(of: "e") {
                var mant = String(m[..<r.lowerBound])
                let ex = Int(m[r.upperBound...]) ?? 0
                if mant.contains(".") {
                    while mant.hasSuffix("0") { mant.removeLast() }
                    if mant.hasSuffix(".") { mant.removeLast() }
                }
                m = mant + "e" + String(ex)
            }
            body = o.decimalComma ? m.replacingOccurrences(of: ".", with: ",") : m
        } else {
            let exp10 = Int(floor(log10(a)))
            let decimals = min(max(sig - 1 - exp10, 0), 15)
            var s = String(format: "%.\(decimals)f", a)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            var intPart = String(parts[0])
            if o.grouping { intPart = group(intPart) }
            body = intPart
            if parts.count > 1 { body += (o.decimalComma ? "," : ".") + parts[1] }
        }
        if body == "0" { return "0" }
        return neg ? "-" + body : body
    }

    static func group(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out += groupSeparator }
            out.append(ch)
        }
        return out
    }
}
