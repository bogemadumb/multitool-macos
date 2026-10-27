import Testing
import Foundation
@testable import MultitulCore

private final class BTFakePower: BluetoothPowering {
    var available = true
    var on: Bool? = true
    var setSucceeds = true
    var setCalls: [Bool] = []

    var isAvailable: Bool { available }
    func isOn() -> Bool? { on }
    func setOn(_ value: Bool) -> Bool {
        setCalls.append(value)
        if setSucceeds { on = value }
        return setSucceeds
    }
}

private final class BTFakeStore: BluetoothPendingStoring {
    var restorePending = false
}

private func make(_ p: BTFakePower = BTFakePower(), restore: Bool = true) -> (BluetoothSleepLogic, BTFakePower, BTFakeStore) {
    var s = BluetoothSleepSettings()
    s.restoreOnWake = restore
    let store = BTFakeStore()
    return (BluetoothSleepLogic(power: p, store: store, settings: s), p, store)
}

@Suite struct BluetoothSleepTests {
    @Test func sleepTurnsOffAndRemembers() {
        let (l, p, s) = make()
        #expect(l.willSleep() == .turnedOff)
        #expect(p.on == false)
        #expect(s.restorePending)
    }

    @Test func alreadyOffIsLeftAlone() {
        let p = BTFakePower()
        p.on = false
        let (l, _, s) = make(p)
        #expect(l.willSleep() == .skipped("Bluetooth уже выключен"))
        #expect(p.setCalls.isEmpty)
        #expect(!s.restorePending)
        #expect(l.restore(attempt: 0) == .notOwed)
        #expect(p.on == false)
    }

    @Test func wakeRestoresOnlyWhatWeTurnedOff() {
        let (l, p, s) = make()
        _ = l.willSleep()
        #expect(l.restore(attempt: 0) == .restored)
        #expect(p.on == true)
        #expect(!s.restorePending)
        #expect(l.restore(attempt: 0) == .notOwed)
    }

    @Test func restoreDisabledDoesNotRemember() {
        let (l, p, s) = make(restore: false)
        #expect(l.willSleep() == .turnedOff)
        #expect(!s.restorePending)
        #expect(l.restore(attempt: 0) == .notOwed)
        #expect(p.on == false)
    }

    @Test func switchingRestoreOffClearsPendingDebt() {
        let (l, p, s) = make()
        _ = l.willSleep()
        l.settings.restoreOnWake = false
        #expect(l.restore(attempt: 0) == .notOwed)
        #expect(!s.restorePending)
        #expect(p.on == false)
    }

    @Test func failedTurnOffForgetsDebt() {
        let p = BTFakePower()
        p.setSucceeds = false
        let (l, _, s) = make(p)
        #expect(l.willSleep() == .failedToTurnOff)
        #expect(!s.restorePending)
    }

    @Test func userTurnedItOnMeanwhile() {
        let (l, p, s) = make()
        _ = l.willSleep()
        p.on = true
        #expect(l.restore(attempt: 0) == .alreadyOn)
        #expect(p.setCalls == [false])
        #expect(!s.restorePending)
    }

    @Test func failedRestoreRetriesThenGivesUpButKeepsDebt() {
        let (l, p, s) = make()
        _ = l.willSleep()
        p.setSucceeds = false
        #expect(l.restore(attempt: 0) == .retry(after: 1))
        #expect(l.restore(attempt: 1) == .retry(after: 3))
        #expect(l.restore(attempt: 2) == .retry(after: 8))
        #expect(l.restore(attempt: 3) == .gaveUp)
        #expect(s.restorePending)
        p.setSucceeds = true
        #expect(l.restore(attempt: 0) == .restored)
    }

    @Test func unavailableApiDoesNothing() {
        let p = BTFakePower()
        p.available = false
        let (l, _, s) = make(p)
        #expect(l.willSleep() == .skipped("Bluetooth API недоступен"))
        #expect(!s.restorePending)
        #expect(p.setCalls.isEmpty)
    }

    @Test func unreadableStateDoesNothing() {
        let p = BTFakePower()
        p.on = nil
        let (l, _, _) = make(p)
        if case .skipped = l.willSleep() {} else { Issue.record("expected skipped") }
        #expect(p.setCalls.isEmpty)
    }

    @Test func debtSurvivesRestartAndIsPaidAtStart() {
        let (l, p, s) = make()
        _ = l.willSleep()
        let again = BluetoothSleepLogic(power: p, store: s)
        #expect(again.owesRestore)
        #expect(again.restore(attempt: 0) == .restored)
    }

    @Test func settingsStoreRoundtrip() {
        let suite = "multitul-bt-\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let store = BluetoothDefaultsStore(defaults: d)
        #expect(store.loadSettings() == BluetoothSleepSettings())
        var s = BluetoothSleepSettings()
        s.restoreOnWake = false
        s.restoreDelaySeconds = 5
        s.notify = true
        store.save(s)
        #expect(store.loadSettings() == s)
        store.restorePending = true
        #expect(BluetoothDefaultsStore(defaults: d).restorePending)
        store.restorePending = false
        store.save(BluetoothSleepSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("bluetoothSleep.") }.isEmpty)
    }
}
