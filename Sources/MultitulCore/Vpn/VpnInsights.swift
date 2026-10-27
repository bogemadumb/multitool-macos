import Foundation
import SwiftUI

@MainActor
public final class VpnInsightsModel: ObservableObject {
    @Published public var range: VpnChartRange = .hour
    @Published public private(set) var buckets: [VpnBucket?] = []
    @Published public private(set) var events: [VpnEventRow] = []
    @Published public private(set) var apps: [VpnAppRow] = []
    @Published public private(set) var todayVPS = 0.0
    @Published public private(set) var todayDirect = 0.0
    @Published public private(set) var avgDelay: Int?
    @Published public private(set) var sampleCount = 0
    @Published public private(set) var loaded = false

    private let history: VpnHistoryStore?
    private let clock: () -> Date
    private let calendar: Calendar

    public init(history: VpnHistoryStore?, clock: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.history = history
        self.clock = clock
        self.calendar = calendar
    }

    public var available: Bool { history != nil }
    public var todayTotal: Double { todayVPS + todayDirect }
    public var journal: [VpnEventDay] { VpnEventGrouping.group(events, now: clock(), calendar: calendar) }

    public func setRange(_ r: VpnChartRange) {
        range = r
        Task { await refresh() }
    }

    public func refresh() async {
        guard let history else { return }
        let r = range
        let now = clock()
        let out = await Task.detached {
            (history.series(r, now: now), history.events(limit: 500), history.trafficRows(day: now, limit: 8),
             history.trafficTotals(day: now), history.averageDelay(since: now.addingTimeInterval(-3600)), history.sampleCount())
        }.value
        buckets = out.0
        events = out.1
        apps = out.2
        todayVPS = out.3.vps
        todayDirect = out.3.direct
        avgDelay = out.4.map { Int($0.rounded()) }
        sampleCount = out.5
        loaded = true
    }

    // Runs until the owning view goes away.
    public func run(every seconds: UInt64 = 5) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }
}
