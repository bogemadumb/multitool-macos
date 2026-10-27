import SwiftUI
import AppKit
import MultitulCore

@MainActor
protocol ShelfActionHandling: AnyObject {
    func open(_ ids: [Int64])
    func reveal(_ ids: [Int64])
    func quickLook(_ ids: [Int64])
    func copy(_ ids: [Int64])
    func share(_ ids: [Int64])
    func airDrop(_ ids: [Int64])
    func compress(_ ids: [Int64])
    func remove(_ ids: [Int64])
    func clearAll()
    func closeShelf()
    func dragEnded(ids: [Int64], accepted: Bool)
    func writers(for ids: [Int64]) -> [NSPasteboardWriting]
}

@MainActor
final class ShelfViewModel: ObservableObject {
    let service: ShelfService
    weak var actions: ShelfActionHandling?
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var states: [Int64: ShelfFileState] = [:]
    @Published var selection: Set<Int64> = []
    @Published var targeted = false
    @Published var busy: String?
    private var anchor: Int64?

    init(service: ShelfService) {
        self.service = service
        refresh()
    }

    func refresh() {
        items = service.items
        states = service.states()
        selection = selection.intersection(Set(items.map(\.id)))
    }

    var selectedOrAll: [Int64] { selection.isEmpty ? items.map(\.id) : items.filter { selection.contains($0.id) }.map(\.id) }
    var orderedSelection: [Int64] { items.filter { selection.contains($0.id) }.map(\.id) }

    func pointerDown(_ id: Int64, command: Bool, shift: Bool) {
        if shift, let a = anchor, let ai = items.firstIndex(where: { $0.id == a }), let ci = items.firstIndex(where: { $0.id == id }) {
            selection = Set(items[min(ai, ci)...max(ai, ci)].map(\.id))
            return
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            return
        }
        anchor = id
        if !selection.contains(id) { selection = [id] }
    }

    func pointerUp(_ id: Int64, command: Bool, shift: Bool) {
        if !command && !shift && selection.count > 1 && selection.contains(id) { selection = [id] }
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    func idsForContext(_ id: Int64) -> [Int64] {
        if selection.contains(id) { return orderedSelection }
        selection = [id]
        return [id]
    }
}
