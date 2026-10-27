import Foundation
import Network
import CoreGraphics

public enum TvMode: String, CaseIterable, Sendable {
    case screen, fast

    public var title: String { self == .screen ? "Со звуком (плеер ТВ)" : "Быстрый (браузер ТВ, без звука)" }
}

public protocol TvStreamEngine: AnyObject {
    var clientCount: Int { get }
    var onEvent: ((String) -> Void)? { get set }
    func start(mode: TvMode, displayID: UInt32, config: TvConfig) throws
    func stop()
}

public enum TvNetwork {
    // UDP connect sends nothing; it only makes the kernel pick the interface that routes to the TV.
    public static func localIP(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(80).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc2 = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard rc2 == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = local.sin_addr
        guard inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }
}

private final class TvConnection {
    let conn: NWConnection
    let queue: DispatchQueue
    var inflight = 0
    var buffer = Data()
    var closed = false
    var waitingKey = true
    var streaming = false
    var onClosed: ((TvConnection) -> Void)?

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    func send(_ data: Data, thenClose: Bool = false) {
        guard !closed else { return }
        inflight += data.count
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.queue.async {
                self.inflight -= data.count
                if err != nil || thenClose { self.close() }
            }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClosed?(self)
    }
}

public final class TvStreamServer: TvStreamEngine, @unchecked Sendable {
    public var onEvent: ((String) -> Void)?
    private let queue = DispatchQueue(label: "dev.multitool.app.tv.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: TvConnection] = [:]
    private var mode: TvMode = .screen
    private var config = TvConfig()
    private var displayID: UInt32 = 0
    private var tsPipeline: TsPipeline?
    private var mjpegPipeline: MjpegPipeline?
    private var pipelineRunning = false
    private var graceStop: DispatchWorkItem?
    private static let maxBacklog = 6 * 1024 * 1024

    public init() {}

    public var clientCount: Int { queue.sync { clients.count } }

    private func emit(_ s: String) {
        let cb = onEvent
        DispatchQueue.main.async { cb?(s) }
    }

    public func start(mode: TvMode, displayID: UInt32, config: TvConfig) throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw TvCaptureError(description: "нет доступа к записи экрана: включи Мультитул в Настройки → Конфиденциальность → Запись экрана")
        }
        let port = mode == .screen ? config.streamPort : config.fastPort
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw TvCaptureError(description: "плохой порт \(port)") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: nwPort)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: String?
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: ready.signal()
            case .failed(let e):
                failure = "\(e)"
                ready.signal()
                self?.emit("сервер потока остановился: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        queue.sync {
            self.mode = mode
            self.config = config
            self.displayID = displayID
            self.listener = l
        }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 4) == .timedOut || failure != nil {
            l.cancel()
            queue.sync { self.listener = nil }
            throw TvCaptureError(description: "порт \(port) занят — видимо, трансляция уже запущена")
        }
    }

    public func stop() {
        queue.sync {
            graceStop?.cancel()
            listener?.cancel()
            listener = nil
            for c in clients.values { c.onClosed = nil; c.close() }
            clients.removeAll()
            stopPipeline()
        }
    }

    // MARK: connections (all on `queue`)

    private func accept(_ nw: NWConnection) {
        let c = TvConnection(nw, queue: queue)
        c.onClosed = { [weak self] c in self?.dropped(c) }
        nw.stateUpdateHandler = { [weak c] st in
            switch st {
            case .failed, .cancelled: c?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        readHead(c)
    }

    private func readHead(_ c: TvConnection) {
        c.conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] data, _, done, err in
            guard let self, let c else { return }
            if let data { c.buffer.append(data) }
            if let req = TvHttp.parseRequest(c.buffer) {
                self.route(req, c)
            } else if err != nil || done || c.buffer.count > 16384 {
                c.close()
            } else {
                self.readHead(c)
            }
        }
    }

    private func route(_ req: TvHttpRequest, _ c: TvConnection) {
        let r = mode == .screen ? TvHttp.streamRoute(req) : TvHttp.fastRoute(req)
        switch r {
        case .stream(let headOnly):
            c.send(TvHttp.streamHeaders(config: config), thenClose: headOnly)
            if !headOnly {
                emit("телевизор подключился — гоню картинку")
                attach(c)
            }
        case .page:
            let page = TvHttp.page
            var d = TvHttp.pageHeaders(length: page.count)
            d.append(page)
            c.send(d, thenClose: true)
            emit("телевизор открыл страницу")
        case .mjpeg:
            c.send(TvHttp.mjpegHeaders())
            c.waitingKey = false
            emit("телевизор запросил поток — гоню кадры")
            attach(c)
        case .notFound:
            c.send(TvHttp.notFoundResponse(), thenClose: true)
        }
    }

    private func attach(_ c: TvConnection) {
        c.streaming = true
        clients[ObjectIdentifier(c)] = c
        graceStop?.cancel()
        startPipelineIfNeeded()
    }

    private func dropped(_ c: TvConnection) {
        queue.async { [self] in
            guard clients.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
            emit("телевизор отключился")
            if clients.isEmpty {
                let w = DispatchWorkItem { [weak self] in self?.stopPipeline() }
                graceStop = w
                queue.asyncAfter(deadline: .now() + 2, execute: w)
            }
        }
    }

    // MARK: pipelines

    private func startPipelineIfNeeded() {
        guard !pipelineRunning else { return }
        pipelineRunning = true
        let cfg = config
        let log: (String) -> Void = { [weak self] in self?.emit($0) }
        switch mode {
        case .screen:
            let p = TsPipeline(config: cfg, displayID: displayID, publish: { [weak self] d, key in self?.queue.async { self?.publishTS(d, key) } }, log: log)
            tsPipeline = p
            Task { [weak self] in
                do { try await p.start() } catch {
                    self?.emit("не удалось запустить трансляцию: \(error)")
                    self?.queue.async { self?.stopPipeline() }
                }
            }
        case .fast:
            let p = MjpegPipeline(config: cfg, displayID: displayID, publish: { [weak self] d in self?.queue.async { self?.publishFrame(d) } }, log: log)
            mjpegPipeline = p
            Task { [weak self] in
                do { try await p.start() } catch {
                    self?.emit("не удалось запустить трансляцию: \(error)")
                    self?.queue.async { self?.stopPipeline() }
                }
            }
        }
    }

    private func stopPipeline() {
        tsPipeline?.stop()
        tsPipeline = nil
        mjpegPipeline?.stop()
        mjpegPipeline = nil
        pipelineRunning = false
    }

    private func publishTS(_ d: Data, _ isKey: Bool) {
        for c in clients.values where c.streaming {
            if c.waitingKey {
                guard isKey else { continue }
                c.waitingKey = false
            }
            if c.inflight > Self.maxBacklog {
                c.waitingKey = true
                continue
            }
            c.send(d)
        }
    }

    private func publishFrame(_ d: Data) {
        for c in clients.values where c.streaming && c.inflight < Self.maxBacklog { c.send(d) }
    }
}
