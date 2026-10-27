import SwiftUI
import AppKit
import MultitulCore

@MainActor
final class AudioDevicesHub: ObservableObject {
    static let shared = AudioDevicesHub()

    let hal = CoreAudioHal()
    let queue = DispatchQueue(label: "dev.multitool.app.audio")

    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var defaultOutput: String?
    @Published private(set) var defaultInput: String?
    @Published private(set) var systemOutput: String?
    @Published private(set) var knownNames: [String: String]

    private let store = SoundSettingsStore()

    private init() { knownNames = store.loadNames() }

    private var subscribers: [String: (AudioHardwareEvent) -> Void] = [:]
    private var refreshWork: DispatchWorkItem?

    func outputs() -> [AudioDeviceInfo] { AudioDeviceInfo.visible(devices, scope: .output) }
    func inputs() -> [AudioDeviceInfo] { AudioDeviceInfo.visible(devices, scope: .input) }

    func retain(_ owner: String, handler: @escaping (AudioHardwareEvent) -> Void) {
        let first = subscribers.isEmpty
        subscribers[owner] = handler
        guard first else { return }
        hal.startListening(queue: queue) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { AudioDevicesHub.shared.received(event) } }
        }
        refresh()
    }

    func release(_ owner: String) {
        subscribers[owner] = nil
        if subscribers.isEmpty {
            hal.stopListening()
            refreshWork?.cancel()
            refreshWork = nil
        }
    }

    func refresh() {
        let hal = self.hal
        queue.async {
            let devs = hal.devices()
            let out = hal.defaultUID(.output)
            let inp = hal.defaultUID(.input)
            let sys = hal.systemOutputUID()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let h = AudioDevicesHub.shared
                    if h.devices != devs { h.devices = devs; h.rememberNames(devs) }
                    if h.defaultOutput != out { h.defaultOutput = out }
                    if h.defaultInput != inp { h.defaultInput = inp }
                    if h.systemOutput != sys { h.systemOutput = sys }
                }
            }
        }
    }

    func choose(_ scope: AudioScope, uid: String, syncSystem: Bool) {
        let hal = self.hal
        queue.async {
            let ok = hal.setDefault(scope, uid: uid)
            if ok, scope == .output, syncSystem { _ = hal.setSystemOutput(uid: uid) }
            Log.write("audio choose \(scope.rawValue) \(uid) ok=\(ok)")
            DispatchQueue.main.async { MainActor.assumeIsolated { AudioDevicesHub.shared.refresh() } }
        }
    }

    func name(of uid: String?) -> String? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }?.name ?? knownNames[uid]
    }

    func isOnline(_ uid: String) -> Bool { devices.contains { $0.uid == uid && !$0.isHidden } }

    private func rememberNames(_ devs: [AudioDeviceInfo]) {
        var names = knownNames
        for d in devs where !d.isHidden && !d.transport.isSynthetic { names[d.uid] = d.name }
        guard names != knownNames else { return }
        knownNames = names
        store.saveNames(names)
    }

    private func received(_ event: AudioHardwareEvent) {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        for h in subscribers.values { h(event) }
    }
}
