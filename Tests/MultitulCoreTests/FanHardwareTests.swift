import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FanFakeSmc: SmcReading {
    var infos: [String: SmcKeyInfo] = [:]
    var data: [String: [UInt8]] = [:]
    var scans = 0
    var reads = 0

    func keyInfo(_ name: String) -> SmcKeyInfo? { infos[name] }
    func readBytes(_ name: String) -> [UInt8]? { reads += 1; return data[name] }
    func allKeyNames() -> [String] { scans += 1; return infos.keys.sorted() }

    func put(_ name: String, _ type: String, _ size: Int, _ value: Double) {
        infos[name] = SmcKeyInfo(size: size, type: type)
        data[name] = SmcCodec.encode(value, type: type, size: size)
    }

    static func macWithFans(count: Int = 2, intel: Bool = false) -> FanFakeSmc {
        let s = FanFakeSmc()
        s.put("FNum", "ui8", 1, Double(count))
        for i in 0..<count {
            let t = intel ? "fpe2" : "flt"
            let n = intel ? 2 : 4
            s.put("F\(i)Ac", t, n, 1500 + Double(i) * 100)
            s.put("F\(i)Mn", t, n, 1200)
            s.put("F\(i)Mx", t, n, 6000)
            s.put("F\(i)Tg", t, n, 1250)
            if !intel { s.put("F\(i)Md", "ui8", 1, 0) }
        }
        if intel { s.infos["FS! "] = SmcKeyInfo(size: 2, type: "ui16"); s.data["FS! "] = [0, 0] }
        s.put("Tp01", "flt", 4, 55)
        s.put("Tp05", "flt", 4, 65)
        s.put("Tg0a", "flt", 4, 48)
        s.put("TB0T", "flt", 4, 30)
        return s
    }
}

@Suite struct FanSmcHardwareTests {
    @Test func macWithoutFnumHasNoFans() {
        let h = FanSmcHardware(smc: FanFakeSmc())
        #expect(h.detect() == .noFans)
        #expect(h.readFans() == nil)
    }

    @Test func fnumZeroHasNoFans() {
        let s = FanFakeSmc()
        s.put("FNum", "ui8", 1, 0)
        #expect(FanSmcHardware(smc: s).detect() == .noFans)
    }

    @Test func appleSiliconFansAreListed() {
        let h = FanSmcHardware(smc: FanFakeSmc.macWithFans())
        #expect(h.detect() == .fans([FanInfo(index: 0, minRpm: 1200, maxRpm: 6000), FanInfo(index: 1, minRpm: 1200, maxRpm: 6000)]))
    }

    @Test func intelFansAreListed() {
        let h = FanSmcHardware(smc: FanFakeSmc.macWithFans(count: 1, intel: true))
        #expect(h.detect() == .fans([FanInfo(index: 0, minRpm: 1200, maxRpm: 6000)]))
    }

    @Test func missingKeysMakeTheFanUnsupported() {
        let s = FanFakeSmc.macWithFans(count: 1)
        s.infos["F0Mx"] = nil
        s.data["F0Mx"] = nil
        if case .unsupported = FanSmcHardware(smc: s).detect() {} else { Issue.record("expected unsupported") }
    }

    @Test func readingsCarryActualTargetAndMode() {
        let s = FanFakeSmc.macWithFans(count: 2)
        s.data["F1Md"] = [1]
        let h = FanSmcHardware(smc: s)
        _ = h.detect()
        let r = h.readFans()!
        #expect(r.count == 2 && r[0].actual == 1500 && r[0].target == 1250 && !r[0].manual)
        #expect(r[1].actual == 1600 && r[1].manual)
    }

    @Test func intelMaskBitsAreReadAsManual() {
        let s = FanFakeSmc.macWithFans(count: 2, intel: true)
        s.data["FS! "] = [0, 2]
        let h = FanSmcHardware(smc: s)
        _ = h.detect()
        #expect(h.readFans()!.map(\.manual) == [false, true])
    }

    @Test func oneUnreadableKeyFailsTheWholeReading() {
        let s = FanFakeSmc.macWithFans(count: 2)
        let h = FanSmcHardware(smc: s)
        _ = h.detect()
        s.data["F1Ac"] = nil
        #expect(h.readFans() == nil)
    }

    @Test func absurdReadingsAreRejected() {
        let s = FanFakeSmc.macWithFans(count: 1)
        let h = FanSmcHardware(smc: s)
        _ = h.detect()
        s.put("F0Ac", "flt", 4, 90000)
        #expect(h.readFans() == nil)
    }

    @Test func thermalGroupsComeFromTheSharedKeySelector() {
        let h = FanSmcHardware(smc: FanFakeSmc.macWithFans())
        let t = h.readThermal()!
        #expect(t.cpu.sorted() == [55, 65] && t.gpu == [48])
    }

    @Test func keyScanHappensOnce() {
        let s = FanFakeSmc.macWithFans()
        let h = FanSmcHardware(smc: s)
        _ = h.readThermal()
        _ = h.readThermal()
        #expect(s.scans == 1)
    }

    @Test func noTemperatureKeysMeansSensorLoss() {
        let s = FanFakeSmc()
        s.put("FNum", "ui8", 1, 0)
        #expect(FanSmcHardware(smc: s).readThermal() == nil)
    }

    @Test func unavailableSmcIsUnsupportedAndSilent() {
        let h = FanUnavailableHardware()
        if case .unsupported = h.detect() {} else { Issue.record("expected unsupported") }
        #expect(h.readFans() == nil && h.readThermal() == nil)
    }

    @Test func readerHasNoWriteSurface() {
        let reader: Any = FanSmcHardware(smc: FanFakeSmc())
        #expect(!(reader is SmcWriting))
    }
}

@Suite struct FanCtlApplierTests {
    private func make(_ r: FakeRunner) -> FanCtlApplier {
        FanCtlApplier(ctl: PrivilegedCtl(runner: r, stagingDir: NSTemporaryDirectory() + "multitul-fan-\(UUID().uuidString)", binaryExists: { _ in true }), timeout: 7)
    }

    @Test func autoAllBuildsTheDocumentedCommand() throws {
        let r = FakeRunner()
        try make(r).setAuto(index: nil)
        #expect(r.calls[0].1 == ["-n", "/usr/local/libexec/multitul-ctl", "smc", "fan-auto", "all"])
    }

    @Test func autoOneFan() throws {
        let r = FakeRunner()
        try make(r).setAuto(index: 2)
        #expect(r.calls[0].1.suffix(3) == ["smc", "fan-auto", "2"])
    }

    @Test func setRpmBuildsTheDocumentedCommand() throws {
        let r = FakeRunner()
        try make(r).setRpm(index: 1, rpm: 3456)
        #expect(r.calls[0].1.suffix(4) == ["smc", "fan-set", "1", "3456"])
    }

    @Test func invalidValuesNeverReachSudo() {
        let r = FakeRunner()
        #expect(throws: CtlError.self) { try make(r).setRpm(index: 10, rpm: 3000) }
        #expect(throws: CtlError.self) { try make(r).setRpm(index: 0, rpm: 10001) }
        #expect(throws: CtlError.self) { try make(r).setRpm(index: 0, rpm: -1) }
        #expect(throws: CtlError.self) { try make(r).setAuto(index: 10) }
        #expect(r.calls.isEmpty)
    }

    @Test func missingHelperSurfacesAsAnError() {
        let r = FakeRunner()
        let a = FanCtlApplier(ctl: PrivilegedCtl(runner: r, stagingDir: "/tmp/x", binaryExists: { _ in false }))
        #expect(throws: CtlError.notInstalled) { try a.setAuto(index: nil) }
    }

    @Test func helperFailureIsReported() {
        let r = FakeRunner()
        r.result = ProcessOutput(status: 9, stderr: "smc: fan 0: write failed")
        #expect(throws: CtlError.self) { try make(r).setRpm(index: 0, rpm: 3000) }
    }
}

@Suite struct FanModuleInfoTests {
    @Test func moduleIsOffByDefaultInTheSystemGroupWithoutHotkeys() {
        let i = ModuleID.fanControl.info
        #expect(i.group == .system && !i.enabledByDefault && i.hotkeys.isEmpty && i.permissions.isEmpty)
        #expect(i.summary.contains("не проверено на железе"))
    }

    @Test func identifiersAreAscii() {
        #expect(ModuleID.fanControl.rawValue == "fanControl" && ModuleID.fanControl.enabledKey == "module.fanControl.enabled")
    }

    @Test func textsCoverEveryFaultAndState() {
        for k in [FanEngine.Fault.Kind.sensorLost, .fanReadLost, .thermalPressure, .writeFailed, .watchdog, .reclaimed] {
            #expect(!FanText.faultTitle(k).isEmpty)
        }
        let states: [FanEngine.State] = [.stopped, .noFans, .unsupported("x"), .system, .manual, .curve]
        #expect(Set(states.map { FanText.status($0, restorePending: false, asleep: false) }).count == 6)
        #expect(FanText.status(.system, restorePending: true, asleep: false).contains("Не удалось"))
        #expect(FanText.status(.system, restorePending: false, asleep: true).contains("Сон"))
        #expect(FanText.rpm(1234.6) == "1235 об/мин")
    }

    @Test func snapshotMirrorsTheEngine() {
        let r = FanRig(config: { $0.manualRpm = 3000 })
        _ = r.engine.setMode(.manualRpm)
        let s = r.engine.snapshot()
        #expect(s.isControlling && s.fans.count == 1 && s.config.mode == .manualRpm && s.targets[0] == 3000 && s.fault == nil)
    }

    @Test func faultMessageIsRussianAndNamesTheCause() {
        #expect(FanEngine.Fault(kind: .sensorLost).message == "Пропали датчики температуры")
        #expect(FanEngine.Fault(kind: .writeFailed, detail: "boom").message.hasSuffix(": boom"))
    }
}
