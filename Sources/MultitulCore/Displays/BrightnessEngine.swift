import Foundation

public protocol BrightnessBackend: AnyObject {
    var method: BrightnessMethod { get }
    func probe() -> Bool
    func read() -> Double?
    func write(_ value: Double) -> Bool
    func release()
}

public protocol PowerBackend: AnyObject {
    func setPower(_ on: Bool) -> Bool
}

public protocol ContrastBackend: AnyObject {
    func readContrast() -> Double?
    func writeContrast(_ value: Double) -> Bool
}

public protocol BrightnessBackendFactory: AnyObject {
    func prepare(_ displays: [DisplaySnapshot])
    func candidates(for display: DisplaySnapshot, forceSoftware: Bool, softwareFloor: Double) -> [BrightnessBackend]
}

public struct BrightnessRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var cgID: UInt32
    public var name: String
    public var isBuiltin: Bool
    public var method: BrightnessMethod
    public var value: Double
    public var contrast: Double?
    public var canPower: Bool
    public var forcedSoftware: Bool
}

public final class BrightnessEngine {
    private final class Slot {
        var snapshot: DisplaySnapshot
        var backend: BrightnessBackend?
        var method: BrightnessMethod = .unavailable
        var value = 1.0
        var contrast: Double?
        var coalescer: WriteCoalescer<Double>
        var failures = 0
        var demoted = false

        init(snapshot: DisplaySnapshot, interval: TimeInterval) {
            self.snapshot = snapshot
            coalescer = WriteCoalescer(minInterval: interval)
        }
    }

    public static let failuresBeforeFallback = 3

    private let store: BrightnessStore
    private let factory: BrightnessBackendFactory
    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    public var settings: BrightnessSettings

    public init(store: BrightnessStore, factory: BrightnessBackendFactory, settings: BrightnessSettings = BrightnessSettings()) {
        self.store = store
        self.factory = factory
        self.settings = settings
    }

    static func interval(for method: BrightnessMethod) -> TimeInterval {
        switch method {
        case .ddc: 0.12
        case .builtin, .software: 0.02
        case .unavailable: 0
        }
    }

    public var rows: [BrightnessRow] {
        order.compactMap { id in
            guard let s = slots[id] else { return nil }
            return BrightnessRow(id: id, cgID: s.snapshot.cgID, name: s.snapshot.name, isBuiltin: s.snapshot.isBuiltin, method: s.method, value: s.value,
                                 contrast: s.contrast, canPower: s.backend is PowerBackend, forcedSoftware: store.forceSoftware(for: id))
        }
    }

    public var controllable: Set<UInt32> {
        Set(slots.values.filter { $0.method != .unavailable }.map { $0.snapshot.cgID })
    }

    public var snapshots: [DisplaySnapshot] { order.compactMap { slots[$0]?.snapshot } }

    public func id(forCG cgID: UInt32) -> String? { order.first { slots[$0]?.snapshot.cgID == cgID } }

    public func reconcile(_ snaps: [DisplaySnapshot], now: Date = Date()) {
        let ids = BrightnessIDs.assign(snaps.map(\.identity))
        factory.prepare(snaps)
        for id in order where !ids.contains(id) { slots[id]?.backend?.release(); slots[id] = nil }
        order = ids
        for (id, snap) in zip(ids, snaps) {
            if let slot = slots[id], slot.snapshot.cgID == snap.cgID {
                slot.snapshot = snap
                if slot.method == .software { _ = slot.backend?.write(slot.value) }
                continue
            }
            slots[id]?.backend?.release()
            let slot = Slot(snapshot: snap, interval: 0)
            slots[id] = slot
            build(slot, id: id)
        }
    }

    private func build(_ slot: Slot, id: String) {
        slot.backend?.release()
        slot.backend = nil
        slot.method = .unavailable
        slot.failures = 0
        let force = store.forceSoftware(for: id) || slot.demoted
        for candidate in factory.candidates(for: slot.snapshot, forceSoftware: force, softwareFloor: settings.softwareFloor) where candidate.probe() {
            slot.backend = candidate
            slot.method = candidate.method
            break
        }
        slot.coalescer = WriteCoalescer(minInterval: Self.interval(for: slot.method))
        let saved = store.value(for: id)
        if slot.method == .software {
            slot.value = saved ?? 1.0
            _ = slot.backend?.write(slot.value)
        } else {
            slot.value = slot.backend?.read().map(BrightnessStep.clamp) ?? saved ?? 1.0
        }
        if let c = slot.backend as? ContrastBackend { slot.contrast = c.readContrast().map(BrightnessStep.clamp) ?? store.contrast(for: id) }
        slot.coalescer.markSent(slot.value, now: Date.distantPast)
    }

    @discardableResult
    public func set(id: String, value: Double, now: Date = Date()) -> Double? {
        guard let slot = slots[id], slot.method != .unavailable else { return nil }
        let v = BrightnessStep.clamp(value)
        slot.value = v
        store.setValue(v, for: id)
        if let out = slot.coalescer.submit(v, now: now) { perform(slot, id: id, value: out, now: now) }
        return v
    }

    @discardableResult
    public func adjust(cgID: UInt32, up: Bool, fine: Bool, now: Date = Date()) -> BrightnessRow? {
        guard let id = id(forCG: cgID), let slot = slots[id] else { return nil }
        set(id: id, value: BrightnessStep.next(slot.value, up: up, fine: fine), now: now)
        return rows.first { $0.id == id }
    }

    private func perform(_ slot: Slot, id: String, value: Double, now: Date) {
        guard let backend = slot.backend else { return }
        if backend.write(value) {
            slot.failures = 0
            return
        }
        slot.failures += 1
        if slot.failures >= Self.failuresBeforeFallback, slot.method == .ddc || slot.method == .builtin, !slot.demoted {
            slot.demoted = true
            let keep = slot.value
            build(slot, id: id)
            slot.value = keep
            _ = slot.backend?.write(keep)
        }
    }

    // Returns how long until the next queued write is due, nil when nothing waits.
    @discardableResult
    public func flush(now: Date = Date()) -> TimeInterval? {
        var wait: TimeInterval?
        for id in order {
            guard let slot = slots[id] else { continue }
            if let v = slot.coalescer.flushDue(now: now) { perform(slot, id: id, value: v, now: now) }
            if let w = slot.coalescer.waitTime(now: now) { wait = min(wait ?? w, w) }
        }
        return wait
    }

    @discardableResult
    public func setContrast(id: String, value: Double) -> Bool {
        guard let slot = slots[id], let c = slot.backend as? ContrastBackend else { return false }
        let v = BrightnessStep.clamp(value)
        slot.contrast = v
        store.setContrast(v, for: id)
        return c.writeContrast(v)
    }

    @discardableResult
    public func setPower(id: String, on: Bool) -> Bool {
        guard let p = slots[id]?.backend as? PowerBackend else { return false }
        return p.setPower(on)
    }

    public func setForceSoftware(id: String, _ on: Bool) {
        store.setForceSoftware(on, for: id)
        guard let slot = slots[id] else { return }
        slot.demoted = false
        build(slot, id: id)
    }

    public func releaseAll() {
        for slot in slots.values { slot.backend?.release() }
        slots.removeAll()
        order.removeAll()
    }
}

public protocol KeyboardBacklighting: AnyObject {
    var isAvailable: Bool { get }
    func level() -> Double?
    func setLevel(_ v: Double) -> Bool
}

public enum KeyboardBacklightLogic {
    public static let defaultOnLevel = 0.5

    public static func onLevel(lastNonZero: Double?) -> Double {
        guard let l = lastNonZero, l > 0 else { return defaultOnLevel }
        return min(l, 1)
    }

    public static func next(current: Double, up: Bool, fine: Bool) -> Double {
        BrightnessStep.next(current, up: up, fine: fine)
    }
}
