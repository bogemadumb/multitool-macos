import Foundation

public enum PanelItemKind: String, Codable, Sendable { case card, tile }

public enum PanelItemSize: String, Codable, Sendable, CaseIterable {
    case small, medium, wide

    public static func resolve(_ requested: PanelItemSize?, allowed: [PanelItemSize], fallback: PanelItemSize) -> PanelItemSize {
        guard !allowed.isEmpty else { return fallback }
        let want = requested ?? fallback
        if allowed.contains(want) { return want }
        let chain: [PanelItemSize]
        switch want {
        case .small: chain = [.medium, .wide]
        case .wide: chain = [.medium, .small]
        case .medium: chain = [.small, .wide]
        }
        return chain.first(where: allowed.contains) ?? allowed[0]
    }
}

public enum PanelItemID {
    public static func make(_ module: String, _ kind: PanelItemKind) -> String { module + "." + kind.rawValue }

    public static func parse(_ id: String) -> (module: String, kind: PanelItemKind)? {
        guard let dot = id.lastIndex(of: ".") else { return nil }
        let module = String(id[..<dot])
        guard !module.isEmpty, let kind = PanelItemKind(rawValue: String(id[id.index(after: dot)...])) else { return nil }
        return (module, kind)
    }

    public static func isValid(_ id: String, modules: Set<String>) -> Bool {
        guard let p = parse(id) else { return false }
        return modules.contains(p.module)
    }
}

public enum PanelPresentation: String, Sendable {
    case quick, module, cardOnly

    public var emitsCard: Bool { self != .module }
    public var emitsTile: Bool { self != .cardOnly }
}

public enum PanelSection: Int, CaseIterable, Sendable {
    case modules, sliders, metrics, cards, quick

    public static func of(module: String, kind: PanelItemKind, presentation: PanelPresentation, small: Bool = false) -> PanelSection {
        switch kind {
        case .tile: return presentation == .module ? .modules : .quick
        case .card:
            if small { return .quick }
            if module == ModuleID.brightness.rawValue || module == ModuleID.soundOutputSwitcher.rawValue { return .sliders }
            if ModuleID(rawValue: module)?.monitorMetric != nil { return .metrics }
            return .cards
        }
    }

    public static func group(_ ids: [String], by section: (String) -> PanelSection) -> [PanelSection: [String]] {
        var out: [PanelSection: [String]] = [:]
        for id in ids { out[section(id), default: []].append(id) }
        return out
    }
}

public struct PanelProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var order: [String] = []
    public var hidden: Set<String> = []
    public var sizes: [String: PanelItemSize] = [:]
    public var collapsed: Set<String> = []

    public init(id: String = UUID().uuidString, name: String, order: [String] = []) {
        self.id = id
        self.name = name
        self.order = order
    }

    public mutating func reconcile(available: [String], validModules: Set<String>) {
        var seen = Set<String>()
        order = order.filter { PanelItemID.isValid($0, modules: validModules) && seen.insert($0).inserted }
        hidden = hidden.filter { PanelItemID.isValid($0, modules: validModules) }
        collapsed = collapsed.filter { PanelItemID.isValid($0, modules: validModules) }
        sizes = sizes.filter { PanelItemID.isValid($0.key, modules: validModules) }
        for id in available where seen.insert(id).inserted { order.append(id) }
    }

    public func visible(available: [String]) -> [String] {
        let set = Set(available)
        return order.filter { set.contains($0) && !hidden.contains($0) }
    }

    public func hiddenItems(available: [String]) -> [String] {
        let set = Set(available)
        return order.filter { set.contains($0) && hidden.contains($0) }
    }

    public mutating func move(_ id: String, before target: String?) {
        guard id != target, let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) { order.insert(id, at: to) } else { order.append(id) }
    }

    public mutating func hide(_ id: String) { hidden.insert(id) }

    public mutating func show(_ id: String) {
        guard hidden.remove(id) != nil else { return }
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        order.append(id)
    }

    public func size(of id: String, allowed: [PanelItemSize], fallback: PanelItemSize) -> PanelItemSize {
        PanelItemSize.resolve(sizes[id], allowed: allowed, fallback: fallback)
    }

    public mutating func setSize(_ id: String, _ size: PanelItemSize) { sizes[id] = size }

    public func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    public mutating func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

struct PanelLayoutData: Codable, Equatable {
    var profiles: [PanelProfile]
    var activeID: String
}

@MainActor
public final class PanelLayoutStore: ObservableObject {
    public static let defaultsKey = "panel.layout.data"
    public static let mainProfileID = "main"

    private let defaults: KeyValueStoring
    private let validModules: Set<String>
    private var available: [String] = []

    @Published public private(set) var profiles: [PanelProfile]
    @Published public private(set) var activeID: String

    public init(defaults: KeyValueStoring = UserDefaults.standard, validModules: Set<String> = Set(ModuleID.allCases.map(\.rawValue))) {
        self.defaults = defaults
        self.validModules = validModules
        if let raw = defaults.data(forKey: Self.defaultsKey),
           let d = try? JSONDecoder().decode(PanelLayoutData.self, from: raw), !d.profiles.isEmpty {
            profiles = d.profiles
            activeID = d.profiles.contains(where: { $0.id == d.activeID }) ? d.activeID : d.profiles[0].id
        } else {
            profiles = [PanelProfile(id: Self.mainProfileID, name: "Основной")]
            activeID = Self.mainProfileID
        }
    }

    public var active: PanelProfile { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }

    public func reconcile(available: [String]) {
        self.available = available
        var changed = false
        for i in profiles.indices {
            let before = profiles[i]
            profiles[i].reconcile(available: available, validModules: validModules)
            if profiles[i] != before { changed = true }
        }
        if changed { save() }
    }

    private func save() {
        let d = PanelLayoutData(profiles: profiles, activeID: activeID)
        if let raw = try? JSONEncoder().encode(d) { defaults.set(raw, forKey: Self.defaultsKey) }
    }

    private func mutateActive(_ f: (inout PanelProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        f(&profiles[i])
        save()
    }

    public func move(_ id: String, before target: String?) { mutateActive { $0.move(id, before: target) } }
    public func hide(_ id: String) { mutateActive { $0.hide(id) } }
    public func show(_ id: String) { mutateActive { $0.show(id) } }
    public func setSize(_ id: String, _ size: PanelItemSize) { mutateActive { $0.setSize(id, size) } }
    public func toggleCollapsed(_ id: String) { mutateActive { $0.toggleCollapsed(id) } }

    public func switchProfile(_ id: String) {
        guard profiles.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id
        save()
    }

    @discardableResult
    public func addProfile(name: String) -> String {
        let p = PanelProfile(name: cleanName(name, fallback: "Набор"), order: available)
        profiles.append(p)
        activeID = p.id
        save()
        return p.id
    }

    @discardableResult
    public func duplicateActive() -> String {
        var p = active
        p.id = UUID().uuidString
        p.name = p.name + " копия"
        profiles.append(p)
        activeID = p.id
        save()
        return p.id
    }

    public func renameActive(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        mutateActive { $0.name = n }
    }

    @discardableResult
    public func deleteActive() -> Bool {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == activeID }) else { return false }
        profiles.remove(at: i)
        activeID = profiles[min(i, profiles.count - 1)].id
        save()
        return true
    }

    private func cleanName(_ s: String, fallback: String) -> String {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? fallback : n
    }
}
