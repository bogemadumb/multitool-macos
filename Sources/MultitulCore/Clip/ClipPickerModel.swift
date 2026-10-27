import Foundation

public final class ClipPickerModel {
    public private(set) var items: [ClipItem] = []
    public private(set) var selection = 0
    public private(set) var multi: [Int64] = []
    public var query = "" { didSet { if query != oldValue { reload() } } }
    public var kindFilter: Set<ClipKind> = [] { didSet { if kindFilter != oldValue { reload() } } }
    public var limit = 200

    private let store: ClipStore
    private let engine: ClipPasteEngine?

    public init(store: ClipStore, engine: ClipPasteEngine? = nil) {
        self.store = store
        self.engine = engine
    }

    public func reload() {
        let keepID = highlighted?.id
        items = ((try? store.search(query, kinds: kindFilter.isEmpty ? nil : kindFilter, limit: limit)) ?? [])
        multi = multi.filter { id in items.contains { $0.id == id } }
        if let keepID, let i = items.firstIndex(where: { $0.id == keepID }) { selection = i } else { selection = 0 }
    }

    public var highlighted: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    public func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    public func select(index: Int) {
        if items.indices.contains(index) { selection = index }
    }

    public func toggleMulti(id: Int64) {
        if let i = multi.firstIndex(of: id) { multi.remove(at: i) } else { multi.append(id) }
    }

    public func item(quickKey n: Int) -> ClipItem? {
        guard (1...9).contains(n), items.indices.contains(n - 1) else { return nil }
        return items[n - 1]
    }

    public var chosen: [ClipItem] {
        if !multi.isEmpty { return items.filter { multi.contains($0.id) } }
        return highlighted.map { [$0] } ?? []
    }

    public func togglePin(_ item: ClipItem) {
        try? store.setPinned(id: item.id, !item.pinned)
        reload()
    }

    public func delete(_ list: [ClipItem]) {
        try? store.delete(ids: list.map(\.id))
        multi.removeAll { id in list.contains { $0.id == id } }
        reload()
    }

    @discardableResult
    public func activate(_ list: [ClipItem], plain: Bool, copyOnly: Bool, target: AppIdentity?, completion: ((PasteOutcome) -> Void)? = nil) -> PasteOutcome {
        guard let engine, !list.isEmpty else { completion?(.nothing); return .nothing }
        let entries: [(item: ClipItem, reps: [ClipRep])] = list.compactMap { it in
            guard let reps = try? store.reps(id: it.id), !reps.isEmpty else { return nil }
            return (it, reps)
        }
        let outcome = engine.paste(entries, plain: plain, target: target, copyOnly: copyOnly, completion: completion)
        if outcome != .nothing { for it in list { try? store.touch(id: it.id) } }
        return outcome
    }

    public func previewText(_ item: ClipItem, limit: Int = 4000) -> String? {
        guard item.kind == .text || item.kind == .rich else { return nil }
        guard let t = try? store.text(id: item.id) else { return nil }
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
