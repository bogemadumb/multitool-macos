import Foundation
import CoreGraphics

public enum SwitcherListBuilder {
    public static let finderBundleID = "com.apple.finder"

    public static func build(windows: [SwitchWindow], apps: [SwitchApp], filter: SwitchFilter, context: SwitcherContext, order: WindowUseOrder? = nil,
                             creationOrder: Bool = false) -> [SwitchEntry] {
        var sameApp: Int32?
        if case .sameApp(let pid) = context.scope { sameApp = pid }

        var candidates: [SwitchWindow] = []
        candidates.reserveCapacity(windows.count)
        var pidsWithWindows = Set<Int32>()
        for w in windows where w.pid != filter.ownPID {
            pidsWithWindows.insert(w.pid)
            if let s = sameApp, w.pid != s { continue }
            if filter.rules[w.bundleID] == .hidden { continue }
            if w.frame.width < filter.minSide || w.frame.height < filter.minSide { continue }
            if filter.currentSpaceOnly, !w.isOnCurrentSpace, !(w.isFullscreen && filter.showFullscreen) { continue }
            if !filter.showFullscreen, w.isFullscreen { continue }
            if filter.currentDisplayOnly, let want = context.activeDisplayID, let have = w.displayID, want != have { continue }
            if filter.minimized == .hidden, minimizedLike(w, filter) { continue }
            candidates.append(w)
        }

        var sorted: [SwitchWindow]
        if creationOrder {
            sorted = candidates.enumerated().sorted { a, b in
                let wa = a.element.windowID, wb = b.element.windowID
                if wa != wb { return wa < wb }
                return a.offset < b.offset
            }.map(\.element)
        } else if let order {
            sorted = order.sorted(candidates)
        } else {
            sorted = candidates
        }
        if filter.minimized == .end {
            sorted = sorted.filter { !minimizedLike($0, filter) } + sorted.filter { minimizedLike($0, filter) }
        }
        if !creationOrder, let fk = context.focusedKey, let i = sorted.firstIndex(where: { $0.key == fk }), i > 0 {
            sorted.insert(sorted.remove(at: i), at: 0)
        }

        var entries: [SwitchEntry] = []
        entries.reserveCapacity(sorted.count + 8)
        if filter.mergeWindows && sameApp == nil {
            var index: [Int32: Int] = [:]
            for w in sorted {
                if let i = index[w.pid] {
                    entries[i].windowCount += 1
                    if entries[i].isMinimized && !w.isMinimized { entries[i].isMinimized = false }
                } else {
                    index[w.pid] = entries.count
                    entries.append(SwitchEntry(window: w, kind: .window, count: 1, previewAllowed: !filter.previewExcluded.contains(w.bundleID)))
                }
            }
            for i in entries.indices where entries[i].windowCount > 1 { entries[i].kind = .group }
        } else {
            for w in sorted { entries.append(SwitchEntry(window: w, previewAllowed: !filter.previewExcluded.contains(w.bundleID))) }
        }

        if sameApp == nil {
            let candidatePIDs = Set(entries.map(\.pid))
            let ordered = order?.sortedApps(apps) ?? apps
            for a in ordered where a.isRegular && a.pid != filter.ownPID && !candidatePIDs.contains(a.pid) && !pidsWithWindows.contains(a.pid) {
                let rule = filter.rules[a.bundleID]
                if rule == .hidden || rule == .windowsOnly { continue }
                let wanted = rule == .showWithoutWindows || windowlessWanted(a, filter.windowless)
                if wanted { entries.append(SwitchEntry(app: a)) }
            }
        }
        return entries
    }

    static func minimizedLike(_ w: SwitchWindow, _ f: SwitchFilter) -> Bool {
        w.isMinimized || (f.hiddenLikeMinimized && w.isAppHidden)
    }

    static func windowlessWanted(_ a: SwitchApp, _ mode: WindowlessApps) -> Bool {
        switch mode {
        case .off: false
        case .finder: a.bundleID == finderBundleID
        case .all: true
        }
    }

    public static func initialIndex(count: Int, backward: Bool) -> Int? {
        guard count > 0 else { return nil }
        if backward { return count - 1 }
        return count > 1 ? 1 : 0
    }
}
