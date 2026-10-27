import Foundation
import CoreGraphics

public enum OcrLevel: String, CaseIterable, Sendable {
    case fast, accurate

    public var title: String { self == .fast ? "Быстро" : "Точно" }
}

public struct OcrRequestConfig: Equatable, Sendable {
    public static let defaultLanguages = ["ru-RU", "en-US"]
    public var level = OcrLevel.accurate
    public var languages = OcrRequestConfig.defaultLanguages
    public var usesLanguageCorrection = true
    public var minimumTextHeight = 0.0

    public init() {}

    public var sanitized: OcrRequestConfig {
        var s = self
        var seen = Set<String>()
        s.languages = languages.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        if s.languages.isEmpty { s.languages = Self.defaultLanguages }
        s.minimumTextHeight = ToolsClamp.double(minimumTextHeight, 0...1)
        return s
    }
}

public struct OcrSettings: Equatable, Sendable {
    public var request = OcrRequestConfig()
    public var removeLineBreaks = false
    public var detectQr = true
    public var minConfidence = 0.0
    public var showHud = true

    public init() {}

    public var sanitized: OcrSettings {
        var s = self
        s.request = request.sanitized
        s.minConfidence = ToolsClamp.double(minConfidence, 0...1)
        return s
    }
}

public final class OcrSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> OcrSettings {
        var s = OcrSettings()
        let p = "screenOcr."
        s.removeLineBreaks = a.bool(p + "removeLineBreaks", s.removeLineBreaks)
        s.detectQr = a.bool(p + "detectQr", s.detectQr)
        s.minConfidence = a.double(p + "minConfidence", s.minConfidence)
        s.showHud = a.bool(p + "showHud", s.showHud)
        if let v = a.string(p + "level"), let l = OcrLevel(rawValue: v) { s.request.level = l }
        if let l = a.strings(p + "languages") { s.request.languages = l }
        s.request.usesLanguageCorrection = a.bool(p + "languageCorrection", s.request.usesLanguageCorrection)
        s.request.minimumTextHeight = a.double(p + "minimumTextHeight", s.request.minimumTextHeight)
        return s.sanitized
    }

    public func save(_ settings: OcrSettings) {
        let s = settings.sanitized
        let b = OcrSettings()
        let p = "screenOcr."
        a.put(p + "removeLineBreaks", s.removeLineBreaks, b.removeLineBreaks)
        a.put(p + "detectQr", s.detectQr, b.detectQr)
        a.put(p + "minConfidence", s.minConfidence, b.minConfidence)
        a.put(p + "showHud", s.showHud, b.showHud)
        a.put(p + "level", s.request.level.rawValue, b.request.level.rawValue)
        if s.request.languages == b.request.languages { a.kv.removeObject(forKey: p + "languages") } else { a.kv.set(s.request.languages, forKey: p + "languages") }
        a.put(p + "languageCorrection", s.request.usesLanguageCorrection, b.request.usesLanguageCorrection)
        a.put(p + "minimumTextHeight", s.request.minimumTextHeight, b.request.minimumTextHeight)
    }
}

public struct OcrLine: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var box: CGRect

    public init(_ text: String, confidence: Double = 1, box: CGRect = .zero) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

public enum OcrPostProcessor {
    public static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{200B}", with: "")
        t = t.replacingOccurrences(of: "\t", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Row {
        var items: [OcrLine]
        var midY: Double
        var height: Double
    }

    static func rows(_ lines: [OcrLine]) -> [Row] {
        let sorted = lines.sorted { $0.box.midY != $1.box.midY ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
        var rows: [Row] = []
        for l in sorted {
            let h = max(Double(l.box.height), 0.001)
            if let last = rows.last, abs(Double(l.box.midY) - last.midY) <= 0.5 * min(h, last.height) {
                rows[rows.count - 1].items.append(l)
                rows[rows.count - 1].height = max(last.height, h)
            } else {
                rows.append(Row(items: [l], midY: Double(l.box.midY), height: h))
            }
        }
        return rows.map { r in
            var r = r
            r.items.sort { $0.box.minX < $1.box.minX }
            return r
        }
    }

    public static func assemble(_ input: [OcrLine], removeLineBreaks: Bool, minConfidence: Double = 0) -> String {
        let lines = input.filter { $0.confidence >= minConfidence }.map { OcrLine(normalize($0.text), confidence: $0.confidence, box: $0.box) }.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return "" }
        let hasGeometry = lines.contains { $0.box.height > 0 }
        let built: [(text: String, gapAbove: Bool)]
        if hasGeometry {
            let rs = rows(lines)
            built = rs.enumerated().map { i, r in
                let gap = i > 0 && (rs[i - 1].midY - r.midY) > 1.9 * max(rs[i - 1].height, r.height)
                return (r.items.map(\.text).joined(separator: " "), gap)
            }
        } else {
            built = lines.map { ($0.text, false) }
        }
        if removeLineBreaks { return joinFlat(built.map(\.text)) }
        var out = ""
        for (i, b) in built.enumerated() {
            if i > 0 { out += b.gapAbove ? "\n\n" : "\n" }
            out += b.text
        }
        return out
    }

    static func joinFlat(_ parts: [String]) -> String {
        var out = ""
        for p in parts {
            if out.isEmpty { out = p; continue }
            if out.hasSuffix("-"), out.dropLast().last?.isLetter == true, p.first?.isLowercase == true {
                out.removeLast()
                out += p
            } else {
                out += " " + p
            }
        }
        return out
    }
}

public enum QrContent: Equatable, Sendable {
    case url(URL)
    case email(String)
    case phone(String)
    case wifi(ssid: String, password: String, security: String)
    case text(String)

    public var title: String {
        switch self {
        case .url: "Ссылка"
        case .email: "Почта"
        case .phone: "Телефон"
        case .wifi: "Wi-Fi"
        case .text: "Текст"
        }
    }

    public var copyText: String {
        switch self {
        case .url(let u): u.absoluteString
        case .email(let e): e
        case .phone(let p): p
        case .wifi(_, let password, _): password
        case .text(let t): t
        }
    }

    public var displayText: String {
        switch self {
        case .wifi(let ssid, let password, let security): "Сеть: \(ssid)\nПароль: \(password.isEmpty ? "—" : password)\nЗащита: \(security.isEmpty ? "—" : security)"
        default: copyText
        }
    }

    public var openURL: URL? {
        switch self {
        case .url(let u): u
        case .email(let e): URL(string: "mailto:" + e)
        case .phone(let p): URL(string: "tel:" + p.filter { $0.isNumber || $0 == "+" })
        default: nil
        }
    }
}

public enum QrClassifier {
    private static let openableSchemes: Set<String> = ["http", "https"]

    public static func classify(_ payload: String) -> QrContent {
        let p = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = p.lowercased()
        if lower.hasPrefix("wifi:"), let w = wifi(String(p.dropFirst(5))) { return w }
        if lower.hasPrefix("mailto:") {
            let addr = String(p.dropFirst(7)).split(separator: "?").first.map(String.init) ?? ""
            if isEmail(addr) { return .email(addr) }
        }
        if lower.hasPrefix("tel:") {
            let num = String(p.dropFirst(4))
            if !num.isEmpty, num.allSatisfy({ $0.isNumber || "+-() ".contains($0) }) { return .phone(num) }
        }
        if isEmail(p) { return .email(p) }
        if !p.contains(where: { $0.isWhitespace }), let u = URL(string: p), let scheme = u.scheme?.lowercased(), openableSchemes.contains(scheme), let host = u.host, !host.isEmpty {
            return .url(u)
        }
        return .text(p)
    }

    static func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !s.contains(where: { $0.isWhitespace }) else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    static func wifi(_ body: String) -> QrContent? {
        var fields: [String: String] = [:]
        var key = "", value = "", inKey = true, escaped = false
        func flush() {
            if !key.isEmpty { fields[key] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in body {
            if escaped { if inKey { key.append(ch) } else { value.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == ":" && inKey { inKey = false; continue }
            if ch == ";" { flush(); continue }
            if inKey { key.append(ch) } else { value.append(ch) }
        }
        flush()
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        return .wifi(ssid: ssid, password: fields["P"] ?? "", security: fields["T"] ?? "")
    }
}

public protocol OcrRecognizing: AnyObject {
    func recognizeText(in image: CGImage, config: OcrRequestConfig) throws -> [OcrLine]
    func detectCodes(in image: CGImage) -> [String]
}

public enum OcrOutcome: Equatable, Sendable {
    case text(String)
    case codes([QrContent])
    case nothing
    case failed(String)
}

public final class ScreenOcrEngine {
    public static let minSide = 4
    public var settings: OcrSettings
    private let recognizer: OcrRecognizing
    private let clipboard: TextWriting

    public init(recognizer: OcrRecognizing, clipboard: TextWriting, settings: OcrSettings = OcrSettings()) {
        self.recognizer = recognizer
        self.clipboard = clipboard
        self.settings = settings.sanitized
    }

    public func process(_ image: CGImage) -> OcrOutcome {
        guard image.width >= Self.minSide, image.height >= Self.minSide else { return .nothing }
        if settings.detectQr {
            let codes = recognizer.detectCodes(in: image).map(QrClassifier.classify)
            if !codes.isEmpty { return .codes(codes) }
        }
        do {
            let lines = try recognizer.recognizeText(in: image, config: settings.request)
            let text = OcrPostProcessor.assemble(lines, removeLineBreaks: settings.removeLineBreaks, minConfidence: settings.minConfidence)
            guard !text.isEmpty else { return .nothing }
            clipboard.write(text)
            return .text(text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
