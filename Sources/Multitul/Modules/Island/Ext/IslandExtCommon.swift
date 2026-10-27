import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

@MainActor
final class IslandExtModule: Module {
    let info: ModuleInfo
    private let onStart: () -> Void
    private let onStop: () -> Void
    var wantsCard: Bool { false }
    var settingsView: AnyView { AnyView(EmptyView()) }

    init(_ id: ModuleID, start: @escaping () -> Void, stop: @escaping () -> Void) {
        info = id.info
        onStart = start
        onStop = stop
    }

    func start() {
        onStart()
        Log.write("module \(info.id.rawValue) start")
        IslandController.shared.modulesChanged()
    }

    func stop() {
        onStop()
        Log.write("module \(info.id.rawValue) stop")
        IslandController.shared.modulesChanged()
    }
}

@MainActor
func makeIslandExtModule(_ id: ModuleID) -> Module {
    switch id {
    case .notchCalendar: IslandExtModule(id, start: { IslandCalendarService.shared.start() }, stop: { IslandCalendarService.shared.stop() })
    case .notchNotifications: IslandExtModule(id, start: { IslandNotificationsService.shared.start() }, stop: { IslandNotificationsService.shared.stop() })
    case .notchTimer: IslandExtModule(id, start: { IslandTimerService.shared.start() }, stop: { IslandTimerService.shared.stop() })
    case .notchAccessories: IslandExtModule(id, start: { IslandAccessoriesService.shared.start() }, stop: { IslandAccessoriesService.shared.stop() })
    case .notchLyrics: IslandExtModule(id, start: { IslandLyricsService.shared.start() }, stop: { IslandLyricsService.shared.stop() })
    case .notchQueue: IslandExtModule(id, start: { IslandQueueService.shared.start() }, stop: { IslandQueueService.shared.stop() })
    case .notchLiveEq: IslandExtModule(id, start: { IslandEqService.shared.start() }, stop: { IslandEqService.shared.stop() })
    case .notchDownloads: IslandExtModule(id, start: { IslandDownloadsService.shared.start() }, stop: { IslandDownloadsService.shared.stop() })
    case .notchWatch: IslandExtModule(id, start: { IslandWatchService.shared.start() }, stop: { IslandWatchService.shared.stop() })
    case .notchMascot: IslandExtModule(id, start: { IslandMascotService.shared.start() }, stop: { IslandMascotService.shared.stop() })
    default: fatalError("not an island extension: \(id.rawValue)")
    }
}

struct IslandNote: View {
    let text: String
    var tint: Color = .white.opacity(0.5)

    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }
}

struct IslandStepperRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""

    var body: some View {
        StepperSetting(title, subtitle, value: $value, in: range, unit: unit)
    }
}

enum IslandExtTime {
    static func shortClock(_ date: Date) -> String {
        IslCalFormat.time(date, tz: .current)
    }
}
