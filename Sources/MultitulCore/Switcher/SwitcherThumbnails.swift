import Foundation
import CoreGraphics

public struct ThumbEntry {
    public var image: CGImage
    public var capturedAt: TimeInterval
    public var lastUsed: TimeInterval
    public var bytes: Int
}

public final class ThumbnailCache {
    public let maxCount: Int
    public let maxBytes: Int
    public private(set) var totalBytes = 0
    private var items: [UInt32: ThumbEntry] = [:]

    public init(maxCount: Int = 160, maxBytes: Int = 160 * 1024 * 1024) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    public var count: Int { items.count }

    public func image(_ id: UInt32, now: TimeInterval = 0) -> CGImage? {
        guard var e = items[id] else { return nil }
        e.lastUsed = now
        items[id] = e
        return e.image
    }

    public func peek(_ id: UInt32) -> CGImage? { items[id]?.image }

    public func capturedAt(_ id: UInt32) -> TimeInterval? { items[id]?.capturedAt }

    public func store(_ image: CGImage, for id: UInt32, now: TimeInterval) {
        if let old = items[id] { totalBytes -= old.bytes }
        let bytes = image.bytesPerRow * image.height
        items[id] = ThumbEntry(image: image, capturedAt: now, lastUsed: now, bytes: bytes)
        totalBytes += bytes
        evict()
    }

    public func remove(_ id: UInt32) {
        if let e = items.removeValue(forKey: id) { totalBytes -= e.bytes }
    }

    public func prune(keeping alive: Set<UInt32>) {
        for id in items.keys where !alive.contains(id) { remove(id) }
    }

    public func isFresh(_ id: UInt32, now: TimeInterval, maxAge: TimeInterval) -> Bool {
        guard let t = items[id]?.capturedAt else { return false }
        return now - t <= maxAge
    }

    private func evict() {
        guard items.count > maxCount || totalBytes > maxBytes else { return }
        for (id, _) in items.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            if items.count <= maxCount && totalBytes <= maxBytes { break }
            remove(id)
        }
    }
}

public enum ThumbnailPlanner {
    public static let freshAge: TimeInterval = 2.0
    public static let minimizedAge: TimeInterval = 120.0

    public static func plan(entries: [SwitchEntry], selected: Int?, cache: ThumbnailCache, now: TimeInterval, allowCapture: Bool, budget: Int, visibleRange: Range<Int>? = nil) -> [UInt32] {
        guard allowCapture, budget > 0 else { return [] }
        var order: [Int] = []
        order.reserveCapacity(entries.count)
        if let s = selected, entries.indices.contains(s) { order.append(s) }
        let range = visibleRange ?? entries.startIndex..<entries.endIndex
        for i in entries.indices where i != selected && range.contains(i) { order.append(i) }
        for i in entries.indices where i != selected && !range.contains(i) { order.append(i) }
        var out: [UInt32] = []
        var seen = Set<UInt32>()
        for i in order {
            let e = entries[i]
            guard e.previewAllowed, let id = e.windowID, seen.insert(id).inserted else { continue }
            let age = e.isMinimized || e.isAppHidden ? minimizedAge : freshAge
            if cache.isFresh(id, now: now, maxAge: age) { continue }
            out.append(id)
            if out.count >= budget { break }
        }
        return out
    }
}

public protocol ThumbnailCapturing: AnyObject {
    func capture(windowID: UInt32, maxPixelWidth: Int, completion: @escaping (CGImage?) -> Void)
}

public final class ThumbnailService {
    public static let maxInFlight = 4
    public let cache: ThumbnailCache
    private let capturer: ThumbnailCapturing
    private let clock: () -> TimeInterval
    private var inFlight = Set<UInt32>()
    private var queue: [UInt32] = []
    private var failures: [UInt32: Int] = [:]
    public var maxPixelWidth = 480
    public var onUpdate: ((UInt32) -> Void)?
    public private(set) var captureCount = 0

    public init(capturer: ThumbnailCapturing, cache: ThumbnailCache = ThumbnailCache(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capturer = capturer
        self.cache = cache
        self.clock = clock
    }

    public var pending: Int { queue.count + inFlight.count }

    public func request(_ ids: [UInt32]) {
        queue = ids.filter { !inFlight.contains($0) && (failures[$0] ?? 0) < 3 }
        pump()
    }

    public func cancelQueued() { queue.removeAll() }

    public func resetFailures() { failures.removeAll() }

    private func pump() {
        while inFlight.count < Self.maxInFlight, !queue.isEmpty {
            let id = queue.removeFirst()
            guard inFlight.insert(id).inserted else { continue }
            captureCount += 1
            capturer.capture(windowID: id, maxPixelWidth: maxPixelWidth) { [weak self] image in
                guard let self else { return }
                self.inFlight.remove(id)
                if let image {
                    self.failures[id] = nil
                    self.cache.store(image, for: id, now: self.clock())
                    self.onUpdate?(id)
                } else {
                    self.failures[id, default: 0] += 1
                }
                self.pump()
            }
        }
    }
}
