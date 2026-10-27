import Foundation

public final class WindowUseOrder {
    public static let capacity = 512
    public static let reconcileDepth = 8

    private var windowStamp: [Int: Int] = [:]
    private var appStamp: [Int32: Int] = [:]
    private var counter = 0

    public init() {}

    public var trackedWindows: Int { windowStamp.count }

    public func touch(window key: Int, pid: Int32) {
        counter += 1
        windowStamp[key] = counter
        appStamp[pid] = counter
        if windowStamp.count > Self.capacity { trim() }
    }

    public func touchApp(_ pid: Int32) {
        counter += 1
        appStamp[pid] = counter
    }

    public func stamp(ofWindow key: Int) -> Int? { windowStamp[key] }
    public func stamp(ofApp pid: Int32) -> Int? { appStamp[pid] }

    public func forget(window key: Int) { windowStamp.removeValue(forKey: key) }

    public func prune(aliveWindows: Set<Int>, alivePIDs: Set<Int32>) {
        windowStamp = windowStamp.filter { aliveWindows.contains($0.key) }
        appStamp = appStamp.filter { alivePIDs.contains($0.key) }
    }

    private func trim() {
        let keep = windowStamp.sorted { $0.value > $1.value }.prefix(Self.capacity * 3 / 4)
        windowStamp = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    public func reconcile(frontToBack visible: [SwitchWindow]) {
        let top = Array(visible.filter { !$0.isMinimized && $0.isOnCurrentSpace }.prefix(Self.reconcileDepth))
        var ordered = true
        var previous = Int.max
        for w in top {
            guard let s = windowStamp[w.key] else { ordered = false; break }
            if s > previous { ordered = false; break }
            previous = s
        }
        guard !ordered else { return }
        for w in top.reversed() { touch(window: w.key, pid: w.pid) }
    }

    public func sorted(_ windows: [SwitchWindow]) -> [SwitchWindow] {
        func rank(_ w: SwitchWindow) -> (Int, Int, Int) {
            if let s = windowStamp[w.key] { return (2, s, 0) }
            return (1, appStamp[w.pid] ?? 0, -w.zIndex)
        }
        return windows.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra > rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    public func sortedApps(_ apps: [SwitchApp]) -> [SwitchApp] {
        apps.enumerated().sorted { a, b in
            let sa = appStamp[a.element.pid] ?? 0, sb = appStamp[b.element.pid] ?? 0
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }
}
