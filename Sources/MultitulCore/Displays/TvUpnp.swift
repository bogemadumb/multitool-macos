import Foundation

public struct UpnpRequest: Equatable, Sendable {
    public var url: String
    public var headers: [String: String]
    public var body: String
}

public enum UpnpResult: Equatable, Sendable {
    case ok(String)
    case fault(code: Int?, text: String)
    case httpError(Int)
    case transport(String)

    public var isOK: Bool { if case .ok = self { true } else { false } }

    public var summary: String {
        switch self {
        case .ok: "ok"
        case .fault(let c, let t): "ошибка UPnP\(c.map { " \($0)" } ?? ""): \(t)"
        case .httpError(let s): "HTTP \(s)"
        case .transport(let m): m
        }
    }
}

public enum Upnp {
    public static let ns = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let instance = "<InstanceID>0</InstanceID>"

    public static func envelope(action: String, inner: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(ns)\">\(inner)</u:\(action)>"
            + "</s:Body></s:Envelope>"
    }

    public static func request(controlURL: String, action: String, inner: String) -> UpnpRequest {
        UpnpRequest(url: controlURL,
                    headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPACTION": "\"\(ns)#\(action)\""],
                    body: envelope(action: action, inner: inner))
    }

    // Same set as Python html.escape(s, quote=True).
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func features(profile: String) -> String {
        "DLNA.ORG_PN=\(profile);DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=8D500000000000000000000000000000"
    }

    public static func didl(url: String, features: String, title: String = "Vtoroy ekran") -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>\(title)</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:video/mpeg:\(features)\">\(url)</res>"
            + "</item></DIDL-Lite>"
    }

    public static func setURIInner(url: String, features: String) -> String {
        "\(instance)<CurrentURI>\(url)</CurrentURI><CurrentURIMetaData>\(escape(didl(url: url, features: features)))</CurrentURIMetaData>"
    }

    public static let playInner = "\(instance)<Speed>1</Speed>"

    public static func castSteps(url: String, profile: String) -> [(action: String, inner: String)] {
        [("Stop", instance), ("SetAVTransportURI", setURIInner(url: url, features: features(profile: profile))), ("Play", playInner)]
    }

    public static func xmlValue(_ tag: String, in xml: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_]+:)?\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_]+:)?\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r = Range(m.range(at: 1), in: xml) else { return nil }
        return unescape(String(xml[r]))
    }

    public static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func parse(status: Int, body: String) -> UpnpResult {
        if body.contains("Fault>") || body.contains("UPnPError") {
            let code = xmlValue("errorCode", in: body).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let text = xmlValue("errorDescription", in: body) ?? xmlValue("faultstring", in: body) ?? "без описания"
            return .fault(code: code, text: text)
        }
        if status >= 400 || status < 200 { return .httpError(status) }
        return .ok(body)
    }

    public static func transportState(from body: String) -> String? {
        xmlValue("CurrentTransportState", in: body)
    }
}

public protocol UpnpTransporting {
    func post(_ request: UpnpRequest) -> UpnpResult
}

public struct URLSessionUpnpTransport: UpnpTransporting {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func post(_ request: UpnpRequest) -> UpnpResult {
        guard let url = URL(string: request.url) else { return .transport("плохой адрес \(request.url)") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpBody = Data(request.body.utf8)
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = UpnpResult.transport("нет ответа")
        session.dataTask(with: r) { data, resp, err in
            if let err { result = .transport(err.localizedDescription) } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = Upnp.parse(status: status, body: String(decoding: data ?? Data(), as: UTF8.self))
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}

public struct UpnpClient {
    public var transport: UpnpTransporting
    public var config: TvConfig

    public init(transport: UpnpTransporting, config: TvConfig) {
        self.transport = transport
        self.config = config
    }

    @discardableResult
    public func send(_ action: String, _ inner: String = Upnp.instance) -> UpnpResult {
        transport.post(Upnp.request(controlURL: config.avTransportURL, action: action, inner: inner))
    }

    public func stop() -> UpnpResult { send("Stop") }

    public func state() -> String {
        guard case .ok(let body) = send("GetTransportInfo") else { return "нет связи" }
        return Upnp.transportState(from: body) ?? "нет связи"
    }

    // Returns the steps that failed, in order; the TV may refuse Stop when idle, that is not fatal.
    public func cast(url: String) -> [(step: String, result: UpnpResult)] {
        var failed: [(String, UpnpResult)] = []
        for s in Upnp.castSteps(url: url, profile: config.dlnaProfile) {
            let r = send(s.action, s.inner)
            if !r.isOK { failed.append((s.action, r)) }
        }
        return failed
    }
}
