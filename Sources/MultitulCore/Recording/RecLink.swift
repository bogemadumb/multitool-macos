import Foundation

public struct RecUploadJob: Equatable, Sendable {
    public var fileName: String
    public var path: String
    public var mime: String
    public var ttl: ShotLinkTTL

    public init(fileName: String, path: String, mime: String, ttl: ShotLinkTTL) {
        self.fileName = fileName
        self.path = path
        self.mime = mime
        self.ttl = ttl
    }
}

public enum RecLinkBuilder {
    public static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "gif": "image/gif"
        default: "application/octet-stream"
        }
    }

    public static func request(settings raw: ShotUploadSettings, job: RecUploadJob, data: Data, token: String?, boundary: String) throws -> HTTPRequest {
        let s = raw.sanitized
        if s.endpoint.isEmpty { throw ShotUploadError.notConfigured }
        if let why = ShotUploadBuilder.validate(endpoint: s.endpoint) { throw ShotUploadError.badEndpoint(why) }
        guard data.count <= s.maxBytes else { throw ShotUploadError.tooLarge(data.count) }
        var fields: [(String, String)] = s.extraFields.compactMap(ShotUploadBuilder.parseField)
        if !s.ttlField.isEmpty { fields.append((s.ttlField, String(s.ttlInSeconds ? job.ttl.seconds : job.ttl.hours))) }
        let name = ShotNaming.sanitize(job.fileName).isEmpty ? "recording" : job.fileName
        let body = ShotMultipart.body(boundary: boundary, fields: fields, file: (s.fileField, name, job.mime, data))
        var headers = ["Content-Type": ShotMultipart.contentType(boundary: boundary), "Accept": "application/json, text/plain"]
        if !s.authHeader.isEmpty {
            guard let token, !token.isEmpty else { throw ShotUploadError.missingToken }
            headers[s.authHeader] = s.authPrefix + token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return HTTPRequest(url: s.endpoint, method: "POST", headers: headers, body: body, timeout: 300)
    }
}

public protocol RecDataReading: AnyObject {
    func read(_ path: String) -> Data?
}

public final class RecLinkService {
    private let settings: () -> ShotUploadSettings
    private let client: HTTPClient
    private let keychain: KeychainStore
    private let reader: RecDataReading
    private let history: RecHistoryStore?
    private let clipboard: TextWriting
    private let events: ShotEventHub?
    private let makeBoundary: () -> String

    public init(settings: @escaping () -> ShotUploadSettings, client: HTTPClient, keychain: KeychainStore, reader: RecDataReading, history: RecHistoryStore?,
                clipboard: TextWriting, events: ShotEventHub? = nil, boundary: @escaping () -> String = { ShotMultipart.boundary() }) {
        self.settings = settings
        self.client = client
        self.keychain = keychain
        self.reader = reader
        self.history = history
        self.clipboard = clipboard
        self.events = events
        makeBoundary = boundary
    }

    public func makeLink(record: RecRecord?, path: String, ttl: ShotLinkTTL, now: Date = Date()) -> Result<ShotUploadResult, ShotUploadError> {
        guard let data = reader.read(path) else { return .failure(.transport("не удалось прочитать файл")) }
        let name = (path as NSString).lastPathComponent
        let job = RecUploadJob(fileName: name, path: path, mime: RecLinkBuilder.mime(forExtension: (name as NSString).pathExtension), ttl: ttl)
        let s = settings()
        let token = keychain.read(ShotUploadSettings.keychainService)?["token"] as? String
        do {
            let req = try RecLinkBuilder.request(settings: s, job: job, data: data, token: token, boundary: makeBoundary())
            let resp: HTTPResponse
            do { resp = try client.send(req) } catch { return .failure(.transport("\(error)")) }
            guard (200..<300).contains(resp.status) else { return .failure(.http(resp.status)) }
            guard let url = ShotUploadBuilder.extractURL(from: resp, path: s.sanitized.responsePath) else { return .failure(.badResponse) }
            let res = ShotUploadResult(url: url, expires: now.addingTimeInterval(Double(ttl.seconds)))
            if let id = record?.id, id > 0 { try? history?.setLink(id: id, url: res.url, expires: res.expires) }
            clipboard.write(res.url)
            events?.emit(.linked(url: res.url))
            return .success(res)
        } catch let e as ShotUploadError {
            return .failure(e)
        } catch {
            return .failure(.transport("\(error)"))
        }
    }
}
