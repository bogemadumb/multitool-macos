import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class IslandTimerService: ObservableObject {
    static let shared = IslandTimerService()

    @Published private(set) var hub: IslTmrHub
    @Published private(set) var revision = 0
    var onChange: (() -> Void)?
    private let settingsStore = IslTmrSettingsStore()
    private let persistence = IslTmrPersistence()
    private var ticker: Timer?
    private(set) var running = false

    private init() { hub = IslTmrHub(state: IslTmrPersistence().load(), settings: IslTmrSettingsStore().load()) }

    var settings: IslTmrSettings { hub.settings }

    func start() {
        guard !running else { return }
        running = true
        hub = IslTmrHub(state: persistence.load(), settings: settingsStore.load())
        _ = hub.tick(now: Date())
        hub.dismissAlert()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        HotkeyManager.shared.register(IslTmrHotkeys.toggle, owner: ModuleID.notchTimer.rawValue) { [weak self] in self?.hotkeyToggle() }
        HotkeyManager.shared.register(IslTmrHotkeys.cancel, owner: ModuleID.notchTimer.rawValue) { [weak self] in self?.hotkeyCancel() }
        changed(save: false)
    }

    func stop() {
        guard running else { return }
        running = false
        persistence.save(hub.state)
        ticker?.invalidate()
        ticker = nil
        HotkeyManager.shared.unregisterAll(owner: ModuleID.notchTimer.rawValue)
        hub.dismissAlert()
        onChange?()
    }

    private func tick() {
        var h = hub
        let events = h.tick(now: Date())
        if h != hub { hub = h }
        if !events.isEmpty {
            playSound()
            persistence.save(hub.state)
            changed(save: false)
        } else if hub.anyActive || hub.alertAt != nil {
            revision &+= 1
        }
    }

    private func changed(save: Bool = true) {
        if save { persistence.save(hub.state) }
        revision &+= 1
        onChange?()
    }

    private func playSound() {
        let s = hub.settings
        guard s.soundEnabled else { return }
        for i in 0..<s.soundRepeats {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { NSSound(named: NSSound.Name(s.sound))?.play() }
        }
    }

    // MARK: intents

    func startTimer(minutes: Int?) { hub.startTimer(minutes: minutes, now: Date()); changed() }
    func toggleTimer() { hub.toggleTimer(now: Date()); changed() }
    func addTime(_ seconds: TimeInterval) { hub.state.timer.add(seconds: seconds, now: Date()); changed() }
    func toggleStopwatch() { hub.toggleStopwatch(now: Date()); changed() }
    func lap() { hub.state.stopwatch.lap(now: Date()); changed() }
    func togglePomodoro() { hub.togglePomodoro(now: Date()); changed() }
    func skipPomodoro() { hub.state.pomodoro.skip(now: Date(), settings: hub.settings.pomodoro); changed() }
    func reset(_ kind: IslTmrKind) { hub.reset(kind); changed() }
    func dismissAlert() { hub.dismissAlert(); changed(save: false) }

    func update(_ s: IslTmrSettings) {
        hub.updateSettings(s)
        settingsStore.save(hub.settings)
        changed(save: false)
    }

    private func hotkeyToggle() {
        let h = hub
        if h.state.timer.isActive || h.state.timer.phase == .finished || h.state.timer.phase == .idle && !h.state.pomodoro.isActive && !h.state.stopwatch.isActive { toggleTimer() }
        else if h.state.pomodoro.isActive || h.state.pomodoro.waiting { togglePomodoro() }
        else { toggleStopwatch() }
    }

    private func hotkeyCancel() {
        if hub.state.timer.phase != .idle { reset(.timer) }
        else if hub.state.pomodoro.started { reset(.pomodoro) }
        else { reset(.stopwatch) }
    }

    func activity() -> IslActivity? { running ? hub.activity(now: Date()) : nil }
}

@MainActor
final class IslandTimerSection: IslandSectionBase {
    private let service = IslandTimerService.shared

    init() { super.init(IslSectionIDs.timer) }

    override var availability: IslAvailability { requires(.notchTimer) }

    override var activities: [IslActivity] { service.activity().map { [$0] } ?? [] }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandTimerGlyph(service: service))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandTimerClock(service: service, hideable: true))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(HStack(spacing: 10) {
            IslandTimerGlyph(service: service)
            Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
            IslandTimerClock(service: service, hideable: false)
        }.padding(.horizontal, 14))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandTimerView(service: service)) }
}

struct IslandTimerGlyph: View {
    @ObservedObject var service: IslandTimerService

    var body: some View {
        let p = service.hub.primary(now: Date())
        let symbol: String = {
            switch p?.kind {
            case .stopwatch: "stopwatch"
            case .pomodoro: service.hub.state.pomodoro.phase == .focus ? "brain.head.profile" : "cup.and.saucer"
            default: service.hub.alertAt != nil ? "bell.fill" : "timer"
            }
        }()
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(service.hub.alertAt != nil ? Theme.warn : .white)
    }
}

struct IslandTimerClock: View {
    @ObservedObject var service: IslandTimerService
    var hideable: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            if service.hub.alertAt != nil {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ok)
            } else if hideable && service.settings.hideCountdown {
                if let p = service.hub.primary(now: ctx.date), let pr = p.progress {
                    Circle().trim(from: 0, to: pr).stroke(Theme.accent, lineWidth: 2.5).rotationEffect(.degrees(-90)).frame(width: 14, height: 14)
                }
            } else if let p = service.hub.primary(now: ctx.date) {
                Text(IslTmrFormat.clock(p.seconds)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(p.running ? .white : .white.opacity(0.6))
            }
        }
    }
}

struct IslandTimerView: View {
    @ObservedObject var service: IslandTimerService
    @State private var mode = 0

    var body: some View {
        let _ = service.revision
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text("Таймер").tag(0)
                Text("Секундомер").tag(1)
                Text("Помодоро").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                switch mode {
                case 0: timer(ctx.date)
                case 1: stopwatch(ctx.date)
                default: pomodoro(ctx.date)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
    }

    private func bigClock(_ text: String, tint: Color = .white) -> some View {
        Text(text).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(tint).frame(minWidth: 130)
    }

    private func timer(_ now: Date) -> some View {
        let t = service.hub.state.timer
        return HStack(spacing: 14) {
            bigClock(IslTmrFormat.clock(t.phase == .idle || t.phase == .finished ? Double(service.settings.defaultMinutes * 60) : t.remaining(at: now)), tint: t.phase == .paused ? .white.opacity(0.55) : .white)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    IslIconButton(symbol: t.phase == .running ? "pause.fill" : "play.fill", size: 16, background: true, help: t.phase == .running ? "Пауза" : "Старт") { service.toggleTimer() }
                    IslIconButton(symbol: "arrow.counterclockwise", size: 14, help: "Сбросить") { service.reset(.timer) }
                    IslIconButton(symbol: "plus.circle", size: 14, help: "Добавить минуту") { service.addTime(60) }
                }
                HStack(spacing: 5) {
                    ForEach([5, 10, 15, 25, 45], id: \.self) { m in
                        Button("\(m)") { service.startTimer(minutes: m) }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                            .frame(width: 30, height: 22).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func stopwatch(_ now: Date) -> some View {
        let s = service.hub.state.stopwatch
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                bigClock(IslTmrFormat.stopwatch(s.elapsed(at: now)))
                if let last = s.lapSplits.last { Text("Круг \(s.laps.count): \(IslTmrFormat.stopwatch(last))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.6)) }
            }
            HStack(spacing: 6) {
                IslIconButton(symbol: s.phase == .running ? "pause.fill" : "play.fill", size: 16, background: true, help: s.phase == .running ? "Пауза" : "Старт") { service.toggleStopwatch() }
                IslIconButton(symbol: "flag", size: 14, help: "Круг") { service.lap() }
                IslIconButton(symbol: "arrow.counterclockwise", size: 14, help: "Сбросить") { service.reset(.stopwatch) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pomodoro(_ now: Date) -> some View {
        let p = service.hub.state.pomodoro
        let cfg = service.settings.pomodoro
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                bigClock(IslTmrFormat.clock(p.remaining(at: now, settings: cfg)), tint: p.phase.isBreak ? Theme.ok : .white)
                Text(p.label(settings: cfg) + (p.completedFocus > 0 ? " · сессий: \(p.completedFocus)" : "")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 6) {
                IslIconButton(symbol: p.clock.phase == .running ? "pause.fill" : "play.fill", size: 16, background: true, help: p.clock.phase == .running ? "Пауза" : "Старт") { service.togglePomodoro() }
                IslIconButton(symbol: "forward.end.fill", size: 13, help: "Пропустить фазу") { service.skipPomodoro() }
                IslIconButton(symbol: "arrow.counterclockwise", size: 14, help: "Сбросить") { service.reset(.pomodoro) }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct IslandTimerSettings: View {
    @ObservedObject var service: IslandTimerService

    private func binding<T>(_ kp: WritableKeyPath<IslTmrSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        Section {
            IslandStepperRow(symbol: "timer", title: "Таймер по умолчанию", value: binding(\.defaultMinutes), range: IslTmrSettings.minutesRange, unit: " мин")
            Toggle(isOn: binding(\.hideCountdown)) { SettingLabel("Скрывать обратный отсчёт в закрытом острове", "Вместо цифр показывается кольцо прогресса") }
            Toggle("Звук по окончании", isOn: binding(\.soundEnabled))
            if service.settings.soundEnabled {
                Picker("Какой звук", selection: binding(\.sound)) { ForEach(IslTmrSounds.names, id: \.self) { Text($0).tag($0) } }
                Button("Проверить звук") { NSSound(named: NSSound.Name(service.settings.sound))?.play() }
                IslandStepperRow(symbol: "repeat", title: "Сколько раз сыграть", value: binding(\.soundRepeats), range: IslTmrSettings.repeatsRange)
            }
        } header: { Text("Таймер") }
        Section {
            IslandStepperRow(symbol: "brain.head.profile", title: "Фокус", value: pomBinding(\.focusMinutes), range: IslPomSettings.focusRange, unit: " мин")
            IslandStepperRow(symbol: "cup.and.saucer", title: "Короткий перерыв", value: pomBinding(\.shortMinutes), range: IslPomSettings.shortRange, unit: " мин")
            IslandStepperRow(symbol: "bed.double", title: "Длинный перерыв", value: pomBinding(\.longMinutes), range: IslPomSettings.longRange, unit: " мин")
            IslandStepperRow(symbol: "number", title: "Сессий до длинного перерыва", value: pomBinding(\.sessionsBeforeLong), range: IslPomSettings.sessionsRange)
            Toggle("Следующая фаза стартует сама", isOn: pomBinding(\.autoStart))
        } header: { Text("Помодоро") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SectionFooter("Сочетания клавиш (запустить / сбросить таймер) назначаются на странице «Горячие клавиши».")
                Button("Открыть «Горячие клавиши»") { AppController.shared.openSection("keys") }.buttonStyle(.link)
            }
        }
    }

    private func pomBinding<T>(_ kp: WritableKeyPath<IslPomSettings, T>) -> Binding<T> {
        Binding(get: { service.settings.pomodoro[keyPath: kp] }, set: { v in var s = service.settings; s.pomodoro[keyPath: kp] = v; service.update(s) })
    }
}
