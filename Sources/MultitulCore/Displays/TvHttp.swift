import Foundation

public struct TvHttpRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
}

public enum TvRoute: Equatable, Sendable {
    case stream(headOnly: Bool)
    case page
    case mjpeg
    case notFound
}

public enum TvHttp {
    public static let boundary = "kadr"

    public static func headEnd(in data: Data) -> Int? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)?.upperBound
    }

    public static func parseRequest(_ data: Data) -> TvHttpRequest? {
        guard let end = headEnd(in: data) else { return nil }
        let text = String(decoding: data.prefix(end), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return TvHttpRequest(method: String(first[0]).uppercased(), path: String(first[1]), headers: headers)
    }

    private static func head(_ status: String, _ fields: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status)\r\n"
        for (k, v) in fields { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    // The Samsung from 2017 will not play a live stream without Content-Length: lie about the size so it treats it as a plain file.
    public static func streamHeaders(config c: TvConfig) -> Data {
        head("200 OK", [
            ("Content-Type", "video/mpeg"),
            ("Content-Length", String(c.fakeContentLength)),
            ("transferMode.dlna.org", "Streaming"),
            ("contentFeatures.dlna.org", Upnp.features(profile: c.dlnaProfile)),
            ("Accept-Ranges", "none"),
            ("Connection", "close")
        ])
    }

    public static func pageHeaders(length: Int) -> Data {
        head("200 OK", [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", String(length)), ("Cache-Control", "no-store")])
    }

    public static func mjpegHeaders() -> Data {
        head("200 OK", [
            ("Content-Type", "multipart/x-mixed-replace; boundary=\(boundary)"),
            ("Cache-Control", "no-store, no-cache"),
            ("Connection", "close")
        ])
    }

    public static func notFoundResponse() -> Data {
        head("404 Not Found", [("Content-Length", "0")])
    }

    public static func multipartFrame(_ jpeg: Data) -> Data {
        var d = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        d.append(jpeg)
        d.append(Data("\r\n".utf8))
        return d
    }

    public static func streamRoute(_ r: TvHttpRequest) -> TvRoute {
        switch r.method {
        case "GET": .stream(headOnly: false)
        case "HEAD": .stream(headOnly: true)
        default: .notFound
        }
    }

    public static func fastRoute(_ r: TvHttpRequest) -> TvRoute {
        guard r.method == "GET" else { return .notFound }
        switch r.path.split(separator: "?").first.map(String.init) ?? r.path {
        case "/", "/index.html": return .page
        case "/potok": return .mjpeg
        default: return .notFound
        }
    }

    public static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Ekran</title><style>
    html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}
    img{width:100vw;height:100vh;object-fit:contain;display:block}
    </style></head><body>
    <img src="/potok">
    </body></html>
    """

    public static var page: Data { Data(pageHTML.utf8) }
}
