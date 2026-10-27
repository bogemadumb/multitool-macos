import Foundation

public enum SystemMetric: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, memory, network, disk, power, devices

    public var title: String {
        switch self {
        case .cpu: "Процессор"
        case .gpu: "Графика"
        case .memory: "Память"
        case .network: "Сеть"
        case .disk: "Диск"
        case .power: "Питание"
        case .devices: "Устройства"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .power: "battery.100percent"
        case .devices: "cable.connector"
        }
    }

    public var shortTitle: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "ОЗУ"
        case .network: "Сеть"
        case .disk: "Диск"
        case .power: "Бат."
        case .devices: "USB"
        }
    }

    public var inMenuBar: Bool { self != .devices }
}

public extension ModuleID {
    var monitorMetric: SystemMetric? {
        switch self {
        case .monitorCPU: .cpu
        case .monitorGPU: .gpu
        case .monitorMemory: .memory
        case .monitorNetwork: .network
        case .monitorDisk: .disk
        case .monitorPower: .power
        case .connectedDevices: .devices
        default: nil
        }
    }

    static func monitor(for metric: SystemMetric) -> ModuleID {
        switch metric {
        case .cpu: .monitorCPU
        case .gpu: .monitorGPU
        case .memory: .monitorMemory
        case .network: .monitorNetwork
        case .disk: .monitorDisk
        case .power: .monitorPower
        case .devices: .connectedDevices
        }
    }
}

public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct CPULoad: Equatable, Sendable {
    public var total: Double
    public var user: Double
    public var system: Double
    public init(total: Double, user: Double, system: Double) {
        self.total = total
        self.user = user
        self.system = system
    }
    public static let zero = CPULoad(total: 0, user: 0, system: 0)
}

public struct VMPages: Equatable, Sendable {
    public var pageSize: UInt64
    public var free: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var speculative: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressor: UInt64 = 0
    public var purgeable: UInt64 = 0
    public var fileBacked: UInt64 = 0
    public var anonymous: UInt64 = 0

    public init(pageSize: UInt64) { self.pageSize = pageSize }
}

public struct MemoryComposition: Equatable, Sendable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var freeBytes: UInt64

    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    public var usedFraction: Double { totalBytes == 0 ? 0 : min(Double(usedBytes) / Double(totalBytes), 1) }
}

public enum MemoryPressure: Int, Comparable, Sendable {
    case normal = 1, warning = 2, critical = 4

    public init(level: Int) {
        switch level {
        case 4...: self = .critical
        case 2...3: self = .warning
        default: self = .normal
        }
    }

    public var title: String {
        switch self {
        case .normal: "Норма"
        case .warning: "Повышенное"
        case .critical: "Критическое"
        }
    }

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

public struct MemoryReading: Equatable, Sendable {
    public var composition: MemoryComposition
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var pressure: MemoryPressure
}

public struct GPUReading: Equatable, Sendable {
    public var utilization: Double
    public var name: String?
}

public struct NetworkReading: Equatable, Sendable {
    public var downBps: Double
    public var upBps: Double
    public var sessionDownBytes: UInt64
    public var sessionUpBytes: UInt64
    public var localIP: String?
}

public struct NetProcRow: Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var name: String
    public var downBps: Double
    public var upBps: Double
    public var id: Int32 { pid }
    public var total: Double { downBps + upBps }
}

public enum SmartStatus: String, Sendable {
    case verified, failing, unsupported, unknown

    public var title: String {
        switch self {
        case .verified: "SMART: исправен"
        case .failing: "SMART: сбой"
        case .unsupported: "SMART недоступен"
        case .unknown: "SMART не проверен"
        }
    }
}

public struct DiskVolume: Equatable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var isInternal: Bool
    public var isEjectable: Bool
    public var id: String { path }

    public var freeFraction: Double { totalBytes == 0 ? 0 : Double(freeBytes) / Double(totalBytes) }
    public var usedFraction: Double { 1 - freeFraction }
}

public struct DiskReading: Equatable, Sendable {
    public var volumes: [DiskVolume]
    public var readBps: Double
    public var writeBps: Double
    public var smart: SmartStatus
}

public struct AccessoryBattery: Equatable, Identifiable, Sendable {
    public var name: String
    public var percent: Int
    public var id: String { name }
}

public struct BatteryReading: Equatable, Sendable {
    public var hasBattery = false
    public var percent: Int?
    public var onAC = false
    public var isCharging = false
    public var isCharged = false
    public var timeRemainingMin: Int?
    public var cycles: Int?
    public var healthPercent: Double?
    public var maxCapacityMAh: Double?
    public var designCapacityMAh: Double?
    public var temperatureC: Double?
    public var voltageV: Double?
    public var adapterWatts: Double?
    public var systemPowerW: Double?
    public var batteryPowerW: Double?
    public var accessories: [AccessoryBattery] = []

    public init() {}
}

public struct TemperatureReading: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var battery: Double?
    public var isEmpty: Bool { cpu == nil && gpu == nil && battery == nil }
    public init(cpu: Double? = nil, gpu: Double? = nil, battery: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
    }
}

public struct USBDevice: Equatable, Identifiable, Sendable {
    public var name: String
    public var vendor: String?
    public var vendorID: Int
    public var productID: Int
    public var serial: String?
    public var locationID: Int
    public var builtIn = false
    public var id: String { "\(vendorID):\(productID):\(locationID)" }
}

public struct ProcRow: Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var cpu: Double
    public var rssBytes: Int64
    public var netDownBps: Double = 0
    public var netUpBps: Double = 0
    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, name: String, cpu: Double, rssBytes: Int64) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.cpu = cpu
        self.rssBytes = rssBytes
    }
}

public struct ProcGroup: Equatable, Identifiable, Sendable {
    public var name: String
    public var pids: [Int32]
    public var cpu: Double
    public var rssBytes: Int64
    public var netBps: Double
    public var id: String { name }
}

public struct LiveSnapshot: Equatable, Sendable {
    public var at: Date = Date()
    public var cpu: CPULoad?
    public var perCore: [CPULoad] = []
    public var gpu: GPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var disk: DiskReading?
    public var battery: BatteryReading?
    public var temps = TemperatureReading()
    public var devices: [USBDevice] = []
    public var thermalState: Int = 0

    public init() {}
}
