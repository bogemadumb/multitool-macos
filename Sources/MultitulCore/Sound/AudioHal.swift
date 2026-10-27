import Foundation
import CoreAudio

// Every call can block while the audio daemon holds a device: use from a background queue only.
public final class CoreAudioHal: AudioHardware, AudioInputControlling, @unchecked Sendable {
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenQueue: DispatchQueue?
    private let lock = NSLock()

    public init() {}

    deinit { stopListening() }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func deviceIDs() -> [AudioObjectID] {
        var a = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = Self.address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    private func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = Self.address(selector, scope: scope)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var a = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func transport(_ raw: UInt32?) -> AudioTransport {
        guard let raw else { return .other }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }

    private func info(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        let out = hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
        let inp = hasStreams(id, scope: kAudioObjectPropertyScopeInput)
        guard out || inp else { return nil }
        return AudioDeviceInfo(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, transport: Self.transport(uint32(id, kAudioDevicePropertyTransportType)),
                               hasOutput: out, hasInput: inp, isHidden: (uint32(id, kAudioDevicePropertyIsHidden) ?? 0) != 0)
    }

    private func deviceID(uid: String) -> AudioObjectID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    public func devices() -> [AudioDeviceInfo] { deviceIDs().compactMap(info) }

    private func defaultID(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var a = Self.address(selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func selector(_ scope: AudioScope) -> AudioObjectPropertySelector {
        scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }

    public func defaultUID(_ scope: AudioScope) -> String? {
        defaultID(Self.selector(scope)).flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    public func systemOutputUID() -> String? {
        defaultID(kAudioHardwarePropertyDefaultSystemOutputDevice).flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    private func setSystemProperty(_ selector: AudioObjectPropertySelector, uid: String) -> Bool {
        guard var id = deviceID(uid: uid) else { return false }
        var a = Self.address(selector)
        return AudioObjectSetPropertyData(Self.system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    public func setDefault(_ scope: AudioScope, uid: String) -> Bool {
        setSystemProperty(Self.selector(scope), uid: uid) && defaultUID(scope) == uid
    }

    public func setSystemOutput(uid: String) -> Bool {
        setSystemProperty(kAudioHardwarePropertyDefaultSystemOutputDevice, uid: uid) && systemOutputUID() == uid
    }

    // MARK: input mute / volume

    private func settableElements(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        func ok(_ e: AudioObjectPropertyElement) -> Bool {
            var a = Self.address(selector, scope: kAudioObjectPropertyScopeInput, element: e)
            guard AudioObjectHasProperty(id, &a) else { return false }
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
        }
        if ok(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).map { AudioObjectPropertyElement($0) }.filter(ok)
    }

    private func readU32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ e: AudioObjectPropertyElement) -> UInt32? {
        var a = Self.address(selector, scope: kAudioObjectPropertyScopeInput, element: e)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func readF32(_ id: AudioObjectID, _ e: AudioObjectPropertyElement) -> Float? {
        var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: e)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    public func muteSwitch(uid: String) -> Bool? {
        guard let id = deviceID(uid: uid) else { return nil }
        let els = settableElements(id, kAudioDevicePropertyMute)
        guard !els.isEmpty else { return nil }
        let values = els.compactMap { readU32(id, kAudioDevicePropertyMute, $0) }
        guard values.count == els.count else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    public func setMuteSwitch(uid: String, _ muted: Bool) -> Bool {
        guard let id = deviceID(uid: uid) else { return false }
        let els = settableElements(id, kAudioDevicePropertyMute)
        guard !els.isEmpty else { return false }
        var ok = true
        for e in els {
            var a = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, element: e)
            var v: UInt32 = muted ? 1 : 0
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr && ok
        }
        return ok && muteSwitch(uid: uid) == muted
    }

    public func inputVolume(uid: String) -> Float? {
        guard let id = deviceID(uid: uid) else { return nil }
        let els = settableElements(id, kAudioDevicePropertyVolumeScalar)
        guard !els.isEmpty else { return nil }
        let values = els.compactMap { readF32(id, $0) }
        guard values.count == els.count else { return nil }
        return values.max()
    }

    public func setInputVolume(uid: String, _ value: Float) -> Bool {
        guard let id = deviceID(uid: uid) else { return false }
        let els = settableElements(id, kAudioDevicePropertyVolumeScalar)
        guard !els.isEmpty else { return false }
        var ok = true
        for e in els {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: e)
            var v = Float32(min(max(value, 0), 1))
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr && ok
        }
        return ok
    }

    // MARK: listeners

    public func startListening(queue: DispatchQueue, handler: @escaping @Sendable (AudioHardwareEvent) -> Void) {
        stopListening()
        lock.lock(); defer { lock.unlock() }
        listenQueue = queue
        let items: [(AudioObjectPropertySelector, AudioHardwareEvent)] = [
            (kAudioHardwarePropertyDevices, .devicesChanged),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultChanged(.output)),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultChanged(.input)),
            (kAudioHardwarePropertyDefaultSystemOutputDevice, .systemOutputChanged)
        ]
        for (selector, event) in items {
            var a = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(event) }
            if AudioObjectAddPropertyListenerBlock(Self.system, &a, queue, block) == noErr {
                listenerBlocks.append((a, block))
            }
        }
    }

    public func stopListening() {
        lock.lock(); defer { lock.unlock() }
        guard let queue = listenQueue else { return }
        for (address, block) in listenerBlocks {
            var a = address
            AudioObjectRemovePropertyListenerBlock(Self.system, &a, queue, block)
        }
        listenerBlocks = []
        listenQueue = nil
    }
}
