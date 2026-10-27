import Foundation

public struct PasteboardChange: Equatable, Sendable {
    public var changeCount: Int
    public var source: AppIdentity?
}

public final class PasteboardWatcher {
    public typealias Handler = (PasteboardChange) -> Bool
    public struct Token: Hashable { fileprivate let raw: Int }

    private struct Sub {
        var priority: Int
        var handler: Handler
    }

    private let pasteboard: PasteboardDriving
    private let frontmost: FrontmostAppProviding
    private var subs: [Int: Sub] = [:]
    private var counter = 0
    private var last: Int
    public var onActiveChange: ((Bool) -> Void)?

    public init(pasteboard: PasteboardDriving, frontmost: FrontmostAppProviding) {
        self.pasteboard = pasteboard
        self.frontmost = frontmost
        self.last = pasteboard.changeCount
    }

    public var subscriberCount: Int { subs.count }

    public func subscribe(priority: Int, _ handler: @escaping Handler) -> Token {
        counter += 1
        let wasEmpty = subs.isEmpty
        subs[counter] = Sub(priority: priority, handler: handler)
        if wasEmpty {
            last = pasteboard.changeCount
            onActiveChange?(true)
        }
        return Token(raw: counter)
    }

    public func unsubscribe(_ t: Token) {
        guard subs.removeValue(forKey: t.raw) != nil else { return }
        if subs.isEmpty { onActiveChange?(false) }
    }

    public func acknowledgeOwnWrite() { last = pasteboard.changeCount }

    public func tick() {
        let now = pasteboard.changeCount
        guard now != last else { return }
        last = now
        let source = frontmost.frontmost()
        for key in subs.keys.sorted(by: { (subs[$0]!.priority, $0) < (subs[$1]!.priority, $1) }) {
            guard let s = subs[key] else { continue }
            if s.handler(PasteboardChange(changeCount: pasteboard.changeCount, source: source)) { last = pasteboard.changeCount }
        }
    }
}

public final class ClipboardRecorder {
    private let pasteboard: PasteboardDriving
    private let store: ClipStore
    private let ownBundleID: String?
    public var settings: ClipSettings
    public private(set) var recorded = 0
    public private(set) var lastSkip: ClipSkipReason?
    public var onRecorded: ((ClipItem) -> Void)?

    public init(pasteboard: PasteboardDriving, store: ClipStore, settings: ClipSettings, ownBundleID: String? = nil) {
        self.pasteboard = pasteboard
        self.store = store
        self.settings = settings.sanitized
        self.ownBundleID = ownBundleID
    }

    @discardableResult
    public func handle(_ change: PasteboardChange) -> Bool {
        let types = pasteboard.typeIdentifiers
        let items = pasteboard.readItems(types: ClipCapture.wantedTypes(settings).union(PBType.concealedMarkers).union(PBType.transientMarkers))
        let snap = ClipSnapshot(changeCount: change.changeCount, types: types, items: items, source: change.source)
        switch ClipCapture.evaluate(snap, settings: settings, ownBundleID: ownBundleID) {
        case .skip(let r):
            lastSkip = r
        case .record(let cand):
            lastSkip = nil
            do {
                let res = try store.insert(cand)
                try store.prune(settings)
                recorded += 1
                if let it = try store.item(id: res.id) { onRecorded?(it) }
            } catch {
                Log.write("clipboard insert failed: \(error)")
            }
        }
        return false
    }
}

public final class ClipAutoClear {
    private let pasteboard: PasteboardDriving
    private let scheduler: Scheduling
    private let acknowledge: () -> Void
    public var seconds: Int
    public private(set) var clears = 0

    public init(pasteboard: PasteboardDriving, scheduler: Scheduling, seconds: Int, acknowledge: @escaping () -> Void) {
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.seconds = seconds
        self.acknowledge = acknowledge
    }

    @discardableResult
    public func handle(_ change: PasteboardChange) -> Bool {
        guard seconds > 0 else { return false }
        let expected = change.changeCount
        scheduler.after(Double(seconds)) { [weak self] in
            guard let self, self.pasteboard.changeCount == expected else { return }
            self.clearNow()
        }
        return false
    }

    public func clearNow() {
        guard !pasteboard.typeIdentifiers.isEmpty else { return }
        pasteboard.clear()
        acknowledge()
        clears += 1
    }
}
