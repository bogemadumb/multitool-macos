import Foundation

public enum RegistryParsers {
    public static func int(_ v: Any?) -> Int64? {
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            let u = n.uint64Value
            if u > UInt64(Int64.max) { return Int64(bitPattern: u) }
            return n.int64Value
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        case let u as UInt64: return Int64(bitPattern: u)
        case let d as Double: return Int64(d)
        default: return nil
        }
    }

    public static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        return int(v).map(Double.init)
    }

    public static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        return int(v).map { $0 != 0 }
    }

    public static func gpuUtilization(_ perf: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            if let v = double(perf[key]) { return min(max(v / 100, 0), 1) }
        }
        let parts = ["Renderer Utilization %", "Tiler Utilization %"].compactMap { double(perf[$0]) }
        if let m = parts.max() { return min(max(m / 100, 0), 1) }
        return nil
    }

    public static func diskIOTotals(_ stats: [[String: Any]]) -> (read: UInt64, write: UInt64) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        for s in stats {
            if let v = int(s["Bytes (Read)"]), v > 0 { r &+= UInt64(v) }
            if let v = int(s["Bytes (Write)"]), v > 0 { w &+= UInt64(v) }
        }
        return (r, w)
    }

    public static func compose(iops: [[String: Any]], smart: [String: Any]?) -> BatteryReading {
        var b = BatteryReading()
        let internalSource = iops.first { ($0["Type"] as? String) == "InternalBattery" }
        if let s = internalSource {
            b.hasBattery = true
            if let cur = int(s["Current Capacity"]), let mx = int(s["Max Capacity"]), mx > 0 {
                b.percent = mx == 100 ? Int(cur) : Int((Double(cur) / Double(mx) * 100).rounded())
            }
            b.onAC = (s["Power Source State"] as? String) == "AC Power"
            b.isCharging = bool(s["Is Charging"]) ?? false
            b.isCharged = bool(s["Is Charged"]) ?? false
            let key = b.isCharging ? "Time to Full Charge" : "Time to Empty"
            if let t = int(s[key]), t > 0, !b.isCharged { b.timeRemainingMin = Int(t) }
        }
        b.accessories = iops.compactMap { s in
            guard (s["Type"] as? String) != "InternalBattery", let name = s["Name"] as? String,
                  let cur = int(s["Current Capacity"]), cur >= 0 else { return nil }
            return AccessoryBattery(name: name, percent: Int(cur))
        }
        if let d = smart {
            b.hasBattery = b.hasBattery || (bool(d["BatteryInstalled"]) ?? true)
            b.cycles = int(d["CycleCount"]).map(Int.init)
            let design = double(d["DesignCapacity"])
            let raw = double(d["AppleRawMaxCapacity"]) ?? double(d["NominalChargeCapacity"])
            b.designCapacityMAh = design
            b.maxCapacityMAh = raw
            if let design, design > 0, let raw { b.healthPercent = (raw / design * 1000).rounded() / 10 }
            if let t = double(d["Temperature"]), t > 0 { b.temperatureC = (t / 100 * 10).rounded() / 10 }
            if let v = double(d["Voltage"]), v > 0 { b.voltageV = v / 1000 }
            if let ad = d["AdapterDetails"] as? [String: Any], let w = double(ad["Watts"]), w > 0 { b.adapterWatts = w }
            if let tel = d["PowerTelemetryData"] as? [String: Any] {
                if let load = double(tel["SystemLoad"]), load > 0 { b.systemPowerW = load / 1000 }
                if let bp = int(tel["BatteryPower"]) { b.batteryPowerW = Double(bp) / 1000 }
            }
            if internalSource == nil {
                if let ext = bool(d["ExternalConnected"]) { b.onAC = ext }
                if let c = bool(d["IsCharging"]) { b.isCharging = c }
                if let cap = int(d["CurrentCapacity"]), let mx = int(d["MaxCapacity"]), mx > 0, b.percent == nil {
                    b.percent = mx == 100 ? Int(cap) : Int((Double(cap) / Double(mx) * 100).rounded())
                }
            }
        }
        return b
    }

    public static func usbDevice(_ d: [String: Any]) -> USBDevice? {
        let name = (d["USB Product Name"] as? String) ?? (d["kUSBProductString"] as? String)
        guard let name, !name.isEmpty, let vid = int(d["idVendor"]), let pid = int(d["idProduct"]) else { return nil }
        return USBDevice(name: name, vendor: (d["USB Vendor Name"] as? String) ?? (d["kUSBVendorString"] as? String),
                         vendorID: Int(vid), productID: Int(pid),
                         serial: (d["USB Serial Number"] as? String) ?? (d["kUSBSerialNumberString"] as? String),
                         locationID: Int(int(d["locationID"]) ?? 0), builtIn: bool(d["Built-In"]) == true)
    }

    public static func isInternalUSB(_ d: USBDevice) -> Bool {
        if d.builtIn { return true }
        let n = d.name.lowercased()
        if n.contains("root hub") { return true }
        if d.vendorID == 0x05AC {
            let markers = ["internal", "bluetooth", "ambient light", "facetime", "camera", "touch bar", "t2 controller", "ibridge"]
            return markers.contains { n.contains($0) }
        }
        return false
    }

    public static func externalUSB(_ all: [USBDevice]) -> [USBDevice] {
        var seen = Set<String>()
        return all.filter { !isInternalUSB($0) && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

public struct UnsafeRemovalDetector {
    private var known: Set<String> = []
    private var unmounted: [String: Date] = [:]
    public var grace: TimeInterval

    public init(grace: TimeInterval = 15) { self.grace = grace }

    public mutating func noteUnmount(_ path: String, at now: Date) { unmounted[path] = now }

    public mutating func update(externalPaths: Set<String>, now: Date) -> [String] {
        let gone = known.subtracting(externalPaths)
        known = externalPaths
        let result = gone.filter { p in
            if let t = unmounted[p], now.timeIntervalSince(t) <= grace { return false }
            return true
        }.sorted()
        unmounted = unmounted.filter { now.timeIntervalSince($0.value) <= grace }
        return result
    }
}
