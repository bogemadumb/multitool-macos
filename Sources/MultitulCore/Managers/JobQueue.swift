import Foundation

public enum JobState: Equatable, Sendable {
    case queued, running, succeeded, failed(String), cancelled

    public var isFinished: Bool {
        switch self {
        case .queued, .running: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .queued: "В очереди"
        case .running: "Выполняется"
        case .succeeded: "Готово"
        case .failed: "Ошибка"
        case .cancelled: "Отменено"
        }
    }
}

public enum JobOutcome: Equatable, Sendable {
    case success(String)
    case failure(String)
    case cancelled
}

public struct JobSnapshot: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var kind: String
    public var state: JobState
    public var progress: Double?
    public var detail: String
    public var log: [String]
    public var result: String
}

public final class JobContext: @unchecked Sendable {
    public let id: Int
    private let lock = NSLock()
    private var _progress: Double?
    private var _detail = ""
    private var _log: [String] = []
    private let logLimit: Int
    private let notify: @Sendable () -> Void

    init(id: Int, logLimit: Int, notify: @escaping @Sendable () -> Void) {
        self.id = id
        self.logLimit = logLimit
        self.notify = notify
    }

    public func setProgress(_ value: Double?, detail: String? = nil) {
        lock.lock()
        _progress = value.map { min(max($0, 0), 1) }
        if let detail { _detail = detail }
        lock.unlock()
        notify()
    }

    public func log(_ line: String) {
        lock.lock()
        _log.append(line)
        if _log.count > logLimit { _log.removeFirst(_log.count - logLimit) }
        lock.unlock()
        notify()
    }

    var snapshot: (Double?, String, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (_progress, _detail, _log)
    }
}

public typealias JobWork = @Sendable (JobContext) async -> JobOutcome

@MainActor
public final class JobQueue {
    private final class Entry {
        let id: Int
        let title: String
        let kind: String
        let work: JobWork
        let context: JobContext
        var state = JobState.queued
        var result = ""
        var cancelRequested = false
        var task: Task<Void, Never>?

        init(id: Int, title: String, kind: String, work: @escaping JobWork, context: JobContext) {
            self.id = id
            self.title = title
            self.kind = kind
            self.work = work
            self.context = context
        }
    }

    public let maxConcurrent: Int
    public let historyLimit: Int
    public var onChange: (() -> Void)?
    public var onFinish: ((JobSnapshot) -> Void)?

    private var entries: [Entry] = []
    private var nextID = 1
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 1, historyLimit: Int = 50) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.historyLimit = max(1, historyLimit)
    }

    public var jobs: [JobSnapshot] { entries.map(snapshot) }
    public var runningCount: Int { entries.filter { $0.state == .running }.count }
    public var queuedCount: Int { entries.filter { $0.state == .queued }.count }
    public var isBusy: Bool { runningCount + queuedCount > 0 }

    public func job(_ id: Int) -> JobSnapshot? { entries.first { $0.id == id }.map(snapshot) }

    @discardableResult
    public func enqueue(title: String, kind: String = "", work: @escaping JobWork) -> Int {
        let id = nextID
        nextID += 1
        let ctx = JobContext(id: id, logLimit: 200) { [weak self] in
            Task { @MainActor in self?.onChange?() }
        }
        entries.append(Entry(id: id, title: title, kind: kind, work: work, context: ctx))
        trimHistory()
        pump()
        onChange?()
        return id
    }

    public func cancel(_ id: Int) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        switch e.state {
        case .queued:
            e.state = .cancelled
            finished(e)
        case .running:
            e.cancelRequested = true
            e.task?.cancel()
            onChange?()
        default:
            break
        }
    }

    public func cancelAll() {
        for e in entries where !e.state.isFinished { cancel(e.id) }
    }

    public func clearFinished() {
        entries.removeAll { $0.state.isFinished }
        onChange?()
    }

    public func waitUntilIdle() async {
        if !isBusy { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func snapshot(_ e: Entry) -> JobSnapshot {
        let (p, d, l) = e.context.snapshot
        return JobSnapshot(id: e.id, title: e.title, kind: e.kind, state: e.state, progress: p, detail: d, log: l, result: e.result)
    }

    private func pump() {
        while runningCount < maxConcurrent, let e = entries.first(where: { $0.state == .queued }) {
            e.state = .running
            let work = e.work
            let ctx = e.context
            e.task = Task { [weak self] in
                let outcome = await work(ctx)
                self?.complete(e.id, outcome)
            }
        }
    }

    private func complete(_ id: Int, _ outcome: JobOutcome) {
        guard let e = entries.first(where: { $0.id == id }), e.state == .running else { return }
        switch outcome {
        case .success(let text):
            if e.cancelRequested {
                e.state = .cancelled
            } else {
                e.state = .succeeded
                e.result = text
            }
        case .failure(let message):
            e.state = e.cancelRequested ? .cancelled : .failed(message)
        case .cancelled:
            e.state = .cancelled
        }
        e.task = nil
        finished(e)
    }

    private func finished(_ e: Entry) {
        pump()
        onFinish?(snapshot(e))
        onChange?()
        if !isBusy {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    private func trimHistory() {
        let finished = entries.filter { $0.state.isFinished }
        guard finished.count > historyLimit else { return }
        let drop = Set(finished.prefix(finished.count - historyLimit).map(\.id))
        entries.removeAll { drop.contains($0.id) }
    }
}
