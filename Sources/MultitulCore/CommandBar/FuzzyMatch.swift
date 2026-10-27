import Foundation

public enum FuzzyKind: Int, Comparable, Sendable {
    case subsequence, substring, acronym, wordPrefix, prefix, exact

    public static func < (a: FuzzyKind, b: FuzzyKind) -> Bool { a.rawValue < b.rawValue }
}

public struct FuzzyScore: Equatable, Comparable, Sendable {
    public var value: Double
    public var kind: FuzzyKind

    public init(value: Double, kind: FuzzyKind) {
        self.value = value
        self.kind = kind
    }

    public static func < (a: FuzzyScore, b: FuzzyScore) -> Bool { a.value < b.value }
}

public struct FuzzyKey: Equatable, Sendable {
    public let norm: String
    public let words: [String]
    public let initials: String

    public init(_ text: String) {
        norm = Fuzzy.normalize(text)
        words = Fuzzy.words(text).map(Fuzzy.normalize)
        initials = String(words.compactMap { $0.first })
    }
}

public struct FuzzyQuery: Equatable, Sendable {
    public let norm: String
    public let tokens: [String]
    public let swapped: [String]?

    public init(_ raw: String) {
        norm = Fuzzy.normalize(raw)
        tokens = norm.split(separator: " ").map(String.init)
        if let alt = KeyboardLayoutSwap.swapped(raw.lowercased()) {
            let n = Fuzzy.normalize(alt)
            let t = n.split(separator: " ").map(String.init)
            swapped = t.isEmpty || t == tokens ? nil : t
        } else {
            swapped = nil
        }
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

public enum Fuzzy {
    public static let layoutPenalty = 0.9
    public static let secondaryKeyPenalty = 0.92

    public static func normalize(_ s: String) -> String {
        let t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: Character?
        for ch in s {
            if !(ch.isLetter || ch.isNumber) {
                if !cur.isEmpty { out.append(cur); cur = "" }
                prev = nil
                continue
            }
            if let p = prev, !cur.isEmpty {
                let lowerToUpper = p.isLowercase && ch.isUppercase
                let digitBoundary = (p.isNumber != ch.isNumber)
                if lowerToUpper || digitBoundary { out.append(cur); cur = "" }
            }
            cur.append(ch)
            prev = ch
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func subsequenceSpan(_ needle: [Character], in hay: [Character]) -> Int? {
        guard !needle.isEmpty else { return nil }
        var best: Int?
        var start = 0
        while start < hay.count {
            guard let s = hay[start...].firstIndex(of: needle[0]) else { break }
            var j = 1
            var pos = s + 1
            var last = s
            while j < needle.count, pos < hay.count {
                if hay[pos] == needle[j] { last = pos; j += 1 }
                pos += 1
            }
            if j == needle.count {
                let span = last - s + 1
                if best == nil || span < best! { best = span }
            }
            start = s + 1
        }
        return best
    }

    static func scoreToken(_ t: String, _ key: FuzzyKey) -> FuzzyScore? {
        let n = key.norm
        guard !t.isEmpty, !n.isEmpty else { return nil }
        let tc = Double(t.count)
        let ratio = tc / Double(n.count)
        if n == t { return FuzzyScore(value: 100, kind: .exact) }
        if n.hasPrefix(t) { return FuzzyScore(value: 88 + 10 * ratio, kind: .prefix) }
        var best: FuzzyScore?
        func bump(_ v: Double, _ k: FuzzyKind) { if best == nil || v > best!.value { best = FuzzyScore(value: v, kind: k) } }
        for (i, w) in key.words.enumerated() where w.hasPrefix(t) {
            bump(74 + 8 * (tc / Double(w.count)) - Double(min(i * 3, 12)), .wordPrefix)
            break
        }
        if t.count >= 2, key.initials.hasPrefix(t) { bump(key.initials == t ? 76 : 66, .acronym) }
        if let r = n.range(of: t) {
            let pos = Double(n.distance(from: n.startIndex, to: r.lowerBound)) / Double(n.count)
            bump(45 + 15 * ratio - 5 * pos, .substring)
        }
        if best == nil, t.count >= 2, !t.contains(" ") {
            if let span = subsequenceSpan(Array(t), in: Array(n)), span <= t.count * 3 + 4 {
                bump(20 + 20 * (tc / Double(span)), .subsequence)
            }
        }
        return best
    }

    static func scoreTokens(_ tokens: [String], _ whole: String, _ key: FuzzyKey) -> FuzzyScore? {
        guard !tokens.isEmpty else { return nil }
        if tokens.count == 1 { return scoreToken(tokens[0], key) }
        var parts: [FuzzyScore] = []
        for t in tokens {
            guard let s = scoreToken(t, key) else { break }
            parts.append(s)
        }
        var best: FuzzyScore?
        if parts.count == tokens.count {
            let avg = parts.map(\.value).reduce(0, +) / Double(parts.count)
            let kind = parts.map(\.kind).min() ?? .subsequence
            best = FuzzyScore(value: avg, kind: kind)
        }
        if let w = scoreToken(whole, key), best == nil || w.value > best!.value { best = w }
        return best
    }

    public static func score(_ q: FuzzyQuery, _ key: FuzzyKey) -> FuzzyScore? {
        guard !q.isEmpty else { return nil }
        var best = scoreTokens(q.tokens, q.norm, key)
        if let alt = q.swapped, let s = scoreTokens(alt, alt.joined(separator: " "), key) {
            let adj = FuzzyScore(value: s.value * layoutPenalty, kind: s.kind)
            if best == nil || adj.value > best!.value { best = adj }
        }
        return best
    }

    public static func score(_ query: String, in text: String) -> FuzzyScore? {
        score(FuzzyQuery(query), FuzzyKey(text))
    }

    // keys[0] is the primary name, the rest are aliases and keywords and count a little less.
    public static func best(_ q: FuzzyQuery, _ keys: [FuzzyKey]) -> FuzzyScore? {
        var best: FuzzyScore?
        for (i, k) in keys.enumerated() {
            guard var s = score(q, k) else { continue }
            if i > 0 { s.value *= secondaryKeyPenalty }
            if best == nil || s.value > best!.value { best = s }
        }
        return best
    }
}
