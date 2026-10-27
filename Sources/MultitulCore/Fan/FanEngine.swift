import Foundation

public final class FanWatchdog: @unchecked Sendable {
    public let timeout: TimeInterval
    private let clock: FanClock
    private let restore: () -> Bool
    private let lock = NSLock()
    private var last: TimeInterval = 0
    private var armed = false
    private var tripped = false

    public init(clock: FanClock, timeout: TimeInterval = FanPolicy.watchdogTimeout, restore: @escaping () -> Bool) {
        self.clock = clock
        self.timeout = timeout
        self.restore = restore
    }

    public var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }

    public func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
        tripped = false
        last = clock.now
    }

    public func disarm() {
        lock.lock(); defer { lock.unlock() }
        armed = false
    }

    public func beat() {
        lock.lock(); defer { lock.unlock() }
        last = clock.now
    }

    // Called from a queue other than the engine's: a stalled engine cannot rescue itself.
    @discardableResult
    public func check() -> Bool {
        lock.lock()
        guard armed, clock.now - last > timeout else { lock.unlock(); return false }
        armed = false
        tripped = true
        lock.unlock()
        if !restore() {
            lock.lock()
            armed = true
            lock.unlock()
        }
        return true
    }

    public func consumeTrip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { tripped = false }
        return tripped
    }
}

public struct FanSnapshot: Equatable, Sendable {
    public var state = FanEngine.State.stopped
    public var config = FanConfig()
    public var fans: [FanInfo] = []
    public var readings: [FanReading] = []
    public var targets: [Int: Double] = [:]
    public var temperature: Double?
    public var fault: FanEngine.Fault?
    public var restorePending = false
    public var asleep = false
    public init() {}
    public var isControlling: Bool { state == .manual || state == .curve }
}

public final class FanEngine {
    public enum State: Equatable, Sendable {
        case stopped, noFans, unsupported(String), system, manual, curve
    }

    public struct Fault: Equatable, Sendable {
        public enum Kind: String, Sendable { case sensorLost, fanReadLost, thermalPressure, writeFailed, watchdog, reclaimed }
        public var kind: Kind
        public var detail: String
        public init(kind: Kind, detail: String = "") {
            self.kind = kind
            self.detail = detail
        }
        public var message: String { FanText.faultTitle(kind) + (detail.isEmpty ? "" : ": \(detail)") }
    }

    public private(set) var state = State.stopped
    public private(set) var config: FanConfig
    public private(set) var fans: [FanInfo] = []
    public private(set) var readings: [FanReading] = []
    public private(set) var temperature: Double?
    public private(set) var targets: [Int: Double] = [:]
    public private(set) var lastFault: Fault?
    public private(set) var restorePending = false
    public private(set) var asleep = false

    public let watchdog: FanWatchdog
    private let hardware: FanHardware
    private let applier: FanApplying
    private let store: FanSettingsStore
    private let clock: FanClock
    private let thermalState: () -> Int
    private let notify: (String, String) -> Void
    private var hysteresis = FanHysteresis()
    private var written: [Int: (rpm: Double, at: TimeInterval)] = [:]
    private var lastControlAt: TimeInterval?
    private var lastRestoreAttempt: TimeInterval?
    private var sensorMisses = 0
    private var fanMisses = 0
    private var reclaims = 0
    private var resumeMode: FanControlMode?

    public init(hardware: FanHardware, applier: FanApplying, store: FanSettingsStore, clock: FanClock = FanSystemClock(),
                thermalState: @escaping () -> Int = { ProcessInfo.processInfo.thermalState.rawValue },
                notify: @escaping (String, String) -> Void = { _, _ in }) {
        self.hardware = hardware
        self.applier = applier
        self.store = store
        self.clock = clock
        self.thermalState = thermalState
        self.notify = notify
        config = store.load()
        watchdog = FanWatchdog(clock: clock) { [applier] in (try? applier.setAuto(index: nil)) != nil }
    }

    public var isControlling: Bool { state == .manual || state == .curve }

    public func snapshot() -> FanSnapshot {
        var s = FanSnapshot()
        s.state = state
        s.config = config
        s.fans = fans
        s.readings = readings
        s.targets = targets
        s.temperature = temperature
        s.fault = lastFault
        s.restorePending = restorePending
        s.asleep = asleep
        return s
    }

    // MARK: lifecycle

    public func start() {
        guard state == .stopped else { return }
        config = store.load()
        switch hardware.detect() {
        case .noFans:
            state = .noFans
            return
        case .unsupported(let why):
            state = .unsupported(why)
            return
        case .fans(let list):
            fans = list
            state = list.isEmpty ? .noFans : .system
        }
        guard state == .system else { return }
        if store.dirty { restoreAuto() }
        readings = hardware.readFans() ?? []
        if config.resumeOnLaunch, config.mode != .auto, !restorePending {
            if !canEngage(config.mode) || !engage(config.mode) { config.mode = .auto; store.save(config) }
        } else if config.mode != .auto {
            config.mode = .auto
            store.save(config)
        }
    }

    public func stop() {
        guard state != .stopped else { return }
        if isControlling || store.dirty || restorePending { restoreAuto() }
        if restorePending { watchdog.disarm() }
        state = .stopped
        readings = []
        temperature = nil
    }

    public func sleep() {
        asleep = true
        guard isControlling else { return }
        resumeMode = config.mode
        restoreAuto()
    }

    public func wake() {
        asleep = false
        guard let m = resumeMode else { return }
        resumeMode = nil
        guard state == .system, !restorePending else { return }
        _ = engage(m)
    }

    // MARK: user actions

    @discardableResult
    public func setMode(_ mode: FanControlMode) -> Bool {
        guard canAccept else { return false }
        if mode == .auto {
            config.mode = .auto
            store.save(config)
            restoreAuto()
            lastFault = nil
            return true
        }
        guard canEngage(mode) else { return false }
        config.mode = mode
        store.save(config)
        return engage(mode)
    }

    @discardableResult
    public func update(_ new: FanConfig) -> Bool {
        var c = new.sanitized
        let modeChanged = c.mode != config.mode
        guard canAccept else {
            c.mode = config.mode
            config = c
            store.save(config)
            return !modeChanged
        }
        config = c
        store.save(config)
        guard modeChanged else { return true }
        if c.mode == .auto {
            restoreAuto()
            lastFault = nil
            return true
        }
        guard canEngage(c.mode) else {
            config.mode = .auto
            store.save(config)
            return false
        }
        return engage(c.mode)
    }

    private var canAccept: Bool { !asleep && !fans.isEmpty && (state == .system || isControlling) }

    private func canEngage(_ mode: FanControlMode) -> Bool { mode != .curve || config.curveUsable }

    // MARK: periodic

    public func tick() {
        guard !fans.isEmpty, state != .stopped, !asleep else { return }
        let now = clock.now
        if isControlling {
            watchdog.beat()
            if watchdog.consumeTrip() {
                fail(.watchdog)
                return
            }
        }
        guard let r = hardware.readFans(), r.count == fans.count else {
            fanMisses += 1
            if isControlling, fanMisses >= FanPolicy.fanReadLossLimit { fail(.fanReadLost) }
            return
        }
        fanMisses = 0
        readings = r
        if isControlling {
            if thermalState() >= FanPolicy.seriousThermalState {
                fail(.thermalPressure)
                return
            }
            _ = control(now: now)
        } else {
            if restorePending, lastRestoreAttempt.map({ now - $0 >= FanPolicy.restoreRetryInterval }) ?? true { restoreAuto() }
            temperature = hardware.readThermal().flatMap { FanSensors.aggregate($0, source: config.source, how: config.aggregate) }
        }
    }

    // MARK: control

    private func engage(_ mode: FanControlMode) -> Bool {
        guard let r = hardware.readFans(), r.count == fans.count else {
            fail(.fanReadLost)
            return false
        }
        readings = r
        hysteresis.reset()
        written = [:]
        targets = [:]
        lastControlAt = nil
        sensorMisses = 0
        fanMisses = 0
        reclaims = 0
        lastFault = nil
        store.dirty = true
        watchdog.arm()
        state = mode == .curve ? .curve : .manual
        return control(now: clock.now)
    }

    private func desiredRpm() -> [Int: Double]? {
        switch config.mode {
        case .auto:
            return nil
        case .manualRpm:
            return Dictionary(uniqueKeysWithValues: fans.map { ($0.index, Double(config.manualRpm)) })
        case .manualPercent:
            return Dictionary(uniqueKeysWithValues: fans.map { ($0.index, FanPolicy.rpm(percent: Double(config.manualPercent), fan: $0)) })
        case .curve:
            let thermal = hardware.readThermal()
            guard let raw = thermal.flatMap({ FanSensors.aggregate($0, source: config.source, how: config.aggregate) }) else {
                sensorMisses += 1
                return nil
            }
            sensorMisses = 0
            temperature = raw
            let eff = hysteresis.filter(raw, band: config.hysteresis)
            guard let pct = FanCurve.percent(at: eff, in: config.curve) else { return nil }
            return Dictionary(uniqueKeysWithValues: fans.map { ($0.index, FanPolicy.rpm(percent: pct, fan: $0)) })
        }
    }

    // Returns false when it handed the fans back to the system.
    private func control(now: TimeInterval) -> Bool {
        guard let desired = desiredRpm() else {
            if config.mode == .curve {
                if sensorMisses >= FanPolicy.sensorLossLimit { fail(.sensorLost); return false }
                if sensorMisses == 0 { fail(.writeFailed, "пустая кривая"); return false }
            }
            return true
        }
        let dt = lastControlAt.map { now - $0 } ?? FanPolicy.nominalTick
        lastControlAt = now
        var taken = false
        for fan in fans {
            guard let want = desired[fan.index] else { continue }
            let reading = readings.first { $0.index == fan.index }
            let prev = written[fan.index]
            if prev != nil, reading?.manual == false { taken = true }
            let current = targets[fan.index] ?? reading?.actual ?? fan.minRpm
            let next = FanPolicy.clamp(FanRamp.step(current: current, target: FanPolicy.clamp(want, fan: fan), dt: dt,
                                                    up: config.rampUp, down: config.rampDown), fan: fan)
            targets[fan.index] = next
            if taken || FanPolicy.shouldWrite(last: prev?.rpm, new: next, since: prev.map { now - $0.at }) {
                do { try applier.setRpm(index: fan.index, rpm: Int(next.rounded())) } catch {
                    fail(.writeFailed, "\(error)")
                    return false
                }
                written[fan.index] = (next, now)
            }
        }
        if taken {
            reclaims += 1
            if reclaims > FanPolicy.maxReclaims { fail(.reclaimed); return false }
        } else {
            reclaims = 0
        }
        return true
    }

    private func fail(_ kind: Fault.Kind, _ detail: String = "") {
        let fault = Fault(kind: kind, detail: detail)
        lastFault = fault
        config.mode = .auto
        store.save(config)
        resumeMode = nil
        restoreAuto()
        notify("Вентиляторы: управление возвращено системе", fault.message)
    }

    private func restoreAuto() {
        lastRestoreAttempt = clock.now
        var ok = false
        for _ in 0..<2 where !ok { ok = (try? applier.setAuto(index: nil)) != nil }
        if ok {
            store.dirty = false
            restorePending = false
            watchdog.disarm()
        } else {
            restorePending = true
            notify("Вентиляторы: не удалось вернуть управление системе",
                   "Повторяю. Вручную: sudo /usr/local/libexec/multitul-ctl smc fan-auto all")
        }
        if !fans.isEmpty, state != .stopped { state = .system }
        targets = [:]
        written = [:]
        lastControlAt = nil
        hysteresis.reset()
    }
}
