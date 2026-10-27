import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class LiveWallpaperModule: Module {
    let info = ModuleID.liveWallpaper.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    var quickTile: AnyView? { AnyView(LiveWallpaperTile()) }
    var panelPresentation: PanelPresentation { .module }

    func start() {
        LiveWallpaperController.shared.start()
        Log.write("module liveWallpaper start")
    }

    func stop() {
        LiveWallpaperController.shared.stop()
        Log.write("module liveWallpaper stop")
    }
}

@MainActor
final class StaticWallpaperModule: Module {
    let info = ModuleID.staticWallpaper.info
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }
    func start() { Log.write("module staticWallpaper start") }
    func stop() { Log.write("module staticWallpaper stop") }
}

struct LiveWallpaperTile: View {
    @ObservedObject private var c = LiveWallpaperController.shared

    private var status: String {
        c.status.pauseReason.map { "пауза: \(pauseReasonText($0))" } ?? (c.status.videoName ?? "нет роликов")
    }

    var body: some View {
        ModuleTile(symbol: c.manualPause ? "play.fill" : (c.status.isDay ? "sun.max.fill" : "moon.stars.fill"), title: "Обои", status: status,
                   active: !c.manualPause && c.status.playing > 0, action: { c.togglePause() }, options: { options })
    }

    @ViewBuilder private var options: some View {
        ForEach(DayMode.allCases, id: \.self) { m in
            Button((c.dayMode == m ? "✓ " : "") + m.title) { c.setDayMode(m) }
        }
        Divider()
        Button(c.manualPause ? "Продолжить" : "Поставить на паузу") { c.togglePause() }
    }
}

func pauseReasonText(_ r: PauseReason) -> String {
    switch r {
    case .manual: "вручную"
    case .locked: "экран заблокирован"
    case .asleep: "сон"
    case .battery: "батарея"
    case .occluded: "закрыто окном"
    case .covered: "перекрыто окнами"
    }
}
