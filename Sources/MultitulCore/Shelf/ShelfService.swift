import Foundation

public struct ShelfAfterDrop: Equatable, Sendable {
    public var removed: [Int64] = []
    public var closeShelf = false
    public init() {}
}

public enum ShelfMaintenance {
    public static func orphans(listing: [String], dir: String, referenced: Set<String>) -> [String] {
        listing.map { ShelfPaths.normalize(dir + "/" + $0) }.filter { !referenced.contains($0) }
    }
}

public final class ShelfService {
    public let store: ShelfStore
    public let fs: ShelfFileSystem
    public var settings: ShelfSettings
    public let ownedDirs: [String]
    public let outDir: String
    public private(set) var items: [ShelfItem] = []
    public var onChange: (() -> Void)?

    public init(store: ShelfStore, fs: ShelfFileSystem, settings: ShelfSettings = ShelfSettings(),
                ownedDirs: [String] = [MultitulPaths.shelfFilesDir, MultitulPaths.shelfArchivesDir], outDir: String = MultitulPaths.shelfOutDir) {
        self.store = store
        self.fs = fs
        self.settings = settings
        self.ownedDirs = ownedDirs
        self.outDir = outDir
        reload()
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func item(id: Int64) -> ShelfItem? { items.first { $0.id == id } }

    public func reload() {
        items = (try? store.items()) ?? []
    }

    private func changed() {
        reload()
        onChange?()
    }

    @discardableResult
    public func add(_ incoming: [ShelfIncoming], source: String? = nil) -> ShelfAddResult {
        var res = ShelfAddResult()
        for inc in incoming {
            guard let c = ShelfIngest.candidate(inc, fs: fs, source: source), let r = try? store.insert(c) else { res.skipped += 1; continue }
            if r.deduped {
                if !res.deduped.contains(r.id) { res.deduped.append(r.id) }
            } else {
                res.added.append(r.id)
            }
        }
        if let extra = try? store.oldestUnpinned(beyond: ShelfLimits.maxItems), !extra.isEmpty { discard(extra) }
        if !res.ids.isEmpty { changed() }
        return res
    }

    @discardableResult
    public func addPaths(_ paths: [String], owned: Bool = false, source: String? = nil) -> ShelfAddResult {
        add(paths.map { .file(path: $0, owned: owned) }, source: source)
    }

    public func payload(of id: Int64) -> ShelfPayload? { try? store.payload(id: id) }

    public func setPinned(_ ids: [Int64], _ pinned: Bool) {
        for id in ids { try? store.setPinned(id: id, pinned) }
        changed()
    }

    public func togglePin(_ id: Int64) {
        guard let it = item(id: id) else { return }
        setPinned([id], !it.pinned)
    }

    private func discard(_ list: [ShelfItem]) {
        for it in list where it.owned { removeOwnedFile(it.path) }
        try? store.delete(ids: list.map(\.id))
    }

    private func removeOwnedFile(_ path: String?) {
        guard let path, let container = ShelfService.ownedContainer(of: path, dirs: ownedDirs) else { return }
        fs.remove(container)
    }

    public static func ownedContainer(of path: String, dirs: [String]) -> String? {
        let p = ShelfPaths.normalize(path)
        for d in dirs where ShelfPaths.isInside(p, dir: d) {
            let base = ShelfPaths.normalize(d)
            guard let first = p.dropFirst(base.count + 1).split(separator: "/").first else { return nil }
            return base + "/" + first
        }
        return nil
    }

    public func remove(_ ids: [Int64]) {
        let set = Set(ids)
        let list = items.filter { set.contains($0.id) }
        guard !list.isEmpty else { return }
        discard(list)
        changed()
    }

    public func clear(keepPinned: Bool = true) {
        let list = items.filter { !(keepPinned && $0.pinned) }
        guard !list.isEmpty else { return }
        discard(list)
        changed()
    }

    public func resolve(_ it: ShelfItem) -> ShelfFileState {
        guard it.kind.isPath else { return .missing(lastPath: nil) }
        let bookmark = (try? store.payload(id: it.id))?.bookmark
        if let bookmark, case .resolved(let path, let stale) = fs.resolveBookmark(bookmark), fs.exists(path) {
            let moved = ShelfPaths.normalize(path) != it.path.map(ShelfPaths.normalize)
            if moved || stale {
                try? store.updateLocation(id: it.id, path: ShelfPaths.normalize(path), bookmark: fs.makeBookmark(path))
                reload()
            }
            return moved ? .relocated(path: path) : .ok(path: path)
        }
        if let p = it.path, fs.exists(p) {
            if bookmark == nil, let b = fs.makeBookmark(p) { try? store.updateLocation(id: it.id, path: p, bookmark: b) }
            return .ok(path: p)
        }
        return .missing(lastPath: it.path)
    }

    public func states() -> [Int64: ShelfFileState] {
        var out: [Int64: ShelfFileState] = [:]
        for it in items where it.kind.isPath { out[it.id] = resolve(it) }
        return out
    }

    public func resolvedPaths(_ ids: [Int64]) -> [String] {
        let set = Set(ids)
        return items.filter { set.contains($0.id) && $0.kind.isPath }.compactMap { resolve($0).path }
    }

    public struct DragPlan: Equatable, Sendable {
        public var payloads: [ShelfDragPayload] = []
        public var missing: [Int64] = []
    }

    public func dragPlan(_ ids: [Int64]) -> DragPlan {
        let set = Set(ids)
        var plan = DragPlan()
        var files: [String] = []
        var filesSlot: Int?
        for it in items where set.contains(it.id) {
            switch it.kind {
            case .file, .folder:
                if let p = resolve(it).path {
                    if filesSlot == nil { filesSlot = plan.payloads.count; plan.payloads.append(.files([])) }
                    files.append(p)
                } else {
                    plan.missing.append(it.id)
                }
            case .text:
                if let b = payload(of: it.id)?.body { plan.payloads.append(.text(b)) } else { plan.missing.append(it.id) }
            case .url:
                if let b = payload(of: it.id)?.body { plan.payloads.append(.url(b)) } else { plan.missing.append(it.id) }
            case .image:
                if let d = payload(of: it.id)?.data { plan.payloads.append(.image(d, ext: it.ext ?? "png", name: it.title)) } else { plan.missing.append(it.id) }
            }
        }
        if let slot = filesSlot { plan.payloads[slot] = .files(files) }
        return plan
    }

    public func dragCompleted(ids: [Int64], accepted: Bool) -> ShelfAfterDrop {
        var out = ShelfAfterDrop()
        guard accepted else { return out }
        if settings.deleteAfterDrop {
            let set = Set(ids)
            let doomed = items.filter { set.contains($0.id) && !$0.pinned }
            if !doomed.isEmpty {
                discard(doomed)
                out.removed = doomed.map(\.id)
                changed()
            }
        }
        out.closeShelf = settings.closeAfterDrop || (settings.autoHideEmpty && items.isEmpty)
        return out
    }

    public func cleanupOrphans() -> [String] {
        let referenced = Set(((try? store.ownedPaths()) ?? []).compactMap { Self.ownedContainer(of: $0, dirs: ownedDirs) })
        var removed: [String] = []
        for dir in ownedDirs {
            for o in ShelfMaintenance.orphans(listing: fs.list(dir), dir: dir, referenced: referenced) where fs.remove(o) { removed.append(o) }
        }
        for name in fs.list(outDir) {
            let p = outDir + "/" + name
            if fs.remove(p) { removed.append(p) }
        }
        return removed
    }
}
