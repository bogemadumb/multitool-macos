import Foundation
import CoreAudio
import AudioToolbox
import Darwin

enum MixHal {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        CoreAudioHal.address(selector, scope: scope, element: element)
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    static func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(selector, scope: scope)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func f64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var a = address(selector)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id) }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func processPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func streamIsFloat32(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        guard let stream = ids(device, kAudioDevicePropertyStreams, scope: scope).first else { return true }
        var a = address(kAudioStreamPropertyVirtualFormat)
        var f = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &f) == noErr else { return true }
        return f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
    }
}

@available(macOS 14.2, *)
final class MixTapSession {
    let desired: MixDesiredTap
    let processor: MixProcessor
    let aggregateUID: String
    let tapUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false

    private init(desired: MixDesiredTap, processor: MixProcessor, aggregateUID: String, tapUID: String) {
        self.desired = desired
        self.processor = processor
        self.aggregateUID = aggregateUID
        self.tapUID = tapUID
    }

    static func start(_ d: MixDesiredTap) -> Result<MixTapSession, MixTapError> {
        guard let outputID = MixHal.deviceID(uid: d.outputUID) else { return .failure(.deviceUnavailable) }
        let desc = CATapDescription(stereoMixdownOfProcesses: d.processObjectIDs.map { AudioObjectID($0) })
        let id = UUID()
        desc.name = MixIdentity.tapNamePrefix + d.key
        desc.uuid = id
        desc.isPrivate = true
        desc.muteBehavior = d.mode == .process ? .mutedWhenTapped : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr else { return .failure(.tapFailed(tapStatus)) }
        let tapUID = id.uuidString
        let aggUID = MixIdentity.aggregateUID(for: id.uuidString)
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: MixIdentity.aggregateNamePrefix + d.key,
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: d.outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: d.outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]]
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return .failure(.aggregateFailed(aggStatus))
        }
        _ = outputID
        guard MixHal.streamIsFloat32(agg, scope: kAudioObjectPropertyScopeOutput) else {
            AudioHardwareDestroyAggregateDevice(agg)
            AudioHardwareDestroyProcessTap(tap)
            return .failure(.badFormat)
        }
        let rate = MixHal.f64(agg, kAudioDevicePropertyNominalSampleRate) ?? 48_000
        var initial = d.params
        initial.ceiling = 1
        let processor = MixProcessor(sampleRate: rate, initial: initial, renderOutput: d.mode == .process)
        let session = MixTapSession(desired: d, processor: processor, aggregateUID: aggUID, tapUID: tapUID)
        session.tapID = tap
        session.aggregateID = agg
        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, outData, _ in
            processor.process(input: inData, output: outData)
        }
        guard ioStatus == noErr, let proc else {
            session.teardown()
            return .failure(.ioFailed(ioStatus))
        }
        session.procID = proc
        let startStatus = AudioDeviceStart(agg, proc)
        guard startStatus == noErr else {
            session.teardown()
            return .failure(.ioFailed(startStatus))
        }
        session.started = true
        return .success(session)
    }

    func teardown() {
        if started, let procID { AudioDeviceStop(aggregateID, procID) }
        started = false
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // Gain returns to unity first, so handing the app back to the system is not a jump in level.
    func releaseGain() {
        var p = desired.params
        p.volume = 1
        p.muted = false
        processor.setParams(p)
    }
}

public final class MixLiveDriver: MixDriving, MixOutputVolumeControlling, @unchecked Sendable {
    private var sessions: [String: Any] = [:]
    private let lock = NSLock()
    private var appSnapshot: [MixRunningApp] = []
    private var processListener: AudioObjectPropertyListenerBlock?
    private var listenerQueue: DispatchQueue?

    public init() {}

    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    public func setRunningApps(_ apps: [MixRunningApp]) {
        lock.lock(); appSnapshot = apps; lock.unlock()
    }

    public func runningApps() -> [MixRunningApp] {
        lock.lock(); defer { lock.unlock() }
        return appSnapshot
    }

    public func processes() -> [MixProcessInfo] {
        MixHal.ids(MixHal.system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = MixHal.u32(obj, kAudioProcessPropertyPID) else { return nil }
            let p = Int32(truncatingIfNeeded: pid)
            let bundle = MixHal.string(obj, kAudioProcessPropertyBundleID)
            let running = (MixHal.u32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            return MixProcessInfo(objectID: obj, pid: p, bundleID: (bundle?.isEmpty ?? true) ? nil : bundle, isRunningOutput: running, executablePath: MixHal.processPath(p))
        }
    }

    public var ownedAggregateUIDs: Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        return Set(sessions.values.compactMap { ($0 as? MixTapSession)?.aggregateUID })
    }

    public var ownedTapUIDs: Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        return Set(sessions.values.compactMap { ($0 as? MixTapSession)?.tapUID })
    }

    public func create(_ tap: MixDesiredTap) -> MixTapError? {
        guard #available(macOS 14.2, *) else { return .unsupported }
        destroy(key: tap.key)
        switch MixTapSession.start(tap) {
        case .success(let s):
            sessions[tap.key] = s
            return nil
        case .failure(let e):
            return e
        }
    }

    public func update(key: String, params: MixParams) {
        guard #available(macOS 14.2, *), let s = sessions[key] as? MixTapSession else { return }
        s.processor.setParams(params)
    }

    public func destroy(key: String) {
        guard #available(macOS 14.2, *), let s = sessions.removeValue(forKey: key) as? MixTapSession else { return }
        if s.desired.mode == .process {
            s.releaseGain()
            Thread.sleep(forTimeInterval: 0.05)
        }
        s.teardown()
    }

    public func destroyAll() {
        guard #available(macOS 14.2, *) else { return }
        let all = sessions.values.compactMap { $0 as? MixTapSession }
        sessions = [:]
        for s in all where s.desired.mode == .process { s.releaseGain() }
        if all.contains(where: { $0.desired.mode == .process }) { Thread.sleep(forTimeInterval: 0.05) }
        for s in all { s.teardown() }
    }

    public func levels(key: String, bands: Bool) -> MixLevels? {
        guard #available(macOS 14.2, *), let s = sessions[key] as? MixTapSession else { return nil }
        return s.processor.levels(bands: bands)
    }

    public func orphanCandidates() -> (aggregates: [MixAggregateInfo], taps: [MixTapInfo]) {
        var aggs: [MixAggregateInfo] = []
        for id in MixHal.ids(MixHal.system, kAudioHardwarePropertyDevices) {
            let transport = MixHal.u32(id, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate else { continue }
            guard let uid = MixHal.string(id, kAudioDevicePropertyDeviceUID) else { continue }
            aggs.append(MixAggregateInfo(objectID: id, uid: uid, name: MixHal.string(id, kAudioObjectPropertyName) ?? ""))
        }
        return (aggs, tapCandidates())
    }

    private func tapCandidates() -> [MixTapInfo] {
        guard #available(macOS 14.2, *) else { return [] }
        var out: [MixTapInfo] = []
        for id in MixHal.ids(MixHal.system, kAudioHardwarePropertyTapList) {
            guard let uid = MixHal.string(id, kAudioTapPropertyUID) else { continue }
            var a = MixHal.address(kAudioTapPropertyDescription)
            var ref: Unmanaged<CATapDescription>?
            var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
            let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
            guard status == noErr, let ref else { continue }
            out.append(MixTapInfo(objectID: id, uid: uid, name: ref.takeRetainedValue().name))
        }
        return out
    }

    public func destroyAggregate(_ id: UInt32) { AudioHardwareDestroyAggregateDevice(AudioObjectID(id)) }

    public func destroyTap(_ id: UInt32) {
        guard #available(macOS 14.2, *) else { return }
        AudioHardwareDestroyProcessTap(AudioObjectID(id))
    }

    public func startListening(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        stopListening()
        var a = MixHal.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(MixHal.system, &a, queue, block) == noErr {
            processListener = block
            listenerQueue = queue
        }
    }

    public func stopListening() {
        guard let block = processListener, let queue = listenerQueue else { return }
        var a = MixHal.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(MixHal.system, &a, queue, block)
        processListener = nil
        listenerQueue = nil
    }

    // MARK: system output volume (headphone guard)

    private func volumeElements(_ id: AudioObjectID) -> [(AudioObjectPropertySelector, AudioObjectPropertyElement)] {
        func settable(_ s: AudioObjectPropertySelector, _ e: AudioObjectPropertyElement) -> Bool {
            var a = MixHal.address(s, scope: kAudioObjectPropertyScopeOutput, element: e)
            guard AudioObjectHasProperty(id, &a) else { return false }
            var ok: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
        }
        if settable(MixHal.virtualMainVolume, kAudioObjectPropertyElementMain) { return [(MixHal.virtualMainVolume, kAudioObjectPropertyElementMain)] }
        if settable(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) { return [(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)] }
        return (1...2).map { AudioObjectPropertyElement($0) }.filter { settable(kAudioDevicePropertyVolumeScalar, $0) }.map { (kAudioDevicePropertyVolumeScalar, $0) }
    }

    public func outputVolume(uid: String) -> Float? {
        guard let id = MixHal.deviceID(uid: uid) else { return nil }
        let values: [Float] = volumeElements(id).compactMap { sel, el in
            var a = MixHal.address(sel, scope: kAudioObjectPropertyScopeOutput, element: el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return values.max()
    }

    public func setOutputVolume(uid: String, _ value: Float) -> Bool {
        guard let id = MixHal.deviceID(uid: uid) else { return false }
        let els = volumeElements(id)
        guard !els.isEmpty else { return false }
        var ok = true
        for (sel, el) in els {
            var a = MixHal.address(sel, scope: kAudioObjectPropertyScopeOutput, element: el)
            var v = Float32(min(max(value, 0), 1))
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr && ok
        }
        return ok
    }
}
