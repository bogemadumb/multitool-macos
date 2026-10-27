import Foundation

public enum KeyboardLayoutSwap {
    private static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбю")
    private static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
    private static let toEn: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(ru, en))
    private static let toRu: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(en, ru))

    public static func swapped(_ s: String) -> String? {
        var changed = false
        let hasCyr = s.contains { toEn[$0] != nil }
        let out = s.map { c -> Character in
            if hasCyr, let m = toEn[c] { changed = true; return m }
            if !hasCyr, let m = toRu[c] { changed = true; return m }
            return c
        }
        return changed ? String(out) : nil
    }
}

public struct SwitcherSearchIndex {
    struct Row {
        var name: String
        var title: String
        var nameWords: [Substring]
        var titleWords: [Substring]
    }

    var rows: [Row]

    public init(_ entries: [SwitchEntry]) {
        rows = entries.map { e in
            let n = SwitcherSearch.fold(e.appName)
            let t = SwitcherSearch.fold(e.kind == .window ? e.title : "")
            return Row(name: n, title: t, nameWords: SwitcherSearch.words(n), titleWords: SwitcherSearch.words(t))
        }
    }
}

public enum SwitcherSearch {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ s: String) -> [Substring] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    public static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func isSubsequence(_ needle: String, in hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    static func score(token: String, row: SwitcherSearchIndex.Row) -> Int? {
        var best: Int?
        func bump(_ v: Int) { if v > (best ?? 0) { best = v } }
        if row.name == token { bump(120) }
        else if row.name.hasPrefix(token) { bump(100) }
        else if row.nameWords.contains(where: { $0.hasPrefix(token) }) { bump(85) }
        else if row.name.contains(token) { bump(60) }
        if row.titleWords.contains(where: { $0.hasPrefix(token) }) { bump(70) }
        else if row.title.contains(token) { bump(45) }
        if best == nil, token.count >= 2 {
            if isSubsequence(token, in: row.name) { bump(25) }
            else if isSubsequence(token, in: row.title) { bump(15) }
        }
        return best
    }

    static func score(tokens: [String], row: SwitcherSearchIndex.Row) -> Int? {
        var total = 0
        for t in tokens {
            var s = score(token: fold(t), row: row)
            if let alt = KeyboardLayoutSwap.swapped(t), let a = score(token: fold(alt), row: row), a > (s ?? 0) { s = a }
            guard let v = s else { return nil }
            total += v
        }
        return total
    }

    public static func rank(_ entries: [SwitchEntry], query: String, index: SwitcherSearchIndex? = nil) -> [SwitchEntry] {
        let toks = tokens(query)
        guard !toks.isEmpty else { return entries }
        let idx = index ?? SwitcherSearchIndex(entries)
        var scored: [(Int, Int)] = []
        for i in entries.indices {
            if let s = score(tokens: toks, row: idx.rows[i]) { scored.append((i, s)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.map { entries[$0.0] }
    }
}
