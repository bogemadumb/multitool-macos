import Foundation
import MultitulCtlCore

public typealias JSON = [String: Any]

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
    public var json: JSON? { (try? JSONSerialization.jsonObject(with: body)) as? JSON }
}

public struct HTTPTransportError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// Blocking on purpose: collectors run on their own queue and the old Python collector was synchronous too.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let url = URL(string: request.url) else { throw HTTPTransportError("bad url") }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = request.timeout
        cfg.timeoutIntervalForResource = request.timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        session.dataTask(with: r) { data, resp, err in
            if let err { box.result = .failure(HTTPTransportError(err.localizedDescription)) }
            else if let http = resp as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields { if let k = k as? String { h[k] = "\(v)" } }
                box.result = .success(HTTPResponse(status: http.statusCode, headers: h, body: data ?? Data()))
            } else { box.result = .failure(HTTPTransportError("no response")) }
            sem.signal()
        }.resume()
        sem.wait()
        return try box.result!.get()
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<HTTPResponse, Error>?
    }
}

// Keychain access goes through /usr/bin/security: items created by that tool carry an ACL for it,
// so it reads them without a prompt (a SecItem call from another binary would ask every time).
public protocol KeychainStore: Sendable {
    func read(_ service: String) -> JSON?
    func write(_ service: String, _ payload: JSON) -> Bool
    // true while an item was deleted (the caller repeats until "not found": duplicates of one service happen)
    func deleteOnce(_ service: String) -> Bool
}

public struct SecurityCLIKeychain: KeychainStore {
    private let runner: ProcessRunning
    private let account: String

    public init(runner: ProcessRunning = SystemProcessRunner(), account: String = NSUserName()) {
        self.runner = runner
        self.account = account
    }

    public func read(_ service: String) -> JSON? {
        let out = runner.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 15)
        guard out.status == 0 else { return nil }
        let raw = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? JSON
    }

    public func write(_ service: String, _ payload: JSON) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        _ = runner.run("/usr/bin/security", ["delete-generic-password", "-s", service], timeout: 15)
        return runner.run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", account, "-w", String(decoding: d, as: UTF8.self), "-U"], timeout: 15).status == 0
    }

    public func deleteOnce(_ service: String) -> Bool {
        runner.run("/usr/bin/security", ["delete-generic-password", "-s", service], timeout: 15).status == 0
    }
}

// In-memory keychain for tests and dry runs.
public final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    public var items: [String: JSON]
    public var writes: [String] = []
    public var deletes: [String] = []
    public var failWrites = false

    public init(_ items: [String: JSON] = [:]) { self.items = items }

    public func read(_ service: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return items[service]
    }
    public func write(_ service: String, _ payload: JSON) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append(service)
        if failWrites { return false }
        items[service] = payload
        return true
    }
    public func deleteOnce(_ service: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deletes.append(service)
        return items.removeValue(forKey: service) != nil
    }
}

