import SwiftUI
import AppKit
import EventKit
import MultitulCore
import MultitulUI

final class IslEKSource: IslCalSource {
    private let store = EKEventStore()

    var access: IslCalAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func calendars() -> [IslCalInfo] {
        store.calendars(for: .event).map { IslCalInfo(id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex($0.cgColor)) }
    }

    static func hex(_ c: CGColor?) -> String? {
        guard let c, let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil), let k = rgb.components, k.count >= 3 else { return nil }
        return String(format: "%02X%02X%02X", Int(k[0] * 255), Int(k[1] * 255), Int(k[2] * 255))
    }

    func events(from: Date, to: Date) -> [IslCalEvent] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { e in
            let id = (e.eventIdentifier ?? e.calendarItemIdentifier) + "|" + String(Int(e.startDate.timeIntervalSince1970))
            let declined = e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            let model = IslCalEvent(id: id, title: e.title ?? "", start: e.startDate, end: e.endDate ?? e.startDate, isAllDay: e.isAllDay, calendarID: e.calendar.calendarIdentifier,
                                    calendarTitle: e.calendar.title, colorHex: Self.hex(e.calendar.cgColor), location: e.location, isCancelled: e.status == .canceled || declined)
            return IslCalZone.floatingAllDay(model, from: e.timeZone ?? .current, to: .current)
        }
    }

    func reminders(_ done: @escaping ([IslCalReminder]) -> Void) {
        func fetch() {
            let p = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: p) { list in
                let mapped = (list ?? []).map { r -> IslCalReminder in
                    let comps = r.dueDateComponents
                    let due = comps.flatMap { Calendar.current.date(from: $0) }
                    return IslCalReminder(id: r.calendarItemIdentifier, title: r.title ?? "", due: due, dueHasTime: comps?.hour != nil, completed: r.isCompleted, priority: r.priority,
                                          listTitle: r.calendar?.title ?? "")
                }
                DispatchQueue.main.async { done(mapped) }
            }
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: fetch()
        case .notDetermined: store.requestFullAccessToReminders { ok, _ in if ok { fetch() } else { DispatchQueue.main.async { done([]) } } }
        default: DispatchQueue.main.async { done([]) }
        }
    }
}

@MainActor
final class IslandCalendarService: ObservableObject {
    static let shared = IslandCalendarService()

    @Published private(set) var revision = 0
    @Published private(set) var settings: IslCalSettings
    let engine: IslCalEngine
    var onChange: (() -> Void)?
    private let store = IslCalSettingsStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private(set) var running = false

    private init() {
        let s = store.load()
        settings = s
        engine = IslCalEngine(source: IslEKSource(), settings: s)
    }

    func start() {
        guard !running else { return }
        running = true
        settings = store.load()
        engine.settings = settings
        engine.timeZone = .current
        engine.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed() } }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.reload(now: Date()) }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        engine.start(now: Date())
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine.onChange = nil
    }

    private func tick() {
        engine.tick(now: Date())
        changed()
    }

    private func changed() {
        revision &+= 1
        onChange?()
    }

    func update(_ s: IslCalSettings) {
        settings = s.sanitized
        store.save(settings)
        engine.settings = settings
        if running { engine.reload(now: Date()) }
    }

    var denied: Bool { engine.denied }

    func activity() -> IslActivity? {
        guard running, settings.countdownInClosed else { return nil }
        return engine.activity(now: Date())
    }
}

@MainActor
final class IslandCalendarSection: IslandSectionBase {
    private let service = IslandCalendarService.shared

    init() { super.init(IslSectionIDs.calendar) }

    override var availability: IslAvailability {
        if !moduleRunning(.notchCalendar) { return .unavailable("Включи модуль «Остров: календарь»") }
        return service.denied ? .unavailable("Нет доступа к календарям: разреши в настройках системы") : .available
    }

    override var activities: [IslActivity] { service.activity().map { [$0] } ?? [] }

    override func start() { service.onChange = { [weak self] in self?.notify() } }

    override func stop() { service.onChange = nil }

    override func compactLeading(_ activity: IslActivity) -> AnyView? {
        AnyView(Image(systemName: "calendar").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent))
    }

    override func compactTrailing(_ activity: IslActivity) -> AnyView? {
        AnyView(IslandCalendarCountdown(service: service, compact: true))
    }

    override func peekView(_ activity: IslActivity) -> AnyView? {
        AnyView(HStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                IslandCalendarCountdown(service: service, compact: false)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14))
    }

    override func expandedView(_ context: IslExpandContext) -> AnyView { AnyView(IslandCalendarView(service: service)) }
}

struct IslandCalendarCountdown: View {
    let service: IslandCalendarService
    var compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let c = service.engine.countdown(now: ctx.date) {
                if compact {
                    Text(c.seconds >= 3600 ? IslCalFormat.countdown(c.seconds) : IslCalFormat.compactClock(c.seconds))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(IslCalFormat.label(c)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                EmptyView()
            }
        }
    }
}

struct IslandCalendarView: View {
    @ObservedObject var service: IslandCalendarService
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())

    var body: some View {
        let _ = service.revision
        let now = Date()
        HStack(alignment: .top, spacing: 14) {
            monthView(now)
                .frame(width: 190)
            agenda(now)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private func monthView(_ now: Date) -> some View {
        let grid = IslCalMonthGrid.build(year: year, month: month, events: service.engine.visibleEvents, now: now, tz: .current)
        return VStack(spacing: 3) {
            HStack {
                IslIconButton(symbol: "chevron.left", size: 10, help: "Предыдущий месяц") { shift(-1) }
                Spacer()
                Text(IslCalMonthGrid.title(year: year, month: month)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).onTapGesture { resetToToday() }
                Spacer()
                IslIconButton(symbol: "chevron.right", size: 10, help: "Следующий месяц") { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(IslCalMonthGrid.weekdaySymbols(), id: \.self) { Text($0).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity) }
            }
            ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        ZStack {
                            if cell.isToday { Circle().fill(Theme.accent).frame(width: 18, height: 18) }
                            VStack(spacing: 0) {
                                Text("\(cell.day)").font(.system(size: 10.5, weight: cell.isToday ? .bold : .regular).monospacedDigit())
                                    .foregroundStyle(cell.inMonth ? .white : .white.opacity(0.25))
                                Circle().fill(cell.eventCount > 0 && !cell.isToday ? Theme.accent : .clear).frame(width: 3, height: 3)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 20)
                    }
                }
            }
        }
    }

    private func shift(_ d: Int) {
        let n = IslCalMonthGrid.shift(year: year, month: month, by: d)
        year = n.year
        month = n.month
    }

    private func resetToToday() {
        year = Calendar.current.component(.year, from: Date())
        month = Calendar.current.component(.month, from: Date())
    }

    private func agenda(_ now: Date) -> some View {
        let days = service.engine.agenda(now: now)
        let reminders = service.engine.reminderRows(now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if days.isEmpty && reminders.isEmpty {
                    IslandNote(text: service.denied ? "Нет доступа к календарям" : "Ближайших встреч нет")
                }
                ForEach(days) { day in
                    Text(IslCalFormat.dayTitle(day.day, now: now, tz: .current)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    ForEach(day.items) { item in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1.5).fill(color(item.event.colorHex)).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.event.displayTitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                Text(item.kind == .continuing ? "Продолжается" : IslCalFormat.range(item.event, tz: .current)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                }
                if !reminders.isEmpty {
                    Text("Напоминания").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
                    ForEach(reminders) { r in
                        HStack(spacing: 6) {
                            Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(r.urgency == .overdue ? Theme.danger : .white.opacity(0.5))
                            Text(r.reminder.title).font(.system(size: 11.5)).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ hex: String?) -> Color {
        guard let hex, let v = UInt32(hex, radix: 16) else { return Theme.accent }
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

struct IslandCalendarSettings: View {
    @ObservedObject var service: IslandCalendarService

    private func binding<T>(_ kp: WritableKeyPath<IslCalSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: kp] }, set: { v in var s = service.settings; s[keyPath: kp] = v; service.update(s) })
    }

    var body: some View {
        ToolsPermissionNote(permission: .calendars, text: "Календари только читаются. Без доступа остров не увидит события.")
        Section {
            IslandStepperRow(symbol: "clock", title: "Отсчёт за", subtitle: "За сколько минут до события в закрытом острове появляется обратный отсчёт", value: binding(\.leadMinutes), range: IslCalSettings.leadRange, unit: " мин")
            IslandStepperRow(symbol: "calendar.badge.clock", title: "Дней в списке", value: binding(\.daysAhead), range: IslCalSettings.daysRange)
            Toggle("Показывать события на весь день", isOn: binding(\.showAllDay))
            Toggle(isOn: binding(\.showReminders)) { SettingLabel("Показывать напоминания", "Нужен доступ к «Напоминаниям»; только невыполненные") }
            Toggle(isOn: binding(\.countdownInClosed)) { SettingLabel("Отсчёт в закрытом острове", "Если выключить, события видны только в открытом острове") }
        } header: { Text("Календарь") }
        if !service.engine.infos.isEmpty {
            Section("Какие календари показывать") {
                ForEach(service.engine.infos) { c in
                    Toggle(c.title, isOn: Binding(get: { !service.settings.hiddenCalendars.contains(c.id) }, set: { on in
                        var s = service.settings
                        if on { s.hiddenCalendars.remove(c.id) } else { s.hiddenCalendars.insert(c.id) }
                        service.update(s)
                    }))
                }
            }
        }
    }
}
