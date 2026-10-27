import Foundation
import AppKit
import MultitulCtlCore

public enum TvProtectedDisplays {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: Set<UInt32> = []

    public static var ids: Set<UInt32> {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

public protocol AppControlling {
    func isRunning(_ name: String) -> Bool
    func launch(_ name: String)
    func hide(_ name: String)
    func quit(_ name: String)
}

public struct SystemAppControl: AppControlling {
    public init() {}

    private func find(_ name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
    }

    public func isRunning(_ name: String) -> Bool { find(name) != nil }
    public func launch(_ name: String) { _ = SystemProcessRunner().run("/usr/bin/open", ["-a", name], timeout: 15) }
    public func hide(_ name: String) { _ = find(name)?.hide() }
    public func quit(_ name: String) { _ = find(name)?.terminate() }
}

public struct TvSessionError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum TvState: Equatable, Sendable {
    case idle
    case starting(String)
    case running(TvMode)
    case stopping
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }
    public var isActive: Bool {
        switch self {
        case .running, .starting: true
        default: false
        }
    }
}

public struct TvSessionDeps {
    public var runner: ProcessRunning
    public var apps: AppControlling
    public var upnp: UpnpTransporting
    public var engine: TvStreamEngine
    public var browser: TvBrowserLaunching
    public var sleep: (TimeInterval) -> Void
    public var exists: (String) -> Bool
    public var localIP: (String) -> String?
    public var log: (String) -> Void

    public init(runner: ProcessRunning, apps: AppControlling, upnp: UpnpTransporting, engine: TvStreamEngine, browser: TvBrowserLaunching,
                sleep: @escaping (TimeInterval) -> Void, exists: @escaping (String) -> Bool, localIP: @escaping (String) -> String?, log: @escaping (String) -> Void) {
        self.runner = runner
        self.apps = apps
        self.upnp = upnp
        self.engine = engine
        self.browser = browser
        self.sleep = sleep
        self.exists = exists
        self.localIP = localIP
        self.log = log
    }

    public static func live(engine: TvStreamEngine = TvStreamServer(), log: @escaping (String) -> Void) -> TvSessionDeps {
        TvSessionDeps(runner: SystemProcessRunner(environment: TvCommands.toolEnvironment), apps: SystemAppControl(), upnp: URLSessionUpnpTransport(),
                      engine: engine, browser: SamsungBrowserLauncher(), sleep: { Thread.sleep(forTimeInterval: $0) },
                      exists: { FileManager.default.fileExists(atPath: $0) }, localIP: { TvNetwork.localIP(toward: $0) }, log: log)
    }
}

public final class TvSessionRunner: @unchecked Sendable {
    public var config: TvConfig
    public let deps: TvSessionDeps

    public init(config: TvConfig, deps: TvSessionDeps) {
        self.config = config
        self.deps = deps
    }

    private func placer(_ args: [String]) -> ProcessOutput {
        deps.runner.run(config.displayplacerPath, args, timeout: 30)
    }

    private func screens() -> (built: PlacerDisplay?, virt: PlacerDisplay?) {
        let out = placer(["list"])
        return DisplayplacerParser.findScreens(DisplayplacerParser.parse(out.stdout), mainId: config.mainDisplayId, virtualId: config.virtualDisplayId)
    }

    public func hideDeskpad() { deps.apps.hide(config.deskpadName) }

    // Port of televizor.py / brauzer.py main(): DeskPad, placement, server, then tell the TV.
    public func start(mode: TvMode) throws {
        let problems = config.validate()
        if let p = problems.first { throw TvSessionError("настройки: \(p)") }
        guard deps.exists(config.displayplacerPath) else {
            throw TvSessionError("displayplacer не найден по пути \(config.displayplacerPath); поставь: brew install displayplacer")
        }
        if deps.apps.isRunning(config.deskpadName) {
            deps.log("виртуальный экран уже поднят")
        } else {
            deps.log("поднимаю виртуальный экран (\(config.deskpadName))")
            deps.apps.launch(config.deskpadName)
            deps.sleep(TimeInterval(config.deskpadBootDelay))
        }
        let first = screens()
        guard let built = first.built, let virt = first.virt else {
            throw TvSessionError("виртуальный экран не найден: открой \(config.deskpadName) вручную")
        }
        _ = placer(TvPlacement.arrangeArgs(builtID: built.id, virtualID: virt.id, config: config))
        deps.sleep(TimeInterval(config.arrangeDelay))
        hideDeskpad()
        deps.log("второй экран \(config.width)x\(config.height) поставлен справа от основного (окно-превью скрыто)")
        guard let ctx = screens().virt.flatMap({ UInt32($0.ctx) }) else {
            throw TvSessionError("не удалось узнать номер виртуального экрана после раскладки")
        }
        TvProtectedDisplays.ids = [ctx]
        deps.log("экран для трансляции: id \(ctx)")
        do {
            try deps.engine.start(mode: mode, displayID: ctx, config: config)
        } catch {
            teardown(mode: nil)
            throw TvSessionError("\(error)")
        }
        guard let ip = deps.localIP(config.tvIP) else {
            teardown(mode: mode)
            throw TvSessionError("не удалось определить свой адрес в сети телевизора \(config.tvIP)")
        }
        deps.sleep(TimeInterval(config.castDelay))
        switch mode {
        case .screen:
            let url = config.streamURL(localIP: ip)
            for f in UpnpClient(transport: deps.upnp, config: config).cast(url: url) {
                deps.log("телевизор не принял \(f.step): \(f.result.summary)")
            }
        case .fast:
            deps.log(deps.browser.openBrowser(url: config.fastURL(localIP: ip), config: config))
        }
        deps.log("готово: перетаскивай окна вправо за край экрана — они появятся на телевизоре")
    }

    public func stop(mode: TvMode?) {
        deps.log("выключаю")
        teardown(mode: mode)
    }

    private func teardown(mode: TvMode?) {
        if mode == .screen { _ = UpnpClient(transport: deps.upnp, config: config).stop() }
        deps.engine.stop()
        deps.apps.quit(config.deskpadName)
        deps.sleep(1)
        if let built = screens().built {
            _ = placer(TvPlacement.restoreArgs(builtID: built.id, config: config))
        }
        TvProtectedDisplays.ids = []
        deps.log("второй экран убран, телевизор свободен")
    }

    // MARK: sound

    @discardableResult
    public func routeAudio(toTv: Bool) -> String {
        let device = toTv ? config.audioTvDevice : config.audioMacDevice
        guard deps.exists(config.switchAudioPath) else {
            return "SwitchAudioSource не найден по пути \(config.switchAudioPath); поставь: brew install switchaudio-osx"
        }
        let r = deps.runner.run(config.switchAudioPath, TvAudio.setArgs(device), timeout: 15)
        if r.status != 0 { return "не удалось переключить звук на «\(device)»: \(r.stderr.isEmpty ? r.stdout : r.stderr)" }
        return toTv ? "Весь звук Мака теперь идёт на телевизор («\(device)»)." : "Звук вернулся на «\(device)»."
    }

    public func currentAudioDevice() -> String? {
        guard deps.exists(config.switchAudioPath) else { return nil }
        let r = deps.runner.run(config.switchAudioPath, TvAudio.currentArgs, timeout: 10)
        return r.status == 0 ? TvAudio.parseCurrent(r.stdout) : nil
    }

    // MARK: Acer

    public func remote(_ action: String) -> String {
        guard deps.exists(config.resolvedRemoteScript) else { return "нет скрипта \(config.resolvedRemoteScript)" }
        let cmd = TvCommands.remote(action, config: config)
        let r = deps.runner.run(cmd.exe, cmd.args, timeout: 180)
        if r.timedOut { return "скрипт домашнего сервера не уложился в 180 с" }
        let text = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "готово (код \(r.status))" : text
    }

    // MARK: dependencies

    public func dependencies() -> DependencyReport {
        let brew = deps.exists(config.brewPath)
        var formulae = Set<String>(), casks = Set<String>()
        if brew {
            formulae = TvDependencies.parseBrewList(deps.runner.run(config.brewPath, ["list", "--formula", "-1"], timeout: 30).stdout)
            casks = TvDependencies.parseBrewList(deps.runner.run(config.brewPath, ["list", "--cask", "-1"], timeout: 30).stdout)
        }
        return TvDependencies.evaluate(config: config, formulae: formulae, casks: casks, brewAvailable: brew, exists: deps.exists)
    }
}
