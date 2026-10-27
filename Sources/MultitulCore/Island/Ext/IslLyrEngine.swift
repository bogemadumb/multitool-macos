import Foundation

public struct IslLyricsQuery: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String = "", duration: TimeInterval? = nil) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init?(track: IslTrack?) {
        guard let t = track, !t.title.isEmpty else { return nil }
        self.init(title: t.title, artist: t.artist, album: t.album, duration: t.duration)
    }

    public var key: String {
        "lyr-" + IslArtworkKey.fnv1a(IslArtworkKey.normalize(artist) + "|" + IslArtworkKey.normalize(title))
    }
}

public enum IslLyricsResult: Equatable, Sendable {
    case synced(IslLrc)
    case plain(IslLrc)
    case instrumental
    case notFound
    case failed(String)
}

public protocol IslLyricsProviding: AnyObject {
    func fetch(_ query: IslLyricsQuery, completion: @escaping (IslLyricsResult) -> Void)
}

public protocol IslLyricsStoring: AnyObject {
    func load(_ key: String) -> String?
    func save(_ key: String, text: String)
    func remove(_ key: String)
}

public protocol IslHTTPFetching: AnyObject {
    func get(_ url: URL, headers: [String: String], completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void)
}

public enum IslLrclib {
    public static let base = "https://lrclib.net/api"
    public static let userAgent = "Multitul/1.0 (https://github.com/example/multitool-macos)"
    public static let durationTolerance: TimeInterval = 3

    public static func getURL(_ q: IslLyricsQuery) -> URL? {
        var c = URLComponents(string: base + "/get")
        var items = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist)]
        if !q.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: q.album)) }
        if let d = q.duration { items.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        c?.queryItems = items
        return c?.url
    }

    public static func searchURL(_ q: IslLyricsQuery) -> URL? {
        var c = URLComponents(string: base + "/search")
        var items = [URLQueryItem(name: "track_name", value: q.title)]
        if !q.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: q.artist)) }
        c?.queryItems = items
        return c?.url
    }

    struct Record {
        var instrumental: Bool
        var synced: String?
        var plain: String?
        var duration: TimeInterval?
    }

    static func record(_ obj: [String: Any]) -> Record {
        func text(_ k: String) -> String? {
            guard let s = obj[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return Record(instrumental: (obj["instrumental"] as? Bool) ?? false, synced: text("syncedLyrics"), plain: text("plainLyrics"), duration: (obj["duration"] as? NSNumber)?.doubleValue)
    }

    static func result(_ r: Record) -> IslLyricsResult {
        if let s = r.synced {
            let lrc = IslLrcParser.parse(s)
            if lrc.isSynced, !lrc.isEmpty { return .synced(lrc) }
        }
        if let p = r.plain {
            let lrc = IslLrcParser.parse(p)
            if !lrc.isEmpty { return .plain(IslLrc(lines: lrc.lines.map { IslLrcLine(time: 0, text: $0.text) }, metadata: lrc.metadata, offset: 0, isSynced: false)) }
        }
        return r.instrumental ? .instrumental : .notFound
    }

    public static func parseGet(_ data: Data) -> IslLyricsResult {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failed("Ответ не разобран") }
        if obj["statusCode"] != nil, obj["syncedLyrics"] == nil, obj["plainLyrics"] == nil { return .notFound }
        return result(record(obj))
    }

    // Prefers synced entries whose duration is close to the track; falls back to the closest plain one.
    public static func parseSearch(_ data: Data, query q: IslLyricsQuery) -> IslLyricsResult {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return .failed("Ответ не разобран") }
        let records = arr.map(record)
        func distance(_ r: Record) -> TimeInterval {
            guard let want = q.duration, let have = r.duration else { return 0 }
            return abs(want - have)
        }
        let close = records.filter { distance($0) <= durationTolerance }
        let ordered = close.sorted { distance($0) < distance($1) }
        if let best = ordered.first(where: { $0.synced != nil }) { return result(best) }
        if let best = ordered.first(where: { $0.plain != nil }) { return result(best) }
        if let inst = ordered.first(where: { $0.instrumental }) { return result(inst) }
        return .notFound
    }
}

public final class IslLrclibProvider: IslLyricsProviding {
    private let http: IslHTTPFetching

    public init(http: IslHTTPFetching) { self.http = http }

    public func fetch(_ query: IslLyricsQuery, completion: @escaping (IslLyricsResult) -> Void) {
        guard let url = IslLrclib.getURL(query) else { completion(.failed("Адрес не собран")); return }
        let headers = ["User-Agent": IslLrclib.userAgent]
        http.get(url, headers: headers) { [http] result in
            switch result {
            case .failure(let e):
                completion(.failed(e.localizedDescription))
            case .success(let r):
                if r.status == 200 {
                    let parsed = IslLrclib.parseGet(r.data)
                    if parsed == .notFound { self.search(query, headers: headers, http: http, completion: completion) } else { completion(parsed) }
                } else if r.status == 404 {
                    self.search(query, headers: headers, http: http, completion: completion)
                } else {
                    completion(.failed("Сервер ответил \(r.status)"))
                }
            }
        }
    }

    private func search(_ q: IslLyricsQuery, headers: [String: String], http: IslHTTPFetching, completion: @escaping (IslLyricsResult) -> Void) {
        guard let url = IslLrclib.searchURL(q) else { completion(.notFound); return }
        http.get(url, headers: headers) { result in
            switch result {
            case .failure(let e): completion(.failed(e.localizedDescription))
            case .success(let r): completion(r.status == 200 ? IslLrclib.parseSearch(r.data, query: q) : (r.status == 404 ? .notFound : .failed("Сервер ответил \(r.status)")))
            }
        }
    }
}

public enum IslLyricsCodec {
    public static let notFoundRetry: TimeInterval = 24 * 3600

    public static func encode(_ r: IslLyricsResult, now: Date) -> String? {
        switch r {
        case .synced(let l): return l.lines.map { "[\(stamp($0.time))]\($0.text)" }.joined(separator: "\n")
        case .plain(let l): return "#plain\n" + l.lines.map(\.text).joined(separator: "\n")
        case .instrumental: return "#instrumental"
        case .notFound: return "#notfound \(Int(now.timeIntervalSince1970))"
        case .failed: return nil
        }
    }

    public static func decode(_ text: String, now: Date) -> IslLyricsResult? {
        if text.hasPrefix("#instrumental") { return .instrumental }
        if text.hasPrefix("#notfound") {
            let ts = Double(text.dropFirst("#notfound".count).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return now.timeIntervalSince1970 - ts < notFoundRetry ? .notFound : nil
        }
        if text.hasPrefix("#plain\n") {
            let body = String(text.dropFirst("#plain\n".count))
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { IslLrcLine(time: 0, text: String($0)) }
            return lines.isEmpty ? nil : .plain(IslLrc(lines: lines, isSynced: false))
        }
        let lrc = IslLrcParser.parse(text)
        if lrc.isEmpty { return nil }
        return lrc.isSynced ? .synced(lrc) : .plain(lrc)
    }

    static func stamp(_ t: TimeInterval) -> String {
        let cs = Int((max(t, 0) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }
}

public struct IslLyrSettings: Equatable, Sendable {
    public static let leadRange: ClosedRange<Double> = -1...2
    public var fetchOnline = true
    public var lead = 0.2
    public var showUnderTrack = true
    public var userOffset = 0.0

    public init() {}

    public var sanitized: IslLyrSettings {
        var s = self
        s.lead = IslSettings.clamp(lead, Self.leadRange)
        s.userOffset = IslSettings.clamp(userOffset, -10...10)
        return s
    }
}

public final class IslLyrSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.lyrics."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslLyrSettings {
        var s = IslLyrSettings()
        let p = Self.prefix
        s.fetchOnline = a.bool(p + "fetchOnline", s.fetchOnline)
        s.lead = a.double(p + "lead", s.lead)
        s.showUnderTrack = a.bool(p + "showUnderTrack", s.showUnderTrack)
        s.userOffset = a.double(p + "userOffset", s.userOffset)
        return s.sanitized
    }

    public func save(_ settings: IslLyrSettings) {
        let s = settings.sanitized
        let b = IslLyrSettings()
        let p = Self.prefix
        a.put(p + "fetchOnline", s.fetchOnline, b.fetchOnline)
        a.put(p + "lead", s.lead, b.lead)
        a.put(p + "showUnderTrack", s.showUnderTrack, b.showUnderTrack)
        a.put(p + "userOffset", s.userOffset, b.userOffset)
    }
}

public struct IslLyricsFrame: Equatable, Sendable {
    public var index: Int?
    public var line: String
    public var next: String?
    public var progress: Double
    public var wordIndex: Int?
}

public final class IslLyricsEngine {
    public enum State: Equatable {
        case idle
        case loading
        case ready(IslLrc)
        case instrumental
        case notFound
        case failed(String)
    }

    public private(set) var state = State.idle
    public private(set) var query: IslLyricsQuery?
    public var settings = IslLyrSettings()
    public var onChange: (() -> Void)?
    private let provider: IslLyricsProviding
    private let store: IslLyricsStoring
    private var generation = 0
    private let clock: () -> Date

    public init(provider: IslLyricsProviding, store: IslLyricsStoring, clock: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.store = store
        self.clock = clock
    }

    public func trackChanged(_ q: IslLyricsQuery?) {
        guard q != query else { return }
        query = q
        generation += 1
        guard let q else { set(.idle); return }
        if let text = store.load(q.key), let cached = IslLyricsCodec.decode(text, now: clock()) {
            apply(cached)
            return
        }
        guard settings.fetchOnline else { set(.notFound); return }
        set(.loading)
        let gen = generation
        provider.fetch(q) { [weak self] result in
            guard let self, self.generation == gen else { return }
            if let text = IslLyricsCodec.encode(result, now: self.clock()) { self.store.save(q.key, text: text) }
            self.apply(result)
        }
    }

    @discardableResult
    public func importText(_ text: String) -> Bool {
        guard let q = query else { return false }
        let lrc = IslLrcParser.parse(text)
        guard !lrc.isEmpty else { return false }
        let result: IslLyricsResult = lrc.isSynced ? .synced(lrc) : .plain(lrc)
        if let enc = IslLyricsCodec.encode(result, now: clock()) { store.save(q.key, text: lrc.isSynced ? text : enc) }
        apply(result)
        return true
    }

    public func clearCurrent() {
        guard let q = query else { return }
        store.remove(q.key)
        let keep = q
        query = nil
        trackChanged(keep)
    }

    private func apply(_ r: IslLyricsResult) {
        switch r {
        case .synced(let l), .plain(let l): set(.ready(l))
        case .instrumental: set(.instrumental)
        case .notFound: set(.notFound)
        case .failed(let m): set(.failed(m))
        }
    }

    private func set(_ s: State) {
        state = s
        onChange?()
    }

    public func frame(at elapsed: TimeInterval) -> IslLyricsFrame? {
        guard case .ready(let lrc) = state, lrc.isSynced else { return nil }
        let t = elapsed + settings.userOffset
        guard let i = lrc.index(at: t, lead: settings.lead) else {
            return IslLyricsFrame(index: nil, line: "", next: lrc.lines.first?.text, progress: 0, wordIndex: nil)
        }
        let nextText = i + 1 < lrc.lines.count ? lrc.lines[i + 1].text : nil
        return IslLyricsFrame(index: i, line: lrc.lines[i].text, next: nextText, progress: lrc.progress(in: i, at: t + settings.lead), wordIndex: lrc.wordIndex(in: i, at: t + settings.lead))
    }
}
