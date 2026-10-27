import Foundation

public enum SamsungRemote {
    public static func socketURL(host: String, port: Int, name: String, token: String?) -> String {
        let b64 = Data(name.utf8).base64EncodedString()
        var u = "wss://\(host):\(port)/api/v2/channels/samsung.remote.control?name=\(b64)"
        if let t = token, !t.isEmpty { u += "&token=\(t)" }
        return u
    }

    public static func launchBrowserMessage(url: String) -> String {
        let obj: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["action_type": "NATIVE_LAUNCH", "appId": "org.tizen.browser", "metaTag": url]]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public enum Event: Equatable {
        case connected(token: String?)
        case other(String)
    }

    public static func parseEvent(_ text: String) -> Event {
        guard let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let name = obj["event"] as? String else { return .other("") }
        if name == "ms.channel.connect" {
            let token = (obj["data"] as? [String: Any])?["token"]
            return .connected(token: token.map { "\($0)" })
        }
        return .other(name)
    }

    public static func restFallbackRequest(host: String, port: Int, url: String) -> (url: String, body: String) {
        ("http://\(host):\(port)/ws/app/Internet", url)
    }
}

public protocol TvBrowserLaunching {
    func openBrowser(url: String, config: TvConfig) -> String
}

public final class SamsungBrowserLauncher: NSObject, TvBrowserLaunching, URLSessionDelegate, @unchecked Sendable {
    private var trustedHost = ""

    public override init() { super.init() }

    private func readToken(_ c: TvConfig) -> String? {
        for p in [c.resolvedTokenPath, c.resolvedLegacyTokenPath] {
            if let s = try? String(contentsOfFile: p, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private func saveToken(_ t: String, _ c: TvConfig) {
        let p = c.resolvedTokenPath
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? t.write(toFile: p, atomically: true, encoding: .utf8)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == trustedHost, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func openBrowser(url: String, config c: TvConfig) -> String {
        trustedHost = c.tvIP
        let wsURL = SamsungRemote.socketURL(host: c.tvIP, port: c.samsungWsPort, name: c.samsungName, token: readToken(c))
        var failure = ""
        if let u = URL(string: wsURL) {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: u)
            task.resume()
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var connected = false
            func receive() {
                task.receive { result in
                    switch result {
                    case .failure(let e):
                        failure = e.localizedDescription
                        sem.signal()
                    case .success(let msg):
                        if case .string(let text) = msg, case .connected(let token) = SamsungRemote.parseEvent(text) {
                            if let token, !token.isEmpty { self.saveToken(token, c) }
                            connected = true
                            sem.signal()
                        } else {
                            receive()
                        }
                    }
                }
            }
            receive()
            let waited = sem.wait(timeout: .now() + 40)
            if connected {
                let sent = DispatchSemaphore(value: 0)
                task.send(.string(SamsungRemote.launchBrowserMessage(url: url))) { _ in sent.signal() }
                _ = sent.wait(timeout: .now() + 5)
                Thread.sleep(forTimeInterval: 0.5)
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
                return "телевизор открывает страницу"
            }
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if waited == .timedOut { failure = "телевизор не ответил за 40 с (разреши подключение на экране ТВ)" }
        }
        let fb = SamsungRemote.restFallbackRequest(host: c.tvIP, port: c.samsungRestPort, url: url)
        if let u = URL(string: fb.url) {
            var r = URLRequest(url: u, timeoutInterval: 10)
            r.httpMethod = "POST"
            r.httpBody = Data(fb.body.utf8)
            r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            let session = URLSession(configuration: cfg)
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            session.dataTask(with: r) { _, resp, err in
                ok = err == nil && ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 12)
            session.invalidateAndCancel()
            if ok { return "браузер телевизора запущен (служебный канал не сработал: \(failure))" }
        }
        return "открой на телевизоре браузер вручную и набери: \(url) (служебный канал: \(failure))"
    }
}
