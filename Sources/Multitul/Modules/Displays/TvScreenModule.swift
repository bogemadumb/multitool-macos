import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class TvScreenController: ObservableObject {
    static let shared = TvScreenController()

    @Published private(set) var state: TvState = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var config: TvConfig
    @Published private(set) var report: DependencyReport?
    @Published private(set) var audioNote: String?
    @Published private(set) var currentAudio: String?
    @Published private(set) var remoteOutput: String?
    @Published private(set) var remoteBusy = false

    private let engine = TvStreamServer()
    private let work = DispatchQueue(label: "dev.multitool.app.tv.work")
    private let remoteQueue = DispatchQueue(label: "dev.multitool.app.tv.remote")
    private var runner: TvSessionRunner
    private var watchdog: Timer?
    private var mode: TvMode?

    init() {
        let cfg = TvSettings.load()
        config = cfg
        let logger: (String) -> Void = { msg in DispatchQueue.main.async { MainActor.assumeIsolated { TvScreenController.shared.append(msg) } } }
        runner = TvSessionRunner(config: cfg, deps: .live(engine: engine, log: logger))
        engine.onEvent = logger
    }

    private func append(_ s: String) {
        log.append(s)
        if log.count > 60 { log.removeFirst(log.count - 60) }
        Log.write("tvScreen " + s)
    }

    func stopModule() {
        guard state.isActive || state.isBusy else { return }
        stopWatchdog()
        let m = mode
        work.sync { runner.stop(mode: m) }
        state = .idle
        mode = nil
    }

    func begin(_ m: TvMode) {
        guard !state.isBusy, !state.isActive else { return }
        state = .starting("запускаю…")
        mode = m
        let r = runner
        work.async { [weak self] in
            do {
                try r.start(mode: m)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.state = .running(m); self?.startWatchdog() } }
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.state = .failed("\(error)"); self?.mode = nil } }
            }
        }
    }

    func end() {
        guard state.isActive else { return }
        let m = mode
        state = .stopping
        stopWatchdog()
        let r = runner
        work.async { [weak self] in
            r.stop(mode: m)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.state = .idle; self?.mode = nil } }
        }
    }

    func toggleFromTile() {
        if state.isActive { end() } else { begin(.screen) }
    }

    private func startWatchdog() {
        stopWatchdog()
        let r = runner
        watchdog = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(config.watchdogSeconds, 1)), repeats: true) { _ in r.hideDeskpad() }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    func route(toTv: Bool) {
        let r = runner
        work.async { [weak self] in
            let note = r.routeAudio(toTv: toTv)
            let cur = r.currentAudioDevice()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioNote = note; self?.currentAudio = cur } }
        }
    }

    func refreshAudio() {
        let r = runner
        work.async { [weak self] in
            let cur = r.currentAudioDevice()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.currentAudio = cur } }
        }
    }

    func remote(_ action: String) {
        guard !remoteBusy else { return }
        remoteBusy = true
        remoteOutput = "выполняю…"
        let r = runner
        remoteQueue.async { [weak self] in
            let out = r.remote(action)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remoteOutput = out; self?.remoteBusy = false } }
        }
    }

    func checkDependencies() {
        let r = runner
        work.async { [weak self] in
            let rep = r.dependencies()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report = rep } }
        }
    }

    func apply(_ c: TvConfig) {
        guard !state.isActive, !state.isBusy else { return }
        TvSettings.save(c)
        config = c
        runner.config = c
    }

    func resetConfig() {
        guard !state.isActive, !state.isBusy else { return }
        TvSettings.reset()
        let c = TvConfig()
        config = c
        runner.config = c
    }
}

@MainActor
final class TvScreenModule: Module {
    let info = ModuleID.tvScreen.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(TvScreenTile()) }
    var panelPresentation: PanelPresentation { .module }

    func start() { Log.write("module tvScreen start") }

    func stop() {
        TvScreenController.shared.stopModule()
        Log.write("module tvScreen stop")
    }
}

struct TvScreenTile: View {
    @ObservedObject private var c = TvScreenController.shared

    private var status: String {
        switch c.state {
        case .idle: "Выключен"
        case .starting: "Запуск…"
        case .running: "Идёт"
        case .stopping: "Остановка…"
        case .failed: "Ошибка"
        }
    }

    var body: some View {
        ModuleTile(symbol: "tv.fill", title: "Телевизор", status: status, active: c.state.isActive) { c.toggleFromTile() }
    }
}

struct TvScreenView: View {
    @ObservedObject private var c = TvScreenController.shared
    @State private var draft = TvConfig()
    @State private var loaded = false

    private func stateText() -> String {
        switch c.state {
        case .idle: "выключен"
        case .starting(let s): s
        case .running(let m): m == .screen ? "идёт со звуком" : "идёт быстрый режим"
        case .stopping: "выключаю…"
        case .failed(let m): "ошибка: \(m)"
        }
    }

    var body: some View {
        SettingsPage {
            statusSection
            soundSection
            remoteSection
            dependenciesSection
            settingsSection
            logSection
        }
        .onAppear {
            if !loaded { draft = c.config; loaded = true }
            c.checkDependencies()
            c.refreshAudio()
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if c.state.isBusy { ProgressView().controlSize(.small) }
                    switch c.state {
                    case .running: StatusLabel(stateText(), color: .green)
                    case .failed: StatusLabel(stateText(), color: .orange)
                    default: Text(stateText()).foregroundStyle(.secondary)
                    }
                }
            } label: { Label("Телевизор \(c.config.tvIP)", systemImage: "tv") }
            Button("Включить со звуком") { c.begin(.screen) }.disabled(c.state.isActive || c.state.isBusy)
            Button("Быстрый режим (без звука)") { c.begin(.fast) }.disabled(c.state.isActive || c.state.isBusy)
            Button("Выключить") { c.end() }.disabled(!c.state.isActive)
        } header: { Text("Трансляция") } footer: {
            SectionFooter("Со звуком: картинка около 4,3 с позади (буфер самого ТВ), звук синхронный. Быстрый: доли секунды, звука нет. Выключение убирает DeskPad и возвращает масштаб основного экрана.")
        }
    }

    private var soundSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("На телевизор") { c.route(toTv: true) }
                    Button("Обратно на Мак") { c.route(toTv: false) }
                }
            } label: { SettingLabel("Звук", "Сейчас: \(c.currentAudio ?? "неизвестно")") }
        } footer: { if let n = c.audioNote { SectionFooter(n) } }
    }

    private var remoteSection: some View {
        Section {
            LabeledContent {
                HStack {
                    if c.remoteBusy { ProgressView().controlSize(.small) }
                    Button("Включить") { c.remote("start") }.disabled(c.remoteBusy)
                    Button("Выключить") { c.remote("stop") }.disabled(c.remoteBusy)
                    Button("Статус") { c.remote("status") }.disabled(c.remoteBusy)
                }
            } label: { SettingLabel("Экран домашнего ПК на телевизор", "Запускает home-tv.py (домашний сервер)") }
            if let o = c.remoteOutput { Text(o).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var dependenciesSection: some View {
        Section {
            if let r = c.report {
                ForEach(r.items, id: \.dep.id) { item in
                    LabeledContent {
                        StatusLabel(item.status.isPresent ? "есть" : "нет", color: item.status.isPresent ? .green : .orange)
                    } label: { SettingLabel(item.dep.title, item.dep.purpose) }
                }
                let hint = TvDependencies.installHint(r)
                if !hint.isEmpty { Text(hint).font(.body.monospaced()).textSelection(.enabled) }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Проверяю…").foregroundStyle(.secondary) }
            }
            Button("Проверить") { c.checkDependencies() }
        } header: { Text("Зависимости") }
    }

    private var settingsSection: some View {
        let locked = c.state.isActive || c.state.isBusy
        let problems = draft.validate()
        return Section {
            FieldSetting("IP телевизора", text: $draft.tvIP)
            IntFieldSetting("Ширина экрана", value: $draft.width)
            IntFieldSetting("Высота экрана", value: $draft.height)
            IntFieldSetting("Кадров в секунду", value: $draft.fps)
            FieldSetting("Битрейт", "25M, 8000k", text: $draft.bitrate)
            DisclosureGroup("Дополнительно") {
                IntFieldSetting("Порт UPnP", value: $draft.upnpPort)
                IntFieldSetting("Порт потока (со звуком)", value: $draft.streamPort)
                IntFieldSetting("Порт быстрого режима", value: $draft.fastPort)
                IntFieldSetting("GOP", "Кадров между ключевыми", value: $draft.gop)
                FieldSetting("Масштаб основного экрана", text: $draft.mainRes)
                FieldSetting("ID основного экрана", "Пусто: встроенный", text: $draft.mainDisplayId)
                FieldSetting("ID виртуального экрана", "Пусто: первый внешний", text: $draft.virtualDisplayId)
                IntFieldSetting("Быстрый режим: ширина", value: $draft.fastWidth)
                IntFieldSetting("Быстрый режим: высота", value: $draft.fastHeight)
                IntFieldSetting("Быстрый режим: кадров/с", value: $draft.fastFPS)
                IntFieldSetting("Быстрый режим: качество JPEG", "2 лучшее, 31 худшее", value: $draft.fastQuality)
                FieldSetting("Устройство звука «на ТВ»", text: $draft.audioTvDevice)
                FieldSetting("Устройство звука «на Мак»", text: $draft.audioMacDevice)
                FieldSetting("Вход звука", "Часть имени", text: $draft.audioInputMatch)
                IntFieldSetting("Сторож DeskPad", "Секунд", value: $draft.watchdogSeconds)
                FieldSetting("Скрипт домашнего сервера", text: $draft.remoteScript)
                FieldSetting("Python для скрипта домашнего сервера", text: $draft.remotePython)
                FieldSetting("displayplacer", text: $draft.displayplacerPath)
                FieldSetting("SwitchAudioSource", text: $draft.switchAudioPath)
            }
            ForEach(problems, id: \.self) { ToolWarning(text: $0) }
            Button("По умолчанию") { c.resetConfig(); draft = c.config }.disabled(locked)
            Button("Сохранить") { c.apply(draft) }.disabled(locked || !problems.isEmpty || draft == c.config)
        } header: { Text("Параметры") } footer: {
            if locked { SectionFooter("Пока трансляция идёт, параметры не меняются.") }
        }
        .disabled(locked)
    }

    private var logSection: some View {
        Section {
            if c.log.isEmpty {
                Text("Пока пусто").foregroundStyle(.secondary)
            } else {
                ForEach(Array(c.log.suffix(12).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption).textSelection(.enabled)
                }
            }
        } header: { Text("Журнал") }
    }
}
