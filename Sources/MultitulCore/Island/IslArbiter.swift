import Foundation

public struct IslSectionID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

public enum IslSectionIDs {
    public static let music: IslSectionID = "music"
    public static let levels: IslSectionID = "levels"
    public static let shortcuts: IslSectionID = "shortcuts"
    public static let mixer: IslSectionID = "mixer"
    public static let clipboard: IslSectionID = "clipboard"
    public static let shots: IslSectionID = "shots"
    public static let shelf: IslSectionID = "shelf"
    public static let stats: IslSectionID = "stats"
    public static let tools: IslSectionID = "tools"
}

public enum IslPriority {
    public static let ambient = 10
    public static let music = 50
    public static let transient = 60
    public static let levelsHud = 70
    public static let timer = 80
    public static let recording = 90
    public static let critical = 100
}

public struct IslActivity: Equatable, Identifiable, Sendable {
    public var id: String
    public var section: IslSectionID
    public var priority: Int
    public var startedAt: Date
    public var expiresAt: Date?
    public var urgent: Bool
    public var peeks: Bool
    public var token: String
    public var title: String

    public init(id: String, section: IslSectionID, priority: Int, startedAt: Date, expiresAt: Date? = nil, urgent: Bool = false,
                peeks: Bool = false, token: String = "", title: String = "") {
        self.id = id
        self.section = section
        self.priority = priority
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.urgent = urgent
        self.peeks = peeks
        self.token = token
        self.title = title
    }

    public func isExpired(at now: Date) -> Bool {
        guard let e = expiresAt else { return false }
        return e <= now
    }
}

public struct IslArbitration: Equatable, Sendable {
    public var winner: IslActivity?
    public var secondary: IslActivity?
    public var ranked: [IslActivity]
    public var shouldPeek: Bool
    public var changed: Bool

    public init(winner: IslActivity? = nil, secondary: IslActivity? = nil, ranked: [IslActivity] = [], shouldPeek: Bool = false, changed: Bool = false) {
        self.winner = winner
        self.secondary = secondary
        self.ranked = ranked
        self.shouldPeek = shouldPeek
        self.changed = changed
    }

    public static let empty = IslArbitration()
}

public struct IslArbiter: Sendable {
    public private(set) var currentID: String?
    private var seenTokens: [String: String] = [:]
    private var primed = false

    public init() {}

    public static func rank(_ a: IslActivity, _ b: IslActivity) -> Bool {
        if a.urgent != b.urgent { return a.urgent }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id < b.id
    }

    public mutating func resolve(_ activities: [IslActivity], now: Date, muted: Set<String> = []) -> IslArbitration {
        var byID: [String: IslActivity] = [:]
        for a in activities where !a.isExpired(at: now) && !muted.contains(a.section.rawValue) {
            if let old = byID[a.id], old.startedAt >= a.startedAt { continue }
            byID[a.id] = a
        }
        let ranked = byID.values.sorted(by: Self.rank)
        let top = ranked.first
        let current = currentID.flatMap { byID[$0] }

        var winner = top
        if let current, let top, top.id != current.id {
            let preempts = (top.urgent && !current.urgent) || (top.urgent == current.urgent && top.priority > current.priority)
            if !preempts { winner = current }
        }

        let previous = currentID
        currentID = winner?.id
        var peek = false
        if let w = winner {
            let isNew = w.id != previous || seenTokens[w.id] != w.token
            peek = primed && w.peeks && isNew
            seenTokens[w.id] = w.token
        }
        seenTokens = seenTokens.filter { byID[$0.key] != nil }
        primed = true
        let secondary = ranked.first { $0.id != winner?.id }
        return IslArbitration(winner: winner, secondary: secondary, ranked: ranked, shouldPeek: peek, changed: previous != currentID)
    }

    public mutating func reset() {
        currentID = nil
        seenTokens = [:]
        primed = false
    }
}
