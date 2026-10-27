import Foundation
import SwiftUI

@MainActor
public final class ModuleRuntime: ObservableObject {
    public typealias Factory = (ModuleID) -> Module

    private let defaults: KeyValueStoring
    private let factory: Factory
    private let ids: [ModuleID]
    private var instances: [ModuleID: Module] = [:]

    @Published public private(set) var revision = 0

    public init(defaults: KeyValueStoring = UserDefaults.standard, ids: [ModuleID] = ModuleID.allCases, factory: @escaping Factory) {
        self.defaults = defaults
        self.ids = ids
        self.factory = factory
    }

    public func isEnabled(_ id: ModuleID) -> Bool {
        (defaults.object(forKey: id.enabledKey) as? Bool) ?? id.info.enabledByDefault
    }

    public func isRunning(_ id: ModuleID) -> Bool { instances[id] != nil }

    public var activeModules: [Module] { ids.compactMap { instances[$0] } }

    public var enabledIDs: [ModuleID] { ids.filter { isEnabled($0) } }

    public func modules(in group: ModuleGroup) -> [Module] {
        activeModules.filter { $0.info.group == group }
    }

    public func startEnabled() {
        for id in ids where isEnabled(id) { launch(id) }
        revision += 1
    }

    public func setEnabled(_ id: ModuleID, _ on: Bool) {
        defaults.set(on, forKey: id.enabledKey)
        if on { launch(id) } else { terminate(id) }
        revision += 1
        Log.write("module \(id.rawValue) \(on ? "enabled" : "disabled") running=\(isRunning(id))")
    }

    public func stopAll() {
        for id in ids { terminate(id) }
        revision += 1
    }

    private func launch(_ id: ModuleID) {
        guard instances[id] == nil else { return }
        let m = factory(id)
        instances[id] = m
        m.start()
    }

    private func terminate(_ id: ModuleID) {
        guard let m = instances.removeValue(forKey: id) else { return }
        m.stop()
    }
}
