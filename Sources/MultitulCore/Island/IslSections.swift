import Foundation
import SwiftUI

public enum IslAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
    public var reason: String? { if case .unavailable(let r) = self { r } else { nil } }
}

public struct IslSectionDescriptor: Equatable, Identifiable, Sendable {
    public var id: IslSectionID
    public var title: String
    public var symbol: String
    public var summary: String
    public var defaultOrder: Int
    public var defaultHidden: Bool
    public var module: ModuleID?

    public init(id: IslSectionID, title: String, symbol: String, summary: String = "", defaultOrder: Int, defaultHidden: Bool = false, module: ModuleID? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.defaultOrder = defaultOrder
        self.defaultHidden = defaultHidden
        self.module = module
    }
}

public enum IslSectionIntent: Equatable, Sendable {
    case swipeNext
    case swipePrevious
}

public struct IslExpandContext {
    public var size: CGSize
    public var topInset: CGFloat
    public var preset: IslSizePreset
    public var closeIsland: () -> Void
    public var openSettings: () -> Void

    public init(size: CGSize, topInset: CGFloat, preset: IslSizePreset, closeIsland: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.size = size
        self.topInset = topInset
        self.preset = preset
        self.closeIsland = closeIsland
        self.openSettings = openSettings
    }
}

@MainActor
public protocol IslSection: AnyObject {
    var descriptor: IslSectionDescriptor { get }
    var availability: IslAvailability { get }
    var activities: [IslActivity] { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    func didAppear()
    func didDisappear()
    func compactLeading(_ activity: IslActivity) -> AnyView?
    func compactTrailing(_ activity: IslActivity) -> AnyView?
    func peekView(_ activity: IslActivity) -> AnyView?
    func expandedView(_ context: IslExpandContext) -> AnyView
    func handle(_ intent: IslSectionIntent) -> Bool
    var settingsView: AnyView? { get }
}

public extension IslSection {
    var id: IslSectionID { descriptor.id }
    var availability: IslAvailability { .available }
    var activities: [IslActivity] { [] }
    func start() {}
    func stop() {}
    func didAppear() {}
    func didDisappear() {}
    func compactLeading(_ activity: IslActivity) -> AnyView? { nil }
    func compactTrailing(_ activity: IslActivity) -> AnyView? { nil }
    func peekView(_ activity: IslActivity) -> AnyView? { nil }
    func handle(_ intent: IslSectionIntent) -> Bool { false }
    var settingsView: AnyView? { nil }
}

public struct IslLayout: Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>

    public init(order: [String] = [], hidden: Set<String> = []) {
        self.order = order
        self.hidden = hidden
    }

    public static func defaults(for known: [IslSectionDescriptor]) -> IslLayout {
        IslLayout(order: known.sorted { $0.defaultOrder < $1.defaultOrder }.map(\.id.rawValue), hidden: Set(known.filter(\.defaultHidden).map(\.id.rawValue)))
    }

    public func resolved(known: [IslSectionDescriptor]) -> [IslSectionDescriptor] {
        var byID: [String: IslSectionDescriptor] = [:]
        for d in known where byID[d.id.rawValue] == nil { byID[d.id.rawValue] = d }
        var seen = Set<String>()
        var out: [IslSectionDescriptor] = []
        for id in order {
            if let d = byID[id], seen.insert(id).inserted { out.append(d) }
        }
        let fresh = known.filter { !seen.contains($0.id.rawValue) && byID[$0.id.rawValue] == $0 }.sorted { $0.defaultOrder < $1.defaultOrder }
        var inserted = Set<String>()
        for d in fresh where inserted.insert(d.id.rawValue).inserted {
            let at = out.lastIndex { $0.defaultOrder <= d.defaultOrder }.map { $0 + 1 } ?? 0
            out.insert(d, at: at)
        }
        return out
    }

    public func visible(known: [IslSectionDescriptor]) -> [IslSectionDescriptor] {
        resolved(known: known).filter { !hidden.contains($0.id.rawValue) }
    }

    public mutating func normalize(known: [IslSectionDescriptor]) {
        order = resolved(known: known).map(\.id.rawValue)
        let ids = Set(order)
        hidden = hidden.filter { ids.contains($0) }
    }

    public mutating func move(_ id: String, before target: String, known: [IslSectionDescriptor]) {
        normalize(known: known)
        guard id != target, let from = order.firstIndex(of: id), order.contains(target) else { return }
        order.remove(at: from)
        let to = order.firstIndex(of: target) ?? order.count
        order.insert(id, at: to)
    }

    public mutating func move(_ id: String, toIndex index: Int, known: [IslSectionDescriptor]) {
        normalize(known: known)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(index, 0), order.count))
    }

    public mutating func nudge(_ id: String, by delta: Int, known: [IslSectionDescriptor]) {
        normalize(known: known)
        guard let from = order.firstIndex(of: id) else { return }
        move(id, toIndex: min(max(from + delta, 0), order.count - 1), known: known)
    }

    public mutating func setHidden(_ id: String, _ on: Bool) {
        if on { hidden.insert(id) } else { hidden.remove(id) }
    }
}

public final class IslLayoutStore {
    private let a: KVAccess
    static let orderKey = "notch.order"
    static let hiddenKey = "notch.hidden"
    static let lastKey = "notch.lastSection"

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load(known: [IslSectionDescriptor]) -> IslLayout {
        let defaults = IslLayout.defaults(for: known)
        var l = IslLayout(order: Self.clean(a.strings(Self.orderKey) ?? []), hidden: defaults.hidden)
        if let h = a.strings(Self.hiddenKey) { l.hidden = Set(Self.clean(h)) }
        l.normalize(known: known)
        return l
    }

    public func save(_ layout: IslLayout, known: [IslSectionDescriptor]) {
        var l = layout
        l.normalize(known: known)
        let d = IslLayout.defaults(for: known)
        if l.order == d.order { a.kv.removeObject(forKey: Self.orderKey) } else { a.kv.set(l.order, forKey: Self.orderKey) }
        if l.hidden == d.hidden { a.kv.removeObject(forKey: Self.hiddenKey) } else { a.kv.set(l.hidden.sorted(), forKey: Self.hiddenKey) }
    }

    public func loadLast() -> IslSectionID? { a.string(Self.lastKey).map { IslSectionID($0) } }

    public func saveLast(_ id: IslSectionID?) {
        if let id { a.kv.set(id.rawValue, forKey: Self.lastKey) } else { a.kv.removeObject(forKey: Self.lastKey) }
    }

    static func clean(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0).inserted }
    }
}

public enum IslNavigator {
    public static func next(after current: IslSectionID?, in ids: [IslSectionID], wrap: Bool = true) -> IslSectionID? {
        step(current, ids, +1, wrap)
    }

    public static func previous(before current: IslSectionID?, in ids: [IslSectionID], wrap: Bool = true) -> IslSectionID? {
        step(current, ids, -1, wrap)
    }

    private static func step(_ current: IslSectionID?, _ ids: [IslSectionID], _ d: Int, _ wrap: Bool) -> IslSectionID? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return d > 0 ? ids.first : ids.last }
        let j = i + d
        if ids.indices.contains(j) { return ids[j] }
        guard wrap, ids.count > 1 else { return ids[i] }
        return d > 0 ? ids.first : ids.last
    }

    public static func start(choice: IslStartChoice, last: IslSectionID?, visible ids: [IslSectionID], activeSection: IslSectionID?, dropTarget: IslSectionID? = nil) -> IslSectionID? {
        guard !ids.isEmpty else { return nil }
        if let d = dropTarget, ids.contains(d) { return d }
        switch choice {
        case .fixed(let id):
            let want = IslSectionID(id)
            if ids.contains(want) { return want }
        case .auto:
            if let a = activeSection, ids.contains(a) { return a }
        case .last:
            break
        }
        if let l = last, ids.contains(l) { return l }
        return ids.first
    }

    public static func settle(current: IslSectionID?, visible ids: [IslSectionID]) -> IslSectionID? {
        if let c = current, ids.contains(c) { return c }
        return ids.first
    }
}

@MainActor
public final class IslSectionRegistry {
    public private(set) var sections: [IslSection] = []

    public init() {}

    public func register(_ s: IslSection) {
        if let i = sections.firstIndex(where: { $0.descriptor.id == s.descriptor.id }) { sections[i] = s } else { sections.append(s) }
    }

    public func unregister(_ id: IslSectionID) {
        sections.removeAll { $0.descriptor.id == id }
    }

    public func section(_ id: IslSectionID) -> IslSection? { sections.first { $0.descriptor.id == id } }

    public var descriptors: [IslSectionDescriptor] { sections.map(\.descriptor) }

    public func ordered(_ layout: IslLayout) -> [IslSection] {
        layout.visible(known: descriptors).compactMap { section($0.id) }
    }

    public func available(_ layout: IslLayout) -> [IslSection] {
        ordered(layout).filter { $0.availability.isAvailable }
    }

    public func activities(muted: Set<String>) -> [IslActivity] {
        sections.filter { $0.availability.isAvailable && !muted.contains($0.descriptor.id.rawValue) }.flatMap(\.activities)
    }
}

public struct IslAccessory: Identifiable {
    public enum Slot: String, Sendable { case musicBelow, musicSide, headerTrailing, wingLeading, wingTrailing }

    public var id: String
    public var slot: Slot
    public var order: Int
    public var isActive: () -> Bool
    public var view: () -> AnyView

    public init(id: String, slot: Slot, order: Int = 0, isActive: @escaping () -> Bool = { true }, view: @escaping () -> AnyView) {
        self.id = id
        self.slot = slot
        self.order = order
        self.isActive = isActive
        self.view = view
    }
}

@MainActor
public final class IslAccessoryRegistry {
    public private(set) var items: [IslAccessory] = []

    public init() {}

    public func register(_ a: IslAccessory) {
        items.removeAll { $0.id == a.id }
        items.append(a)
    }

    public func unregister(_ id: String) { items.removeAll { $0.id == id } }

    public func active(in slot: IslAccessory.Slot) -> [IslAccessory] {
        items.filter { $0.slot == slot && $0.isActive() }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}
