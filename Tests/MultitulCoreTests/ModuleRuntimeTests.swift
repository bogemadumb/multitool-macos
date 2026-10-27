import Testing
import Foundation
import SwiftUI
@testable import MultitulCore

@MainActor
final class FakeModule: Module {
    let info: ModuleInfo
    var started = 0
    var stopped = 0
    init(_ id: ModuleID) { info = id.info }
    func start() { started += 1 }
    func stop() { stopped += 1 }
    var settingsView: AnyView { AnyView(EmptyView()) }
}

@MainActor
final class Spawner {
    var made: [ModuleID: [FakeModule]] = [:]
    func make(_ id: ModuleID) -> Module {
        let m = FakeModule(id)
        made[id, default: []].append(m)
        return m
    }
}

private func freshDefaults() -> InMemoryKeyValueStore {
    InMemoryKeyValueStore()
}

@MainActor
@Suite struct ModuleRuntimeTests {
    @Test func startEnabledInstantiatesOnlyEnabled() {
        let d = freshDefaults()
        d.set(true, forKey: ModuleID.demoHotkey.enabledKey)
        d.set(false, forKey: ModuleID.demoClock.enabledKey)
        let sp = Spawner()
        let rt = ModuleRuntime(defaults: d, factory: sp.make)
        rt.startEnabled()
        #expect(sp.made[.demoHotkey]?.count == 1)
        #expect(sp.made[.demoHotkey]?.first?.started == 1)
        #expect(sp.made[.demoClock] == nil)
        #expect(sp.made[.demoAccessibility] == nil)
        #expect(rt.activeModules.map(\.id) == [.demoHotkey])
    }

    @Test func enableDisableLiveWithoutRestart() {
        let d = freshDefaults()
        let sp = Spawner()
        let rt = ModuleRuntime(defaults: d, factory: sp.make)
        rt.startEnabled()
        #expect(!rt.isRunning(.demoAccessibility))
        rt.setEnabled(.demoAccessibility, true)
        #expect(rt.isRunning(.demoAccessibility))
        #expect(sp.made[.demoAccessibility]?.first?.started == 1)
        rt.setEnabled(.demoAccessibility, false)
        #expect(!rt.isRunning(.demoAccessibility))
        #expect(sp.made[.demoAccessibility]?.first?.stopped == 1)
        #expect(d.bool(forKey: "module.demoAccessibility.enabled") == false)
    }

    @Test func repeatedEnableDoesNotDoubleStart() {
        let sp = Spawner()
        let rt = ModuleRuntime(defaults: freshDefaults(), factory: sp.make)
        rt.setEnabled(.demoHotkey, true)
        rt.setEnabled(.demoHotkey, true)
        #expect(sp.made[.demoHotkey]?.count == 1)
        #expect(sp.made[.demoHotkey]?.first?.started == 1)
        rt.setEnabled(.demoHotkey, false)
        rt.setEnabled(.demoHotkey, false)
        #expect(sp.made[.demoHotkey]?.first?.stopped == 1)
    }

    @Test func reenableCreatesFreshInstance() {
        let sp = Spawner()
        let rt = ModuleRuntime(defaults: freshDefaults(), factory: sp.make)
        rt.setEnabled(.demoClock, true)
        rt.setEnabled(.demoClock, false)
        rt.setEnabled(.demoClock, true)
        #expect(sp.made[.demoClock]?.count == 2)
    }

    @Test func stateSurvivesNewRuntime() {
        let d = freshDefaults()
        let sp = Spawner()
        let a = ModuleRuntime(defaults: d, factory: sp.make)
        a.setEnabled(.demoAccessibility, true)
        a.stopAll()
        let sp2 = Spawner()
        let b = ModuleRuntime(defaults: d, factory: sp2.make)
        b.startEnabled()
        #expect(sp2.made[.demoAccessibility]?.count == 1)
    }

    @Test func defaultEnabledFollowsModuleInfo() {
        let rt = ModuleRuntime(defaults: freshDefaults(), factory: Spawner().make)
        #expect(rt.isEnabled(.demoClock) == ModuleID.demoClock.info.enabledByDefault)
        #expect(rt.isEnabled(.demoHotkey) == false)
    }

    @Test func groupFilterReturnsOnlyActiveInGroup() {
        let sp = Spawner()
        let rt = ModuleRuntime(defaults: freshDefaults(), factory: sp.make)
        rt.setEnabled(.demoClock, true)
        #expect(rt.modules(in: .tools).count == 1)
        #expect(rt.modules(in: .input).isEmpty)
        rt.setEnabled(.demoClock, false)
        #expect(rt.modules(in: .tools).isEmpty)
    }
}
