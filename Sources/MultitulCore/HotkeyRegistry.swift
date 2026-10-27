import Foundation

public struct HotkeyRow: Identifiable, Equatable, Sendable {
    public let spec: HotkeySpec
    public let owner: String
    public let group: String
    public let groupOrder: Int
    public let module: ModuleID?
    public var id: String { spec.id }
}

public struct HotkeySection: Identifiable {
    public let title: String
    public let rows: [HotkeyRow]
    public var id: String { title }
}

public enum HotkeyFilter: String, CaseIterable, Identifiable, Sendable {
    case all, changed, conflicts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Все"
        case .changed: "Изменённые"
        case .conflicts: "Конфликты"
        }
    }
}

public enum HotkeyRegistry {
    public static let coreGroup = "Мультитул"

    public static let rows: [HotkeyRow] = {
        var out = CoreHotkeys.all.map { HotkeyRow(spec: $0, owner: coreGroup, group: coreGroup, groupOrder: 0, module: nil) }
        for id in ModuleID.allCases {
            let info = id.info
            let order = (ModuleGroup.allCases.firstIndex(of: info.group) ?? 0) + 1
            for s in info.hotkeys { out.append(HotkeyRow(spec: s, owner: info.title, group: info.group.title, groupOrder: order, module: id)) }
        }
        return out
    }()

    // For every id that shares an identical non-empty combo with another id: titles of the others.
    public static func duplicates(_ items: [(id: String, title: String, combo: KeyCombo)]) -> [String: [String]] {
        var byCombo: [KeyCombo: [(id: String, title: String)]] = [:]
        for it in items where !it.combo.isNone { byCombo[it.combo, default: []].append((it.id, it.title)) }
        var out: [String: [String]] = [:]
        for (_, group) in byCombo where group.count > 1 {
            for g in group { out[g.id] = group.filter { $0.id != g.id }.map(\.title) }
        }
        return out
    }

    public static func matches(_ row: HotkeyRow, query: String, combo: KeyCombo) -> Bool {
        let words = SettingsSearch.words(query)
        let raw = query.trimmingCharacters(in: .whitespaces).lowercased()
        if words.isEmpty && raw.isEmpty { return true }
        if !raw.isEmpty && !combo.isNone && combo.display.lowercased().contains(raw) { return true }
        if words.isEmpty { return false }
        return SettingsSearch.score(query: query, title: row.spec.title, keywords: row.owner + " " + row.group) != nil
    }

    public static func sections(rows: [HotkeyRow] = HotkeyRegistry.rows, query: String, filter: HotkeyFilter,
                                combo: (HotkeySpec) -> KeyCombo, conflicting: Set<String>) -> [HotkeySection] {
        let kept = rows.filter { r in
            let c = combo(r.spec)
            switch filter {
            case .all: break
            case .changed: if c == r.spec.defaultCombo { return false }
            case .conflicts: if !conflicting.contains(r.id) { return false }
            }
            return matches(r, query: query, combo: c)
        }
        var order: [String] = []
        var byGroup: [String: [HotkeyRow]] = [:]
        for r in kept.sorted(by: { $0.groupOrder < $1.groupOrder }) {
            if byGroup[r.group] == nil { order.append(r.group) }
            byGroup[r.group, default: []].append(r)
        }
        return order.map { HotkeySection(title: $0, rows: byGroup[$0] ?? []) }
    }
}
