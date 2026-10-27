import Testing
import Foundation
@testable import MultitulCtlCore

private func service(_ d: SmcFakeDevice, attempts: Int = 5) -> SmcFanService {
    SmcFanService(smc: d, sleeper: { _ in }, unlockAttempts: attempts, retryDelay: 0)
}

@Suite struct SmcFanDiscoveryTests {
    @Test func noFnumKeyMeansNoFans() {
        let d = SmcFakeDevice()
        #expect(throws: SmcFanError.noFans) { try service(d).discover() }
    }

    @Test func zeroFansMeansNoFans() {
        let d = SmcFakeDevice()
        d.put("FNum", "ui8", 1, value: 0)
        #expect(throws: SmcFanError.noFans) { try service(d).discover() }
    }

    @Test func appleSiliconFanIsDiscovered() throws {
        let fans = try service(.appleSilicon(fans: [(1200, 6000, 1300), (1300, 6500, 0)])).discover()
        #expect(fans.map(\.index) == [0, 1])
        #expect(fans[1].minRpm == 1300 && fans[1].maxRpm == 6500)
        #expect(fans[0].modeKey == "F0Md" && fans[0].targetType == "flt")
    }

    @Test func lowercaseModeKeyIsAccepted() throws {
        let fans = try service(.appleSilicon(modeKeyCase: "md")).discover()
        #expect(fans[0].modeKey == "F0md")
    }

    @Test func intelFanUsesTheMask() throws {
        let fans = try service(.intel()).discover()
        #expect(fans.count == 2 && fans[0].modeKey == nil && fans[0].targetType == "fpe2")
    }

    @Test func missingModeControlIsUnsupported() {
        let d = SmcFakeDevice.appleSilicon()
        d.infos["F0Md"] = nil
        d.data["F0Md"] = nil
        #expect(throws: SmcFanError.self) { try service(d).discover() }
    }

    @Test func absurdBoundsAreUnsupported() {
        #expect(throws: SmcFanError.self) { try service(.appleSilicon(fans: [(6000, 1200, 1300)])).discover() }
        #expect(throws: SmcFanError.self) { try service(.appleSilicon(fans: [(1200, 20000, 1300)])).discover() }
    }

    @Test func tooManyFansAreUnsupported() {
        let d = SmcFakeDevice()
        d.put("FNum", "ui8", 1, value: 11)
        #expect(throws: SmcFanError.self) { try service(d).discover() }
    }
}

@Suite struct SmcFanAppleSiliconTests {
    @Test func setRpmUnlocksThenSwitchesModeThenWritesTarget() throws {
        let d = SmcFakeDevice.appleSilicon()
        #expect(try service(d).setRpm(index: 0, rpm: 3000) == 3000)
        #expect(d.names == ["Ftst", "F0Md", "F0Tg"])
        #expect(d.value("F0Tg") == 3000 && d.value("F0Md") == 1 && d.value("Ftst") == 1)
    }

    @Test func rpmAboveMaximumIsClamped() throws {
        let d = SmcFakeDevice.appleSilicon()
        #expect(try service(d).setRpm(index: 0, rpm: 9000) == 6000)
        #expect(d.value("F0Tg") == 6000)
    }

    @Test func rpmBelowMinimumIsRaisedToMinimum() throws {
        let d = SmcFakeDevice.appleSilicon()
        #expect(try service(d).setRpm(index: 0, rpm: 300) == 1200)
    }

    @Test func zeroIsRefusedWhenTheFanCannotStop() {
        let d = SmcFakeDevice.appleSilicon()
        #expect(throws: SmcFanError.stopNotSupported(1200)) { try service(d).setRpm(index: 0, rpm: 0) }
        #expect(d.writes.isEmpty)
    }

    @Test func zeroIsAllowedWhenMinimumIsZero() throws {
        let d = SmcFakeDevice.appleSilicon(fans: [(0, 5000, 800)])
        #expect(try service(d).setRpm(index: 0, rpm: 0) == 0)
        #expect(d.value("F0Tg") == 0)
    }

    @Test func secondWriteSkipsUnlockWhenAlreadyManual() throws {
        let d = SmcFakeDevice.appleSilicon()
        try service(d).setRpm(index: 0, rpm: 3000)
        d.writes = []
        try service(d).setRpm(index: 0, rpm: 3500)
        #expect(d.names == ["F0Tg"])
    }

    @Test func modeSwitchIsRetriedUntilTheSystemReleasesIt() throws {
        let d = SmcFakeDevice.appleSilicon()
        var tries = 0
        d.onWrite = { name, _ in if name == "F0Md" { tries += 1; if tries < 4 { d.ignore.insert("F0Md") } else { d.ignore.remove("F0Md") } } }
        try service(d).setRpm(index: 0, rpm: 2500)
        #expect(tries == 4 && d.value("F0Md") == 1)
    }

    @Test func failedUnlockRollsBackAndThrows() {
        let d = SmcFakeDevice.appleSilicon()
        d.ignore.insert("F0Md")
        #expect(throws: SmcFanError.self) { try service(d, attempts: 3).setRpm(index: 0, rpm: 2500) }
        #expect(d.value("F0Md") == 0 && d.value("Ftst") == 0)
        #expect(!d.names.contains("F0Tg"))
    }

    @Test func refusedTargetWriteReturnsTheFanToAuto() {
        let d = SmcFakeDevice.appleSilicon()
        d.refuse.insert("F0Tg")
        #expect(throws: SmcFanError.self) { try service(d).setRpm(index: 0, rpm: 2500) }
        #expect(d.value("F0Md") == 0 && d.value("Ftst") == 0)
    }

    @Test func targetReadbackMismatchReturnsTheFanToAuto() {
        let d = SmcFakeDevice.appleSilicon()
        d.ignore.insert("F0Tg")
        #expect(throws: SmcFanError.self) { try service(d).setRpm(index: 0, rpm: 2500) }
        #expect(d.value("F0Md") == 0)
    }

    @Test func autoAllClearsModesAndTheTestFlag() throws {
        let d = SmcFakeDevice.appleSilicon(fans: [(1200, 6000, 1300), (1200, 6000, 1300)])
        let s = service(d)
        try s.setRpm(index: 0, rpm: 3000)
        try s.setRpm(index: 1, rpm: 3000)
        try s.setAuto(.all)
        #expect(d.value("F0Md") == 0 && d.value("F1Md") == 0 && d.value("Ftst") == 0)
    }

    @Test func autoOneKeepsTheTestFlagWhileAnotherFanIsManual() throws {
        let d = SmcFakeDevice.appleSilicon(fans: [(1200, 6000, 1300), (1200, 6000, 1300)])
        let s = service(d)
        try s.setRpm(index: 0, rpm: 3000)
        try s.setRpm(index: 1, rpm: 3000)
        try s.setAuto(.index(0))
        #expect(d.value("F0Md") == 0 && d.value("F1Md") == 1 && d.value("Ftst") == 1)
        try s.setAuto(.index(1))
        #expect(d.value("Ftst") == 0)
    }

    @Test func autoContinuesWithOtherFansAfterAFailureAndReports() {
        let d = SmcFakeDevice.appleSilicon(fans: [(1200, 6000, 1300), (1200, 6000, 1300)])
        let s = service(d)
        try? s.setRpm(index: 0, rpm: 3000)
        try? s.setRpm(index: 1, rpm: 3000)
        d.refuse.insert("F0Md")
        #expect(throws: SmcFanError.self) { try s.setAuto(.all) }
        #expect(d.value("F1Md") == 0)
    }

    @Test func autoOnAnUntouchedMacWritesNothingToTheTestKey() throws {
        let d = SmcFakeDevice.appleSilicon()
        try service(d).setAuto(.all)
        #expect(!d.names.contains("Ftst"))
    }

    @Test func setManualKeepsTheCurrentSpeedAsTarget() throws {
        let d = SmcFakeDevice.appleSilicon(fans: [(1200, 6000, 2400)])
        try service(d).setManual(index: 0)
        #expect(d.value("F0Md") == 1 && d.value("F0Tg") == 2400)
    }

    @Test func setManualClampsASlowFanUpToMinimum() throws {
        let d = SmcFakeDevice.appleSilicon(fans: [(1200, 6000, 0)])
        try service(d).setManual(index: 0)
        #expect(d.value("F0Tg") == 1200)
    }

    @Test func unknownFanIndexIsRejectedWithoutWrites() {
        let d = SmcFakeDevice.appleSilicon()
        #expect(throws: SmcFanError.badIndex(3)) { try service(d).setRpm(index: 3, rpm: 3000) }
        #expect(throws: SmcFanError.badIndex(3)) { try service(d).setAuto(.index(3)) }
        #expect(d.writes.isEmpty)
    }

    @Test func machineWithoutTestKeyStillSwitches() throws {
        let d = SmcFakeDevice.appleSilicon(withTest: false)
        try service(d).setRpm(index: 0, rpm: 2800)
        #expect(d.names == ["F0Md", "F0Tg"])
    }
}

@Suite struct SmcFanIntelTests {
    @Test func setRpmSetsMaskBitThenTarget() throws {
        let d = SmcFakeDevice.intel()
        try service(d).setRpm(index: 1, rpm: 3000)
        #expect(d.data["FS! "] == [0, 2])
        #expect(d.value("F1Tg") == 3000)
        #expect(d.names == ["FS! ", "F1Tg"])
    }

    @Test func maskBitsAccumulateAndClearIndependently() throws {
        let d = SmcFakeDevice.intel()
        let s = service(d)
        try s.setRpm(index: 0, rpm: 3000)
        try s.setRpm(index: 1, rpm: 3000)
        #expect(d.data["FS! "] == [0, 3])
        try s.setAuto(.index(0))
        #expect(d.data["FS! "] == [0, 2])
        try s.setAuto(.all)
        #expect(d.data["FS! "] == [0, 0])
    }

    @Test func autoWithNothingSetWritesNothing() throws {
        let d = SmcFakeDevice.intel()
        try service(d).setAuto(.all)
        #expect(d.writes.isEmpty)
    }

    @Test func fpe2TargetIsEncodedAsQuarters() throws {
        let d = SmcFakeDevice.intel()
        try service(d).setRpm(index: 0, rpm: 2500)
        #expect(d.data["F0Tg"] == [0x27, 0x10])
    }

    @Test func failedMaskWriteThrows() {
        let d = SmcFakeDevice.intel()
        d.refuse.insert("FS! ")
        #expect(throws: SmcFanError.self) { try service(d).setRpm(index: 0, rpm: 3000) }
        #expect(!d.names.contains("F0Tg"))
    }

    @Test func clampUsesTheFanOwnLimits() throws {
        let d = SmcFakeDevice.intel()
        #expect(try service(d).setRpm(index: 1, rpm: 9000) == 5500)
    }
}

@Suite struct CtlSmcExecutorTests {
    private func run(_ c: CtlCommand, device: SmcFakeDevice?) -> (code: Int32, out: [String], err: [String]) {
        let box = LogBox()
        let ex = CtlExecutor(context: CtlContext(ownPid: 500, parentPid: 400, allowedApplyDirs: []), sleeper: { _ in },
                             smcFactory: { device }, out: { box.out.append($0) }, err: { box.err.append($0) })
        return (ex.execute(c), box.out, box.err)
    }

    @Test func setAppliesAndReports() {
        let d = SmcFakeDevice.appleSilicon()
        let r = run(.smcFanSet(index: 0, rpm: 3000), device: d)
        #expect(r.code == CtlExit.ok && r.out == ["smc: fan 0 target 3000 rpm"])
    }

    @Test func autoAllReturnsControl() {
        let d = SmcFakeDevice.appleSilicon()
        _ = run(.smcFanSet(index: 0, rpm: 3000), device: d)
        let r = run(.smcFanAuto(.all), device: d)
        #expect(r.code == CtlExit.ok && d.value("F0Md") == 0)
    }

    @Test func modeCommandsRoute() {
        let d = SmcFakeDevice.appleSilicon()
        #expect(run(.smcFanMode(index: 0, manual: true), device: d).code == CtlExit.ok)
        #expect(d.value("F0Md") == 1)
        #expect(run(.smcFanMode(index: 0, manual: false), device: d).code == CtlExit.ok)
        #expect(d.value("F0Md") == 0)
    }

    @Test func noFansHasItsOwnExitCode() {
        let r = run(.smcFanAuto(.all), device: SmcFakeDevice())
        #expect(r.code == CtlExit.noFans && r.err.first?.contains("no fans") == true)
    }

    @Test func unavailableSmcIsReported() {
        #expect(run(.smcFanAuto(.all), device: nil).code == CtlExit.unavailable)
    }

    @Test func rejectedRequestsUseUsageCode() {
        let d = SmcFakeDevice.appleSilicon()
        #expect(run(.smcFanSet(index: 5, rpm: 3000), device: d).code == CtlExit.usage)
        #expect(run(.smcFanSet(index: 0, rpm: 0), device: d).code == CtlExit.usage)
        #expect(d.writes.isEmpty)
    }

    @Test func hardwareFailureUsesSmcFailedCode() {
        let d = SmcFakeDevice.appleSilicon()
        d.refuse.insert("F0Tg")
        #expect(run(.smcFanSet(index: 0, rpm: 3000), device: d).code == CtlExit.smcFailed)
    }

    @Test func defaultExecutorNeverTouchesHardware() {
        let ex = CtlExecutor(context: CtlContext(ownPid: 1, parentPid: 1, allowedApplyDirs: []), err: { _ in })
        #expect(ex.execute(.smcFanAuto(.all)) == CtlExit.unavailable)
    }
}
