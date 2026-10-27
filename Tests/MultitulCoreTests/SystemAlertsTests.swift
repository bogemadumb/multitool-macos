import Testing
import Foundation
@testable import MultitulCore

@Suite struct SystemAlertsTests {
    let t0 = Date(timeIntervalSince1970: 5000)

    func snap(cpu: Double? = nil, temp: Double? = nil, pressure: MemoryPressure? = nil, freeFrac: Double? = nil,
              battery: Int? = nil, onAC: Bool = false, charging: Bool = false) -> LiveSnapshot {
        var s = LiveSnapshot()
        if let cpu { s.cpu = CPULoad(total: cpu, user: cpu, system: 0) }
        s.temps.cpu = temp
        if let pressure {
            s.memory = MemoryReading(composition: MemoryComposition(totalBytes: 1, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedBytes: 0, freeBytes: 0),
                                     swapUsedBytes: 0, swapTotalBytes: 0, pressure: pressure)
        }
        if let freeFrac {
            let total: UInt64 = 500_000_000_000
            s.disk = DiskReading(volumes: [DiskVolume(path: "/", name: "Macintosh HD", totalBytes: total, freeBytes: UInt64(Double(total) * freeFrac), isInternal: true, isEjectable: false)],
                                 readBps: 0, writeBps: 0, smart: .verified)
        }
        if let battery {
            var b = BatteryReading()
            b.hasBattery = true
            b.percent = battery
            b.onAC = onAC
            b.isCharging = charging
            s.battery = b
        }
        return s
    }

    @Test func sustainedGateNeedsContinuousExceedance() {
        var g = SustainedGate()
        let r0 = g.shouldAlert(value: 0.95, threshold: 0.9, now: t0, sustain: 12)
        #expect(!r0)
        let r1 = g.shouldAlert(value: 0.95, threshold: 0.9, now: t0.addingTimeInterval(11), sustain: 12)
        #expect(!r1)
        let r2 = g.shouldAlert(value: 0.95, threshold: 0.9, now: t0.addingTimeInterval(12), sustain: 12)
        #expect(r2)
        let r3 = g.shouldAlert(value: 0.5, threshold: 0.9, now: t0.addingTimeInterval(13), sustain: 12)
        #expect(!r3)
        let r4 = g.shouldAlert(value: 0.95, threshold: 0.9, now: t0.addingTimeInterval(14), sustain: 12)
        #expect(!r4)
        let r5 = g.shouldAlert(value: nil, threshold: 0.9, now: t0.addingTimeInterval(30), sustain: 12)
        #expect(!r5)
    }

    @Test func cooldownPerKind() {
        var c = AlertCooldown()
        let r6 = c.allow(.cpu, now: t0, cooldown: 1800)
        #expect(r6)
        let r7 = c.allow(.cpu, now: t0.addingTimeInterval(1799), cooldown: 1800)
        #expect(!r7)
        let r8 = c.allow(.memory, now: t0.addingTimeInterval(10), cooldown: 1800)
        #expect(r8)
        let r9 = c.allow(.cpu, now: t0.addingTimeInterval(1800), cooldown: 1800)
        #expect(r9)
    }

    @Test func nothingFiresWhenDisabled() {
        let e = AlertEngine(settings: AlertSettings())
        let s = snap(cpu: 1, temp: 100, pressure: .critical, freeFrac: 0.01, battery: 3)
        #expect(e.evaluate(s, now: t0).isEmpty)
        #expect(e.evaluate(s, now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test func cpuAlertAfterSustainThenCooldown() {
        var st = AlertSettings()
        st.enabled = [.cpu]
        let e = AlertEngine(settings: st)
        let hot = snap(cpu: 0.97)
        #expect(e.evaluate(hot, now: t0).isEmpty)
        #expect(e.evaluate(hot, now: t0.addingTimeInterval(6)).isEmpty)
        let fired = e.evaluate(hot, now: t0.addingTimeInterval(13))
        #expect(fired.map(\.kind) == [.cpu])
        #expect(e.evaluate(hot, now: t0.addingTimeInterval(20)).isEmpty)
        #expect(e.evaluate(hot, now: t0.addingTimeInterval(13 + 1800)).map(\.kind) == [.cpu])
    }

    @Test func memoryDiskBatteryAlerts() {
        var st = AlertSettings()
        st.enabled = [.memory, .disk, .battery]
        let e = AlertEngine(settings: st)
        let fired = e.evaluate(snap(pressure: .critical, freeFrac: 0.05, battery: 10), now: t0)
        #expect(Set(fired.map(\.kind)) == [.memory, .disk, .battery])
        let calm = AlertEngine(settings: st)
        #expect(calm.evaluate(snap(pressure: .warning, freeFrac: 0.4, battery: 60), now: t0).isEmpty)
    }

    @Test func batteryAlertIgnoresChargingAndAC() {
        var st = AlertSettings()
        st.enabled = [.battery]
        #expect(AlertEngine(settings: st).evaluate(snap(battery: 5, onAC: true), now: t0).isEmpty)
        #expect(AlertEngine(settings: st).evaluate(snap(battery: 5, charging: true), now: t0).isEmpty)
        #expect(AlertEngine(settings: st).evaluate(snap(battery: 16), now: t0).isEmpty)
    }

    @Test func diskAlertIgnoresSmallAndExternalVolumes() {
        var st = AlertSettings()
        st.enabled = [.disk]
        let e = AlertEngine(settings: st)
        var s = LiveSnapshot()
        s.disk = DiskReading(volumes: [
            DiskVolume(path: "/Volumes/USB", name: "USB", totalBytes: 64_000_000_000, freeBytes: 1000, isInternal: false, isEjectable: true),
            DiskVolume(path: "/Volumes/Tiny", name: "Tiny", totalBytes: 5_000_000_000, freeBytes: 1000, isInternal: true, isEjectable: false)
        ], readBps: 0, writeBps: 0, smart: .unknown)
        #expect(e.evaluate(s, now: t0).isEmpty)
    }

    @Test func settingsLoadClampsAndReadsToggles() {
        let d = InMemoryKeyValueStore()
        #expect(AlertSettings.load(from: d).enabled.isEmpty)
        d.set(true, forKey: AlertSettings.key(.cpu))
        d.set(true, forKey: AlertSettings.key(.disk))
        d.set(0.1, forKey: "monitor.alert.cpuThreshold")
        d.set(99, forKey: "monitor.alert.batteryPercent")
        d.set(0, forKey: "monitor.alert.cooldownMinutes")
        let s = AlertSettings.load(from: d)
        #expect(s.enabled == [.cpu, .disk])
        #expect(s.cpuThreshold == 0.5)
        #expect(s.batteryPercent == 50)
        #expect(s.cooldownMinutes == 1)
    }
}

@Suite struct MenuBarLayoutTests {
    @Test func defaultCoversAllMetricsExceptDevices() {
        let l = MenuBarLayout()
        #expect(l.items.map(\.metric) == [.cpu, .gpu, .memory, .network, .disk, .power])
        #expect(l.items.allSatisfy { !$0.visible })
        #expect(l.combined)
    }

    @Test func moveToggleStyle() {
        var l = MenuBarLayout()
        l.moveDown(.cpu)
        #expect(l.items.map(\.metric).prefix(2) == [.gpu, .cpu])
        l.moveUp(.power)
        #expect(l.items.last?.metric == .disk)
        l.moveUp(.gpu)
        #expect(l.items.first?.metric == .gpu)
        l.setVisible(.memory, true)
        l.setStyle(.memory, .graph)
        #expect(l.item(.memory) == MenuBarItem(metric: .memory, visible: true, style: .graph))
        l.move(from: 0, to: 99)
        #expect(l.items.first?.metric == .gpu)
    }

    @Test func shownFollowsEnabledModulesAndOrder() {
        var l = MenuBarLayout()
        l.setVisible(.cpu, true); l.setVisible(.network, true); l.setVisible(.power, true)
        l.moveUp(.network); l.moveUp(.network); l.moveUp(.network)
        #expect(l.shown(enabled: [.cpu, .network, .devices]).map(\.metric) == [.network, .cpu])
        #expect(l.shown(enabled: []).isEmpty)
    }

    @Test func roundTripAndTolerantDecode() {
        var l = MenuBarLayout(combined: false)
        l.setVisible(.disk, true)
        l.setStyle(.disk, .bar)
        l.moveUp(.disk)
        #expect(MenuBarLayout.decode(l.encoded()) == l)

        let json = #"{"combined":true,"items":[{"metric":"disk","visible":true,"style":"bar"},{"metric":"bogus","visible":true},{"metric":"disk"},{"metric":"devices","visible":true},{"metric":"cpu","visible":true,"style":"weird"}]}"#
        let d = MenuBarLayout.decode(Data(json.utf8))
        #expect(d.items.map(\.metric) == [.disk, .cpu, .gpu, .memory, .network, .power])
        #expect(d.item(.cpu)?.style == .number && d.item(.cpu)?.visible == true)
        #expect(MenuBarLayout.decode(nil) == MenuBarLayout())
        #expect(MenuBarLayout.decode(Data("junk".utf8)) == MenuBarLayout())
    }

    @Test func persistsInDefaults() {
        let d = InMemoryKeyValueStore()
        var l = MenuBarLayout()
        l.setVisible(.gpu, true)
        l.save(to: d)
        #expect(MenuBarLayout.load(from: d).item(.gpu)?.visible == true)
    }
}

@Suite struct MenuBarValuesTests {
    func history() -> NamedHistory {
        var h = NamedHistory(capacity: 10)
        for v in [10.0, 50, 100] { h.append(HistoryKey.cpu, v) }
        for v in [1024.0, 2048] { h.append(HistoryKey.netDown, v); h.append(HistoryKey.netUp, 512) }
        return h
    }

    @Test func cpuValueLevelAndSeries() {
        var s = LiveSnapshot()
        s.cpu = CPULoad(total: 0.37, user: 0.3, system: 0.07)
        let v = MenuBarValues.make(.cpu, snapshot: s, history: history())
        #expect(v.text == "37%" && v.level == .normal && v.fraction == 0.37)
        #expect(v.series == [0.1, 0.5, 1.0])
        s.cpu = CPULoad(total: 0.97, user: 0.9, system: 0.07)
        #expect(MenuBarValues.make(.cpu, snapshot: s, history: history()).level == .critical)
    }

    @Test func missingDataShowsDash() {
        let v = MenuBarValues.make(.gpu, snapshot: LiveSnapshot(), history: NamedHistory())
        #expect(v.text == "—" && v.fraction == nil && v.lines == ["—"])
    }

    @Test func networkTwoLinesAndUploadFirst() {
        var s = LiveSnapshot()
        s.network = NetworkReading(downBps: 1_572_864, upBps: 34_816, sessionDownBytes: 0, sessionUpBytes: 0, localIP: nil)
        let v = MenuBarValues.make(.network, snapshot: s, history: history())
        #expect(v.lines == ["↓1,5М", "↑34К"])
        let u = MenuBarValues.make(.network, snapshot: s, history: history(), uploadFirst: true)
        #expect(u.lines == ["↑34К", "↓1,5М"])
        #expect(v.series == [0.5, 1.0])
    }

    @Test func memoryPressureDrivesLevel() {
        var s = LiveSnapshot()
        let comp = MemoryComposition(totalBytes: 100, appBytes: 30, wiredBytes: 10, compressedBytes: 0, cachedBytes: 0, freeBytes: 60)
        s.memory = MemoryReading(composition: comp, swapUsedBytes: 0, swapTotalBytes: 0, pressure: .warning)
        let v = MenuBarValues.make(.memory, snapshot: s, history: NamedHistory())
        #expect(v.text == "40%" && v.level == .warn)
        s.memory?.pressure = .critical
        #expect(MenuBarValues.make(.memory, snapshot: s, history: NamedHistory()).level == .critical)
    }

    @Test func powerStates() {
        var s = LiveSnapshot()
        var b = BatteryReading()
        b.hasBattery = true; b.percent = 8
        s.battery = b
        let low = MenuBarValues.make(.power, snapshot: s, history: NamedHistory())
        #expect(low.text == "8%" && low.level == .critical)
        s.battery?.isCharging = true
        let ch = MenuBarValues.make(.power, snapshot: s, history: NamedHistory())
        #expect(ch.text == "⚡8%" && ch.level == .normal)
        s.battery = BatteryReading()
        #expect(MenuBarValues.make(.power, snapshot: s, history: NamedHistory()).text == "сеть")
    }

    @Test func diskShowsFreeSpace() {
        var s = LiveSnapshot()
        s.disk = DiskReading(volumes: [DiskVolume(path: "/", name: "HD", totalBytes: 500_000_000_000, freeBytes: 100_000_000_000, isInternal: true, isEjectable: false)],
                             readBps: 0, writeBps: 0, smart: .verified)
        let v = MenuBarValues.make(.disk, snapshot: s, history: NamedHistory())
        #expect(v.text == "100ГБ" && v.level == .normal)
        s.disk?.volumes[0].freeBytes = 60_000_000_000
        #expect(MenuBarValues.make(.disk, snapshot: s, history: NamedHistory()).level == .warn)
        s.disk?.volumes[0].freeBytes = 30_000_000_000
        #expect(MenuBarValues.make(.disk, snapshot: s, history: NamedHistory()).level == .critical)
    }

    @Test func networkQualityJson() {
        let json = #"{"dl_throughput": 93000000, "ul_throughput": 21000000, "base_rtt": 18.5, "responsiveness": 1200}"#
        #expect(SystemParsers.networkQuality(json) == SpeedTestResult(downMbps: 93, upMbps: 21, rttMs: 18.5))
        #expect(SystemParsers.networkQuality("not json") == nil)
        #expect(SystemParsers.networkQuality(#"{"a":1}"#) == nil)
    }
}
