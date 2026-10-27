import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func fresh() -> InMemoryKeyValueStore { InMemoryKeyValueStore() }

private final class BrightFakeBackend: BrightnessBackend, PowerBackend, ContrastBackend {
    let method: BrightnessMethod
    var probeOK = true
    var readValue: Double?
    var writes: [Double] = []
    var writeOK = true
    var released = 0
    var powerCalls: [Bool] = []
    var contrastWrites: [Double] = []

    init(_ method: BrightnessMethod, read: Double? = nil, probe: Bool = true) {
        self.method = method
        readValue = read
        probeOK = probe
    }

    func probe() -> Bool { probeOK }
    func read() -> Double? { readValue }
    func write(_ value: Double) -> Bool { writes.append(value); return writeOK }
    func release() { released += 1 }
    func setPower(_ on: Bool) -> Bool { powerCalls.append(on); return true }
    func readContrast() -> Double? { 0.4 }
    func writeContrast(_ value: Double) -> Bool { contrastWrites.append(value); return true }
}

private final class BrightFakeFactory: BrightnessBackendFactory {
    var made: [UInt32: [BrightFakeBackend]] = [:]
    var build: (DisplaySnapshot, Bool) -> [BrightFakeBackend] = { _, _ in [] }
    var prepared = 0

    func prepare(_ displays: [DisplaySnapshot]) { prepared += 1 }

    func candidates(for display: DisplaySnapshot, forceSoftware: Bool, softwareFloor: Double) -> [BrightnessBackend] {
        let list = build(display, forceSoftware)
        made[display.cgID, default: []].append(contentsOf: list)
        return list
    }
}

private func builtinSnap() -> DisplaySnapshot {
    DisplaySnapshot(cgID: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 0, isBuiltin: true), isMain: true, frame: CGRect(x: 0, y: 0, width: 1000, height: 700), name: "Built-in")
}

private func extSnap(_ id: UInt32 = 2, serial: UInt32 = 77) -> DisplaySnapshot {
    DisplaySnapshot(cgID: id, identity: DisplayIdentity(vendor: 4268, model: 9, serial: serial), frame: CGRect(x: 1000, y: 0, width: 2000, height: 1000), name: "Dell")
}

private let t0 = Date(timeIntervalSince1970: 5000)

private func makeEngine(_ factory: BrightFakeFactory, defaults: InMemoryKeyValueStore = fresh()) -> (BrightnessEngine, BrightnessStore) {
    let store = BrightnessStore(defaults: defaults)
    return (BrightnessEngine(store: store, factory: factory), store)
}

@Suite struct BrightnessModelTests {
    @Test func stableIDFormat() {
        #expect(DisplayIdentity(vendor: 0x10AC, model: 0xA1B2, serial: 0xDEADBEEF).baseID == "10ac-a1b2-deadbeef")
        #expect(DisplayIdentity(vendor: 1, model: 2, serial: 3, isBuiltin: true).baseID == "builtin")
    }

    @Test func duplicateIdentitiesGetSuffixes() {
        let a = DisplayIdentity(vendor: 1, model: 2, serial: 0)
        let ids = BrightnessIDs.assign([a, DisplayIdentity(vendor: 9, model: 9, serial: 9), a, a])
        #expect(ids == ["0001-0002-00000000", "0009-0009-00000009", "0001-0002-00000000-2", "0001-0002-00000000-3"])
    }

    @Test func idsAreAscii() {
        let ids = BrightnessIDs.assign([extSnap().identity, builtinSnap().identity])
        #expect(ids.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test func edidVendorCodes() {
        #expect(EdidVendor.code("DEL") == 4268)
        #expect(EdidVendor.code("APP") == 1552)
        #expect(EdidVendor.code("del") == 4268)
        #expect(EdidVendor.code("DE") == nil)
        #expect(EdidVendor.code("D1L") == nil)
    }

    @Test func serviceMatchByProductAndSerial() {
        let d1 = DisplayIdentity(vendor: 4268, model: 9, serial: 100)
        let d2 = DisplayIdentity(vendor: 4268, model: 9, serial: 200)
        let s = [AvServiceInfo(vendor: 4268, product: 9, serial: 200), AvServiceInfo(vendor: 4268, product: 9, serial: 100)]
        #expect(AvServiceMatcher.assign(displays: [d1, d2], services: s) == [0: 1, 1: 0])
    }

    @Test func loneDisplayPairsWithLoneUnknownService() {
        let d = DisplayIdentity(vendor: 4268, model: 9, serial: 0)
        #expect(AvServiceMatcher.assign(displays: [d], services: [AvServiceInfo(vendor: 0, product: 0, serial: 0)]) == [0: 0])
    }

    @Test func mismatchedServiceIsNotAssignedWhenAmbiguous() {
        let d1 = DisplayIdentity(vendor: 1, model: 1, serial: 1)
        let d2 = DisplayIdentity(vendor: 2, model: 2, serial: 2)
        let s = [AvServiceInfo(vendor: 0, product: 0, serial: 0), AvServiceInfo(vendor: 0, product: 0, serial: 0)]
        #expect(AvServiceMatcher.assign(displays: [d1, d2], services: s).isEmpty)
    }
}

@Suite struct BrightnessSettingsTests {
    @Test func defaults() {
        let s = BrightnessSettings()
        #expect(s.followCursor && s.showOSD && s.keyboardKeys)
        #expect(!s.interceptKeys && !s.fineAlways)
        #expect(s.softwareFloor == 0.08)
    }

    @Test func roundTrip() {
        let d = fresh()
        let store = BrightnessStore(defaults: d)
        var s = BrightnessSettings()
        s.followCursor = false
        s.interceptKeys = true
        s.fineAlways = true
        s.showOSD = false
        s.keyboardKeys = false
        s.softwareFloorPercent = 14
        store.saveSettings(s)
        #expect(BrightnessStore(defaults: d).loadSettings() == s)
    }

    @Test func defaultsAreNotStored() {
        let d = fresh()
        let store = BrightnessStore(defaults: d)
        var s = BrightnessSettings()
        s.fineAlways = true
        store.saveSettings(s)
        #expect(d.object(forKey: "brightness.fineAlways") != nil)
        store.saveSettings(BrightnessSettings())
        #expect(d.object(forKey: "brightness.fineAlways") == nil)
        #expect(d.object(forKey: "brightness.followCursor") == nil)
    }

    @Test func perDisplayValuesRoundTripAndClamp() {
        let store = BrightnessStore(defaults: fresh())
        #expect(store.value(for: "x") == nil)
        store.setValue(0.42, for: "10ac-0009-0000004d")
        #expect(store.value(for: "10ac-0009-0000004d") == 0.42)
        store.setValue(7, for: "x")
        #expect(store.value(for: "x") == 1)
        store.setContrast(0.3, for: "x")
        #expect(store.contrast(for: "x") == 0.3)
    }

    @Test func forceSoftwareAndForget() {
        let store = BrightnessStore(defaults: fresh())
        store.setForceSoftware(true, for: "a")
        store.setValue(0.5, for: "a")
        #expect(store.forceSoftware(for: "a"))
        store.setForceSoftware(false, for: "a")
        #expect(!store.forceSoftware(for: "a"))
        store.forget(id: "a")
        #expect(store.value(for: "a") == nil)
    }

    @Test func keyboardLastRoundTrip() {
        let store = BrightnessStore(defaults: fresh())
        #expect(store.keyboardLast == nil)
        store.keyboardLast = 0.75
        #expect(store.keyboardLast == 0.75)
        store.keyboardLast = nil
        #expect(store.keyboardLast == nil)
    }

    @Test func keysAndHotkeysAreAsciiAndUnassigned() {
        let d = fresh()
        let store = BrightnessStore(defaults: d)
        var s = BrightnessSettings()
        s.interceptKeys = true
        s.followCursor = false
        store.saveSettings(s)
        store.setValue(0.5, for: "10ac-0009-0000004d")
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("brightness.") }.allSatisfy { $0.allSatisfy(\.isASCII) })
        #expect(BrightnessHotkeys.all.count == 4)
        #expect(BrightnessHotkeys.all.allSatisfy { $0.defaultCombo.isNone && $0.id.allSatisfy(\.isASCII) && $0.id.hasPrefix("brightness.") })
        #expect(Set(BrightnessHotkeys.all.map(\.id)).count == 4)
    }

    @Test func moduleRegistration() {
        let info = ModuleID.brightness.info
        #expect(info.group == .displays)
        #expect(!info.enabledByDefault)
        #expect(info.hotkeys == BrightnessHotkeys.all)
        #expect(!ModuleID.extraBrightness.info.enabledByDefault)
        #expect(ModuleID.extraBrightness.info.group == .displays)
        #expect(ModuleID.brightness.enabledKey == "module.brightness.enabled")
    }
}

@Suite struct BrightnessEngineTests {
    @Test func builtinUsesSystemBackendAndReadsValue() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.builtin, read: 0.6), BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([builtinSnap()], now: t0)
        let row = e.rows[0]
        #expect(row.id == "builtin")
        #expect(row.method == .builtin)
        #expect(row.value == 0.6)
    }

    @Test func fallsBackToSoftwareWhenDdcProbeFails() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.ddc, probe: false), BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap()], now: t0)
        #expect(e.rows[0].method == .software)
    }

    @Test func nothingWorkingMeansUnavailable() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.ddc, probe: false)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap()], now: t0)
        #expect(e.rows[0].method == .unavailable)
        #expect(e.controllable.isEmpty)
        #expect(e.set(id: e.rows[0].id, value: 0.5, now: t0) == nil)
    }

    @Test func writeOnlyDdcFallsBackToSavedValue() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.ddc, read: nil)] }
        let (e, store) = makeEngine(f)
        store.setValue(0.3, for: extSnap().identity.baseID)
        e.reconcile([extSnap()], now: t0)
        #expect(e.rows[0].value == 0.3)
    }

    @Test func forceSoftwareIsPassedToFactory() {
        let f = BrightFakeFactory()
        var seen: [Bool] = []
        f.build = { _, force in seen.append(force); return [BrightFakeBackend(force ? .software : .ddc)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap()], now: t0)
        e.setForceSoftware(id: e.rows[0].id, true)
        #expect(seen == [false, true])
        #expect(e.rows[0].method == .software)
        #expect(e.rows[0].forcedSoftware)
    }

    @Test func firstWriteIsImmediateSecondIsCoalesced() {
        let f = BrightFakeFactory()
        let b = BrightFakeBackend(.ddc, read: 0.5)
        f.build = { _, _ in [b] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap()], now: t0)
        let id = e.rows[0].id
        e.set(id: id, value: 0.7, now: t0)
        e.set(id: id, value: 0.8, now: t0.addingTimeInterval(0.01))
        e.set(id: id, value: 0.9, now: t0.addingTimeInterval(0.02))
        #expect(b.writes == [0.7])
        let wait = e.flush(now: t0.addingTimeInterval(0.03))
        #expect(wait != nil && wait! > 0)
        #expect(e.flush(now: t0.addingTimeInterval(0.5)) == nil)
        #expect(b.writes == [0.7, 0.9])
    }

    @Test func settingTheReadValueDoesNotWrite() {
        let f = BrightFakeFactory()
        let b = BrightFakeBackend(.builtin, read: 0.5)
        f.build = { _, _ in [b] }
        let (e, _) = makeEngine(f)
        e.reconcile([builtinSnap()], now: t0)
        e.set(id: "builtin", value: 0.5, now: t0)
        #expect(b.writes.isEmpty)
    }

    @Test func adjustStepsAndPersists() {
        let f = BrightFakeFactory()
        let b = BrightFakeBackend(.builtin, read: 0.5)
        f.build = { _, _ in [b] }
        let (e, store) = makeEngine(f)
        e.reconcile([builtinSnap()], now: t0)
        let row = e.adjust(cgID: 1, up: true, fine: false, now: t0)
        #expect(row?.value == 0.5625)
        #expect(store.value(for: "builtin") == 0.5625)
        #expect(b.writes == [0.5625])
        #expect(e.adjust(cgID: 99, up: true, fine: false, now: t0) == nil)
    }

    @Test func softwareValueIsRestoredAndReapplied() {
        let f = BrightFakeFactory()
        let sw = BrightFakeBackend(.software)
        f.build = { _, _ in [sw] }
        let (e, store) = makeEngine(f)
        store.setValue(0.4, for: extSnap().identity.baseID)
        e.reconcile([extSnap()], now: t0)
        #expect(e.rows[0].value == 0.4)
        #expect(sw.writes == [0.4])
        e.reconcile([extSnap()], now: t0)
        #expect(sw.writes == [0.4, 0.4])
    }

    @Test func removedDisplayReleasesBackend() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([builtinSnap(), extSnap()], now: t0)
        let ext = f.made[2]![0]
        e.reconcile([builtinSnap()], now: t0)
        #expect(ext.released == 1)
        #expect(e.rows.map(\.id) == ["builtin"])
    }

    @Test func changedCGIDRebuildsSlot() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap(2)], now: t0)
        e.reconcile([extSnap(5)], now: t0)
        #expect(f.made[2]![0].released == 1)
        #expect(e.rows[0].cgID == 5)
    }

    @Test func repeatedDdcFailuresDemoteToSoftware() {
        let f = BrightFakeFactory()
        f.build = { _, force in force ? [BrightFakeBackend(.software)] : [BrightFakeBackend(.ddc, read: 0.5), BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap()], now: t0)
        f.made[2]![0].writeOK = false
        let id = e.rows[0].id
        for i in 1...BrightnessEngine.failuresBeforeFallback { e.set(id: id, value: Double(i) / 10, now: t0.addingTimeInterval(Double(i))) }
        #expect(e.rows[0].method == .software)
    }

    @Test func powerAndContrastOnlyForCapableBackends() {
        let f = BrightFakeFactory()
        let b = BrightFakeBackend(.ddc, read: 0.5)
        f.build = { snap, _ in snap.cgID == 2 ? [b] : [BrightFakeBackend(.builtin, read: 0.5)] }
        let (e, store) = makeEngine(f)
        e.reconcile([builtinSnap(), extSnap()], now: t0)
        let ext = e.rows[1]
        #expect(ext.canPower)
        #expect(ext.contrast == 0.4)
        #expect(e.setPower(id: ext.id, on: false))
        #expect(b.powerCalls == [false])
        #expect(e.setContrast(id: ext.id, value: 0.8))
        #expect(store.contrast(for: ext.id) == 0.8)
        #expect(e.setPower(id: "nope", on: true) == false)
    }

    @Test func identicalMonitorsGetDistinctIDs() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([extSnap(2, serial: 0), extSnap(3, serial: 0)], now: t0)
        #expect(Set(e.rows.map(\.id)).count == 2)
    }

    @Test func releaseAllClearsEverything() {
        let f = BrightFakeFactory()
        f.build = { _, _ in [BrightFakeBackend(.software)] }
        let (e, _) = makeEngine(f)
        e.reconcile([builtinSnap()], now: t0)
        let b = f.made[1]![0]
        e.releaseAll()
        #expect(b.released == 1)
        #expect(e.rows.isEmpty)
    }

    @Test func keyboardBacklightLogic() {
        #expect(KeyboardBacklightLogic.onLevel(lastNonZero: nil) == 0.5)
        #expect(KeyboardBacklightLogic.onLevel(lastNonZero: 0) == 0.5)
        #expect(KeyboardBacklightLogic.onLevel(lastNonZero: 0.8) == 0.8)
        #expect(KeyboardBacklightLogic.onLevel(lastNonZero: 4) == 1)
        #expect(KeyboardBacklightLogic.next(current: 0, up: true, fine: false) == 0.0625)
        #expect(KeyboardBacklightLogic.next(current: 0, up: false, fine: false) == 0)
    }
}
