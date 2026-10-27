import Foundation
import MultitulCtlCore
@testable import MultitulCore

final class FanFakeClock: FanClock {
    var now: TimeInterval = 1000
    func advance(_ s: TimeInterval) { now += s }
}

struct FanFakeError: Error, CustomStringConvertible {
    var description: String { "fake failure" }
}

final class FanFakeHardware: FanHardware {
    var detection: FanDetection
    var actual: [Int: Double] = [:]
    var target: [Int: Double] = [:]
    var manual: Set<Int> = []
    var readFailures = 0
    var readsAlwaysFail = false
    var thermal: FanThermal? = FanThermal(cpu: [50], gpu: [45])
    var detectCalls = 0
    var readCalls = 0
    var thermalCalls = 0
    var reclaimOnRead = false

    init(fans: [FanInfo]) {
        detection = .fans(fans)
        for f in fans { actual[f.index] = 1300; target[f.index] = f.minRpm }
    }

    var infos: [FanInfo] { if case .fans(let f) = detection { return f }; return [] }

    func detect() -> FanDetection { detectCalls += 1; return detection }

    func readFans() -> [FanReading]? {
        readCalls += 1
        if readsAlwaysFail { return nil }
        if readFailures > 0 { readFailures -= 1; return nil }
        if reclaimOnRead { manual = [] }
        return infos.map { FanReading(index: $0.index, actual: actual[$0.index] ?? 0, target: target[$0.index] ?? 0, manual: manual.contains($0.index)) }
    }

    func readThermal() -> FanThermal? { thermalCalls += 1; return thermal }
}

final class FanFakeApplier: FanApplying {
    var calls: [String] = []
    var rpmWrites: [(index: Int, rpm: Int)] = []
    var autoCalls: Int { calls.filter { $0.hasPrefix("auto") }.count }
    var failRpm = false
    var failAutoCount = 0
    weak var hardware: FanFakeHardware?

    func setAuto(index: Int?) throws {
        calls.append("auto:" + (index.map(String.init) ?? "all"))
        if failAutoCount > 0 { failAutoCount -= 1; throw FanFakeError() }
        if let index { hardware?.manual.remove(index) } else { hardware?.manual = [] }
    }

    func setRpm(index: Int, rpm: Int) throws {
        calls.append("rpm:\(index):\(rpm)")
        if failRpm { throw FanFakeError() }
        rpmWrites.append((index, rpm))
        hardware?.manual.insert(index)
        hardware?.target[index] = Double(rpm)
    }
}

final class FanNotes {
    var items: [(String, String)] = []
}

final class FanRig {
    let clock = FanFakeClock()
    let hw: FanFakeHardware
    let applier = FanFakeApplier()
    let kv = WndMemoryStore()
    let store: FanSettingsStore
    let notes = FanNotes()
    var thermalLevel = 0
    private(set) var engine: FanEngine!

    static let one = [FanInfo(index: 0, minRpm: 1200, maxRpm: 6000)]
    static let two = [FanInfo(index: 0, minRpm: 1200, maxRpm: 6000), FanInfo(index: 1, minRpm: 1000, maxRpm: 5000)]

    init(fans: [FanInfo] = FanRig.one, start: Bool = true, config: ((inout FanConfig) -> Void)? = nil, configure: ((FanSettingsStore) -> Void)? = nil) {
        hw = FanFakeHardware(fans: fans)
        applier.hardware = hw
        store = FanSettingsStore(kv)
        var c = FanConfig()
        c.rampUp = 0
        c.rampDown = 0
        config?(&c)
        store.save(c)
        configure?(store)
        makeEngine()
        if start { engine.start() }
    }

    func makeEngine() {
        engine = FanEngine(hardware: hw, applier: applier, store: store, clock: clock, thermalState: { [unowned self] in thermalLevel },
                           notify: { [notes] t, b in notes.items.append((t, b)) })
    }

    func tick(_ dt: TimeInterval = 2) {
        clock.advance(dt)
        engine.tick()
    }

    func temp(_ t: Double) { hw.thermal = FanThermal(cpu: [t], gpu: [t]) }

    var lastRpm: Int? { applier.rpmWrites.last?.rpm }
}
