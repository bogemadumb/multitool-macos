import Foundation

public struct CbSearchOutput: Equatable, Sendable {
    public var query: String
    public var forced: CbProviderID?
    public var results: [CbResult]
}

public final class CbEngine {
    public let providers: [CbProvider]
    private let frecency: FrecencyIndex?
    private let settings: () -> CommandBarSettings

    public init(providers: [CbProvider], frecency: FrecencyIndex?, settings: @escaping () -> CommandBarSettings) {
        self.providers = providers
        self.frecency = frecency
        self.settings = settings
    }

    static func cap(_ p: CbProviderID, _ s: CommandBarSettings, forced: Bool) -> Int {
        let k = forced ? 2 : 1
        switch p {
        case .files: return s.fileLimit * k
        case .clipboard: return s.clipboardLimit * k
        case .menu: return s.menuLimit * k
        case .emoji: return 8 * k
        case .processes: return 5 * k
        case .windows: return 8 * k
        case .snippets: return 6 * k
        case .scripts, .quicklinks, .entries, .commands: return 8 * k
        case .units: return 6
        default: return 50
        }
    }

    func active(_ q: CbQuery, _ s: CommandBarSettings) -> [CbProvider] {
        providers.filter { p in
            guard s.isEnabled(p.id) else { return false }
            if let f = q.forced { return p.id == f }
            if q.isEmpty { return p.id != .web }
            return s.inGlobal(p.id) && q.text.count >= p.id.globalMinLength
        }
    }

    private struct Scored {
        var result: CbResult
        var total: Double
        var order: Int
        var local: Int
    }

    public func search(_ raw: String) -> CbSearchOutput {
        let s = settings()
        let q = CbQuery.parse(raw)
        var scored: [Scored] = []
        let on = active(q, s)
        for (pi, p) in providers.enumerated() where on.contains(where: { $0 === p }) {
            let cands = p.candidates(for: q)
            for (li, c) in cands.enumerated() {
                var r = c.result
                let pinned = c.fixedScore != nil && !c.scoredByProvider
                let boost = (s.useFrecency && !pinned) ? (r.frecencyKey.map { frecency?.boost($0) ?? 0 } ?? 0) : 0
                var base: Double
                if q.isEmpty {
                    guard q.forced != nil || boost > 0 else { continue }
                    base = 0
                } else if let f = c.fixedScore {
                    if q.forced == nil, f < p.id.globalMinScore { continue }
                    base = c.scoredByProvider ? f * p.id.weight : f
                } else {
                    guard let m = Fuzzy.best(q.fuzzy, c.keys) else { continue }
                    base = m.value * p.id.weight
                    if q.forced == nil, m.value < p.id.globalMinScore { continue }
                }
                r.score = base + boost
                scored.append(Scored(result: r, total: r.score, order: pi, local: li))
            }
        }
        scored.sort { a, b in
            if a.total != b.total { return a.total > b.total }
            if a.order != b.order { return a.order < b.order }
            return a.local < b.local
        }
        var seenKeys = Set<String>()
        var seenIDs = Set<String>()
        var perProvider: [CbProviderID: Int] = [:]
        var results: [CbResult] = []
        var web: CbResult?
        for item in scored {
            let r = item.result
            if r.provider == .web, q.forced != .web { if web == nil { web = r }; continue }
            guard seenIDs.insert(r.id).inserted else { continue }
            if r.action != .noop, !seenKeys.insert(r.action.key).inserted { continue }
            let n = perProvider[r.provider, default: 0]
            if n >= Self.cap(r.provider, s, forced: q.forced != nil) { continue }
            perProvider[r.provider] = n + 1
            results.append(r)
        }
        let limit = s.maxResults
        if let w = web {
            results = Array(results.prefix(max(limit - 1, 0)))
            results.append(w)
        } else {
            results = Array(results.prefix(limit))
        }
        return CbSearchOutput(query: raw, forced: q.forced, results: results)
    }

    public func recordUse(_ r: CbResult) {
        guard settings().useFrecency, let k = r.frecencyKey else { return }
        frecency?.record(k)
    }
}
