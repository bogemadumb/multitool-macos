import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class AutoPipController: ObservableObject {
    static let shared = AutoPipController()

    @Published private(set) var settings = AutoPipSettings()
    @Published private(set) var events: [String] = []
    @Published private(set) var automationDenied = false
    @Published private(set) var jsBlocked = false
    @Published private(set) var inPip = 0

    private let store = AutoPipStore()
    private var machine = AutoPipMachine()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private let queue = DispatchQueue(label: "dev.multitool.app.autopip.applescript")

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        machine = AutoPipMachine(settings: settings)
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app.activationPolicy == .regular else { return }
                self.run(self.machine.appActivated(app.bundleIdentifier))
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.run(self.machine.spaceChanged()) } }
        })
        run(machine.start(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
        log("started pid=\(getpid())")
    }

    func stop() {
        guard running else { return }
        running = false
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        run(machine.stop())
        log("stopped")
    }

    func update(_ s: AutoPipSettings) {
        let old = settings
        settings = s.sanitized
        store.save(settings)
        machine.settings = settings
        if running, old.pollInterval != settings.pollInterval, timer != nil { startTimer() }
    }

    private func log(_ text: String) {
        Log.write("autoPip \(text)")
        events.append(text)
        if events.count > 12 { events.removeFirst(events.count - 12) }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: settings.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.run(self.machine.timerFired()) } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func run(_ effects: [AutoPipEffect]) {
        for e in effects {
            switch e {
            case .startPolling: startTimer()
            case .stopPolling: timer?.invalidate(); timer = nil
            case .poll:
                queue.async {
                    let raw = Self.runScript(AutoPipScripts.pollScript)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.noteError(raw)
                            if AutoPipScripts.parseTab(raw) == nil, raw != "none" { self.log("poll: \(raw)") }
                            self.run(self.machine.pollResult(raw))
                        }
                    }
                }
            case .pollThenEnter(let reason, let cached):
                queue.async {
                    let fresh = AutoPipScripts.parseTab(Self.runScript(AutoPipScripts.pollScript))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if fresh == nil && cached == nil { self.log("leave [\(reason)]: no tab") }
                            self.run(self.machine.leaveResolved(fresh: fresh, cached: cached, reason: reason))
                        }
                    }
                }
            case .enter(let tab, let reason):
                let code = AutoPipScripts.enterJS(minWidth: settings.minWidth, minHeight: settings.minHeight)
                queue.async {
                    let r = Self.runScript(AutoPipScripts.doJavaScript(code, in: tab))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.noteError(r)
                            self.log("enter [\(reason)] win=\(tab.win) tab=\(tab.tab) url=\(tab.url) -> \(r)")
                            self.run(self.machine.enterResult(tab, result: r))
                            self.inPip = self.machine.auto.count
                        }
                    }
                }
            case .verify(let tab):
                queue.asyncAfter(deadline: .now() + settings.verifyDelay) {
                    let r = Self.runScript(AutoPipScripts.doJavaScript(AutoPipScripts.statusJS, in: tab))
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.log("verify win=\(tab.win) tab=\(tab.tab) -> \(r)") } }
                }
            case .exit(let tab):
                queue.async {
                    let r = Self.runScript(AutoPipScripts.doJavaScript(AutoPipScripts.exitJS, in: tab))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.log("exit win=\(tab.win) tab=\(tab.tab) -> \(r)")
                            self.inPip = self.machine.auto.count
                        }
                    }
                }
            case .settleCheck(let after):
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    MainActor.assumeIsolated {
                        self.run(self.machine.spaceSettled(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
                    }
                }
            }
        }
    }

    private func noteError(_ r: String) {
        guard r.hasPrefix("ERR") else {
            if automationDenied || jsBlocked { automationDenied = false; jsBlocked = false }
            return
        }
        automationDenied = r.contains("-1743")
        jsBlocked = r.localizedCaseInsensitiveContains("Apple Events") && !automationDenied
    }

    nonisolated private static func runScript(_ src: String) -> String {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src) else { return "ERR: compile" }
        let d = s.executeAndReturnError(&err)
        if let e = err { return "ERR \(e["NSAppleScriptErrorNumber"] ?? "?"): \(e["NSAppleScriptErrorMessage"] ?? "?")" }
        return d.stringValue ?? ""
    }
}

@MainActor
final class AutoPipModule: Module {
    let info = ModuleID.autoPip.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(AutoPipTile()) }

    func start() {
        AutoPipController.shared.start()
        Log.write("module autoPip start")
    }

    func stop() {
        AutoPipController.shared.stop()
        Log.write("module autoPip stop")
    }
}

struct AutoPipTile: View {
    @ObservedObject private var c = AutoPipController.shared

    var body: some View {
        QuickTile(symbol: "pip.fill", caption: "PiP", active: c.settings.safariEnabled, help: c.settings.safariEnabled ? "PiP: авто" : "PiP: пауза") {
            var s = c.settings
            s.safariEnabled.toggle()
            c.update(s)
        }
    }
}

struct AutoPipSections: View {
    @ObservedObject private var c = AutoPipController.shared

    private func binding<T>(_ kp: WritableKeyPath<AutoPipSettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in var s = c.settings; s[keyPath: kp] = v; c.update(s) })
    }

    var body: some View {
        if c.automationDenied || c.jsBlocked {
            Section {
                if c.automationDenied { ToolWarning(text: "Нет доступа «Автоматизация» к Safari: разреши Мультитулу управлять Safari в Настройках → Конфиденциальность → Автоматизация.") }
                if c.jsBlocked { ToolWarning(text: "В Safari выключено «Разрешить JavaScript из Apple Events» (меню «Разработка»): включи его, иначе видео не выйдет в PiP.") }
            }
        }
        Section {
            Toggle(isOn: binding(\.safariEnabled)) { SettingLabel("Работать с Safari", "Выключено: модуль загружен, но ничего не опрашивает и не включает") }
            Toggle(isOn: binding(\.exitOnReturn)) { SettingLabel("Выключать PiP при возвращении", "Вернулся на вкладку — видео снова во вкладке") }
            if c.inPip > 0 { LabeledContent("Сейчас в PiP", value: "\(c.inPip)") }
        } header: { Text("Авто-PiP для Safari") } footer: {
            SectionFooter("Ушёл из Safari (другое приложение, вкладка, рабочий стол) — играющее видео уходит в PiP; вернулся — PiP выключается. Нужны: доступ «Автоматизация» к Safari и пункт «Разработка → Разрешить JavaScript из Apple Events». Telegram и другие браузеры не поддерживаются.")
        }
        Section("Определение видео") {
            Picker(selection: binding(\.pollInterval)) {
                ForEach(AutoPipSettings.pollChoices, id: \.self) { Text(String(format: "%.1f с", $0)).tag($0) }
            } label: { SettingLabel("Опрос Safari", "Как часто спрашивать адрес вкладки, пока Safari впереди") }
            StepperSetting("Минимальная ширина видео", "Мелкие ролики (превью, баннеры) в PiP не уходят", value: binding(\.minWidth), in: 40...1920, step: 20, unit: " пикс.")
            StepperSetting("Минимальная высота видео", value: binding(\.minHeight), in: 40...1080, step: 10, unit: " пикс.")
        }
        if !c.events.isEmpty {
            Section("Последние события") {
                ForEach(Array(c.events.suffix(6).enumerated()), id: \.offset) { _, e in
                    Text(e).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
