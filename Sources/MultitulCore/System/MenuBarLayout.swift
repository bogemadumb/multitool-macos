import Foundation

public enum MenuBarStyle: String, CaseIterable, Sendable {
    case number, bar, graph

    public var title: String {
        switch self {
        case .number: "Число"
        case .bar: "Полоска"
        case .graph: "График"
        }
    }
}

public struct MenuBarItem: Equatable, Sendable {
    public var metric: SystemMetric
    public var visible: Bool
    public var style: MenuBarStyle
    public init(metric: SystemMetric, visible: Bool = false, style: MenuBarStyle = .number) {
        self.metric = metric
        self.visible = visible
        self.style = style
    }
}

public struct MenuBarLayout: Equatable, Sendable {
    public static let defaultsKey = "monitor.menubar.layout"
    public static let metrics: [SystemMetric] = SystemMetric.allCases.filter(\.inMenuBar)

    public var combined: Bool
    public var items: [MenuBarItem]

    public init(combined: Bool = true, items: [MenuBarItem]? = nil) {
        self.combined = combined
        self.items = items ?? Self.metrics.map { MenuBarItem(metric: $0) }
        normalize()
    }

    public mutating func normalize() {
        var seen = Set<SystemMetric>()
        items = items.filter { $0.metric.inMenuBar && seen.insert($0.metric).inserted }
        for m in Self.metrics where !seen.contains(m) { items.append(MenuBarItem(metric: m)) }
    }

    public mutating func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        let it = items.remove(at: from)
        items.insert(it, at: to)
    }

    public mutating func moveUp(_ metric: SystemMetric) {
        if let i = items.firstIndex(where: { $0.metric == metric }), i > 0 { move(from: i, to: i - 1) }
    }

    public mutating func moveDown(_ metric: SystemMetric) {
        if let i = items.firstIndex(where: { $0.metric == metric }), i < items.count - 1 { move(from: i, to: i + 1) }
    }

    public mutating func setVisible(_ metric: SystemMetric, _ on: Bool) {
        if let i = items.firstIndex(where: { $0.metric == metric }) { items[i].visible = on }
    }

    public mutating func setStyle(_ metric: SystemMetric, _ style: MenuBarStyle) {
        if let i = items.firstIndex(where: { $0.metric == metric }) { items[i].style = style }
    }

    public func item(_ metric: SystemMetric) -> MenuBarItem? { items.first { $0.metric == metric } }

    public func shown(enabled: Set<SystemMetric>) -> [MenuBarItem] {
        items.filter { $0.visible && enabled.contains($0.metric) }
    }

    public func encoded() -> Data {
        let obj: [String: Any] = [
            "combined": combined,
            "items": items.map { ["metric": $0.metric.rawValue, "visible": $0.visible, "style": $0.style.rawValue] as [String: Any] }
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func decode(_ data: Data?) -> MenuBarLayout {
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return MenuBarLayout() }
        let combined = (obj["combined"] as? Bool) ?? true
        let raw = (obj["items"] as? [[String: Any]]) ?? []
        let items: [MenuBarItem] = raw.compactMap { d in
            guard let m = (d["metric"] as? String).flatMap(SystemMetric.init(rawValue:)) else { return nil }
            return MenuBarItem(metric: m, visible: (d["visible"] as? Bool) ?? false,
                               style: (d["style"] as? String).flatMap(MenuBarStyle.init(rawValue:)) ?? .number)
        }
        return MenuBarLayout(combined: combined, items: items)
    }

    public static func load(from d: KeyValueStoring = UserDefaults.standard) -> MenuBarLayout { decode(d.data(forKey: defaultsKey)) }
    public func save(to d: KeyValueStoring = UserDefaults.standard) { d.set(encoded(), forKey: Self.defaultsKey) }
}
