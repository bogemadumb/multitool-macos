import Testing
import Foundation
@testable import MultitulCore

private func dev(_ id: String, _ name: String = "Dev", kind: IslAccKind = .headphones, connected: Bool = true, main: Int? = nil, left: Int? = nil, right: Int? = nil, cs: Int? = nil) -> IslAccDevice {
    IslAccDevice(id: id, name: name, kind: kind, connected: connected, battery: IslAccBattery(main: main, left: left, right: right, caseLevel: cs))
}

private let profilerJSON = """
{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
"device_connected":[
 {"Иван AirPods Pro":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelCase":"85%","device_batteryLevelLeft":"90%","device_batteryLevelRight":"100%","device_minorType":"Headphones","device_vendorID":"0x004C"}},
 {"Magic Keyboard":{"device_address":"AA:BB:CC:DD:EE:02","device_batteryLevelMain":"67%","device_minorType":"Keyboard"}},
 {"Logitech MX Master":{"device_address":"AA:BB:CC:DD:EE:03","device_minorType":"Mouse"}}
],
"device_not_connected":[
 {"Sony WH-1000XM5":{"device_address":"AA:BB:CC:DD:EE:04","device_minorType":"Headphones"}}
]}]}
""".data(using: .utf8)!

@Suite struct IslAccParserTests {
    @Test func percentAcceptsNumbersAndStrings() {
        #expect(IslAccParser.percent(85) == 85)
        #expect(IslAccParser.percent("85%") == 85)
        #expect(IslAccParser.percent(" 85 % ") == 85)
        #expect(IslAccParser.percent("85") == 85)
        #expect(IslAccParser.percent(85.4) == 85)
        #expect(IslAccParser.percent(0.5) == 50)
        #expect(IslAccParser.percent(0) == 0 && IslAccParser.percent(100) == 100)
    }

    @Test func percentRejectsGarbage() {
        #expect(IslAccParser.percent(101) == nil && IslAccParser.percent(-1) == nil)
        #expect(IslAccParser.percent("n/a") == nil && IslAccParser.percent("") == nil)
        #expect(IslAccParser.percent(nil) == nil && IslAccParser.percent([1]) == nil)
        #expect(IslAccParser.percent("150%") == nil)
    }

    @Test func addressNormalization() {
        #expect(IslAccParser.normalizeAddress("AA-BB-CC-DD-EE-01") == "aa:bb:cc:dd:ee:01")
        #expect(IslAccParser.normalizeAddress("aabbccddee01") == "aa:bb:cc:dd:ee:01")
        #expect(IslAccParser.normalizeAddress("weird") == "weird")
    }

    @Test func batteryReadsSystemProfilerKeys() {
        let b = IslAccParser.battery(["device_batteryLevelLeft": "90%", "device_batteryLevelRight": "80%", "device_batteryLevelCase": "50%"])
        #expect(b == IslAccBattery(main: nil, left: 90, right: 80, caseLevel: 50))
    }

    @Test func batteryReadsPrivateIOKitKeys() {
        let b = IslAccParser.battery(["BatteryPercent": 72, "BatteryPercentLeft": 60, "BatteryPercentRight": 61, "BatteryPercentCase": 10])
        #expect(b == IslAccBattery(main: 72, left: 60, right: 61, caseLevel: 10))
    }

    @Test func batteryWithoutKeysIsEmpty() {
        #expect(IslAccParser.battery(["foo": 1]).isEmpty)
    }

    @Test func lowestIgnoresTheCase() {
        #expect(IslAccBattery(left: 80, right: 15, caseLevel: 5).lowest == 15)
        #expect(IslAccBattery(caseLevel: 5).lowest == nil)
        #expect(IslAccBattery(main: 40).lowest == 40)
    }

    @Test func headlinePrefersMainThenWeakestEarbud() {
        #expect(IslAccBattery(main: 40, left: 10).headline == 40)
        #expect(IslAccBattery(left: 80, right: 60, caseLevel: 99).headline == 60)
        #expect(IslAccBattery(caseLevel: 33).headline == 33)
    }

    @Test func kindDetection() {
        #expect(IslAccParser.kind(minorType: "Headphones", name: "AirPods Pro") == .airpods)
        #expect(IslAccParser.kind(minorType: "Keyboard", name: "X") == .keyboard)
        #expect(IslAccParser.kind(minorType: nil, name: "Magic Mouse") == .mouse)
        #expect(IslAccParser.kind(minorType: nil, name: "Magic Trackpad") == .trackpad)
        #expect(IslAccParser.kind(minorType: "Speaker", name: "JBL") == .speaker)
        #expect(IslAccParser.kind(minorType: nil, name: "DualSense Wireless Controller") == .gamepad)
        #expect(IslAccParser.kind(minorType: nil, name: "Thing") == .other)
    }

    @Test func systemProfilerJSONParsesConnectedAndOfflineDevices() {
        let list = IslAccParser.fromSystemProfiler(profilerJSON)
        #expect(list.count == 4)
        let pods = list.first { $0.id == "aa:bb:cc:dd:ee:01" }
        #expect(pods?.kind == .airpods && pods?.connected == true && pods?.battery == IslAccBattery(left: 90, right: 100, caseLevel: 85))
        #expect(list.first { $0.id == "aa:bb:cc:dd:ee:02" }?.battery.main == 67)
        #expect(list.first { $0.id == "aa:bb:cc:dd:ee:03" }?.battery.isEmpty == true)
        #expect(list.first { $0.id == "aa:bb:cc:dd:ee:04" }?.connected == false)
    }

    @Test func malformedProfilerOutputGivesNothing() {
        #expect(IslAccParser.fromSystemProfiler(Data("nope".utf8)).isEmpty)
        #expect(IslAccParser.fromSystemProfiler(Data("{}".utf8)).isEmpty)
        #expect(IslAccParser.fromSystemProfiler(Data("{\"SPBluetoothDataType\":[]}".utf8)).isEmpty)
    }

    @Test func formatLineAndSymbols() {
        #expect(IslAccFormat.batteryLine(IslAccBattery(left: 90, right: 100, caseLevel: 85)) == "Л 90% · П 100% · кейс 85%")
        #expect(IslAccFormat.batteryLine(IslAccBattery(main: 40)) == "40%")
        #expect(IslAccFormat.batterySymbol(5) == "battery.0" && IslAccFormat.batterySymbol(50) == "battery.50" && IslAccFormat.batterySymbol(100) == "battery.100")
        #expect(IslAccFormat.batterySymbol(nil) == "battery.0")
    }
}

@Suite struct IslAccTrackerTests {
    private let s = IslAccSettings()

    @Test func theFirstSnapshotIsSilentForConnectedDevices() {
        var t = IslAccTracker()
        #expect(t.update([dev("a", main: 80)], settings: s).isEmpty)
    }

    @Test func newlyConnectedDeviceRaisesAnEvent() {
        var t = IslAccTracker()
        _ = t.update([], settings: s)
        let e = t.update([dev("a", main: 80)], settings: s)
        #expect(e == [.connected(dev("a", main: 80))])
    }

    @Test func reconnectAfterOfflineRaisesAnEvent() {
        var t = IslAccTracker()
        _ = t.update([dev("a", connected: false)], settings: s)
        #expect(t.update([dev("a")], settings: s) == [.connected(dev("a"))])
    }

    @Test func disconnectIsReportedOnceWhenTheDeviceGoesOfflineOrVanishes() {
        var t = IslAccTracker()
        _ = t.update([dev("a"), dev("b")], settings: s)
        let e = t.update([dev("a", connected: false)], settings: s)
        #expect(e.contains(.disconnected(dev("a"))) && e.contains(.disconnected(dev("b"))) && e.count == 2)
        #expect(t.update([], settings: s).isEmpty)
    }

    @Test func steadyStateProducesNothing() {
        var t = IslAccTracker()
        _ = t.update([dev("a", main: 80)], settings: s)
        #expect(t.update([dev("a", main: 79)], settings: s).isEmpty)
    }

    @Test func lowBatteryWarnsOnceAtTwentyPercent() {
        var t = IslAccTracker()
        _ = t.update([dev("a", main: 30)], settings: s)
        #expect(t.update([dev("a", main: 21)], settings: s).isEmpty)
        let e = t.update([dev("a", main: 20)], settings: s)
        #expect(e == [.lowBattery(dev("a", main: 20), level: 20)])
        #expect(t.update([dev("a", main: 19)], settings: s).isEmpty)
        #expect(t.update([dev("a", main: 10)], settings: s).isEmpty)
    }

    @Test func warningRearmsAfterChargingWellAboveTheThreshold() {
        var t = IslAccTracker()
        _ = t.update([dev("a", main: 15)], settings: s)
        _ = t.update([dev("a", main: 22)], settings: s)
        #expect(t.update([dev("a", main: 18)], settings: s).isEmpty)
        _ = t.update([dev("a", main: 60)], settings: s)
        #expect(t.update([dev("a", main: 19)], settings: s).count == 1)
    }

    @Test func weakestEarbudDecidesTheWarning() {
        var t = IslAccTracker()
        _ = t.update([dev("a", left: 90, right: 90)], settings: s)
        let e = t.update([dev("a", left: 90, right: 12)], settings: s)
        #expect(e == [.lowBattery(dev("a", left: 90, right: 12), level: 12)])
    }

    @Test func lowChargingCaseDoesNotWarn() {
        var t = IslAccTracker()
        _ = t.update([dev("a", left: 90, right: 90, cs: 90)], settings: s)
        #expect(t.update([dev("a", left: 90, right: 90, cs: 3)], settings: s).isEmpty)
    }

    @Test func customThreshold() {
        var t = IslAccTracker()
        var custom = IslAccSettings()
        custom.lowThreshold = 40
        _ = t.update([dev("a", main: 60)], settings: custom)
        #expect(t.update([dev("a", main: 40)], settings: custom).count == 1)
    }

    @Test func hiddenDevicesAreIgnored() {
        var t = IslAccTracker()
        var h = IslAccSettings()
        h.hiddenDevices = ["a"]
        _ = t.update([], settings: h)
        #expect(t.update([dev("a", main: 5)], settings: h).isEmpty)
        #expect(t.known.isEmpty)
    }

    @Test func offlineDeviceDoesNotWarnAndRearmsWarningState() {
        var t = IslAccTracker()
        _ = t.update([dev("a", main: 10)], settings: s)
        _ = t.update([dev("a", connected: false)], settings: s)
        #expect(t.update([dev("a", main: 10)], settings: s).contains(.connected(dev("a", main: 10))))
    }

    @Test func resetForgetsEverything() {
        var t = IslAccTracker()
        _ = t.update([dev("a")], settings: s)
        t.reset()
        #expect(t.known.isEmpty)
        #expect(t.update([dev("a")], settings: s).isEmpty)
    }
}

@Suite struct IslAccActivityTests {
    private let now = ExtFix.now

    @Test func connectActivityShowsNameAndBattery() {
        let a = IslAccActivityFactory.activity(for: .connected(dev("a", "AirPods", left: 90, right: 70)), now: now)
        #expect(a?.title == "AirPods · 70%" && a?.priority == IslPriority.accessory && a?.peeks == true)
        #expect(a?.expiresAt == now.addingTimeInterval(IslAccActivityFactory.connectLifetime))
    }

    @Test func lowBatteryActivity() {
        let a = IslAccActivityFactory.activity(for: .lowBattery(dev("a", "Мышь", main: 15), level: 15), now: now)
        #expect(a?.title == "Мышь: заряд 15%" && a?.id == "acc.low.a")
    }

    @Test func disconnectHasNoActivity() {
        #expect(IslAccActivityFactory.activity(for: .disconnected(dev("a")), now: now) == nil)
    }

    @Test func accessoryOutranksMusicAndLosesToTimer() {
        let acc = IslAccActivityFactory.activity(for: .connected(dev("a")), now: IslFix.at(0))!
        var one = IslArbiter()
        #expect(one.resolve([IslFix.activity("music", "music", priority: IslPriority.music), acc], now: IslFix.at(1)).winner?.id == acc.id)
        var two = IslArbiter()
        #expect(two.resolve([IslFix.activity("timer", "timer", priority: IslPriority.timer), acc], now: IslFix.at(1)).winner?.id == "timer")
    }

    @Test func settingsRoundTrip() {
        let kv = WndMemoryStore()
        var s = IslAccSettings()
        s.lowThreshold = 30
        s.notifyConnect = false
        s.hiddenDevices = ["a", "b"]
        IslAccSettingsStore(kv).save(s)
        #expect(IslAccSettingsStore(kv).load() == s)
        IslAccSettingsStore(kv).save(IslAccSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func thresholdIsClamped() {
        var s = IslAccSettings()
        s.lowThreshold = 1
        #expect(s.sanitized.lowThreshold == 5)
        s.lowThreshold = 99
        #expect(s.sanitized.lowThreshold == 50)
    }
}
