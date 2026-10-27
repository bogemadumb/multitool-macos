import Foundation
import CoreAudio

public final class IslSystemLevels: IslLevelsDriving, @unchecked Sendable {
    private let hal = CoreAudioHal()
    private let volumes = MixLiveDriver()

    public init() {}

    public var outputUID: String? { hal.defaultUID(.output) }

    public func outputVolume() -> Float? { outputUID.flatMap { volumes.outputVolume(uid: $0) } }

    public func setOutputVolume(_ value: Float) -> Bool {
        guard let uid = outputUID else { return false }
        return volumes.setOutputVolume(uid: uid, value)
    }

    private func muteElements(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        func settable(_ e: AudioObjectPropertyElement) -> Bool {
            var a = CoreAudioHal.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: e)
            guard AudioObjectHasProperty(id, &a) else { return false }
            var ok: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...2).map { AudioObjectPropertyElement($0) }.filter(settable)
    }

    public func isMuted() -> Bool? {
        guard let uid = outputUID, let id = MixHal.deviceID(uid: uid) else { return nil }
        let els = muteElements(id)
        guard !els.isEmpty else { return nil }
        let values: [UInt32] = els.compactMap { e in
            var a = CoreAudioHal.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: e)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return values.isEmpty ? nil : values.allSatisfy { $0 != 0 }
    }

    public func setMuted(_ on: Bool) -> Bool {
        guard let uid = outputUID, let id = MixHal.deviceID(uid: uid) else { return false }
        let els = muteElements(id)
        guard !els.isEmpty else { return false }
        var ok = true
        for e in els {
            var a = CoreAudioHal.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: e)
            var v: UInt32 = on ? 1 : 0
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr && ok
        }
        return ok
    }
}

public final class IslVolumeListener: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var deviceBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private let hal = CoreAudioHal()

    public init(queue: DispatchQueue = DispatchQueue(label: "dev.multitool.app.island.volume"), handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.handler = handler
    }

    public func start() {
        stop()
        lock.lock(); defer { lock.unlock() }
        var sys = CoreAudioHal.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.attach()
            self?.handler()
        }
        if AudioObjectAddPropertyListenerBlock(MixHal.system, &sys, queue, block) == noErr { systemBlock = block }
        attachLocked()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        detachLocked()
        if let b = systemBlock {
            var sys = CoreAudioHal.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(MixHal.system, &sys, queue, b)
            systemBlock = nil
        }
    }

    private func attach() {
        lock.lock(); defer { lock.unlock() }
        detachLocked()
        attachLocked()
    }

    private func detachLocked() {
        for (id, address, block) in deviceBlocks {
            var a = address
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        deviceBlocks = []
    }

    private func attachLocked() {
        guard let uid = hal.defaultUID(.output), let id = MixHal.deviceID(uid: uid) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handler() }
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (MixHal.virtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        ]
        for (sel, el) in selectors {
            var a = CoreAudioHal.address(sel, scope: kAudioObjectPropertyScopeOutput, element: el)
            guard AudioObjectHasProperty(id, &a) else { continue }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr { deviceBlocks.append((id, a, block)) }
        }
    }
}
