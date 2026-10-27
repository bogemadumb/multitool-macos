import Foundation

// One multitouch listener shared by every module that wants raw frames; MultitouchTouchSource keeps a single global target.
public final class TouchHub {
    public static let shared = TouchHub { MultitouchTouchSource() }

    private let factory: () -> TouchSource
    private let lock = NSLock()
    private var source: TouchSource?
    private var handlers: [Int: (TouchFrame) -> Void] = [:]
    private var counter = 0
    public private(set) var failedToStart = false

    public init(factory: @escaping () -> TouchSource) { self.factory = factory }

    public var subscriberCount: Int { lock.withLock { handlers.count } }

    public var isRunning: Bool { lock.withLock { source != nil } }

    public func attach(_ handler: @escaping (TouchFrame) -> Void) -> Int? {
        lock.lock()
        counter += 1
        let id = counter
        handlers[id] = handler
        let needStart = source == nil
        lock.unlock()
        if needStart {
            let s = factory()
            s.onFrame = { [weak self] f in self?.dispatch(f) }
            if !s.start() {
                lock.withLock { handlers[id] = nil; failedToStart = true }
                return nil
            }
            lock.withLock { source = s; failedToStart = false }
        }
        return id
    }

    public func detach(_ id: Int) {
        var toStop: TouchSource?
        lock.withLock {
            handlers[id] = nil
            if handlers.isEmpty { toStop = source; source = nil }
        }
        toStop?.stop()
    }

    private func dispatch(_ f: TouchFrame) {
        let hs = lock.withLock { Array(handlers.values) }
        for h in hs { h(f) }
    }

    public func makeSource() -> TouchSource { TouchHubSource(hub: self) }
}

final class TouchHubSource: TouchSource {
    var onFrame: ((TouchFrame) -> Void)?
    private let hub: TouchHub
    private var id: Int?

    init(hub: TouchHub) { self.hub = hub }

    func start() -> Bool {
        stop()
        id = hub.attach { [weak self] f in self?.onFrame?(f) }
        return id != nil
    }

    func stop() {
        if let i = id { hub.detach(i) }
        id = nil
    }
}
