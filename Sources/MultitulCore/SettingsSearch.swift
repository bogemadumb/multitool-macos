import Foundation

public struct SettingsIndexEntry: Equatable, Identifiable, Sendable {
    public let title: String
    public let keywords: String
    public let section: String
    public let subpage: String?
    public var id: String { section + "/" + title + "/" + (subpage ?? "") }

    public init(title: String, keywords: String = "", section: String, subpage: String? = nil) {
        self.title = title
        self.keywords = keywords
        self.section = section
        self.subpage = subpage
    }

    public var path: String {
        let s = NavCatalog.title(of: section) ?? section
        return subpage.map { s + " › " + $0 } ?? s
    }
}

public enum SettingsSearch {
    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    public static func words(_ s: String) -> [String] {
        normalize(s).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // nil: no match. Lower is better.
    public static func score(query: String, title: String, keywords: String = "") -> Int? {
        let tokens = words(query)
        guard !tokens.isEmpty else { return nil }
        let t = words(title), k = words(keywords)
        let tFlat = t.joined(separator: " "), kFlat = k.joined(separator: " ")
        var total = 0
        for tok in tokens {
            if t.contains(tok) { total += 0 }
            else if t.contains(where: { $0.hasPrefix(tok) }) { total += 1 }
            else if k.contains(where: { $0.hasPrefix(tok) }) { total += 3 }
            else if tok.count >= 3 && tFlat.contains(tok) { total += 4 }
            else if tok.count >= 3 && kFlat.contains(tok) { total += 6 }
            else { return nil }
        }
        if tFlat == tokens.joined(separator: " ") { total -= 2 }
        else if tFlat.hasPrefix(tokens.joined(separator: " ")) { total -= 1 }
        return total
    }

    public static func search(_ query: String, in entries: [SettingsIndexEntry], limit: Int = 40) -> [SettingsIndexEntry] {
        guard !words(query).isEmpty else { return [] }
        var scored: [(Int, Int, SettingsIndexEntry)] = []
        for (i, e) in entries.enumerated() {
            let sectionTitle = NavCatalog.title(of: e.section) ?? ""
            if let s = score(query: query, title: e.title, keywords: e.keywords + " " + sectionTitle + " " + (e.subpage ?? "")) {
                scored.append((s, i, e))
            }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var seen = Set<String>()
        var out: [SettingsIndexEntry] = []
        for (_, _, e) in scored where seen.insert(e.id).inserted {
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }
}
