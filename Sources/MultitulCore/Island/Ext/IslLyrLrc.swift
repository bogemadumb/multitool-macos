import Foundation

public struct IslLrcWord: Equatable, Sendable {
    public var time: TimeInterval
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

public struct IslLrcLine: Equatable, Sendable {
    public var time: TimeInterval
    public var text: String
    public var words: [IslLrcWord]

    public init(time: TimeInterval, text: String, words: [IslLrcWord] = []) {
        self.time = time
        self.text = text
        self.words = words
    }

    public var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

public struct IslLrc: Equatable, Sendable {
    public var lines: [IslLrcLine]
    public var metadata: [String: String]
    public var offset: TimeInterval
    public var isSynced: Bool

    public init(lines: [IslLrcLine] = [], metadata: [String: String] = [:], offset: TimeInterval = 0, isSynced: Bool = true) {
        self.lines = lines
        self.metadata = metadata
        self.offset = offset
        self.isSynced = isSynced
    }

    public var isEmpty: Bool { lines.allSatisfy(\.isBlank) }

    public var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    // Last line whose time has come; nil before the first line and for unsynced text.
    public func index(at elapsed: TimeInterval, lead: TimeInterval = 0) -> Int? {
        guard isSynced, !lines.isEmpty, elapsed.isFinite else { return nil }
        let t = elapsed + lead
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    public func lineEnd(_ index: Int, fallback: TimeInterval = 6) -> TimeInterval {
        guard lines.indices.contains(index) else { return 0 }
        return index + 1 < lines.count ? lines[index + 1].time : lines[index].time + fallback
    }

    public func progress(in index: Int, at elapsed: TimeInterval) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let start = lines[index].time
        let end = lineEnd(index)
        guard end > start else { return 0 }
        return min(max((elapsed - start) / (end - start), 0), 1)
    }

    public func wordIndex(in index: Int, at elapsed: TimeInterval) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        let words = lines[index].words
        guard !words.isEmpty else { return nil }
        var found: Int?
        for (i, w) in words.enumerated() where w.time <= elapsed { found = i }
        return found
    }

    public func window(around index: Int?, before: Int, after: Int) -> [(index: Int, line: IslLrcLine)] {
        guard !lines.isEmpty else { return [] }
        let c = index ?? -1
        let from = max(c - before, 0)
        let to = min(c + after, lines.count - 1)
        guard from <= to else { return [] }
        return (from...to).map { ($0, lines[$0]) }
    }
}

public enum IslLrcParser {
    static let tagPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    static let metaPattern = #"^\[([A-Za-z][A-Za-z0-9_-]*):(.*)\]\s*$"#
    static let wordPattern = #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#

    static func seconds(_ m: String, _ s: String, _ f: String?) -> TimeInterval? {
        guard let mi = Int(m), let si = Int(s), si < 60 else { return nil }
        var t = TimeInterval(mi * 60 + si)
        if let f, !f.isEmpty, let frac = Double("0." + f) { t += frac }
        return t
    }

    public static func parse(_ raw: String) -> IslLrc {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let tagRe = try! NSRegularExpression(pattern: tagPattern)
        let metaRe = try! NSRegularExpression(pattern: metaPattern)
        let wordRe = try! NSRegularExpression(pattern: wordPattern)

        var meta: [String: String] = [:]
        var offset: TimeInterval = 0
        var entries: [(order: Int, line: IslLrcLine)] = []
        var plain: [String] = []
        var order = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            var cursor = 0
            var times: [TimeInterval] = []
            while cursor < ns.length {
                guard let m = tagRe.firstMatch(in: line, range: NSRange(location: cursor, length: ns.length - cursor)), m.range.location == cursor else { break }
                let f = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
                guard let t = seconds(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), f) else { break }
                times.append(t)
                cursor = m.range.location + m.range.length
            }

            if times.isEmpty {
                if let m = metaRe.firstMatch(in: line, range: full) {
                    let key = ns.substring(with: m.range(at: 1)).lowercased()
                    let value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    if key == "offset" {
                        if let ms = Double(value.replacingOccurrences(of: "+", with: "")), ms.isFinite { offset = ms / 1000 }
                    } else {
                        meta[key] = value
                    }
                } else {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty, !t.hasPrefix("[") { plain.append(t) }
                }
                continue
            }

            let rest = ns.substring(from: cursor)
            let (clean, words) = stripWords(rest, wordRe: wordRe)
            for t in times {
                entries.append((order, IslLrcLine(time: t, text: clean, words: words)))
                order += 1
            }
        }

        guard !entries.isEmpty else {
            return IslLrc(lines: plain.map { IslLrcLine(time: 0, text: $0) }, metadata: meta, offset: offset, isSynced: false)
        }
        let shifted = entries.map { e -> (Int, IslLrcLine) in
            var l = e.line
            l.time = max(l.time - offset, 0)
            l.words = l.words.map { IslLrcWord(time: max($0.time - offset, 0), text: $0.text) }
            return (e.order, l)
        }
        let sorted = shifted.sorted { a, b in a.1.time != b.1.time ? a.1.time < b.1.time : a.0 < b.0 }.map(\.1)
        return IslLrc(lines: sorted, metadata: meta, offset: offset, isSynced: true)
    }

    static func stripWords(_ s: String, wordRe: NSRegularExpression) -> (String, [IslLrcWord]) {
        let ns = s as NSString
        let matches = wordRe.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (s.trimmingCharacters(in: .whitespaces), []) }
        var words: [IslLrcWord] = []
        var plain = ns.substring(to: matches[0].range.location)
        for (i, m) in matches.enumerated() {
            let f = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let start = m.range.location + m.range.length
            let chunk = ns.substring(with: NSRange(location: start, length: max(end - start, 0)))
            plain += chunk
            if let t = seconds(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), f) {
                let w = chunk.trimmingCharacters(in: .whitespaces)
                if !w.isEmpty { words.append(IslLrcWord(time: t, text: w)) }
            }
        }
        return (plain.trimmingCharacters(in: .whitespaces), words)
    }
}
