import Foundation
import CoreAudio
import Darwin
@testable import MultitulCore

enum MixSig {
    static func sine(_ freq: Double, amp: Float = 1, sr: Double = 48_000, frames: Int, phase: Double = 0) -> [Float] {
        (0..<frames).map { Float(Double(amp) * sin(2 * Double.pi * freq * Double($0) / sr + phase)) }
    }

    static func noise(seed: UInt64 = 1, amp: Float = 1, frames: Int) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            return Float((u * 2 - 1) * Double(amp))
        }
    }

    static func impulse(at index: Int, amp: Float = 1, frames: Int) -> [Float] {
        var x = [Float](repeating: 0, count: frames)
        if index < frames { x[index] = amp }
        return x
    }

    static func constant(_ v: Float, frames: Int) -> [Float] { [Float](repeating: v, count: frames) }

    static func peak(_ x: [Float]) -> Float { x.map { abs($0) }.max() ?? 0 }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot().asFloat
    }

    static func db(_ x: Double) -> Double { MixGain.linearToDb(x) }
}

extension Double { var asFloat: Float { Float(self) } }

final class MixPlanes {
    let channels: Int
    let frames: Int
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let storage: UnsafeMutablePointer<Float>

    init(_ data: [[Float]]) {
        channels = data.count
        frames = data.first?.count ?? 0
        storage = .allocate(capacity: max(channels * frames, 1))
        pointers = .allocate(capacity: max(channels, 1))
        for c in 0..<channels {
            pointers[c] = storage + c * frames
            for i in 0..<frames { pointers[c][i] = data[c][i] }
        }
    }

    deinit {
        storage.deallocate()
        pointers.deallocate()
    }

    func read() -> [[Float]] { (0..<channels).map { c in (0..<frames).map { pointers[c][$0] } } }
}

final class MixABL {
    let list: UnsafeMutableAudioBufferListPointer
    let channels: Int
    let frames: Int
    let interleaved: Bool
    private var blocks: [UnsafeMutablePointer<Float>] = []

    init(channels: Int, frames: Int, interleaved: Bool) {
        self.channels = channels
        self.frames = frames
        self.interleaved = interleaved
        let count = interleaved ? 1 : channels
        list = AudioBufferList.allocate(maximumBuffers: max(count, 1))
        for b in 0..<count {
            let nc = interleaved ? channels : 1
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(frames * nc, 1))
            p.initialize(repeating: 0, count: max(frames * nc, 1))
            blocks.append(p)
            list[b] = AudioBuffer(mNumberChannels: UInt32(nc), mDataByteSize: UInt32(frames * nc * 4), mData: UnsafeMutableRawPointer(p))
        }
    }

    deinit {
        for b in blocks { b.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

    func fill(_ data: [[Float]], offset: Int = 0, count: Int? = nil) {
        let n = count ?? frames
        for c in 0..<channels {
            for i in 0..<n {
                let v = c < data.count && offset + i < data[c].count ? data[c][offset + i] : 0
                if interleaved { blocks[0][i * channels + c] = v } else { blocks[c][i] = v }
            }
        }
    }

    func setAll(_ v: Float) {
        for b in 0..<blocks.count {
            let nc = interleaved ? channels : 1
            for i in 0..<(frames * nc) { blocks[b][i] = v }
        }
    }

    func read() -> [[Float]] {
        (0..<channels).map { c in (0..<frames).map { i in interleaved ? blocks[0][i * channels + c] : blocks[c][i] } }
    }
}

enum MixRun {
    static func process(_ p: MixProcessor, input: [[Float]], outChannels: Int? = nil, inInterleaved: Bool = false, outInterleaved: Bool = false, block: Int = 512) -> [[Float]] {
        let frames = input.first?.count ?? 0
        let outCh = outChannels ?? input.count
        var out = [[Float]](repeating: [], count: outCh)
        var start = 0
        while start < frames {
            let n = min(block, frames - start)
            let i = MixABL(channels: input.count, frames: n, interleaved: inInterleaved)
            let o = MixABL(channels: outCh, frames: n, interleaved: outInterleaved)
            i.fill(input, offset: start, count: n)
            p.process(input: UnsafePointer(i.pointer), output: o.pointer)
            let r = o.read()
            for c in 0..<outCh { out[c].append(contentsOf: r[c]) }
            start += n
        }
        return out
    }
}

typealias MixLoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
let mixProbeState: UnsafeMutablePointer<Int> = {
    let p = UnsafeMutablePointer<Int>.allocate(capacity: 2)
    p.initialize(repeating: 0, count: 2)
    return p
}()

enum MixAllocProbe {
    private static func slot() -> UnsafeMutablePointer<MixLoggerFn?>? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return sym.assumingMemoryBound(to: MixLoggerFn?.self)
    }

    static var available: Bool { slot() != nil }

    // Counts malloc/free events made by the calling thread while `body` runs; nil if the hook is not reachable.
    static func count(_ body: () -> Void) -> Int? {
        guard let s = slot() else { return nil }
        let state = mixProbeState
        let previous = s.pointee
        state[1] = 0
        state[0] = Int(bitPattern: pthread_self())
        let logger: MixLoggerFn = { _, _, _, _, _, _ in
            let st = mixProbeState
            if st[0] == Int(bitPattern: pthread_self()) { st[1] += 1 }
        }
        s.pointee = logger
        body()
        s.pointee = previous
        state[0] = 0
        return state[1]
    }
}

final class MixFakeDriver: MixDriving {
    var procs: [MixProcessInfo] = []
    var apps: [MixRunningApp] = []
    var created: [MixDesiredTap] = []
    var destroyed: [String] = []
    var updates: [(String, MixParams)] = []
    var destroyAllCalls = 0
    var failures: [String: MixTapError] = [:]
    var aggregates: [MixAggregateInfo] = []
    var taps: [MixTapInfo] = []
    var destroyedAggregates: [UInt32] = []
    var destroyedTaps: [UInt32] = []
    var levelsByKey: [String: MixLevels] = [:]
    var lastBandsRequest: [String: Bool] = [:]
    var active: [String: MixDesiredTap] = [:]

    var ownedAggregateUIDs: Set<String> { Set(active.keys.map { MixIdentity.aggregateUID(for: $0) }) }
    var ownedTapUIDs: Set<String> { [] }

    func processes() -> [MixProcessInfo] { procs }
    func runningApps() -> [MixRunningApp] { apps }

    func create(_ tap: MixDesiredTap) -> MixTapError? {
        created.append(tap)
        if let e = failures[tap.key] { return e }
        active[tap.key] = tap
        return nil
    }

    func update(key: String, params: MixParams) { updates.append((key, params)); active[key]?.params = params }
    func destroy(key: String) { destroyed.append(key); active[key] = nil }
    func destroyAll() { destroyAllCalls += 1; active = [:] }

    func levels(key: String, bands: Bool) -> MixLevels? {
        lastBandsRequest[key] = bands
        return levelsByKey[key]
    }

    func orphanCandidates() -> (aggregates: [MixAggregateInfo], taps: [MixTapInfo]) { (aggregates, taps) }
    func destroyAggregate(_ id: UInt32) { destroyedAggregates.append(id) }
    func destroyTap(_ id: UInt32) { destroyedTaps.append(id) }
}

final class MixFakeVolume: MixOutputVolumeControlling {
    var volumes: [String: Float] = [:]
    var sets: [(String, Float)] = []
    var failSet = false

    func outputVolume(uid: String) -> Float? { volumes[uid] }

    func setOutputVolume(uid: String, _ value: Float) -> Bool {
        sets.append((uid, value))
        guard !failSet else { return false }
        volumes[uid] = value
        return true
    }
}

final class MixClockBox {
    var now: TimeInterval = 1000
}

enum MixT {
    static let safari = MixRunningApp(pid: 100, bundleID: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app")
    static let music = MixRunningApp(pid: 200, bundleID: "com.apple.Music", name: "Музыка", bundlePath: "/System/Applications/Music.app")
    static let chrome = MixRunningApp(pid: 300, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
    static let airplayTV = AudioDeviceInfo(uid: "airplay-tv", name: "Телевизор", transport: .airplay, hasOutput: true)

    static func proc(_ id: UInt32, pid: Int32, _ bundle: String?, out: Bool = true, path: String? = nil) -> MixProcessInfo {
        MixProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: out, executablePath: path)
    }

    struct Env {
        let driver = MixFakeDriver()
        let hardware: SndFakeHardware
        let kv = WndMemoryStore()
        let volume = MixFakeVolume()
        let clock = MixClockBox()
        let engine: MixEngine

        init(devices: [AudioDeviceInfo] = [Snd.speakers, Snd.airpods, Snd.usb, Snd.mic], out: String? = "speakers", kv shared: WndMemoryStore? = nil) {
            hardware = Snd.hardware(devices, out: out)
            let store = shared ?? kv
            let clock = self.clock
            engine = MixEngine(driver: driver, hardware: hardware, volumes: volume, store: MixSettingsStore(store), ownPID: 1, clock: { clock.now })
            driver.apps = [safari, music, chrome]
            driver.procs = [proc(1, pid: 100, "com.apple.Safari"), proc(2, pid: 200, "com.apple.Music")]
        }
    }
}
