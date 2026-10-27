import Foundation

public struct ShotNameContext: Equatable, Sendable {
    public var date: Date
    public var mode: ShotMode
    public var appName: String?
    public var windowTitle: String?
    public var width: Int
    public var height: Int
    public var counter: Int
    public var timeZone: TimeZone

    public init(date: Date, mode: ShotMode = .area, appName: String? = nil, windowTitle: String? = nil, width: Int = 0, height: Int = 0,
                counter: Int = 1, timeZone: TimeZone = .current) {
        self.date = date
        self.mode = mode
        self.appName = appName
        self.windowTitle = windowTitle
        self.width = width
        self.height = height
        self.counter = counter
        self.timeZone = timeZone
    }
}

public struct ShotNameToken: Equatable, Sendable {
    public let token: String
    public let help: String
}

public enum ShotNaming {
    public static let defaultTemplate = "Снимок экрана {yyyy}-{MM}-{dd} в {HH}.{mm}.{ss}"
    public static let maxNameBytes = 200

    public static let tokens: [ShotNameToken] = [
        ShotNameToken(token: "{yyyy}", help: "год, 4 цифры"),
        ShotNameToken(token: "{yy}", help: "год, 2 цифры"),
        ShotNameToken(token: "{MM}", help: "месяц"),
        ShotNameToken(token: "{dd}", help: "день"),
        ShotNameToken(token: "{HH}", help: "часы, 24-часовой формат"),
        ShotNameToken(token: "{mm}", help: "минуты"),
        ShotNameToken(token: "{ss}", help: "секунды"),
        ShotNameToken(token: "{date}", help: "дата 2026-10-23"),
        ShotNameToken(token: "{time}", help: "время 14.05.33"),
        ShotNameToken(token: "{unix}", help: "секунды с 1970 года"),
        ShotNameToken(token: "{counter}", help: "сквозной номер; {counter:4} дополняет нулями до 4 знаков"),
        ShotNameToken(token: "{app}", help: "приложение, в котором снято"),
        ShotNameToken(token: "{title}", help: "заголовок окна"),
        ShotNameToken(token: "{mode}", help: "вид съёмки: область, окно, экран"),
        ShotNameToken(token: "{w}", help: "ширина в пикселях"),
        ShotNameToken(token: "{h}", help: "высота в пикселях"),
        ShotNameToken(token: "{size}", help: "размер, например 1440x900")
    ]

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(max(v, 0))
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    public static func render(template: String, context c: ShotNameContext) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = c.timeZone
        let d = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: c.date)
        let year = d.year ?? 1970
        func value(_ key: String) -> String? {
            switch key {
            case "yyyy": return pad(year, 4)
            case "yy": return pad(year % 100, 2)
            case "MM": return pad(d.month ?? 1, 2)
            case "dd": return pad(d.day ?? 1, 2)
            case "HH": return pad(d.hour ?? 0, 2)
            case "mm": return pad(d.minute ?? 0, 2)
            case "ss": return pad(d.second ?? 0, 2)
            case "date": return "\(pad(year, 4))-\(pad(d.month ?? 1, 2))-\(pad(d.day ?? 1, 2))"
            case "time": return "\(pad(d.hour ?? 0, 2)).\(pad(d.minute ?? 0, 2)).\(pad(d.second ?? 0, 2))"
            case "unix": return String(Int(c.date.timeIntervalSince1970))
            case "counter": return String(max(c.counter, 0))
            case "app": return c.appName ?? ""
            case "title": return c.windowTitle ?? ""
            case "mode": return c.mode.title.lowercased()
            case "w": return String(c.width)
            case "h": return String(c.height)
            case "size": return "\(c.width)x\(c.height)"
            default: return nil
            }
        }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = String(template[template.index(after: i)..<close])
                if inner.hasPrefix("counter:"), let w = Int(inner.dropFirst(8)), (1...12).contains(w) {
                    out += pad(c.counter, w)
                    i = template.index(after: close)
                    continue
                }
                if let v = value(inner) {
                    out += v
                    i = template.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = template.index(after: i)
        }
        return out
    }

    public static func sanitize(_ raw: String) -> String {
        var s = ""
        for u in raw.unicodeScalars {
            if u == "/" || u == ":" || u == "\\" || u.value < 32 || u.value == 127 { s.unicodeScalars.append("-") } else { s.unicodeScalars.append(u) }
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        var bytes = 0
        var cut = ""
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > maxNameBytes { break }
            bytes += n
            cut.append(ch)
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
    }

    public static func baseName(template: String, context: ShotNameContext) -> String {
        let name = sanitize(render(template: template, context: context))
        if !name.isEmpty { return name }
        let fallback = sanitize(render(template: defaultTemplate, context: context))
        return fallback.isEmpty ? "Screenshot" : fallback
    }

    public static func uniqueFileName(base: String, ext: String, exists: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = base + suffix
        var n = 2
        while exists(candidate) {
            candidate = "\(base) \(n)\(suffix)"
            n += 1
            if n > 10_000 { return "\(base) \(UUID().uuidString.prefix(8))\(suffix)" }
        }
        return candidate
    }

    public static func fileName(template: String, context: ShotNameContext, format: ShotFormat, exists: (String) -> Bool) -> String {
        uniqueFileName(base: baseName(template: template, context: context), ext: format.fileExtension, exists: exists)
    }

    public static func usesCounter(_ template: String) -> Bool {
        template.contains("{counter}") || template.contains("{counter:")
    }
}

public final class ShotCounter {
    public static let key = "screenshot.counter"
    private let kv: KeyValueStoring

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { self.kv = kv }

    public var current: Int { (kv.object(forKey: Self.key) as? Int) ?? 0 }

    @discardableResult
    public func next() -> Int {
        let n = current + 1
        kv.set(n, forKey: Self.key)
        return n
    }

    public func reset() { kv.removeObject(forKey: Self.key) }
}
