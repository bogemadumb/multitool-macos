import SwiftUI
import AppKit
import CoreAudio
import MultitulCore
import MultitulUI

enum IslMicProbe {
    static func inputInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running: UInt32 = 0
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &raddr, 0, nil, &rsize, &running) == noErr else { return false }
        return running != 0
    }
}

@MainActor
final class IslandMascotService: ObservableObject {
    static let shared = IslandMascotService()

    @Published private(set) var frame = IslMscFrame(mood: .resting, visible: false)
    @Published private(set) var settings: IslMscSettings
    private var machine: IslMscMachine
    private var signals = IslMscSignals()
    private let store = IslMscSettingsStore()
    private var timer: Timer?
    private var shotSub: Int?
    private var lastDownloadActive = false
    private var micTick = 0
    private(set) var running = false

    private init() {
        let s = store.load()
        settings = s
        machine = IslMscMachine(settings: s)
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        machine = IslMscMachine(settings: settings)
        signals = IslMscSignals()
        shotSub = ScreenshotController.shared.events.subscribe { [weak self] e in
            if case .captured = e { DispatchQueue.main.async { MainActor.assumeIsolated { self?.signals.shotAt = Date() } } }
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        registerAccessories()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        if let s = shotSub { ScreenshotController.shared.events.unsubscribe(s) }
        shotSub = nil
        IslandController.shared.accessories.unregister("mascot.left")
        IslandController.shared.accessories.unregister("mascot.right")
        frame = IslMscFrame(mood: .resting, visible: false)
    }

    private func registerAccessories() {
        let acc = IslandController.shared.accessories
        acc.unregister("mascot.left")
        acc.unregister("mascot.right")
        let side = settings.side
        let id = side == .left ? "mascot.left" : "mascot.right"
        acc.register(IslAccessory(id: id, slot: side == .left ? .wingLeading : .wingTrailing, order: 100, isActive: { [weak self] in self?.running == true && self?.frame.visible == true },
                                  view: { AnyView(IslandMascotView()) }))
    }

    private func tick() {
        let now = Date()
        let hub = IslandTimerService.shared
        let timerOn = AppController.shared.runtime.isRunning(.notchTimer)
        signals.musicPlaying = IslandMusic.shared.value.isPlaying
        signals.timerRunning = timerOn && (hub.hub.primary(now: now)?.running ?? false)
        signals.timerAlertAt = timerOn ? hub.hub.alertAt : nil
        let dl = IslandDownloadsService.shared
        let dlOn = AppController.shared.runtime.isRunning(.notchDownloads)
        signals.downloadActive = dlOn && !dl.active.isEmpty
        if dlOn, let done = dl.finished.first?.finishedAt { signals.downloadDoneAt = done }
        signals.keepAwake = KeepAwakeController.shared.snapshot.active
                micTick += 1
        if micTick % 4 == 0 { signals.micActive = settings.reactToMic && IslMicProbe.inputInUse() }
        if AppController.shared.runtime.isRunning(.notchCalendar), case .until(_, let s)? = IslandCalendarService.shared.engine.countdown(now: now) { signals.calendarImminent = s <= 60 } else { signals.calendarImminent = false }
        let next = machine.update(signals, now: now, random: { Double.random(in: 0...1) })
        if next != frame {
            let wasVisible = frame.visible
            frame = next
            if wasVisible != next.visible { IslandController.shared.accessoriesChanged() }
        }
    }

    func update(_ s: IslMscSettings) {
        let sideChanged = s.side != settings.side
        settings = s.sanitized
        store.save(settings)
        machine.settings = settings
        if sideChanged, running { registerAccessories() }
    }

    func preview(_ mood: IslMscMood) {
        frame = IslMscFrame(mood: mood, visible: true)
    }
}

struct IslandMascotView: View {
    @ObservedObject private var service = IslandMascotService.shared
    var size: CGFloat = 26

    var body: some View {
        let s = service.settings
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let pose = IslMscAnimator.pose(mood: service.frame.mood, t: ctx.date.timeIntervalSinceReferenceDate)
            IslandMascotFigure(style: s.style, shape: s.shape, palette: s.palette, pose: pose, size: size)
        }
        .frame(width: size + 10, height: size + 6)
        .help(service.frame.mood.title)
    }
}

struct IslandMascotFigure: View {
    var style: IslMscStyle
    var shape: IslMscShape
    var palette: IslMscPalette
    var pose: IslMscPose
    var size: CGFloat

    private var tint: Color {
        let c = palette.rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    var body: some View {
        ZStack {
            body(for: shape)
                .fill(tint)
                .frame(width: size, height: size * (shape == .drop ? 1.1 : 0.95))
            if style == .robot {
                Capsule().fill(Color.black.opacity(0.78)).frame(width: size * 0.76, height: size * 0.36).offset(y: -size * 0.04)
                Rectangle().fill(tint).frame(width: 1.5, height: size * 0.22).offset(y: -size * 0.62)
                Circle().fill(Theme.danger).frame(width: 3.5, height: 3.5).offset(y: -size * 0.74)
            }
            HStack(spacing: size * 0.2) {
                eye
                eye
            }
            .offset(y: style == .robot ? -size * 0.04 : -size * 0.08)
            mouth.offset(y: size * 0.2)
            if pose.prop != .none {
                Image(systemName: symbol(pose.prop)).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1).offset(x: size * 0.45, y: -size * 0.4)
            }
        }
        .rotationEffect(.degrees(pose.tilt))
        .offset(y: -size * pose.bounce)
    }

    private var eye: some View {
        Ellipse().fill(style == .robot ? Color.cyan : Color.black.opacity(0.85)).frame(width: size * 0.16, height: max(size * 0.2 * pose.eyeOpen, 1.2))
    }

    @ViewBuilder
    private var mouth: some View {
        if style == .robot {
            Capsule().fill(Color.black.opacity(0.6)).frame(width: size * (0.18 + 0.2 * pose.mouth), height: 1.6)
        } else {
            Capsule().fill(Color.black.opacity(0.7)).frame(width: size * (0.14 + 0.12 * pose.mouth), height: size * (0.05 + 0.13 * pose.mouth))
        }
    }

    private func body(for shape: IslMscShape) -> AnyShape {
        switch shape {
        case .round: AnyShape(Circle())
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        case .drop: AnyShape(RoundedRectangle(cornerRadius: size * 0.5, style: .continuous))
        }
    }

    private func symbol(_ p: IslMscProp) -> String {
        switch p {
        case .headphones: "headphones"
        case .clock: "timer"
        case .arrow: "arrow.down"
        case .flash: "camera.fill"
        case .mic: "mic.fill"
        case .coffee: "cup.and.saucer.fill"
        case .sparkle: "sparkles"
        case .spinner: "ellipsis"
        case .bell: "bell.fill"
        case .none: "circle"
        }
    }
}

struct IslandMascotSettings: View {
    @ObservedObject var service: IslandMascotService

    private func binding<T>(_ kp: WritableKeyPath<IslMscSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach([IslMscMood.resting, .dancing, .focused, .downloading, .camera, .celebrating], id: \.self) { mood in
                        VStack(spacing: 2) {
                            IslandMascotFigure(style: service.settings.style, shape: service.settings.shape, palette: service.settings.palette,
                                               pose: IslMscAnimator.pose(mood: mood, t: 1.3), size: 34)
                                .frame(width: 52, height: 46)
                            Text(mood.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .onTapGesture { service.preview(mood) }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Талисман") } footer: {
            SectionFooter("Нажмите на настроение, чтобы увидеть его в острове.")
        }
        Section("Внешний вид") {
            Picker("Стиль", selection: binding(\.style)) { ForEach(IslMscStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Форма", selection: binding(\.shape)) { ForEach(IslMscShape.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Цвет", selection: binding(\.palette)) { ForEach(IslMscPalette.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Сторона", selection: binding(\.side)) { ForEach(IslMscSide.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Заходит в гости", selection: binding(\.visits)) { ForEach(IslMscVisits.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("Всегда на виду, даже в покое", isOn: binding(\.visibleAtRest))
        }
        Section("Реагирует на") {
            Toggle("Музыку", isOn: binding(\.reactToMusic))
            Toggle("Таймер и события календаря", isOn: binding(\.reactToTimer))
            Toggle("Загрузки", isOn: binding(\.reactToDownloads))
            Toggle("Скриншоты", isOn: binding(\.reactToShots))
            Toggle("Микрофон", isOn: binding(\.reactToMic))
            Toggle("Режим «Не засыпать»", isOn: binding(\.reactToKeepAwake))
        }
    }
}
