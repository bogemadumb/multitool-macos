import Foundation

public enum WhatsAppKind: String, CaseIterable, Sendable {
    case image, video, audio, voice, document, sticker, other

    public var title: String {
        switch self {
        case .image: "Фото"
        case .video: "Видео"
        case .audio: "Аудио"
        case .voice: "Голосовые"
        case .document: "Документы"
        case .sticker: "Стикеры"
        case .other: "Прочее"
        }
    }

    public var defaultKeepDays: Int {
        switch self {
        case .image: 90
        case .video: 30
        case .audio: 60
        case .voice: 30
        case .document: 180
        case .sticker: 14
        case .other: 90
        }
    }

    public var defaultsKey: String { "cleaner.whatsapp.\(rawValue)Days" }
}

// keepDays 0 means "never touch this kind".
public struct WhatsAppRules: Equatable, Sendable {
    public static let daysRange = 0...1095
    public static let containerBundle = "net.whatsapp.WhatsApp"
    public static let groupContainer = "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"

    public var keepDays: [WhatsAppKind: Int]
    public var includeDownloads = true
    public var includeContainer = true

    public init(keepDays: [WhatsAppKind: Int]? = nil) {
        self.keepDays = keepDays ?? Dictionary(uniqueKeysWithValues: WhatsAppKind.allCases.map { ($0, $0.defaultKeepDays) })
    }

    public func days(_ k: WhatsAppKind) -> Int { min(max(keepDays[k] ?? k.defaultKeepDays, Self.daysRange.lowerBound), Self.daysRange.upperBound) }

    public static func load(_ d: KeyValueStoring = UserDefaults.standard) -> WhatsAppRules {
        var r = WhatsAppRules()
        for k in WhatsAppKind.allCases { if let v = d.object(forKey: k.defaultsKey) as? Int { r.keepDays[k] = min(max(v, daysRange.lowerBound), daysRange.upperBound) } }
        return r
    }
}

public enum WhatsAppNames {
    static let words: [String: WhatsAppKind] = ["image": .image, "video": .video, "audio": .audio, "ptt": .voice, "voice": .voice, "sticker": .sticker,
                                                "animation": .video, "gif": .video, "document": .document, "unknown": .other]
    static let androidPrefix: [String: WhatsAppKind] = ["IMG": .image, "VID": .video, "AUD": .audio, "PTT": .voice, "STK": .sticker, "DOC": .document]
    static let isoDate = try! NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})"#)
    static let androidName = try! NSRegularExpression(pattern: #"^([A-Z]{3})-(\d{4})(\d{2})(\d{2})-WA\d+"#)

    static func date(_ y: String, _ m: String, _ d: String) -> Date? {
        var c = DateComponents()
        c.year = Int(y)
        c.month = Int(m)
        c.day = Int(d)
        c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let yy = c.year, (2009...2100).contains(yy), let mm = c.month, (1...12).contains(mm), let dd = c.day, (1...31).contains(dd) else { return nil }
        return cal.date(from: c)
    }

    // "WhatsApp Image 2024-03-05 at 12.34.56.jpeg" and "IMG-20240305-WA0001.jpg" -> kind and the day it was received.
    public static func parse(_ name: String) -> (kind: WhatsAppKind, date: Date?)? {
        let full = NSRange(name.startIndex..., in: name)
        if let m = androidName.firstMatch(in: name, range: full), let r0 = Range(m.range(at: 1), in: name), let kind = androidPrefix[String(name[r0])],
           let ry = Range(m.range(at: 2), in: name), let rm = Range(m.range(at: 3), in: name), let rd = Range(m.range(at: 4), in: name) {
            return (kind, date(String(name[ry]), String(name[rm]), String(name[rd])))
        }
        let lower = name.lowercased()
        guard lower.hasPrefix("whatsapp ") else { return nil }
        let rest = lower.dropFirst("whatsapp ".count)
        guard let word = rest.split(separator: " ").first, let kind = words[String(word)] else { return nil }
        var when: Date?
        if let m = isoDate.firstMatch(in: name, range: full), let ry = Range(m.range(at: 1), in: name), let rm = Range(m.range(at: 2), in: name), let rd = Range(m.range(at: 3), in: name) {
            when = date(String(name[ry]), String(name[rm]), String(name[rd]))
        }
        return (kind, when)
    }

    public static func kind(ofExtension ext: String) -> WhatsAppKind {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif": return .image
        case "mp4", "mov", "m4v", "3gp": return .video
        case "opus", "ogg", "oga": return .voice
        case "m4a", "mp3", "aac", "amr", "caf", "wav": return .audio
        case "webp": return .sticker
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip", "rar", "csv", "rtf", "pages", "numbers", "key": return .document
        default: return .other
        }
    }
}

func scanWhatsApp(_ e: CleanEnv) -> [CleanItem] {
    let rules = e.whatsapp
    var buckets: [String: (kind: WhatsAppKind, paths: [String], bytes: Int64, oldest: Date)] = [:]
    func add(_ source: String, _ kind: WhatsAppKind, _ path: String, _ bytes: Int64, _ date: Date) {
        let key = source + "-" + kind.rawValue
        var b = buckets[key] ?? (kind, [], 0, date)
        b.paths.append(path)
        b.bytes += bytes
        b.oldest = min(b.oldest, date)
        buckets[key] = b
    }
    if rules.includeDownloads {
        let dir = e.path("Downloads")
        for n in childNames(dir) {
            guard let parsed = WhatsAppNames.parse(n) else { continue }
            let keep = rules.days(parsed.kind)
            guard keep > 0 else { continue }
            let p = dir + "/" + n
            guard !isRealDir(p), let st = lstatInfo(p), !st.isLink else { continue }
            let received = parsed.date ?? Date(timeIntervalSince1970: st.mtime)
            let used = e.lastOpened(p) ?? .distantPast
            let last = max(received, used)
            guard last < e.now.addingTimeInterval(-Double(keep) * 86400) else { continue }
            add("dl", parsed.kind, p, st.alloc, last)
        }
    }
    var containerBlocked: String?
    if rules.includeContainer {
        let root = e.path(WhatsAppRules.groupContainer)
        if isRealDir(root) {
            if e.running.contains(where: { $0.bundleId == WhatsAppRules.containerBundle || $0.name == "WhatsApp" }) { containerBlocked = "WhatsApp запущен: закрой его, потом чисти" }
            var seen = 0
            if let en = FileManager.default.enumerator(atPath: root) {
                for case let rel as String in en {
                    seen += 1
                    if seen > 200_000 { break }
                    let name = (rel as NSString).lastPathComponent
                    if name.hasPrefix(".") || name.hasSuffix(".thumb") { continue }
                    let p = root + "/" + rel
                    guard !isRealDir(p), let st = lstatInfo(p), !st.isLink else { continue }
                    let kind = WhatsAppNames.parse(name)?.kind ?? WhatsAppNames.kind(ofExtension: (name as NSString).pathExtension)
                    let keep = rules.days(kind)
                    let when = Date(timeIntervalSince1970: st.mtime)
                    guard keep > 0, when < e.now.addingTimeInterval(-Double(keep) * 86400) else { continue }
                    add("box", kind, p, st.alloc, when)
                }
            }
        }
    }
    return buckets.map { key, b in
        let fromBox = key.hasPrefix("box")
        let title = (fromBox ? "Медиа в приложении WhatsApp: " : "Из Загрузок: ") + b.kind.title.lowercased()
        return CleanItem(id: "wa-" + key, title: title, subtitle: "старше \(rules.days(b.kind)) дн., файлов: \(b.paths.count), самый старый \(days(b.oldest, e.now)) дн.",
                         bytes: b.bytes, paths: b.paths.sorted(), blocked: fromBox ? containerBlocked : nil)
    }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
}
