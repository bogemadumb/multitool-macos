import Foundation

public struct ShotUploadSettings: Equatable, Sendable {
    public static let keychainService = "dev.multitool.app.screenshot.upload"
    public static let maxBytesLimit = 100_000_000

    public var endpoint = ""
    public var fileField = "file"
    public var ttlField = "ttl"
    public var ttlInSeconds = false
    public var authHeader = "Authorization"
    public var authPrefix = "Bearer "
    public var extraFields: [String] = []
    public var responsePath = "url"
    public var maxBytes = 25_000_000

    public init() {}

    public var isConfigured: Bool { ShotUploadBuilder.validate(endpoint: endpoint) == nil }

    public var sanitized: ShotUploadSettings {
        var s = self
        s.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        s.fileField = ShotMultipart.safeToken(fileField, fallback: "file")
        s.ttlField = ttlField.isEmpty ? "" : ShotMultipart.safeToken(ttlField, fallback: "ttl")
        s.authHeader = authHeader.isEmpty ? "" : ShotMultipart.safeToken(authHeader, fallback: "Authorization")
        s.responsePath = responsePath.trimmingCharacters(in: .whitespacesAndNewlines)
        s.maxBytes = ToolsClamp.int(maxBytes, 1000...Self.maxBytesLimit)
        s.extraFields = extraFields.filter { ShotUploadBuilder.parseField($0) != nil }
        return s
    }
}

public final class ShotUploadSettingsStore {
    private let a: KVAccess

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> ShotUploadSettings {
        var s = ShotUploadSettings()
        let p = "screenshot.upload."
        s.endpoint = a.string(p + "endpoint") ?? s.endpoint
        s.fileField = a.string(p + "fileField") ?? s.fileField
        s.ttlField = a.string(p + "ttlField") ?? s.ttlField
        s.ttlInSeconds = a.bool(p + "ttlInSeconds", s.ttlInSeconds)
        s.authHeader = a.string(p + "authHeader") ?? s.authHeader
        s.authPrefix = a.string(p + "authPrefix") ?? s.authPrefix
        s.extraFields = a.strings(p + "extraFields") ?? s.extraFields
        s.responsePath = a.string(p + "responsePath") ?? s.responsePath
        s.maxBytes = a.int(p + "maxBytes", s.maxBytes)
        return s.sanitized
    }

    public func save(_ settings: ShotUploadSettings) {
        let s = settings.sanitized
        let b = ShotUploadSettings()
        let p = "screenshot.upload."
        a.put(p + "endpoint", s.endpoint, b.endpoint)
        a.put(p + "fileField", s.fileField, b.fileField)
        a.put(p + "ttlField", s.ttlField, b.ttlField)
        a.put(p + "ttlInSeconds", s.ttlInSeconds, b.ttlInSeconds)
        a.put(p + "authHeader", s.authHeader, b.authHeader)
        a.put(p + "authPrefix", s.authPrefix, b.authPrefix)
        if s.extraFields == b.extraFields { a.kv.removeObject(forKey: p + "extraFields") } else { a.kv.set(s.extraFields, forKey: p + "extraFields") }
        a.put(p + "responsePath", s.responsePath, b.responsePath)
        a.put(p + "maxBytes", s.maxBytes, b.maxBytes)
    }
}

public enum ShotMultipart {
    public static func safeToken(_ s: String, fallback: String) -> String {
        let t = s.unicodeScalars.filter { $0.isASCII && $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != ":" && $0 != ";" }
        let r = String(String.UnicodeScalarView(t))
        return r.isEmpty ? fallback : r
    }

    public static func escapeHeaderValue(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u == "\"" { out += "%22" } else if u == "\\" { out += "_" } else if u.value < 32 || u.value == 127 { out += " " } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    public static func contentType(boundary: String) -> String { "multipart/form-data; boundary=\(boundary)" }

    public static func boundary(random: () -> UInt64 = { UInt64.random(in: UInt64.min...UInt64.max) }) -> String {
        "MultitulBoundary" + String(random(), radix: 16)
    }

    public static func body(boundary: String, fields: [(String, String)], file: (field: String, name: String, mime: String, data: Data)) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\n")
            add("Content-Disposition: form-data; name=\"\(escapeHeaderValue(k))\"\r\n\r\n")
            add(v.replacingOccurrences(of: "\r\n", with: "\n"))
            add("\r\n")
        }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"\(escapeHeaderValue(file.field))\"; filename=\"\(escapeHeaderValue(file.name))\"\r\n")
        add("Content-Type: \(file.mime)\r\n\r\n")
        d.append(file.data)
        add("\r\n--\(boundary)--\r\n")
        return d
    }
}

public enum ShotUploadError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case badEndpoint(String)
    case tooLarge(Int)
    case http(Int)
    case transport(String)
    case badResponse
    case missingToken

    public var description: String {
        switch self {
        case .notConfigured: "Адрес сервиса не задан"
        case .badEndpoint(let m): "Адрес сервиса не подходит: \(m)"
        case .tooLarge(let n): "Файл слишком большой (\(n / 1_000_000) МБ)"
        case .http(let c): "Сервис ответил кодом \(c)"
        case .transport(let m): "Нет связи с сервисом: \(m)"
        case .badResponse: "В ответе сервиса нет ссылки"
        case .missingToken: "Ключ сервиса не найден в связке ключей"
        }
    }
}

public struct ShotUploadJob: Equatable, Sendable {
    public var fileName: String
    public var data: Data
    public var format: ShotFormat
    public var ttl: ShotLinkTTL

    public init(fileName: String, data: Data, format: ShotFormat, ttl: ShotLinkTTL) {
        self.fileName = fileName
        self.data = data
        self.format = format
        self.ttl = ttl
    }
}

public struct ShotUploadResult: Equatable, Sendable {
    public var url: String
    public var expires: Date
}

public protocol ShotUploading: AnyObject {
    func upload(_ job: ShotUploadJob, now: Date) throws -> ShotUploadResult
}

public enum ShotUploadBuilder {
    public static func validate(endpoint: String) -> String? {
        let e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return "пусто" }
        guard let c = URLComponents(string: e), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else { return "не ссылка" }
        guard c.user == nil, c.password == nil else { return "логин и пароль в адресе запрещены" }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { return "нужен https" }
        return nil
    }

    public static func parseField(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: eq)...])
        guard !k.isEmpty, k.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0 != "\"" }) else { return nil }
        return (k, v)
    }

    public static func request(settings raw: ShotUploadSettings, job: ShotUploadJob, token: String?, boundary: String) throws -> HTTPRequest {
        let s = raw.sanitized
        if s.endpoint.isEmpty { throw ShotUploadError.notConfigured }
        if let why = validate(endpoint: s.endpoint) { throw ShotUploadError.badEndpoint(why) }
        guard job.data.count <= s.maxBytes else { throw ShotUploadError.tooLarge(job.data.count) }
        var fields: [(String, String)] = s.extraFields.compactMap(parseField)
        if !s.ttlField.isEmpty { fields.append((s.ttlField, String(s.ttlInSeconds ? job.ttl.seconds : job.ttl.hours))) }
        let name = ShotNaming.sanitize(job.fileName).isEmpty ? "screenshot." + job.format.fileExtension : job.fileName
        let body = ShotMultipart.body(boundary: boundary, fields: fields, file: (s.fileField, name, job.format.mimeType, job.data))
        var headers = ["Content-Type": ShotMultipart.contentType(boundary: boundary), "Accept": "application/json, text/plain"]
        if !s.authHeader.isEmpty {
            guard let token, !token.isEmpty else { throw ShotUploadError.missingToken }
            headers[s.authHeader] = s.authPrefix + token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return HTTPRequest(url: s.endpoint, method: "POST", headers: headers, body: body, timeout: 60)
    }

    public static func extractURL(from response: HTTPResponse, path: String) -> String? {
        let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed]) {
            let value: Any? = path.isEmpty ? obj : lookup(obj, path)
            if let s = value as? String, isWebURL(s) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        return isWebURL(text) ? text : nil
    }

    static func lookup(_ obj: Any, _ path: String) -> Any? {
        var cur: Any? = obj
        for part in path.split(separator: ".").map(String.init) {
            if let d = cur as? [String: Any] { cur = d[part] } else if let a = cur as? [Any], let i = Int(part), a.indices.contains(i) { cur = a[i] } else { return nil }
        }
        return cur
    }

    public static func isWebURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: { $0.isWhitespace }), let u = URL(string: t), let sc = u.scheme?.lowercased(), sc == "https" || sc == "http", let h = u.host, !h.isEmpty else { return false }
        return true
    }
}

public final class ShotUploader: ShotUploading {
    private let settings: () -> ShotUploadSettings
    private let client: HTTPClient
    private let keychain: KeychainStore
    private let makeBoundary: () -> String

    public init(settings: @escaping () -> ShotUploadSettings, client: HTTPClient, keychain: KeychainStore, boundary: @escaping () -> String = { ShotMultipart.boundary() }) {
        self.settings = settings
        self.client = client
        self.keychain = keychain
        makeBoundary = boundary
    }

    public func upload(_ job: ShotUploadJob, now: Date = Date()) throws -> ShotUploadResult {
        let s = settings()
        let token = keychain.read(ShotUploadSettings.keychainService)?["token"] as? String
        let req = try ShotUploadBuilder.request(settings: s, job: job, token: token, boundary: makeBoundary())
        let resp: HTTPResponse
        do { resp = try client.send(req) } catch { throw ShotUploadError.transport("\(error)") }
        guard (200..<300).contains(resp.status) else { throw ShotUploadError.http(resp.status) }
        guard let url = ShotUploadBuilder.extractURL(from: resp, path: s.sanitized.responsePath) else { throw ShotUploadError.badResponse }
        return ShotUploadResult(url: url, expires: now.addingTimeInterval(Double(job.ttl.seconds)))
    }
}
