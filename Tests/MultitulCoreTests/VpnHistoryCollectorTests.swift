import Testing
import Foundation
@testable import MultitulCore

final class FakeHistorySource: VpnHistorySource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reading = VpnHistoryReading(daemonRunning: true, apiOK: true, delayMs: 40)
    private var _reads = 0
    var reading: VpnHistoryReading {
        get { lock.lock(); defer { lock.unlock() }; return _reading }
        set { lock.lock(); _reading = newValue; lock.unlock() }
    }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    func read() -> VpnHistoryReading {
        lock.lock(); defer { lock.unlock() }
        _reads += 1
        return _reading
    }
}

final class DateBox: @unchecked Sendable {
    var date: Date
    init(_ d: Date) { date = d }
    func advance(_ s: TimeInterval) { date = date.addingTimeInterval(s) }
}

@Suite struct VpnHistoryCollectorTests {
    let t0 = Date(timeIntervalSince1970: 1_792_627_200 + 36000)

    private func snap(_ id: String, _ p: String, _ via: String, _ d: Double, _ u: Double) -> VpnConnSnap {
        VpnConnSnap(id: id, process: p, via: via, down: d, up: u)
    }

    private func rig(enabled: @escaping () -> Bool = { true }) throws -> (VpnHistoryCollector, FakeHistorySource, DateBox, Store, VpnHistoryStore) {
        let src = FakeHistorySource()
        let box = DateBox(t0)
        let col = VpnHistoryCollector(source: src, calendar: utcCalendar(), isEnabled: enabled, now: { box.date })
        let store = try VpnHistorySchema.openStore(path: tempDBPath())
        return (col, src, box, store, VpnHistoryStore(store: store, calendar: utcCalendar()))
    }

    @Test func declaresTenSecondIntervalAndRetention() {
        let col = VpnHistoryCollector(source: FakeHistorySource())
        #expect(col.id == "vpn.history" && col.interval == 10)
        #expect(col.migrations.map(\.scope) == ["vpn"])
        #expect(col.retention == VpnHistorySchema.retention)
    }

    @Test func agentRegistryIncludesVpnHistory() {
        let ids = CollectorRegistry.standard().collectors.map(\.id)
        #expect(ids.contains("vpn.history") && ids.contains("heartbeat") && ids.contains("maintenance"))
    }

    @Test func writesSampleWithStateAndPing() throws {
        let (col, _, _, store, h) = try rig()
        try col.collect(store: store)
        #expect(h.sampleCount() == 1)
        let r = try store.query("SELECT ts, delay_ms, state, down_bps FROM vpn_samples").first!
        #expect(r.int(0) == Int64(t0.timeIntervalSince1970) && r.int(1) == 40 && r.string(2) == "ok" && r.double(3) == 0)
    }

    @Test func speedIsDeltaPerSecondAndTrafficAccumulates() throws {
        let (col, src, box, store, h) = try rig()
        src.reading.conns = [snap("1", "safari", "vps", 1000, 100)]
        try col.collect(store: store)
        box.advance(10)
        src.reading.conns = [snap("1", "safari", "vps", 6000, 600), snap("2", "curl", "direct", 2000, 0)]
        try col.collect(store: store)
        let last = try store.query("SELECT down_bps, up_bps FROM vpn_samples ORDER BY ts DESC LIMIT 1").first!
        #expect(last.double(0) == 700 && last.double(1) == 50)
        let rows = h.trafficRows(day: t0, limit: 5)
        #expect(rows.map(\.process) == ["safari", "curl"])
        #expect(rows[0].vps == 5500 && rows[1].direct == 2000)
    }

    @Test func stateMachineProgressesWithFakeClock() throws {
        let (col, src, box, store, h) = try rig()
        for _ in 0..<2 { try col.collect(store: store); box.advance(10) }
        #expect(col.lastState == .ok)
        src.reading = VpnHistoryReading(daemonRunning: true, apiOK: false)
        for _ in 0..<8 { box.advance(10); try col.collect(store: store) }
        #expect(col.lastState == .down)
        src.reading = VpnHistoryReading(daemonRunning: false, apiOK: false)
        box.advance(10)
        try col.collect(store: store)
        #expect(col.lastState == .off)
        let states = try store.query("SELECT state FROM vpn_samples ORDER BY ts").compactMap { $0.string(0) }
        #expect(states.first == "ok" && states.contains("down") && states.last == "off")
        #expect(h.series(.hour, now: box.date).compactMap { $0 }.contains { $0.drop })
    }

    @Test func slowPingMarksSlowAfterTwoReadings() throws {
        let (col, src, box, store, _) = try rig()
        try col.collect(store: store)
        box.advance(10)
        src.reading.delayMs = 900
        try col.collect(store: store)
        #expect(col.lastState == .ok)
        box.advance(10)
        try col.collect(store: store)
        box.advance(10)
        try col.collect(store: store)
        #expect(col.lastState == .slow)
    }

    @Test func unavailableSourceWritesNothingAndResetsClock() throws {
        let (col, src, box, store, h) = try rig()
        src.reading = VpnHistoryReading(available: false, daemonRunning: false, apiOK: false)
        try col.collect(store: store)
        #expect(h.sampleCount() == 0)
        src.reading = VpnHistoryReading(daemonRunning: true, apiOK: true, delayMs: 30, conns: [snap("1", "a", "vps", 1_000_000, 0)])
        box.advance(600)
        try col.collect(store: store)
        let r = try store.query("SELECT down_bps FROM vpn_samples").first!
        #expect(r.double(0) == 0)
        #expect(h.trafficRowCount() == 0)
    }

    @Test func disabledModuleSkipsReadingEntirely() throws {
        var on = false
        let (col, src, _, store, h) = try rig(enabled: { on })
        try col.collect(store: store)
        #expect(src.reads == 0 && h.sampleCount() == 0)
        on = true
        try col.collect(store: store)
        #expect(src.reads == 1 && h.sampleCount() == 1)
    }

    @Test func schedulerRunsEveryTenSecondsAndAppliesRetention() throws {
        let src = FakeHistorySource()
        let box = DateBox(t0)
        let clock = FakeClock()
        let col = VpnHistoryCollector(source: src, calendar: utcCalendar(), now: { box.date })
        let store = try Store(path: tempDBPath())
        let sched = CollectorScheduler(store: store, collectors: [col], clock: clock)
        try sched.start()
        for _ in 0..<6 {
            sched.tick()
            clock.now += 10
            box.advance(10)
        }
        let h = VpnHistoryStore(store: store, calendar: utcCalendar())
        #expect(h.sampleCount() == 6)
        clock.now -= 5
        #expect(sched.tick().isEmpty)
        try h.insertSample(ts: t0.addingTimeInterval(-40 * 86400), down: 0, up: 0, delay: nil, state: "ok")
        let del = try store.cleanup(now: box.date)
        #expect(del["vpn_samples"] == 1 && h.sampleCount() == 6)
    }
}
