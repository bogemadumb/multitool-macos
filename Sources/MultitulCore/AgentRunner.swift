import Foundation

public enum AgentRunner {
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var scheduler: CollectorScheduler?
    nonisolated(unsafe) private static var store: Store?
    nonisolated(unsafe) private static var lock: PidLock?

    public static let queue = DispatchQueue(label: "dev.multitool.app.agent")

    public static func run(registry: CollectorRegistry? = nil) -> Never {
        guard let pidLock = PidLock.acquire() else {
            let other = PidLock.holderPID().map(String.init) ?? "?"
            Log.write("agent: another agent holds the lock (pid \(other)), exiting")
            FileHandle.standardError.write(Data("multitul agent: already running (pid \(other))\n".utf8))
            exit(0)
        }
        lock = pidLock
        let store: Store
        do { store = try Store() } catch {
            Log.write("agent: cannot open store: \(error)")
            FileHandle.standardError.write(Data("multitul agent: cannot open store: \(error)\n".utf8))
            exit(1)
        }
        let reg = registry ?? CollectorRegistry.standard()
        let sched = CollectorScheduler(store: store, collectors: reg.collectors)
        do { try sched.start() } catch {
            Log.write("agent: scheduler start failed: \(error)")
            exit(1)
        }
        Self.store = store
        Self.scheduler = sched

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { shutdown(reason: sig == SIGTERM ? "SIGTERM" : "SIGINT") }
            src.resume()
            signalSources.append(src)
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { fire() }
        timer = t
        t.schedule(deadline: .now())
        t.resume()
        Log.write("agent: started pid=\(getpid()) collectors=\(reg.collectors.map(\.id))")
        dispatchMain()
    }

    private static func fire() {
        guard let sched = scheduler else { return }
        sched.tick()
        let wait = min(max(sched.secondsUntilNextDue() ?? 1, 0.05), 5)
        timer?.schedule(deadline: .now() + wait)
    }

    private static func shutdown(reason: String) {
        timer?.cancel()
        timer = nil
        scheduler = nil
        store = nil
        lock?.release()
        lock = nil
        Log.write("agent: stopping on \(reason)")
        exit(0)
    }
}
