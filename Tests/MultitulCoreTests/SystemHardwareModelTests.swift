import Testing
import Foundation
@testable import MultitulCore

@Suite struct SMCCodecTests {
    @Test func floatLittleEndian() {
        #expect(SMCValueCodec.decode([0x00, 0x00, 0x48, 0x42], type: "flt ") == 50.0)
        #expect(SMCValueCodec.decode([0x00, 0x00, 0x20, 0xC1], type: "flt") == -10.0)
        #expect(SMCValueCodec.decode([0, 0, 0xC0, 0x7F], type: "flt ") == nil)
        #expect(SMCValueCodec.decode([0, 0], type: "flt ") == nil)
    }

    @Test func fixedPoint() {
        #expect(SMCValueCodec.decode([0x1A, 0x40], type: "sp78") == 26.25)
        #expect(SMCValueCodec.decode([0xFF, 0x00], type: "sp78") == -1.0)
        #expect(SMCValueCodec.decode([0x1F, 0x40], type: "fpe2") == 2000.0)
        #expect(SMCValueCodec.decode([0x02, 0x80], type: "fp88") == 2.5)
        #expect(SMCValueCodec.decode([0x80, 0x00], type: "fp1f") == 1.0)
        #expect(SMCValueCodec.decode([0x01], type: "fp88") == nil)
        #expect(SMCValueCodec.decode([0x01, 0x00], type: "xx88") == nil)
    }

    @Test func integers() {
        #expect(SMCValueCodec.decode([0x2A], type: "ui8 ") == 42)
        #expect(SMCValueCodec.decode([0xFF], type: "si8 ") == -1)
        #expect(SMCValueCodec.decode([0x01, 0x02], type: "ui16") == 258)
        #expect(SMCValueCodec.decode([0xFF, 0xFE], type: "si16") == -2)
        #expect(SMCValueCodec.decode([0, 0, 1, 0], type: "ui32") == 256)
        #expect(SMCValueCodec.decode([0, 0, 0, 0, 0, 0, 1, 0], type: "ui64") == 256)
        #expect(SMCValueCodec.decode([], type: "ui8 ") == nil)
        #expect(SMCValueCodec.decode([1, 2, 3, 4], type: "????") == nil)
    }

    @Test func keyDataLayoutMatchesAppleSMCABI() {
        #expect(MemoryLayout<SMCKeyData>.size == 80)
        #expect(MemoryLayout<SMCKeyData>.stride == 80)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.infoSize) == 28)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.bytes) == 48)
    }

    @Test func fourCC() {
        #expect(SMCCodes.string(SMCCodes.fourCC("Tp01")) == "Tp01")
        #expect(SMCCodes.fourCC("#KEY") == 0x234B4559)
    }

    @Test func selectorPicksFamilies() {
        #expect(TemperatureSelector.isCPUKey("Tp01") && TemperatureSelector.isCPUKey("Te05") && TemperatureSelector.isCPUKey("TC0P"))
        #expect(!TemperatureSelector.isCPUKey("Tg0f") && !TemperatureSelector.isCPUKey("Tp"))
        #expect(TemperatureSelector.isGPUKey("Tg0f"))
        #expect(TemperatureSelector.isBatteryKey("TB1T") && !TemperatureSelector.isBatteryKey("TBXT") && !TemperatureSelector.isBatteryKey("TB1P"))
        #expect(!TemperatureSelector.isInteresting("FNum"))
    }

    @Test func classifyAveragesCpuAndHottestGpu() {
        let t = TemperatureSelector.classify([("Tp01", 61.5), ("Tp02", 70.5), ("Te05", 0.0), ("Tp09", 300), ("Tg0f", 55), ("TB1T", 31.2), ("FNum", 2)])
        #expect(t.cpu == 66)
        #expect(t.gpu == 55)
        #expect(t.battery == 31.2)
        #expect(TemperatureSelector.classify([("Tp01", 0)]).cpu == nil)
    }

    @Test func cpuHotspotSpikeDoesNotShowAsCpuTemperature() {
        let readings: [(name: String, value: Double)] = [("Tp00", 57), ("Tp01", 64), ("Tp02", 70), ("Te04", 54), ("Tp0Z", 111.4), ("TCMz", 111.4), ("TCHP", 47)]
        let cpu = TemperatureSelector.cpuDisplay(readings)!
        #expect(cpu > 55 && cpu < 70)
        #expect(TemperatureSelector.cpuDisplay([("Tp00", 118), ("Tp01", 140)]) == nil)
        #expect(TemperatureSelector.cpuDisplay([("TC0P", 50), ("TC0D", 60)]) == 55)
    }
}

@Suite struct RegistryParsersTests {
    @Test func gpuUtilization() {
        #expect(RegistryParsers.gpuUtilization(["Device Utilization %": 37]) == 0.37)
        #expect(RegistryParsers.gpuUtilization(["GPU Activity(%)": 12]) == 0.12)
        #expect(RegistryParsers.gpuUtilization(["Renderer Utilization %": 20, "Tiler Utilization %": 45]) == 0.45)
        #expect(RegistryParsers.gpuUtilization(["Device Utilization %": 250]) == 1)
        #expect(RegistryParsers.gpuUtilization([:]) == nil)
    }

    @Test func diskIOTotals() {
        let t = RegistryParsers.diskIOTotals([["Bytes (Read)": 100, "Bytes (Write)": 50], ["Bytes (Read)": 1, "Bytes (Write)": 2], [:]])
        #expect(t.read == 101 && t.write == 52)
    }

    static let smart: [String: Any] = [
        "CycleCount": 312, "DesignCapacity": 6000, "AppleRawMaxCapacity": 5400, "Temperature": 3015, "Voltage": 12650,
        "ExternalConnected": true, "IsCharging": false,
        "AdapterDetails": ["Watts": 67],
        "PowerTelemetryData": ["SystemLoad": 8500, "BatteryPower": 0]
    ]
    static let iops: [[String: Any]] = [
        ["Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100, "Power Source State": "AC Power",
         "Is Charging": false, "Is Charged": false, "Time to Empty": 0, "Time to Full Charge": 0],
        ["Type": "Accessory Source", "Name": "Magic Mouse", "Current Capacity": 64]
    ]

    @Test func composeBatteryFromIOPSAndRegistry() {
        let b = RegistryParsers.compose(iops: Self.iops, smart: Self.smart)
        #expect(b.hasBattery && b.percent == 80 && b.onAC && !b.isCharging)
        #expect(b.cycles == 312)
        #expect(b.healthPercent == 90.0)
        #expect(b.temperatureC == 30.2 || b.temperatureC == 30.1)
        #expect(b.voltageV == 12.65)
        #expect(b.adapterWatts == 67)
        #expect(b.systemPowerW == 8.5)
        #expect(b.accessories == [AccessoryBattery(name: "Magic Mouse", percent: 64)])
        #expect(b.timeRemainingMin == nil)
    }

    @Test func composeDischargingTimeAndNegativeAmperage() {
        let dis: [[String: Any]] = [["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 100,
                                    "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": 200]]
        let b = RegistryParsers.compose(iops: dis, smart: nil)
        #expect(b.timeRemainingMin == 200 && !b.onAC && b.cycles == nil)
        #expect(RegistryParsers.int(NSNumber(value: UInt64.max - 1)) == -2)
        #expect(RegistryParsers.int(NSNumber(value: true)) == 1)
    }

    @Test func composeWithoutBatteryHasNone() {
        let b = RegistryParsers.compose(iops: [], smart: nil)
        #expect(!b.hasBattery && b.percent == nil)
    }

    @Test func usbFiltering() throws {
        let hub = ["USB Product Name": "USB3.1 Hub", "idVendor": 0x2109, "idProduct": 0x0817, "locationID": 0x01100000] as [String: Any]
        let keyb = ["USB Product Name": "Apple Internal Keyboard / Trackpad", "idVendor": 0x05AC, "idProduct": 0x0340, "locationID": 5] as [String: Any]
        let root = ["USB Product Name": "xHCI Root Hub", "idVendor": 0x1234, "idProduct": 1, "locationID": 6] as [String: Any]
        let flash = ["USB Product Name": "Flash Disk", "USB Vendor Name": "Kingston", "idVendor": 0x0951, "idProduct": 0x1666,
                     "USB Serial Number": "XYZ", "locationID": 0x14100000] as [String: Any]
        let builtin = ["USB Product Name": "Fancy Cam", "idVendor": 0x1111, "idProduct": 2, "locationID": 7, "Built-In": true] as [String: Any]
        let devs = [hub, keyb, root, flash, builtin, ["foo": 1], flash].compactMap(RegistryParsers.usbDevice)
        #expect(devs.count == 6)
        let ext = RegistryParsers.externalUSB(devs)
        #expect(ext.map(\.name) == ["Flash Disk", "USB3.1 Hub"])
        #expect(ext[0].vendor == "Kingston" && ext[0].serial == "XYZ")
    }

    @Test func unsafeRemovalDetector() {
        var d = UnsafeRemovalDetector(grace: 15)
        let t0 = Date(timeIntervalSince1970: 1000)
        let r0 = d.update(externalPaths: ["/Volumes/A", "/Volumes/B"], now: t0).isEmpty
        #expect(r0)
        d.noteUnmount("/Volumes/A", at: t0.addingTimeInterval(4))
        let gone = d.update(externalPaths: [], now: t0.addingTimeInterval(5))
        #expect(gone == ["/Volumes/B"])
        let r1 = d.update(externalPaths: [], now: t0.addingTimeInterval(10)).isEmpty
        #expect(r1)
    }
}
