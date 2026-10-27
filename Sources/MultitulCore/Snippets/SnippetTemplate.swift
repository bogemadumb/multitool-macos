import Foundation

public struct SnippetContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    public var clipboard: String?

    public init(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "ru_RU"), clipboard: String? = nil) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.clipboard = clipboard
    }
}

public struct RenderedSnippet: Equatable, Sendable {
    public var text: String
    public var cursorFromEnd: Int?
}

public enum SnippetTemplate {
    public static let defaultDate = "dd.MM.yyyy"
    public static let defaultTime = "HH:mm"
    public static let defaultDateTime = "dd.MM.yyyy HH:mm"

    public static func render(_ body: String, context: SnippetContext) -> RenderedSnippet {
        var out = ""
        var cursor: Int?
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 2 < chars.count, chars[i + 1] == "{", chars[i + 2] == "{" {
                out += "{{"
                i += 3
                continue
            }
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{", let end = closing(chars, from: i + 2) {
                let inner = String(chars[(i + 2)..<end])
                if let value = evaluate(inner, context: context) {
                    switch value {
                    case .text(let t): out += t
                    case .cursor: if cursor == nil { cursor = out.count }
                    }
                    i = end + 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return RenderedSnippet(text: out, cursorFromEnd: cursor.map { out.count - $0 })
    }

    public static func variableNames(in body: String) -> [String] {
        var names: [String] = []
        let chars = Array(body)
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "{", chars[i + 1] == "{", let end = closing(chars, from: i + 2) {
                let inner = String(chars[(i + 2)..<end])
                let name = parse(inner).name
                if known.contains(name), !names.contains(name) { names.append(name) }
                i = end + 2
            } else {
                i += 1
            }
        }
        return names
    }

    static let known: Set<String> = ["date", "time", "datetime", "clipboard", "cursor"]

    private enum Value {
        case text(String)
        case cursor
    }

    private static func closing(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "}", chars[j + 1] == "}" { return j }
            j += 1
        }
        return nil
    }

    static func parse(_ inner: String) -> (name: String, format: String?, zone: String?) {
        var left = inner
        var zone: String?
        if let bar = inner.firstIndex(of: "|") {
            left = String(inner[..<bar])
            zone = String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        }
        var format: String?
        var name = left
        if let colon = left.firstIndex(of: ":") {
            name = String(left[..<colon])
            format = String(left[left.index(after: colon)...])
        }
        return (name.trimmingCharacters(in: .whitespaces).lowercased(), format, zone)
    }

    private static func evaluate(_ inner: String, context: SnippetContext) -> Value? {
        let p = parse(inner)
        switch p.name {
        case "cursor":
            return .cursor
        case "clipboard":
            return .text(context.clipboard ?? "")
        case "date", "time", "datetime":
            var tz = context.timeZone
            if let z = p.zone, !z.isEmpty {
                guard let parsed = TimeZone(identifier: z) ?? TimeZone(abbreviation: z) else { return nil }
                tz = parsed
            }
            let fallback = p.name == "date" ? defaultDate : (p.name == "time" ? defaultTime : defaultDateTime)
            let format = (p.format?.isEmpty ?? true) ? fallback : p.format!
            let f = DateFormatter()
            f.locale = context.locale
            f.timeZone = tz
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = format
            return .text(f.string(from: context.now))
        default:
            return nil
        }
    }
}
