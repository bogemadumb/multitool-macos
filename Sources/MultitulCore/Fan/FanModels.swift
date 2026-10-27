import Foundation

public struct FanInfo: Equatable, Sendable, Identifiable {
    public var index: Int
    public var minRpm: Double
    public var maxRpm: Double
    public var id: Int { index }
    public var canStop: Bool { minRpm <= 0 }

    public init(index: Int, minRpm: Double, maxRpm: Double) {
        self.index = index
        self.minRpm = minRpm
        self.maxRpm = maxRpm
    }
}

public struct FanReading: Equatable, Sendable, Identifiable {
    public var index: Int
    public var actual: Double
    public var target: Double
    public var manual: Bool
    public var id: Int { index }

    public init(index: Int, actual: Double, target: Double, manual: Bool) {
        self.index = index
        self.actual = actual
        self.target = target
        self.manual = manual
    }
}

public enum FanDetection: Equatable, Sendable {
    case noFans
    case unsupported(String)
    case fans([FanInfo])
}

public struct FanThermal: Equatable, Sendable {
    public var cpu: [Double]
    public var gpu: [Double]

    public init(cpu: [Double] = [], gpu: [Double] = []) {
        self.cpu = cpu
        self.gpu = gpu
    }
}

public enum FanSensorSource: String, CaseIterable, Sendable {
    case cpu, gpu, soc

    public var title: String {
        switch self {
        case .cpu: "Процессор"
        case .gpu: "Графика"
        case .soc: "Весь чип (CPU + GPU)"
        }
    }
}

public enum FanAggregate: String, CaseIterable, Sendable {
    case average, hottest

    public var title: String { self == .average ? "Среднее по группе" : "Самый горячий датчик" }
}

public enum FanControlMode: String, CaseIterable, Sendable {
    case auto, manualRpm, manualPercent, curve

    public var title: String {
        switch self {
        case .auto: "Система"
        case .manualRpm: "Обороты"
        case .manualPercent: "Проценты"
        case .curve: "Кривая"
        }
    }
}
