import Testing
import Foundation
import Carbon.HIToolbox
import CoreGraphics
@testable import MultitulCore

final class FakeHotkeyBackend: HotkeyBackend {
    var onFire: ((UInt32) -> Void)?
    var live: [UInt32: KeyCombo] = [:]
    var failing: Set<KeyCombo> = []
    func register(_ combo: KeyCombo, token: UInt32) -> OSStatus {
        if failing.contains(combo) { return OSStatus(eventHotKeyExistsErr) }
        live[token] = combo
        return noErr
    }
    func unregister(token: UInt32) { live[token] = nil }
}

private func fresh() -> InMemoryKeyValueStore { InMemoryKeyValueStore() }

private let cmdOptM = KeyCombo(keyCode: 46, modifiers: KeyCombo.cmd | KeyCombo.opt)
private let ctrlOptCmdJ = KeyCombo(keyCode: 38, modifiers: KeyCombo.ctrl | KeyCombo.opt | KeyCombo.cmd)
private let a = HotkeySpec(id: "mod.a", title: "A", defaultCombo: cmdOptM)
private let b = HotkeySpec(id: "mod.b", title: "B", defaultCombo: cmdOptM)
private let c = HotkeySpec(id: "mod.c", title: "C", defaultCombo: ctrlOptCmdJ)

@MainActor
@Suite struct HotkeyConflictTests {
    @Test func secondRegistrationWithSameComboConflicts() {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        #expect(hm.register(a, owner: "a") {} == .active)
        #expect(hm.register(b, owner: "b") {} == .conflict(with: "mod.a"))
        #expect(be.live.count == 1)
    }

    @Test func differentCombosCoexist() {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        #expect(hm.register(a, owner: "a") {} == .active)
        #expect(hm.register(c, owner: "c") {} == .active)
        #expect(be.live.count == 2)
    }

    @Test func unregisteringHolderActivatesPending() {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        hm.register(a, owner: "a") {}
        hm.register(b, owner: "b") {}
        hm.unregister("mod.a")
        #expect(hm.state(of: "mod.b") == .active)
        #expect(be.live.values.contains(cmdOptM))
        #expect(be.live.count == 1)
    }

    @Test func setComboRejectsTakenCombo() {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        hm.register(a, owner: "a") {}
        hm.register(c, owner: "c") {}
        #expect(hm.setCombo(c, to: cmdOptM) == .conflict(with: "mod.a"))
        #expect(hm.combo(for: c) == ctrlOptCmdJ)
        #expect(be.live.values.contains(ctrlOptCmdJ))
    }

    @Test func setComboPersistsAndRebinds() {
        let be = FakeHotkeyBackend()
        let d = fresh()
        let hm = HotkeyManager(backend: be, defaults: d)
        hm.register(c, owner: "c") {}
        let nc = KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd | KeyCombo.shift)
        #expect(hm.setCombo(c, to: nc) == .applied)
        #expect(Set(be.live.values) == [nc])
        let hm2 = HotkeyManager(backend: FakeHotkeyBackend(), defaults: d)
        #expect(hm2.combo(for: c) == nc)
        #expect(hm.resetCombo(c) == .applied)
        #expect(Set(be.live.values) == [ctrlOptCmdJ])
    }

    @Test func setComboForDisabledModuleStillChecksActiveHolders() {
        let hm = HotkeyManager(backend: FakeHotkeyBackend(), defaults: fresh())
        hm.register(a, owner: "a") {}
        #expect(hm.setCombo(c, to: cmdOptM) == .conflict(with: "mod.a"))
    }

    @Test func systemRefusalIsReportedAsFailed() {
        let be = FakeHotkeyBackend()
        be.failing = [cmdOptM]
        let hm = HotkeyManager(backend: be, defaults: fresh())
        #expect(hm.register(a, owner: "a") {} == .failed(OSStatus(eventHotKeyExistsErr)))
    }

    @Test func firingCallsOnlyActiveHandler() async {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        var hitA = 0, hitB = 0
        hm.register(a, owner: "a") { hitA += 1 }
        hm.register(b, owner: "b") { hitB += 1 }
        let token = be.live.first { $0.value == cmdOptM }!.key
        be.onFire?(token)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(hitA == 1 && hitB == 0)
    }

    @Test func unregisterAllByOwner() {
        let be = FakeHotkeyBackend()
        let hm = HotkeyManager(backend: be, defaults: fresh())
        hm.register(a, owner: "x") {}
        hm.register(c, owner: "x") {}
        hm.unregisterAll(owner: "x")
        #expect(be.live.isEmpty)
    }
}

final class FakeTapBackend: EventTapBackend {
    var onEvent: ((CGEventType, CGEvent) -> EventTapAction)?
    var onDisabled: ((CGEventType) -> Void)?
    var starts: [CGEventMask] = []
    var stops = 0
    func start(mask: CGEventMask) -> Bool { starts.append(mask); return true }
    func stop() { stops += 1 }
}

@Suite struct EventTapHubTests {
    @Test func notStartedWithoutSubscribers() {
        let be = FakeTapBackend()
        let hub = EventTapHub(backend: be)
        #expect(!hub.isRunning && be.starts.isEmpty)
    }

    @Test func startsOnFirstSubscriberStopsOnLast() {
        let be = FakeTapBackend()
        let hub = EventTapHub(backend: be)
        let t1 = hub.subscribe(types: [.keyDown]) { _, _ in .pass }
        #expect(hub.isRunning && be.starts.count == 1)
        let t2 = hub.subscribe(types: [.scrollWheel]) { _, _ in .pass }
        #expect(be.starts.count == 2 && be.stops == 1)
        #expect(be.starts[1] == EventTapHub.mask([.keyDown, .scrollWheel]))
        hub.unsubscribe(t1)
        #expect(hub.isRunning)
        hub.unsubscribe(t2)
        #expect(!hub.isRunning && hub.subscriberCount == 0)
    }
}
