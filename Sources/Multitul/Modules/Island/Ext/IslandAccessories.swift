import SwiftUI
import AppKit
import IOBluetooth
@preconcurrency import MultitulCore
import MultitulUI

final class IslProfilerBluetooth: IslAccProviding {
    func devices() -> [IslAccDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let deadline = DispatchTime.now() + 15
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut { p.terminate(); return [] }
        return IslAccParser.fromSystemProfiler(out.fileHandleForReading.readDataToEndOfFile())
    }
}

final class IslBtConnectObserver: NSObject {
    private var registration: IOBluetoothUserNotification?
    var onEvent: (() -> Void)?

    func start() {
        registration = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    func stop() {
        registration?.unregister()
        registration = nil
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?() }
    }
}

@MainActor
final class IslandAccessoriesService: ObservableObject {
    static let shared = IslandAccessoriesService()

    @Published private(set) var devices: [IslAccDevice] = []
    @Published private(set) var allDevices: [IslAccDevice] = []
    @Published private(set) var settings: IslAccSettings
    @Published private(set) var loaded = false
    var onChange: (() -> Void)?
    private let store = IslAccSettingsStore()
    private let provider: IslAccProviding = IslProfilerBluetooth()
    private let observer = IslBtConnectObserver()
    private var tracker = IslAccTracker()
    private var transient: [String: IslActivity] = [:]
    private var timer: Timer?
    private var loading = false
    private(set) var running = false

    private init() { settings = store.load() }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        tracker.reset()
        observer.onEvent = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.refresh() } }
        }
        observer.start()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
        IslandController.shared.accessories.register(IslAccessory(id: "accessories.header", slot: .headerTrailing, order: 10,
                                                                  isActive: { [weak self] in self?.headerDevice != nil }, view: { AnyView(IslandAccessoryHeaderBadge()) }))
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        observer.stop()
        observer.onEvent = nil
        IslandController.shared.accessories.unregister("accessories.header")
        devices = []
        allDevices = []
        transient = [:]
        loaded = false
        onChange?()
    }

    func refresh() {
        guard running, !loading else { return }
        loading = true
        let p = provider
        DispatchQueue.global(qos: .utility).async {
            let list = p.devices()
            DispatchQueue.main.async { MainActor.assumeIsolated { IslandAccessoriesService.shared.apply(list) } }
        }
    }

    private func apply(_ list: [IslAccDevice]) {
        loading = false
        guard running else { return }
        let now = Date()
        let events = tracker.update(list, settings: settings)
        allDevices = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        devices = tracker.known.values.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
        loaded = true
        for e in events {
            switch e {
            case .connected where !settings.notifyConnect: continue
            case .lowBattery(let d, let level):
                if settings.notifyLow { Notifier.shared.post(title: "Низкий заряд", body: "\(d.name): \(level)%", id: "island-acc-low-\(d.id)") }
                else { continue }
            default: break
            }
            if let a = IslAccActivityFactory.activity(for: e, now: now) { transient[a.id] = a }
        }
        onChange?()
    }

    func update(_ s: IslAccSettings) {
        settings = s.sanitized
        store.save(settings)
        tracker.reset()
        refresh()
    }

    var connected: [IslAccDevice] { devices.filter(\.connected) }

    var headerDevice: IslAccDevice? {
        guard running, settings.showInHeader else { return nil }
        return connected.filter { $0.battery.headline != nil }.min { ($0.battery.headline ?? 100) < ($1.battery.headline ?? 100) }
    }

    func activities() -> [IslActivity] {
        let now = Date()
        transient = transient.filter { !$0.value.isExpired(at: now) }
        return Array(transient.values)
    }
}

struct IslandAccessoryHeaderBadge: View {
    @ObservedObject private var service = IslandAccessoriesService.shared

    var body: some View {
        if let d = service.headerDevice, let p = d.battery.headline {
            HStack(spacing: 3) {
                Image(systemName: d.kind.symbol).font(.system(size: 11))
                Image(systemName: IslAccFormat.batterySymbol(p)).font(.system(size: 12))
                Text("\(p)%").font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(p <= service.settings.lowThreshold ? Theme.warn : .white.opacity(0.75))
            .help("\(d.name): \(IslAccFormat.batteryLine(d.battery))")
        }
    }
}

@MainActor
final class IslandAccessoriesSection: IslandSectionBase {
    private let service = IslandAccessoriesService.shared

    init() { super.init(IslSectionIDs.accessories) }

    override var availability: IslAvailability { requires(.notchAccessories) }

    override var activities: [IslActivity] { service.activities() }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    private func device(_ a: IslActivity) -> IslAccDevice? {
        let id = a.id.replacingOccurrences(of: "acc.low.", with: "").replacingOccurrences(of: "acc.", with: "")
        return service.devices.first { $0.id == id }
    }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        AnyView(Image(systemName: device(activity)?.kind.symbol ?? "airpodspro").font(.system(size: 13, weight: .semibold)).foregroundStyle(activity.id.hasPrefix("acc.low.") ? Theme.warn : .white))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        guard let p = device(activity)?.battery.headline else { return AnyView(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ok)) }
        return AnyView(HStack(spacing: 2) {
            Image(systemName: IslAccFormat.batterySymbol(p)).font(.system(size: 12))
            Text("\(p)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
        }.foregroundStyle(p <= service.settings.lowThreshold ? Theme.warn : .white))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(HStack(spacing: 10) {
            Image(systemName: device(activity)?.kind.symbol ?? "airpodspro").font(.system(size: 16)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let d = device(activity) { Text(IslAccFormat.batteryLine(d.battery)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandAccessoriesView(service: service)) }
}

struct IslandAccessoriesView: View {
    @ObservedObject var service: IslandAccessoriesService

    var body: some View {
        Group {
            if !service.loaded {
                IslEmptyNote(symbol: "dot.radiowaves.left.and.right", text: "Ищу подключённые устройства…")
            } else if service.devices.isEmpty {
                IslEmptyNote(symbol: "airpodspro", text: "Bluetooth-устройств не видно")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(service.devices) { d in row(d) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { service.refresh() }
    }

    private func row(_ d: IslAccDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.kind.symbol).font(.system(size: 14)).frame(width: 22).foregroundStyle(d.connected ? .white : .white.opacity(0.35))
            VStack(alignment: .leading, spacing: 0) {
                Text(d.name).font(.system(size: 12, weight: .medium)).foregroundStyle(d.connected ? .white : .white.opacity(0.4)).lineLimit(1)
                Text(d.connected ? (d.battery.isEmpty ? "подключено" : IslAccFormat.batteryLine(d.battery)) : "не подключено").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if d.connected, let p = d.battery.headline {
                HStack(spacing: 4) {
                    Image(systemName: IslAccFormat.batterySymbol(p)).font(.system(size: 13))
                    Text("\(p)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(p <= service.settings.lowThreshold ? Theme.warn : .white.opacity(0.85))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color.white.opacity(d.connected ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct IslandAccessoriesSettings: View {
    @ObservedObject var service: IslandAccessoriesService

    private func binding<T>(_ kp: WritableKeyPath<IslAccSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .bluetooth, text: "Без доступа к Bluetooth остров не увидит подключения устройств.")
        Section {
            IslandStepperRow(symbol: "battery.25", title: "Предупреждать при заряде", subtitle: "Один раз, пока устройство снова не зарядится", value: binding(\.lowThreshold), range: IslAccSettings.thresholdRange, unit: "%")
            Toggle(isOn: binding(\.notifyConnect)) { SettingLabel("Показывать подключение", "Остров всплывает, когда подключаются наушники или другое устройство") }
            Toggle("Предупреждать о низком заряде", isOn: binding(\.notifyLow))
            Toggle("Заряд в верхнем ряду открытого острова", isOn: binding(\.showInHeader))
        } header: { Text("Аксессуары") }
        if !service.allDevices.isEmpty {
            Section("Какие устройства показывать") {
                ForEach(service.allDevices) { d in
                    Toggle(d.name, isOn: Binding(get: { !service.settings.hiddenDevices.contains(d.id) }, set: { on in
                        var s = service.settings
                        if on { s.hiddenDevices.remove(d.id) } else { s.hiddenDevices.insert(d.id) }
                        service.update(s)
                    }))
                }
            }
        }
    }
}
