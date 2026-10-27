import Foundation
import CoreGraphics

public struct CGWindowRecord: Equatable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var layer: Int
    public var title: String
    public var frame: CGRect
    public var onScreen: Bool
    public var alpha: Double
    public var zIndex: Int

    public init(windowID: UInt32, pid: Int32, layer: Int = 0, title: String = "", frame: CGRect, onScreen: Bool = true, alpha: Double = 1, zIndex: Int = 0) {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.title = title
        self.frame = frame
        self.onScreen = onScreen
        self.alpha = alpha
        self.zIndex = zIndex
    }
}

public struct AXWindowRecord: Equatable, Sendable {
    public var key: Int
    public var pid: Int32
    public var title: String
    public var frame: CGRect
    public var isMinimized: Bool
    public var isFullscreen: Bool

    public init(key: Int, pid: Int32, title: String = "", frame: CGRect, isMinimized: Bool = false, isFullscreen: Bool = false) {
        self.key = key
        self.pid = pid
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
    }
}

public enum WindowSnapshotMerger {
    public static let frameTolerance: CGFloat = 6
    public static let syntheticKeyBase = 1 << 40

    public static func syntheticKey(windowID: UInt32) -> Int { syntheticKeyBase + Int(windowID) }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }

    public static func merge(cg: [CGWindowRecord], ax: [AXWindowRecord], apps: [Int32: SwitchApp], displays: [WndDisplay]) -> [SwitchWindow] {
        var cgByPID: [Int32: [Int]] = [:]
        for (i, r) in cg.enumerated() where r.layer == 0 && r.alpha > 0 && apps[r.pid] != nil { cgByPID[r.pid, default: []].append(i) }
        var axByPID: [Int32: [Int]] = [:]
        for (i, r) in ax.enumerated() where apps[r.pid] != nil { axByPID[r.pid, default: []].append(i) }

        var out: [SwitchWindow] = []
        out.reserveCapacity(ax.count + 4)
        var usedCG = Set<Int>()

        for (pid, axIdx) in axByPID {
            let cgIdx = cgByPID[pid] ?? []
            var pairs: [Int: Int] = [:]
            var taken = Set<Int>()
            func pass(_ test: (AXWindowRecord, CGWindowRecord) -> Bool) {
                for a in axIdx where pairs[a] == nil {
                    if let c = cgIdx.first(where: { !taken.contains($0) && test(ax[a], cg[$0]) }) {
                        pairs[a] = c
                        taken.insert(c)
                    }
                }
            }
            pass { a, c in a.title == c.title && close(a.frame, c.frame) }
            pass { a, c in close(a.frame, c.frame) }
            pass { a, c in !a.title.isEmpty && a.title == c.title && abs(a.frame.width - c.frame.width) <= 40 }
            let app = apps[pid]!
            for a in axIdx {
                let r = ax[a]
                let matched = pairs[a].map { cg[$0] }
                if matched == nil, !r.isMinimized, !app.isHidden, !r.isFullscreen { continue }
                if let m = pairs[a] { usedCG.insert(m) }
                let d = DisplayAssignment.display(for: r.frame, in: displays)
                out.append(SwitchWindow(key: r.key, windowID: matched?.windowID ?? 0, pid: pid, bundleID: app.bundleID, appName: app.name, title: r.title, frame: r.frame,
                                        displayID: d?.id, isMinimized: r.isMinimized, isAppHidden: app.isHidden, isFullscreen: r.isFullscreen, isOnCurrentSpace: true,
                                        zIndex: matched?.zIndex ?? Int.max))
            }
        }

        for (pid, idxs) in cgByPID {
            let app = apps[pid]!
            guard app.isRegular else { continue }
            let hasAX = axByPID[pid] != nil
            for i in idxs where !usedCG.contains(i) {
                let r = cg[i]
                if r.onScreen {
                    if hasAX { continue }
                    guard r.frame.width >= 100, r.frame.height >= 50 else { continue }
                } else {
                    guard AutoQuitSurfaces.isOffscreenUserWindow(layer: r.layer, size: r.frame.size, onScreen: false, title: r.title) else { continue }
                }
                let d = DisplayAssignment.display(for: r.frame, in: displays)
                out.append(SwitchWindow(key: syntheticKey(windowID: r.windowID), windowID: r.windowID, pid: pid, bundleID: app.bundleID, appName: app.name, title: r.title, frame: r.frame,
                                        displayID: d?.id, isMinimized: false, isAppHidden: app.isHidden, isFullscreen: false, isOnCurrentSpace: r.onScreen, zIndex: r.zIndex))
            }
        }
        return out.sorted { $0.zIndex != $1.zIndex ? $0.zIndex < $1.zIndex : $0.key < $1.key }
    }
}
