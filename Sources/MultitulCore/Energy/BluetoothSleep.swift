import Foundation

public struct BluetoothSleepSettings: Equatable, Sendable {
    public var restoreOnWake = true
    public var restoreDelaySeconds = 2
    public var notify = false

    public init() {}

    public static let delayChoices = [0, 1, 2, 5, 10]
    public static let retryDelays: [TimeInterval] = [1, 3, 8]
}

public protocol BluetoothPowering: AnyObject {
    var isAvailable: Bool { get }
    func isOn() -> Bool?
    func setOn(_ on: Bool) -> Bool
}

public protocol BluetoothPendingStoring: AnyObject {
    var restorePending: Bool { get set }
}

public enum BluetoothSleepOutcome: Equatable, Sendable {
    case skipped(String)
    case turnedOff
    case failedToTurnOff
    case notOwed
    case restored
    case alreadyOn
    case retry(after: TimeInterval)
    case gaveUp
}

public final class BluetoothSleepLogic {
    public var settings: BluetoothSleepSettings
    private let power: BluetoothPowering
    private let store: BluetoothPendingStoring

    public init(power: BluetoothPowering, store: BluetoothPendingStoring, settings: BluetoothSleepSettings = BluetoothSleepSettings()) {
        self.power = power
        self.store = store
        self.settings = settings
    }

    public var owesRestore: Bool { store.restorePending }

    public func willSleep() -> BluetoothSleepOutcome {
        guard power.isAvailable else { return .skipped("Bluetooth API недоступен") }
        guard let on = power.isOn() else { return .skipped("состояние Bluetooth не прочиталось") }
        guard on else { return .skipped("Bluetooth уже выключен") }
        if settings.restoreOnWake { store.restorePending = true }
        if power.setOn(false) { return .turnedOff }
        store.restorePending = false
        return .failedToTurnOff
    }

    // attempt counts from 0; the caller schedules the next one after `.retry(after:)`.
    public func restore(attempt: Int) -> BluetoothSleepOutcome {
        guard store.restorePending else { return .notOwed }
        guard settings.restoreOnWake else {
            store.restorePending = false
            return .notOwed
        }
        guard power.isAvailable else { return .gaveUp }
        if power.isOn() == true {
            store.restorePending = false
            return .alreadyOn
        }
        if power.setOn(true) {
            store.restorePending = false
            return .restored
        }
        let delays = BluetoothSleepSettings.retryDelays
        return attempt < delays.count ? .retry(after: delays[attempt]) : .gaveUp
    }
}

public final class BluetoothDefaultsStore: BluetoothPendingStoring {
    static let key = "bluetoothSleep.restorePending"
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public var restorePending: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { if newValue { defaults.set(true, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) } }
    }

    public func loadSettings() -> BluetoothSleepSettings {
        var s = BluetoothSleepSettings()
        if let v = defaults.object(forKey: "bluetoothSleep.restoreOnWake") as? Bool { s.restoreOnWake = v }
        if let v = defaults.object(forKey: "bluetoothSleep.restoreDelay") as? Int { s.restoreDelaySeconds = max(0, min(v, 60)) }
        if let v = defaults.object(forKey: "bluetoothSleep.notify") as? Bool { s.notify = v }
        return s
    }

    public func save(_ s: BluetoothSleepSettings) {
        let base = BluetoothSleepSettings()
        func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
            if v == d { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
        }
        put("bluetoothSleep.restoreOnWake", s.restoreOnWake, base.restoreOnWake)
        put("bluetoothSleep.restoreDelay", s.restoreDelaySeconds, base.restoreDelaySeconds)
        put("bluetoothSleep.notify", s.notify, base.notify)
    }
}

// IOBluetooth private entry points, resolved at run time: a missing symbol just means "unavailable".
public final class IOBluetoothPower: BluetoothPowering {
    typealias GetFn = @convention(c) () -> Int32
    typealias SetFn = @convention(c) (Int32) -> Void

    private let getFn: GetFn?
    private let setFn: SetFn?

    public init() {
        let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        getFn = h.flatMap { dlsym($0, "IOBluetoothPreferenceGetControllerPowerState") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = h.flatMap { dlsym($0, "IOBluetoothPreferenceSetControllerPowerState") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    public var isAvailable: Bool { getFn != nil && setFn != nil }

    public func isOn() -> Bool? { getFn.map { $0() != 0 } }

    public func setOn(_ on: Bool) -> Bool {
        guard let setFn, getFn != nil else { return false }
        setFn(on ? 1 : 0)
        for _ in 0..<20 {
            if isOn() == on { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return isOn() == on
    }
}
