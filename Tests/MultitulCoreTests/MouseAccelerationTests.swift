import Testing
import Foundation
@testable import MultitulCore

@Suite struct MouseAccelerationTests {
    private func setup(_ values: [UInt64: Int64] = [1: 45056, 2: 30000]) -> (MouseAccelerationEngine, InpAccelDriver, InpJournal) {
        let d = InpAccelDriver()
        d.devices = values.keys.sorted().map { PointerDevice(registryID: $0, key: AccelCurve.mouseKey, name: "Мышь \($0)") }
        d.values = values
        let j = InpJournal()
        return (MouseAccelerationEngine(driver: d, store: j), d, j)
    }

    @Test func applyWritesFlatAndJournalsOriginals() {
        let (e, d, j) = setup()
        let r = e.apply()
        #expect(r.applied == 2 && r.failed == 0)
        #expect(d.values == [1: -1, 2: -1])
        #expect(Set(j.entries.map(\.original)) == [45056, 30000])
    }

    @Test func restoreBringsOriginalsBackAndClearsJournal() {
        let (e, d, j) = setup()
        e.apply()
        #expect(e.restore() == 2)
        #expect(d.values == [1: 45056, 2: 30000] && j.entries.isEmpty)
    }

    @Test func secondApplyKeepsTheFirstOriginal() {
        let (e, d, j) = setup([1: 45056])
        e.apply()
        d.values[1] = 45056
        e.apply()
        #expect(j.entries.count == 1 && j.entries[0].original == 45056)
        d.values[1] = -1
        let again = e.apply()
        #expect(again.alreadyFlat == 1 && again.applied == 0)
        e.restore()
        #expect(d.values[1] == 45056)
    }

    @Test func deviceThatWasAlreadyFlatIsNotJournaled() {
        let (e, d, j) = setup([5: -1])
        let r = e.apply()
        #expect(r.alreadyFlat == 1 && j.entries.isEmpty && d.writes.isEmpty)
        #expect(e.restore() == 0 && d.values[5] == -1)
    }

    @Test func unreadableDeviceIsNotTouched() {
        let (e, d, j) = setup([1: 100])
        d.values.removeValue(forKey: 1)
        let r = e.apply()
        #expect(r.failed == 1 && d.writes.isEmpty && j.entries.isEmpty)
    }

    @Test func failedWriteIsCountedButOtherDevicesProceed() {
        let (e, d, _) = setup([1: 100, 2: 200])
        d.failWrites = [1]
        let r = e.apply()
        #expect(r.applied == 1 && r.failed == 1 && d.values[2] == -1)
    }

    @Test func crashRecoveryRestoresFromTheJournalOfAPreviousRun() {
        let (e, d, j) = setup()
        e.apply()
        let reborn = MouseAccelerationEngine(driver: d, store: j)
        #expect(reborn.journal.count == 2)
        #expect(reborn.recoverPending() == 2)
        #expect(d.values == [1: 45056, 2: 30000] && j.entries.isEmpty)
    }

    @Test func recoverWithEmptyJournalDoesNothing() {
        let (e, d, _) = setup()
        #expect(e.recoverPending() == 0 && d.writes.isEmpty)
    }

    @Test func unpluggedDevicesAreDroppedFromTheJournalOnRestore() {
        let (e, d, j) = setup([1: 100, 2: 200])
        e.apply()
        d.devices.removeAll { $0.registryID == 2 }
        #expect(e.restore() == 1)
        #expect(j.entries.isEmpty && d.values[1] == 100)
    }

    @Test func failedRestoreStaysInTheJournalForNextTime() {
        let (e, d, j) = setup([1: 100])
        e.apply()
        d.failWrites = [1]
        #expect(e.restore() == 0 && j.entries.count == 1)
        d.failWrites = []
        #expect(e.restore() == 1 && j.entries.isEmpty)
    }

    @Test func hotpluggedMouseIsPickedUpOnReapply() {
        let (e, d, _) = setup([1: 100])
        e.apply()
        d.devices.append(PointerDevice(registryID: 9, key: AccelCurve.mouseKey, name: "Новая"))
        d.values[9] = 777
        let r = e.apply()
        #expect(r.applied == 1 && r.alreadyFlat == 1 && d.values[9] == -1)
        e.restore()
        #expect(d.values == [1: 100, 9: 777])
    }

    @Test func writableKeysAreMouseOnly() {
        #expect(AccelCurve.writableKey(forType: nil) == AccelCurve.mouseKey)
        #expect(AccelCurve.writableKey(forType: "HIDMouseAcceleration") == AccelCurve.mouseKey)
        #expect(AccelCurve.writableKey(forType: "HIDPointerAcceleration") == AccelCurve.pointerKey)
        #expect(AccelCurve.writableKey(forType: AccelCurve.trackpadType) == nil)
        #expect(AccelCurve.writableKey(forType: "Whatever") == nil)
        #expect(AccelCurve.isFlat(-1) && !AccelCurve.isFlat(0) && !AccelCurve.isFlat(nil))
    }

    @Test func journalSurvivesThroughKeyValueStore() {
        let suite = "inp.accel.\(UUID().uuidString)"
        let defaults = InMemoryKeyValueStore()
        let store = DefaultsAccelJournal(defaults: defaults)
        #expect(store.load().isEmpty)
        let entries = [AccelJournalEntry(registryID: 4_294_967_300, key: AccelCurve.mouseKey, original: -65536)]
        store.save(entries)
        #expect(DefaultsAccelJournal(defaults: defaults).load() == entries)
        store.save([])
        #expect(store.load().isEmpty)
    }

    @Test func reapplyScheduleWalksItsDelaysAndIgnoresStaleTokens() {
        var sc = AccelReapplySchedule()
        let t1 = sc.restart()
        #expect(sc.next(for: t1) == 0)
        #expect(sc.next(for: t1) == 0.3)
        let t2 = sc.restart()
        #expect(sc.next(for: t1) == nil)
        for d in AccelReapplySchedule.delays { #expect(sc.next(for: t2) == d) }
        #expect(sc.next(for: t2) == nil)
        let t3 = sc.restart()
        sc.cancel()
        #expect(sc.next(for: t3) == nil)
    }
}
