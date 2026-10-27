import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class IslandEqService: ObservableObject {
    static let shared = IslandEqService()

    private(set) var values: [Float] = []
    @Published private(set) var live = false
    @Published private(set) var settings: IslEqSettings
    private let store = IslEqSettingsStore()
    private let owner = "island.eq"
    private var feed = IslEqFeed()
    private var timer: Timer?
    private var lastTick = Date()
    private var demandKey: String?
    private(set) var running = false

    private init() { settings = store.load() }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        feed.gain = Float(settings.sensitivity)
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = Date()
        IslandController.shared.accessories.register(IslAccessory(id: "eq.music", slot: .musicSide, order: 10,
                                                                  isActive: { IslandEqService.shared.running && IslandEqService.shared.settings.showInMusic && IslandEqService.shared.live },
                                                                  view: { AnyView(IslandSpectrumBars(count: IslandEqService.shared.settings.expandedBars, tint: IslandMusic.shared.tint, height: 70, width: 4)) }))
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        MixerController.shared.releaseLevels(owner: owner)
        demandKey = nil
        values = []
        live = false
        IslandController.shared.accessories.unregister("eq.music")
    }

    var mixerReady: Bool { MixerController.shared.running }

    var bars: Int { settings.compactBars }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let music = IslandMusic.shared.value
        guard music.isPlaying, MixerController.shared.running, let bundle = music.track?.bundleID else {
            if demandKey != nil { MixerController.shared.releaseLevels(owner: owner); demandKey = nil }
            if live || !values.isEmpty {
                feed.update(bands: nil, bars: max(settings.compactBars, settings.expandedBars), now: now, dt: dt)
                values = feed.values.allSatisfy { $0 == 0 } ? [] : feed.values
                if live { live = false }
            }
            return
        }
        let keys = Set(MixerController.shared.snapshot.rows.map(\.key))
        let key = IslEqSource.key(forBundle: bundle, available: keys)
        if let key, key != demandKey {
            MixerController.shared.requestLevels(owner: owner, keys: [key], bands: true)
            demandKey = key
        } else if key == nil, demandKey != nil {
            MixerController.shared.releaseLevels(owner: owner)
            demandKey = nil
        }
        let bands = key.flatMap { MixerController.shared.levels[$0]?.bands }
        feed.update(bands: bands, bars: max(settings.compactBars, settings.expandedBars), now: now, dt: dt)
        values = feed.values
        let nowLive = feed.isLive(at: now)
        if live != nowLive { live = nowLive }
    }

    func bars(_ count: Int) -> [Float] {
        IslEqMapper.resample(values, to: count)
    }

    func update(_ s: IslEqSettings) {
        settings = s.sanitized
        store.save(settings)
        feed.gain = Float(settings.sensitivity)
    }
}

struct IslandSpectrumBars: View {
    let service = IslandEqService.shared
    var count: Int
    var tint: Color = .white
    var height: CGFloat = 16
    var width: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
            let v = service.bars(count)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let h = CGFloat(i < v.count ? v[i] : 0)
                    Capsule().fill(tint).frame(width: width, height: max(height * (0.12 + 0.88 * h), 2))
                }
            }
            .frame(height: height)
        }
    }
}

struct IslandLiveEqSettings: View {
    @ObservedObject var service: IslandEqService

    private func binding<T>(_ kp: WritableKeyPath<IslEqSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        if !service.mixerReady {
            Section { ToolWarning(text: "Нужен включённый модуль «Микшер»: он снимает звук приложения. Пока он выключен, полоски двигаются по обычной анимации.") }
        }
        ToolsPermissionNote(permission: .systemAudio, text: "Нужно разрешение «Запись системного звука» (запрашивается один раз).")
        Section {
            IslandStepperRow(symbol: "chart.bar", title: "Полосок в закрытом острове", value: binding(\.compactBars), range: IslEqSettings.barsRange)
            IslandStepperRow(symbol: "chart.bar.doc.horizontal", title: "Полосок в разделе «Музыка»", value: binding(\.expandedBars), range: IslEqSettings.barsRange)
            SliderSetting("Чувствительность", String(format: "×%.1f", service.settings.sensitivity), value: binding(\.sensitivity), in: IslEqSettings.sensitivityRange)
            Toggle("Спектр рядом с обложкой в «Музыке»", isOn: binding(\.showInMusic))
        } header: { Text("Живой эквалайзер") } footer: {
            SectionFooter(service.live ? "Сейчас сигнал идёт." : "Сейчас сигнала нет: ничего не играет или приложение не отдаёт звук.")
        }
    }
}
