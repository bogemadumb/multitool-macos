import Foundation

public struct LiveFrame: Sendable {
    public var snapshot: LiveSnapshot
    public var processes: [ProcRow]
    public var netProcesses: [NetProcRow]
    public var unsafeRemovals: [String]
}

public final class LiveSampler: @unchecked Sendable {
    public typealias Handler = @Sendable (LiveFrame) -> Void

    private let queue = DispatchQueue(label: "dev.multitool.app.live", qos: .utility)
    private let slowQueue = DispatchQueue(label: "dev.multitool.app.live.slow", qos: .utility)
    private let handler: Handler
    private var timer: DispatchSourceTimer?
    private var enabled: Set<SystemMetric> = []
    private var wantProcesses = false
    private var interval: TimeInterval = 2

    private var snap = LiveSnapshot()
    private var prevCore: [CPUTicks] = []
    private var netPrev: (inB: UInt64, outB: UInt64, at: TimeInterval)?
    private var netBase: (inB: UInt64, outB: UInt64)?
    private var diskPrev: (r: UInt64, w: UInt64, at: TimeInterval)?
    private var lastVolumes: TimeInterval = -1000
    private var lastSmart: TimeInterval = -1000
    private var lastPower: TimeInterval = -1000
    private var lastDevices: TimeInterval = -1000
    private var lastTemps: TimeInterval = -1000
    private var lastIP: TimeInterval = -1000
    private var removal = UnsafeRemovalDetector(grace: 30)
    private var pendingRemovals: [String] = []
    private var unmountNotes: [(String, Date)] = []
    private let probe = TemperatureProbe()

    private let slowLock = NSLock()
    private var slowProcs: [ProcRow] = []
    private var slowNet: [NetProcRow] = []
    private var slowSmart: SmartStatus = .unknown
    private var procTracker = ProcessCPUTracker()
    private var netRates = CounterRate()
    private var procBusy = false
    private var netBusy = false
    private var smartBusy = false
    private var lastProcs: TimeInterval = -1000
    private var lastNettop: TimeInterval = -1000

    public init(handler: @escaping Handler) { self.handler = handler }

    public func configure(enabled: Set<SystemMetric>, wantProcesses: Bool, interval: TimeInterval) {
        queue.async { [self] in
            let removed = self.enabled.subtracting(enabled)
            self.enabled = enabled
            self.wantProcesses = wantProcesses
            for m in removed { reset(m) }
            if enabled.isEmpty { stopTimer(); return }
            if timer == nil || interval != self.interval {
                self.interval = interval
                startTimer()
            }
        }
    }

    public func noteUnmount(path: String) {
        queue.async { [self] in removal.noteUnmount(path, at: Date()) }
    }

    public func stop() {
        queue.sync { stopTimer(); enabled = [] }
    }

    private func reset(_ m: SystemMetric) {
        switch m {
        case .cpu: prevCore = []; snap.cpu = nil; snap.perCore = []; snap.temps.cpu = nil
        case .gpu: snap.gpu = nil; snap.temps.gpu = nil
        case .memory: snap.memory = nil
        case .network: netPrev = nil; netBase = nil; snap.network = nil
        case .disk: diskPrev = nil; snap.disk = nil
        case .power: snap.battery = nil; snap.temps.battery = nil; lastPower = -1000
        case .devices: snap.devices = []; lastDevices = -1000
        }
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        snap.at = Date()
        snap.thermalState = ProcessInfo.processInfo.thermalState.rawValue

        if enabled.contains(.cpu) {
            let cur = CPUReader.perCoreTicks()
            if !prevCore.isEmpty {
                let loads = CPUMath.loads(prev: prevCore, cur: cur)
                if !loads.isEmpty { snap.perCore = loads; snap.cpu = CPUMath.average(loads) }
            }
            prevCore = cur
        }
        if enabled.contains(.gpu) { snap.gpu = GPUReader.read() }
        if enabled.contains(.memory) { snap.memory = MemoryReader.read() }
        if enabled.contains(.network) { sampleNetwork(now) }
        if enabled.contains(.disk) { sampleDisk(now) }
        if enabled.contains(.power), now - lastPower >= 5 {
            lastPower = now
            snap.battery = PowerReader.read()
        }
        if enabled.contains(.devices), now - lastDevices >= 3 {
            lastDevices = now
            snap.devices = USBReader.devices()
        }
        if !enabled.isDisjoint(with: [.cpu, .gpu, .power]), now - lastTemps >= 3 {
            lastTemps = now
            let t = probe.read()
            if enabled.contains(.cpu) { snap.temps.cpu = t.cpu }
            if enabled.contains(.gpu) { snap.temps.gpu = t.gpu }
            if enabled.contains(.power) { snap.temps.battery = t.battery }
        }
        if wantProcesses { kickProcesses(now) }

        slowLock.lock()
        var procs = slowProcs
        let netp = slowNet
        if enabled.contains(.disk), var d = snap.disk { d.smart = slowSmart; snap.disk = d }
        slowLock.unlock()
        if !netp.isEmpty {
            let byPid = Dictionary(netp.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for i in procs.indices {
                if let n = byPid[procs[i].pid] { procs[i].netDownBps = n.downBps; procs[i].netUpBps = n.upBps }
            }
        }
        let frame = LiveFrame(snapshot: snap, processes: wantProcesses ? procs : [], netProcesses: netp, unsafeRemovals: pendingRemovals)
        pendingRemovals = []
        let h = handler
        DispatchQueue.main.async { h(frame) }
    }

    private func sampleNetwork(_ now: TimeInterval) {
        guard let c = NetworkReader.counters() else { return }
        if netBase == nil { netBase = (c.inBytes, c.outBytes) }
        var down = 0.0
        var up = 0.0
        if let p = netPrev {
            let dt = now - p.at
            down = RateMath.rate(prev: p.inB, cur: c.inBytes, dt: dt)
            up = RateMath.rate(prev: p.outB, cur: c.outBytes, dt: dt)
        }
        netPrev = (c.inBytes, c.outBytes, now)
        var ip = snap.network?.localIP
        if now - lastIP >= 10 || snap.network == nil {
            lastIP = now
            ip = NetworkReader.localIP()
        }
        let base = netBase ?? (c.inBytes, c.outBytes)
        snap.network = NetworkReading(downBps: down, upBps: up,
                                      sessionDownBytes: c.inBytes >= base.inB ? c.inBytes - base.inB : 0,
                                      sessionUpBytes: c.outBytes >= base.outB ? c.outBytes - base.outB : 0, localIP: ip)
    }

    private func sampleDisk(_ now: TimeInterval) {
        var volumes = snap.disk?.volumes ?? []
        if now - lastVolumes >= 10 || snap.disk == nil {
            lastVolumes = now
            volumes = DiskReader.volumes()
            let external = Set(volumes.filter { !$0.isInternal || $0.isEjectable }.map(\.path))
            pendingRemovals += removal.update(externalPaths: external, now: Date())
        }
        let io = DiskReader.ioTotals()
        var r = 0.0
        var w = 0.0
        if let p = diskPrev {
            let dt = now - p.at
            r = RateMath.rate(prev: p.r, cur: io.read, dt: dt)
            w = RateMath.rate(prev: p.w, cur: io.write, dt: dt)
        }
        diskPrev = (io.read, io.write, now)
        slowLock.lock()
        let sBusy = smartBusy
        slowLock.unlock()
        if now - lastSmart >= 600, !sBusy {
            lastSmart = now
            slowLock.lock(); smartBusy = true; slowLock.unlock()
            slowQueue.async { [self] in
                let s = DiskReader.smart()
                slowLock.lock(); slowSmart = s; smartBusy = false; slowLock.unlock()
            }
        }
        snap.disk = DiskReading(volumes: volumes, readBps: r, writeBps: w, smart: snap.disk?.smart ?? .unknown)
    }

    private func kickProcesses(_ now: TimeInterval) {
        slowLock.lock()
        let pBusy = procBusy
        let nBusy = netBusy
        slowLock.unlock()
        if now - lastProcs >= 3, !pBusy {
            lastProcs = now
            slowLock.lock(); procBusy = true; slowLock.unlock()
            slowQueue.async { [self] in
                let raw = SystemParsers.ps(ToolRunner.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,time=,comm="], timeout: 10))
                let at = ProcessInfo.processInfo.systemUptime
                let rows = procTracker.update(raw, at: at)
                slowLock.lock()
                if let rows { slowProcs = rows }
                procBusy = false
                slowLock.unlock()
            }
        }
        if enabled.contains(.network), now - lastNettop >= 5, !nBusy {
            lastNettop = now
            slowLock.lock(); netBusy = true; slowLock.unlock()
            slowQueue.async { [self] in
                let text = ToolRunner.run("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 10)
                let counters = SystemParsers.nettop(text)
                let at = ProcessInfo.processInfo.systemUptime
                var inMap: [String: UInt64] = [:]
                var outMap: [String: UInt64] = [:]
                var names: [Int32: String] = [:]
                for c in counters {
                    inMap["i\(c.pid)"] = c.bytesIn
                    outMap["o\(c.pid)"] = c.bytesOut
                    names[c.pid] = c.name
                }
                var merged = inMap
                merged.merge(outMap) { a, _ in a }
                let rates = netRates.update(merged, at: at)
                let rows: [NetProcRow] = names.map { pid, name in
                    NetProcRow(pid: pid, name: name, downBps: rates["i\(pid)"] ?? 0, upBps: rates["o\(pid)"] ?? 0)
                }.filter { $0.total > 0 }.sorted { $0.total > $1.total }
                slowLock.lock()
                slowNet = rows
                netBusy = false
                slowLock.unlock()
            }
        }
    }
}
