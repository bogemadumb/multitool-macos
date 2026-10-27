import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

enum CleanDefaultsKeys {
    static let screenshotDays = "cleaner.screenshotDays"
    static let iosDays = "cleaner.iosBackupDays"
    static let waDownloads = "cleaner.whatsapp.downloads"
    static let waContainer = "cleaner.whatsapp.container"
}

// Timers that live as long as the module is on: safe auto-clean (cleaner) and the deferred `uv cache prune` retry (razbor).
@MainActor
final class CleanMaintenance {
    static let shared = CleanMaintenance()
    private var autoTimer: Timer?
    private var uvTimer: Timer?
    private var autoBusy = false
    private var uvBusy = false

    func startAuto() {
        guard autoTimer == nil else { return }
        Notifier.shared.requestAuthorization()
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in CleanMaintenance.shared.autoTick() }
        }
        autoTick()
    }

    func stopAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    func startUvRetry() {
        guard uvTimer == nil else { return }
        Notifier.shared.requestAuthorization()
        uvTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in CleanMaintenance.shared.uvTick() }
        }
    }

    func stopUvRetry() {
        uvTimer?.invalidate()
        uvTimer = nil
    }

    private func autoTick() {
        var s = CleanerSchedule.load()
        guard !autoBusy, s.isDue(now: Date()) else { return }
        autoBusy = true
        s.lastRun = Date().timeIntervalSince1970
        s.save()
        Task {
            let out = await Task.detached { () -> AutoCleanOutcome in
                var env = CleanEnv.live()
                CleanEnvSettings.apply(to: &env)
                return CleanerAuto.run(env: env)
            }.value
            autoBusy = false
            Notifier.shared.post(title: out.title, body: out.body, id: "clean-auto-\(Int(Date().timeIntervalSince1970))")
            Log.write("cleaner auto: \(out.body)")
        }
    }

    private func uvTick() {
        guard !uvBusy else { return }
        uvBusy = true
        Task {
            let outcome = await Task.detached { uvRetryPending(env: AnalysisEnv.live()) }.value
            uvBusy = false
            guard let outcome else { return }
            Log.write("razbor uv retry: \(outcome.text)")
            if outcome == .done { Notifier.shared.post(title: "Разбор", body: "uv cache prune выполнен после ожидания", id: "clean-uv-\(Int(Date().timeIntervalSince1970))") }
        }
    }
}

enum CleanEnvSettings {
    static func apply(to env: inout CleanEnv) {
        let d = UserDefaults.standard
        if let v = d.object(forKey: CleanDefaultsKeys.screenshotDays) as? Int { env.screenshotDays = max(v, 1) }
        if let v = d.object(forKey: CleanDefaultsKeys.iosDays) as? Int { env.iosBackupDays = max(v, 1) }
        var wa = WhatsAppRules.load(d)
        wa.includeDownloads = d.object(forKey: CleanDefaultsKeys.waDownloads) as? Bool ?? true
        wa.includeContainer = d.object(forKey: CleanDefaultsKeys.waContainer) as? Bool ?? true
        env.whatsapp = wa
    }
}

@MainActor
final class CleanModule: Module {
    let info: ModuleInfo
    init(id: ModuleID) { info = id.info }
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    func start() {
        switch info.id {
        case .cleaner: CleanMaintenance.shared.startAuto()
        case .razbor: CleanMaintenance.shared.startUvRetry()
        default: break
        }
        Log.write("module \(info.id.rawValue) start")
    }

    func stop() {
        switch info.id {
        case .cleaner: CleanMaintenance.shared.stopAuto()
        case .razbor: CleanMaintenance.shared.stopUvRetry()
        default: break
        }
        Log.write("module \(info.id.rawValue) stop")
    }
}
