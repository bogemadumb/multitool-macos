import Foundation

public struct OutputSwitcherSettings: Equatable, Sendable {
    public var cycle: [String] = []
    public var syncSystemOutput = true
    public var showHud = true

    public init() {}
}

public enum OutputCycle {
    public static func next(cycle: [String], available: Set<String>, current: String?, step: Int = 1) -> String? {
        let eligible = cycle.filter { available.contains($0) }
        guard !eligible.isEmpty else { return nil }
        guard let current, let i = eligible.firstIndex(of: current) else {
            return step >= 0 ? eligible.first : eligible.last
        }
        let n = eligible.count
        let target = eligible[((i + step) % n + n) % n]
        return target == current ? nil : target
    }

    public static func setMember(_ cycle: [String], uid: String, on: Bool) -> [String] {
        if on { return cycle.contains(uid) ? cycle : cycle + [uid] }
        return cycle.filter { $0 != uid }
    }
}

public struct OutputSwitchResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case switched, nothingToSwitch, failed }
    public var status: Status
    public var uid: String?
}

public final class OutputSwitcher: @unchecked Sendable {
    public var settings: OutputSwitcherSettings
    private let hardware: AudioHardware

    public init(hardware: AudioHardware, settings: OutputSwitcherSettings = OutputSwitcherSettings()) {
        self.hardware = hardware
        self.settings = settings
    }

    public func switchNext(step: Int = 1) -> OutputSwitchResult {
        let visible = AudioDeviceInfo.visible(hardware.devices(), scope: .output)
        let target = OutputCycle.next(cycle: settings.cycle, available: Set(visible.map(\.uid)), current: hardware.defaultUID(.output), step: step)
        guard let target else { return OutputSwitchResult(status: .nothingToSwitch, uid: nil) }
        var ok = hardware.setDefault(.output, uid: target)
        if ok, settings.syncSystemOutput { ok = hardware.setSystemOutput(uid: target) }
        return OutputSwitchResult(status: ok ? .switched : .failed, uid: target)
    }
}
