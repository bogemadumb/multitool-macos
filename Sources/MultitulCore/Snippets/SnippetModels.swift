import Foundation
import CoreGraphics

public struct Snippet: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var trigger: String
    public var title: String
    public var body: String
    public var enabled: Bool
    public var created: Date
    public var updated: Date
    public var uses: Int

    public init(id: Int64 = 0, trigger: String, title: String = "", body: String, enabled: Bool = true, created: Date = Date(timeIntervalSince1970: 0),
                updated: Date = Date(timeIntervalSince1970: 0), uses: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.body = body
        self.enabled = enabled
        self.created = created
        self.updated = updated
        self.uses = uses
    }

    public var displayTitle: String { title.isEmpty ? trigger : title }
}

public enum SnippetIssue: Equatable, Sendable {
    case triggerTooShort
    case triggerTooLong
    case triggerHasWhitespace
    case bodyEmpty
    case duplicate(String)

    public var message: String {
        switch self {
        case .triggerTooShort: "Триггер короче \(SnippetRules.minTriggerLength) символов"
        case .triggerTooLong: "Триггер длиннее \(SnippetRules.maxTriggerLength) символов"
        case .triggerHasWhitespace: "В триггере не должно быть пробелов и переводов строк"
        case .bodyEmpty: "Текст вставки пустой"
        case .duplicate(let t): "Такой триггер уже есть: \(t)"
        }
    }
}

public enum SnippetRules {
    public static let minTriggerLength = 2
    public static let maxTriggerLength = 40

    public static func normalized(_ trigger: String) -> String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    public static func key(_ trigger: String) -> String { normalized(trigger).lowercased() }

    public static func validate(trigger: String, body: String) -> SnippetIssue? {
        let t = normalized(trigger)
        if t.contains(where: { $0.isWhitespace || $0.isNewline }) { return .triggerHasWhitespace }
        if t.count < minTriggerLength { return .triggerTooShort }
        if t.count > maxTriggerLength { return .triggerTooLong }
        if body.isEmpty { return .bodyEmpty }
        return nil
    }
}

public enum SnippetTerminator: Equatable, Sendable {
    case space, tab, returnKey

    public var keyCode: UInt32 {
        switch self {
        case .space: Keys.space
        case .tab: Keys.tab
        case .returnKey: Keys.returnKey
        }
    }
}

public enum SnippetMethod: String, CaseIterable, Sendable {
    case auto, paste, type

    public var title: String {
        switch self {
        case .auto: "Автоматически"
        case .paste: "Всегда вставлять через буфер"
        case .type: "Всегда печатать"
        }
    }
}

public struct SnippetSettings: Equatable, Sendable {
    public static let suggestedExceptions: [String] = [
        "com.1password.1password", "com.agilebits.onepassword*", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.lastpass.*", "com.dashlane.*"
    ]

    public var caseSensitive = false
    public var layoutInsensitive = false
    public var method = SnippetMethod.auto
    public var restoreClipboard = true
    public var appendSpace = true
    public var useSpace = true
    public var useTab = true
    public var useReturn = true
    public var typeLimit = 40
    public var timeZoneID = ""
    public var localeID = "ru_RU"
    public var exceptions = AppExceptionList(SnippetSettings.suggestedExceptions)
    public init() {}

    public var sanitized: SnippetSettings {
        var s = self
        s.typeLimit = min(max(typeLimit, 0), 400)
        if !s.useSpace && !s.useTab && !s.useReturn { s.useSpace = true }
        return s
    }

    public func accepts(_ t: SnippetTerminator) -> Bool {
        switch t {
        case .space: useSpace
        case .tab: useTab
        case .returnKey: useReturn
        }
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    public var locale: Locale { Locale(identifier: localeID.isEmpty ? "ru_RU" : localeID) }
}

public enum SnippetHotkeys {
    public static let library = HotkeySpec(id: "snippets.library", title: "Сниппеты: открыть библиотеку", defaultCombo: .none)
}

public extension InputSettingsStore {
    func loadSnippets() -> SnippetSettings {
        var s = SnippetSettings()
        s.caseSensitive = bool("input.snippets.caseSensitive", s.caseSensitive)
        s.layoutInsensitive = bool("input.snippets.layoutInsensitive", s.layoutInsensitive)
        if let v = defaults.string(forKey: "input.snippets.method"), let m = SnippetMethod(rawValue: v) { s.method = m }
        s.restoreClipboard = bool("input.snippets.restoreClipboard", s.restoreClipboard)
        s.appendSpace = bool("input.snippets.appendSpace", s.appendSpace)
        s.useSpace = bool("input.snippets.useSpace", s.useSpace)
        s.useTab = bool("input.snippets.useTab", s.useTab)
        s.useReturn = bool("input.snippets.useReturn", s.useReturn)
        s.typeLimit = int("input.snippets.typeLimit", s.typeLimit)
        s.timeZoneID = defaults.string(forKey: "input.snippets.timeZone") ?? s.timeZoneID
        s.localeID = defaults.string(forKey: "input.snippets.locale") ?? s.localeID
        s.exceptions = list("input.snippets.exceptions", s.exceptions)
        return s.sanitized
    }

    func saveSnippets(_ settings: SnippetSettings) {
        let s = settings.sanitized
        let b = SnippetSettings()
        put("input.snippets.caseSensitive", s.caseSensitive, b.caseSensitive)
        put("input.snippets.layoutInsensitive", s.layoutInsensitive, b.layoutInsensitive)
        put("input.snippets.method", s.method.rawValue, b.method.rawValue)
        put("input.snippets.restoreClipboard", s.restoreClipboard, b.restoreClipboard)
        put("input.snippets.appendSpace", s.appendSpace, b.appendSpace)
        put("input.snippets.useSpace", s.useSpace, b.useSpace)
        put("input.snippets.useTab", s.useTab, b.useTab)
        put("input.snippets.useReturn", s.useReturn, b.useReturn)
        put("input.snippets.typeLimit", s.typeLimit, b.typeLimit)
        put("input.snippets.timeZone", s.timeZoneID, b.timeZoneID)
        put("input.snippets.locale", s.localeID, b.localeID)
        putList("input.snippets.exceptions", s.exceptions, b.exceptions)
    }
}

public enum LayoutMap {
    private static let russian = Array("йцукенгшщзхъфывапролджэячсмитьбюё")
    private static let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")

    private static let table: [Character: Character] = {
        var t: [Character: Character] = [:]
        for (r, l) in zip(russian, latin) {
            t[r] = l
            let upperR = Character(String(r).uppercased())
            let upperL: Character
            switch l {
            case "[": upperL = "{"
            case "]": upperL = "}"
            case ";": upperL = ":"
            case "'": upperL = "\""
            case ",": upperL = "<"
            case ".": upperL = ">"
            case "`": upperL = "~"
            default: upperL = Character(String(l).uppercased())
            }
            t[upperR] = upperL
        }
        return t
    }()

    public static func toLatin(_ c: Character) -> Character { table[c] ?? c }

    public static func toLatin(_ s: String) -> String { String(s.map(toLatin)) }
}

public enum SnippetKey: Equatable, Sendable {
    case text(String)
    case backspace
    case terminator(SnippetTerminator)
    case reset
    case ignore
}

public enum SnippetKeyClassifier {
    public static func classify(keyCode: UInt32, flags: CGEventFlags, characters: String) -> SnippetKey {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .reset }
        switch keyCode {
        case Keys.backspace: return flags.contains(.maskAlternate) ? .reset : .backspace
        case 117: return .reset
        case Keys.space: return .terminator(.space)
        case Keys.tab: return .terminator(.tab)
        case Keys.returnKey, Keys.enterKey: return .terminator(.returnKey)
        default: break
        }
        if characters.isEmpty { return .ignore }
        for u in characters.unicodeScalars {
            if u.properties.generalCategory == .control || u.properties.generalCategory == .privateUse || u.properties.generalCategory == .format { return .reset }
        }
        return .text(characters)
    }
}

public struct SnippetBuffer: Equatable, Sendable {
    public static let capacity = 64
    public private(set) var chars: [Character] = []

    public init() {}

    public var text: String { String(chars) }
    public var isEmpty: Bool { chars.isEmpty }

    public mutating func append(_ s: String) {
        chars.append(contentsOf: s)
        if chars.count > Self.capacity { chars.removeFirst(chars.count - Self.capacity) }
    }

    public mutating func backspace() { if !chars.isEmpty { chars.removeLast() } }
    public mutating func reset() { chars.removeAll() }
}

public struct SnippetMatch: Equatable, Sendable {
    public var snippet: Snippet
    public var typedLength: Int
}

public struct SnippetMatcher: Sendable {
    private struct Entry: Sendable {
        var snippet: Snippet
        var folded: [Character]
    }

    private let entries: [Entry]
    private let caseSensitive: Bool
    private let layoutInsensitive: Bool

    public init(snippets: [Snippet], caseSensitive: Bool = false, layoutInsensitive: Bool = false) {
        self.caseSensitive = caseSensitive
        self.layoutInsensitive = layoutInsensitive
        entries = snippets.filter(\.enabled)
            .map { Entry(snippet: $0, folded: Self.fold(Array(SnippetRules.normalized($0.trigger)), caseSensitive: caseSensitive, layout: layoutInsensitive)) }
            .filter { !$0.folded.isEmpty }
            .sorted { $0.folded.count != $1.folded.count ? $0.folded.count > $1.folded.count : $0.snippet.id < $1.snippet.id }
    }

    public var count: Int { entries.count }

    static func fold(_ chars: [Character], caseSensitive: Bool, layout: Bool) -> [Character] {
        chars.map { c in
            var x = layout ? LayoutMap.toLatin(c) : c
            if !caseSensitive { x = Character(String(x).lowercased()) }
            return x
        }
    }

    public func match(in buffer: [Character]) -> SnippetMatch? {
        guard !buffer.isEmpty else { return nil }
        let folded = Self.fold(buffer, caseSensitive: caseSensitive, layout: layoutInsensitive)
        for e in entries where e.folded.count <= buffer.count {
            let start = buffer.count - e.folded.count
            guard Array(folded[start...]) == e.folded else { continue }
            if start > 0 {
                let prev = buffer[start - 1]
                if prev.isLetter || prev.isNumber { continue }
            }
            return SnippetMatch(snippet: e.snippet, typedLength: e.folded.count)
        }
        return nil
    }
}

public extension CGEvent {
    func typedCharacters() -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, 16))
    }
}
