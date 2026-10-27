import Foundation

// Version ordering in the spirit of Sparkle: numbers compare numerically, words (alpha, beta, rc) sort before the release,
// separators are ignored. "1.2.3b4" < "1.2.3rc1" < "1.2.3" < "1.2.3.1" < "1.2.4"; semver build metadata after "+" is dropped.
public struct AppVersion: Hashable, Comparable, CustomStringConvertible, Sendable {
    enum Part: Hashable, Sendable {
        case number(String)
        case tag(String)
    }

    public let raw: String
    let parts: [Part]

    static let releaseWords: Set<String> = ["final", "release", "ga", "stable", "build", "r", "rev", "version", "ver", "v"]

    public init(_ raw: String) {
        self.raw = raw
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plus = text.firstIndex(of: "+"), text.distance(from: text.startIndex, to: plus) > 0 { text = String(text[..<plus]) }
        var parts: [Part] = []
        var digits = ""
        var letters = ""
        func flush() {
            if !digits.isEmpty {
                var d = String(digits.drop(while: { $0 == "0" }))
                if d.isEmpty { d = "0" }
                parts.append(.number(d))
                digits = ""
            }
            if !letters.isEmpty {
                let w = letters.lowercased()
                if !AppVersion.releaseWords.contains(w) { parts.append(.tag(w)) }
                letters = ""
            }
        }
        for ch in text {
            if ch.isASCII && ch.isNumber {
                if !letters.isEmpty { flush() }
                digits.append(ch)
            } else if ch.isLetter {
                if !digits.isEmpty { flush() }
                letters.append(ch)
            } else {
                flush()
            }
        }
        flush()
        self.parts = parts
    }

    public var description: String { raw }
    public var isEmpty: Bool { parts.isEmpty }

    public var isPreRelease: Bool {
        parts.contains { if case .tag(let t) = $0 { return Self.rank(t) < Self.releaseRank } else { return false } }
    }

    static let releaseRank = 100

    static func rank(_ tag: String) -> Int {
        switch tag {
        case "dev", "snapshot", "nightly", "canary", "git": return 0
        case "alpha", "a": return 1
        case "beta", "b": return 2
        case "pre", "preview", "prerelease", "m", "milestone": return 3
        case "rc", "c", "candidate": return 4
        case "patch", "p", "hotfix", "post", "sp": return 101
        default: return 2
        }
    }

    private static func compareNumbers(_ a: String, _ b: String) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    private static func compareParts(_ a: Part?, _ b: Part?) -> Int {
        switch (a ?? .number("0"), b ?? .number("0")) {
        case (.number(let x), .number(let y)):
            return compareNumbers(x, y)
        case (.tag(let x), .tag(let y)):
            let rx = rank(x), ry = rank(y)
            if rx != ry { return rx < ry ? -1 : 1 }
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.tag(let x), .number):
            return rank(x) > releaseRank ? 1 : -1
        case (.number, .tag(let y)):
            return rank(y) > releaseRank ? -1 : 1
        }
    }

    public static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let c = compareParts(i < a.parts.count ? a.parts[i] : nil, i < b.parts.count ? b.parts[i] : nil)
            if c != 0 { return c }
        }
        return 0
    }

    public static func < (l: AppVersion, r: AppVersion) -> Bool { compare(l, r) < 0 }
    public static func == (l: AppVersion, r: AppVersion) -> Bool { compare(l, r) == 0 }

    public func hash(into h: inout Hasher) {
        var trimmed = parts
        while case .number(let n)? = trimmed.last, n == "0" { trimmed.removeLast() }
        h.combine(trimmed)
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let c = AppVersion(candidate), i = AppVersion(installed)
        guard !c.isEmpty, !i.isEmpty else { return false }
        return compare(c, i) > 0
    }
}
