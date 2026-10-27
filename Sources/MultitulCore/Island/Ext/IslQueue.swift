import Foundation

public enum IslQueueApp: String, Sendable, CaseIterable {
    case music, spotify

    public var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    public var title: String { self == .music ? "Музыка" : "Spotify" }

    public init?(bundleID: String?) {
        guard let b = bundleID, let a = Self.allCases.first(where: { $0.bundleID == b }) else { return nil }
        self = a
    }
}

public struct IslQueueItem: Equatable, Identifiable, Sendable {
    public var position: Int
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    public var id: Int { position }

    public init(position: Int, title: String, artist: String = "", album: String = "", duration: TimeInterval? = nil) {
        self.position = position
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct IslQueueMeta: Equatable, Sendable {
    public var currentIndex: Int
    public var total: Int
    public var shuffle: Bool
    public var playlist: String

    public init(currentIndex: Int, total: Int, shuffle: Bool, playlist: String) {
        self.currentIndex = currentIndex
        self.total = total
        self.shuffle = shuffle
        self.playlist = playlist
    }
}

public enum IslQueueResult: Equatable, Sendable {
    case items([IslQueueItem], IslQueueMeta)
    case empty(IslQueueMeta?)
    case unsupported(String)
    case notRunning
    case stopped
    case needsAutomation
    case failed(String)
}

public enum IslScriptOutput: Equatable, Sendable {
    case text(String)
    case failure(code: Int, message: String)
}

public protocol IslScriptRunning: AnyObject {
    func run(_ source: String) -> IslScriptOutput
}

public enum IslQueueScripts {
    public static let recordSeparator: Character = "\u{1E}"
    public static let fieldSeparator: Character = "\u{1F}"

    public static func upNext(_ app: IslQueueApp, limit: Int) -> String? {
        guard app == .music else { return nil }
        let n = ToolsClamp.int(limit, IslQueueSettings.limitRange)
        return """
        if application id "com.apple.Music" is not running then return "ERR\u{1F}notrunning"
        tell application id "com.apple.Music"
            if player state is stopped then return "ERR\u{1F}stopped"
            set RS to (ASCII character 30)
            set FS to (ASCII character 31)
            set pl to current playlist
            set total to count of tracks of pl
            set idx to index of current track
            set shuf to "0"
            if shuffle enabled then set shuf to "1"
            set out to "META" & FS & idx & FS & total & FS & shuf & FS & (name of pl)
            set last to idx + \(n)
            if last > total then set last to total
            repeat with i from (idx + 1) to last
                set t to track i of pl
                set out to out & RS & "TRK" & FS & i & FS & (name of t) & FS & (artist of t) & FS & (album of t) & FS & (duration of t)
            end repeat
            return out
        end tell
        """
    }

    public static func play(_ app: IslQueueApp, position: Int) -> String? {
        guard app == .music, position > 0, position < 1_000_000 else { return nil }
        return "tell application id \"com.apple.Music\" to play track \(position) of current playlist"
    }
}

public enum IslQueueParser {
    public static func parse(_ raw: String) -> IslQueueResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed("Плеер ничего не ответил") }
        let records = text.split(separator: IslQueueScripts.recordSeparator, omittingEmptySubsequences: true).map(String.init)
        guard let head = records.first else { return .failed("Плеер ничего не ответил") }
        let hf = head.split(separator: IslQueueScripts.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        if hf.first == "ERR" {
            switch hf.count > 1 ? hf[1] : "" {
            case "notrunning": return .notRunning
            case "stopped": return .stopped
            default: return .failed(hf.dropFirst().joined(separator: " "))
            }
        }
        guard hf.first == "META", hf.count >= 5, let idx = Int(hf[1]), let total = Int(hf[2]) else { return .failed("Ответ плеера не разобран") }
        let meta = IslQueueMeta(currentIndex: idx, total: total, shuffle: hf[3] == "1", playlist: hf[4])
        var items: [IslQueueItem] = []
        for r in records.dropFirst() {
            let f = r.split(separator: IslQueueScripts.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, f[0] == "TRK", let pos = Int(f[1]) else { continue }
            let d = Double(f[5].replacingOccurrences(of: ",", with: "."))
            items.append(IslQueueItem(position: pos, title: f[2], artist: f[3], album: f[4], duration: d.flatMap { $0 > 0 ? $0 : nil }))
        }
        return items.isEmpty ? .empty(meta) : .items(items, meta)
    }
}

public struct IslQueueSettings: Equatable, Sendable {
    public static let limitRange = 1...20
    public var limit = 8
    public var refreshSeconds = 5

    public init() {}

    public var sanitized: IslQueueSettings {
        var s = self
        s.limit = ToolsClamp.int(limit, Self.limitRange)
        s.refreshSeconds = ToolsClamp.int(refreshSeconds, 2...60)
        return s
    }
}

public final class IslQueueSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.queue."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslQueueSettings {
        var s = IslQueueSettings()
        s.limit = a.int(Self.prefix + "limit", s.limit)
        s.refreshSeconds = a.int(Self.prefix + "refreshSeconds", s.refreshSeconds)
        return s.sanitized
    }

    public func save(_ settings: IslQueueSettings) {
        let s = settings.sanitized
        let b = IslQueueSettings()
        a.put(Self.prefix + "limit", s.limit, b.limit)
        a.put(Self.prefix + "refreshSeconds", s.refreshSeconds, b.refreshSeconds)
    }
}

public protocol IslQueueProviding: AnyObject {
    func upNext(app: IslQueueApp, limit: Int) -> IslQueueResult
    func play(app: IslQueueApp, position: Int) -> Bool
}

public final class IslQueueProvider: IslQueueProviding {
    private let runner: IslScriptRunning

    public init(runner: IslScriptRunning) { self.runner = runner }

    public func upNext(app: IslQueueApp, limit: Int) -> IslQueueResult {
        guard let script = IslQueueScripts.upNext(app, limit: limit) else {
            return .unsupported("\(app.title) не отдаёт очередь наружу")
        }
        switch runner.run(script) {
        case .text(let t): return IslQueueParser.parse(t)
        case .failure(let code, let message):
            switch code {
            case -1743: return .needsAutomation
            case -600, -609: return .notRunning
            default: return .failed(message.isEmpty ? "Ошибка \(code)" : message)
            }
        }
    }

    public func play(app: IslQueueApp, position: Int) -> Bool {
        guard let script = IslQueueScripts.play(app, position: position) else { return false }
        if case .text = runner.run(script) { return true }
        return false
    }
}

public enum IslQueueFormat {
    public static func note(_ r: IslQueueResult, app: IslQueueApp?) -> String? {
        switch r {
        case .items(_, let m): return m.shuffle ? "Включено перемешивание: показан порядок плейлиста, а не реальная очередь" : nil
        case .empty: return "Дальше в списке ничего нет"
        case .unsupported(let s): return s
        case .notRunning: return "Плеер не запущен"
        case .stopped: return "Ничего не играет"
        case .needsAutomation: return "Разреши Мультитулу управлять плеером: Автоматизация в настройках системы"
        case .failed(let m): return "Не удалось получить очередь: \(m)"
        }
    }
}
