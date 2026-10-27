import SwiftUI
import MultitulCore
import MultitulUI

@MainActor
final class DemoClockModule: Module {
    let info = ModuleID.demoClock.info
    func start() { Log.write("demoClock start") }
    func stop() { Log.write("demoClock stop") }
    var settingsView: AnyView { AnyView(DemoClockCard()) }
    var quickTile: AnyView? { AnyView(DemoClockTile()) }
}

private func clockText(_ date: Date, seconds: Bool) -> String {
    let f = DateFormatter()
    f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: date)
}

struct DemoClockTile: View {
    @AppStorage("demoClock.showSeconds") private var seconds = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            QuickTile(symbol: "clock", caption: clockText(ctx.date, seconds: seconds)) { seconds.toggle() }
        }
    }
}

struct DemoClockCard: View {
    @AppStorage("demoClock.showSeconds") private var seconds = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(clockText(ctx.date, seconds: seconds))
                    .font(.largeTitle.monospacedDigit())
                    .contentTransition(.numericText())
            }
            Toggle("Показывать секунды", isOn: $seconds)
        }
    }
}
