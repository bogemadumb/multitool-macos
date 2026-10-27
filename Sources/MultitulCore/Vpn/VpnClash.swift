import Foundation
import MultitulCtlCore

enum ClashError: Error, Equatable {
    case noSecret
    case http(Int)
    case badBody
}

enum VpnTrafficEvent: Sendable {
    case connected
    case sample(up: Double, down: Double)
    case disconnected
}

protocol ClashSecretProviding: Sendable {
    func secret() -> String?
}

struct KeychainClashSecret: ClashSecretProviding {
    static let service = "dev.vpnstatusbar.clash"
    static let account = NSUserName()
    let runner: ProcessRunning

    init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    func secret() -> String? {
        let r = runner.run("/usr/bin/security", ["find-generic-password", "-s", Self.service, "-a", Self.account, "-w"], timeout: 10)
        guard r.status == 0, !r.timedOut else { return nil }
        let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

protocol ClashTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

struct URLSessionClashTransport: ClashTransport {
    private let session: URLSession
    private let streamSession: URLSession

    init() {
        let a = URLSessionConfiguration.ephemeral
        a.timeoutIntervalForRequest = 20
        a.waitsForConnectivity = false
        a.connectionProxyDictionary = [:]
        session = URLSession(configuration: a)
        let b = URLSessionConfiguration.ephemeral
        b.timeoutIntervalForRequest = 8
        b.timeoutIntervalForResource = 86400
        b.connectionProxyDictionary = [:]
        streamSession = URLSession(configuration: b)
    }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: request)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, resp) = try await streamSession.bytes(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { cont in
            let task = Task {
                do {
                    for try await line in bytes.lines { cont.yield(line) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
        return (code, stream)
    }
}

protocol ClashAPI: Sendable {
    var hasSecret: Bool { get }
    func version() async throws -> String
    func configs() async throws -> (mode: String, modes: [String])
    func delay(timeoutMs: Int) async throws -> Int
    func delay(timeoutMs: Int, url: String, proxy: String) async throws -> Int
    func setMode(_ mode: String) async throws
    func closeConnection(_ id: String) async throws
    func connections() async throws -> [ClashConn]
    func totals() async throws -> (down: Double, up: Double)
    func runTraffic(_ handler: @escaping @Sendable (VpnTrafficEvent) -> Void) async
}

extension ClashAPI {
    func delay(timeoutMs: Int, url: String, proxy: String) async throws -> Int { throw ClashError.badBody }
}

final class ClashClient: ClashAPI, @unchecked Sendable {
    static let probeURL204 = "https://www.gstatic.com/generate_204"
    static let secretRetry: TimeInterval = 60

    private let base: String
    private let transport: ClashTransport
    private let provider: ClashSecretProviding
    private let lock = NSLock()
    private var cached: String?
    private var lastTry = Date.distantPast
    private let clock: @Sendable () -> Date

    init(base: String = "http://127.0.0.1:9090", transport: ClashTransport = URLSessionClashTransport(),
         provider: ClashSecretProviding = KeychainClashSecret(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.transport = transport
        self.provider = provider
        self.clock = clock
    }

    var hasSecret: Bool { currentSecret() != nil }

    private func currentSecret() -> String? {
        lock.lock(); defer { lock.unlock() }
        if cached == nil, clock().timeIntervalSince(lastTry) > Self.secretRetry {
            lastTry = clock()
            cached = provider.secret()
        }
        return cached
    }

    func makeRequest(_ path: String, timeout: TimeInterval = 8, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let s = currentSecret() else { throw ClashError.noSecret }
        guard let url = URL(string: base + path) else { throw ClashError.badBody }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws {
        let (_, code) = try await transport.data(for: makeRequest(path, method: method, body: body))
        guard (200..<300).contains(code) else { throw ClashError.http(code) }
    }

    private func getData(_ path: String, timeout: TimeInterval = 8) async throws -> Data {
        let (data, code) = try await transport.data(for: makeRequest(path, timeout: timeout))
        guard (200..<300).contains(code) else { throw ClashError.http(code) }
        return data
    }

    private func getJSON(_ path: String, timeout: TimeInterval = 8) async throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: try await getData(path, timeout: timeout)) as? [String: Any] else {
            throw ClashError.badBody
        }
        return obj
    }

    func version() async throws -> String {
        guard let v = try await getJSON("/version")["version"] as? String else { throw ClashError.badBody }
        return v
    }

    func configs() async throws -> (mode: String, modes: [String]) {
        let o = try await getJSON("/configs")
        return (o["mode"] as? String ?? "Rule", o["mode-list"] as? [String] ?? ["Rule", "Global", "Direct"])
    }

    func delay(timeoutMs: Int) async throws -> Int {
        try await delay(timeoutMs: timeoutMs, url: Self.probeURL204, proxy: "vps")
    }

    func delay(timeoutMs: Int, url: String, proxy: String) async throws -> Int {
        let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        guard !proxy.isEmpty, proxy.unicodeScalars.allSatisfy({ ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { throw ClashError.badBody }
        let o = try await getJSON("/proxies/\(proxy)/delay?url=\(enc)&timeout=\(timeoutMs)", timeout: Double(timeoutMs) / 1000 + 3)
        guard let d = o["delay"] as? Int else { throw ClashError.badBody }
        return d
    }

    func setMode(_ mode: String) async throws {
        guard VpnMode(rawValue: mode) != nil else { throw ClashError.badBody }
        try await send("PATCH", "/configs", body: try JSONSerialization.data(withJSONObject: ["mode": mode]))
    }

    func closeConnection(_ id: String) async throws {
        guard let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) else {
            throw ClashError.badBody
        }
        try await send("DELETE", "/connections/\(enc)")
    }

    func connections() async throws -> [ClashConn] {
        try VpnConnLogic.parseConnections(try await getData("/connections")).conns
    }

    func totals() async throws -> (down: Double, up: Double) {
        let t = try VpnConnLogic.parseConnections(try await getData("/connections"))
        return (t.down, t.up)
    }

    func runTraffic(_ handler: @escaping @Sendable (VpnTrafficEvent) -> Void) async {
        var connected = false
        while !Task.isCancelled {
            do {
                let (code, lines) = try await transport.lines(for: try makeRequest("/traffic"))
                if (200..<300).contains(code) {
                    connected = true
                    handler(.connected)
                    for try await line in lines {
                        guard let s = VpnConnLogic.parseTrafficLine(line) else { continue }
                        handler(.sample(up: s.up, down: s.down))
                    }
                }
            } catch {}
            if connected { handler(.disconnected); connected = false }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
