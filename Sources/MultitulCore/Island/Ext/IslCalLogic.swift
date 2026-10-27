import Foundation

public enum IslCalCountdown: Equatable, Sendable {
    case until(IslCalEvent, TimeInterval)
    case remaining(IslCalEvent, TimeInterval)

    public var event: IslCalEvent {
        switch self {
        case .until(let e, _), .remaining(let e, _): e
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .until(_, let s), .remaining(_, let s): s
        }
    }
}

public enum IslCalSelector {
    public static let imminent: TimeInterval = 300
    public static let longEvent: TimeInterval = 12 * 3600

    public static func visible(_ events: [IslCalEvent], settings: IslCalSettings) -> [IslCalEvent] {
        events.filter { e in
            !e.isCancelled && !settings.hiddenCalendars.contains(e.calendarID) && (settings.showAllDay || !e.isAllDay)
        }
    }

    public static func eligible(_ e: IslCalEvent) -> Bool {
        !e.isAllDay && !e.isCancelled && e.duration > 0 && e.duration < longEvent
    }

    public static func ongoing(_ events: [IslCalEvent], now: Date) -> [IslCalEvent] {
        events.filter { eligible($0) && $0.start <= now && now < $0.end }.sorted { ($0.end, $0.id) < ($1.end, $1.id) }
    }

    public static func upcoming(_ events: [IslCalEvent], now: Date, limit: Int = .max) -> [IslCalEvent] {
        Array(events.filter { eligible($0) && $0.start > now }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.prefix(limit))
    }

    public static func next(_ events: [IslCalEvent], now: Date) -> IslCalEvent? { upcoming(events, now: now, limit: 1).first }

    public static func countdown(_ events: [IslCalEvent], now: Date, leadMinutes: Int) -> IslCalCountdown? {
        let next = next(events, now: now)
        let lead = TimeInterval(leadMinutes) * 60
        if let n = next, n.start.timeIntervalSince(now) <= imminent { return .until(n, n.start.timeIntervalSince(now)) }
        if let cur = ongoing(events, now: now).first { return .remaining(cur, cur.end.timeIntervalSince(now)) }
        if let n = next, n.start.timeIntervalSince(now) <= lead { return .until(n, n.start.timeIntervalSince(now)) }
        return nil
    }
}

public enum IslCalActivityFactory {
    public static func stage(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "1"
        case ..<300: "5"
        case ..<600: "10"
        case ..<1800: "30"
        default: "60"
        }
    }

    public static func activity(_ c: IslCalCountdown?, now: Date) -> IslActivity? {
        guard let c else { return nil }
        switch c {
        case .until(let e, let s):
            let priority = s <= 60 ? IslPriority.calendarImminent : (s <= 300 ? IslPriority.calendarSoon : IslPriority.calendar)
            return IslActivity(id: "calendar", section: IslSectionIDs.calendar, priority: priority, startedAt: e.start,
                               expiresAt: e.start, peeks: true, token: "u|\(e.id)|\(stage(s))", title: e.displayTitle)
        case .remaining(let e, _):
            return IslActivity(id: "calendar", section: IslSectionIDs.calendar, priority: IslPriority.calendar, startedAt: e.start, expiresAt: e.end, peeks: true,
                               token: "r|\(e.id)", title: e.displayTitle)
        }
    }
}

public struct IslCalAgendaItem: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case allDay, timed, continuing }

    public var event: IslCalEvent
    public var kind: Kind
    public var id: String { event.id + "|" + String(day.timeIntervalSinceReferenceDate) }
    public var day: Date

    public init(event: IslCalEvent, kind: Kind, day: Date) {
        self.event = event
        self.kind = kind
        self.day = day
    }
}

public struct IslCalAgendaDay: Equatable, Identifiable, Sendable {
    public var day: Date
    public var items: [IslCalAgendaItem]
    public var id: Date { day }
}

public enum IslCalDays {
    public static func calendar(_ tz: TimeZone, firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = firstWeekday
        return c
    }

    // Start of each local day the event touches; the end is exclusive, so an event ending at midnight does not spill into the next day.
    public static func coveredDays(_ e: IslCalEvent, tz: TimeZone) -> [Date] {
        let cal = calendar(tz)
        let first = cal.startOfDay(for: e.start)
        let lastMoment = e.end > e.start ? e.end.addingTimeInterval(-1) : e.start
        let last = cal.startOfDay(for: lastMoment)
        var out: [Date] = []
        var d = first
        while d <= last, out.count < 400 {
            out.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    public static func touches(_ e: IslCalEvent, day: Date, tz: TimeZone) -> Bool {
        let cal = calendar(tz)
        let d = cal.startOfDay(for: day)
        return coveredDays(e, tz: tz).contains(d)
    }
}

public enum IslCalAgenda {
    public static func build(_ events: [IslCalEvent], now: Date, days: Int, tz: TimeZone) -> [IslCalAgendaDay] {
        let cal = IslCalDays.calendar(tz)
        let today = cal.startOfDay(for: now)
        var out: [IslCalAgendaDay] = []
        for offset in 0..<max(days, 1) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var items: [IslCalAgendaItem] = []
            for e in events where IslCalDays.touches(e, day: day, tz: tz) {
                let dayStart = day
                if e.isAllDay {
                    items.append(IslCalAgendaItem(event: e, kind: .allDay, day: dayStart))
                } else if cal.startOfDay(for: e.start) == day {
                    if offset == 0, e.end <= now { continue }
                    items.append(IslCalAgendaItem(event: e, kind: .timed, day: dayStart))
                } else {
                    items.append(IslCalAgendaItem(event: e, kind: .continuing, day: dayStart))
                }
            }
            items.sort { a, b in
                func rank(_ k: IslCalAgendaItem.Kind) -> Int { k == .allDay ? 0 : (k == .continuing ? 1 : 2) }
                if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
                return (a.event.start, a.event.id) < (b.event.start, b.event.id)
            }
            if !items.isEmpty { out.append(IslCalAgendaDay(day: day, items: items)) }
        }
        return out
    }
}

public struct IslCalMonthCell: Equatable, Sendable {
    public var date: Date
    public var day: Int
    public var inMonth: Bool
    public var isToday: Bool
    public var eventCount: Int
}

public enum IslCalMonthGrid {
    public static func build(year: Int, month: Int, events: [IslCalEvent], now: Date, tz: TimeZone, firstWeekday: Int = 2) -> [[IslCalMonthCell]] {
        let cal = IslCalDays.calendar(tz, firstWeekday: firstWeekday)
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)), let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let total = lead + range.count
        let rows = (total + 6) / 7
        var counts: [Date: Int] = [:]
        for e in events { for d in IslCalDays.coveredDays(e, tz: tz) { counts[d, default: 0] += 1 } }
        let today = cal.startOfDay(for: now)
        var grid: [[IslCalMonthCell]] = []
        for r in 0..<rows {
            var row: [IslCalMonthCell] = []
            for c in 0..<7 {
                let index = r * 7 + c - lead
                guard let date = cal.date(byAdding: .day, value: index, to: first) else { continue }
                let comps = cal.dateComponents([.year, .month, .day], from: date)
                let inMonth = comps.month == month && comps.year == year
                row.append(IslCalMonthCell(date: date, day: comps.day ?? 0, inMonth: inMonth, isToday: date == today, eventCount: counts[date] ?? 0))
            }
            grid.append(row)
        }
        return grid
    }

    public static func weekdaySymbols(firstWeekday: Int = 2) -> [String] {
        let base = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
        return (0..<7).map { base[(firstWeekday - 1 + $0) % 7] }
    }

    public static func shift(year: Int, month: Int, by delta: Int) -> (year: Int, month: Int) {
        let idx = year * 12 + (month - 1) + delta
        return (idx / 12, idx % 12 + 1)
    }

    public static func title(year: Int, month: Int) -> String {
        let names = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
        guard (1...12).contains(month) else { return "" }
        return names[month - 1].prefix(1).uppercased() + names[month - 1].dropFirst() + " \(year)"
    }
}

public struct IslCalReminderRow: Equatable, Identifiable, Sendable {
    public enum Urgency: Int, Sendable { case overdue = 0, today, later, none }

    public var reminder: IslCalReminder
    public var urgency: Urgency
    public var id: String { reminder.id }
}

public enum IslCalReminders {
    public static func select(_ list: [IslCalReminder], now: Date, tz: TimeZone, limit: Int) -> [IslCalReminderRow] {
        let cal = IslCalDays.calendar(tz)
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        var rows: [IslCalReminderRow] = []
        for r in list where !r.completed {
            let u: IslCalReminderRow.Urgency
            if let due = r.due {
                if r.dueHasTime ? due < now : due < today { u = .overdue } else if due < tomorrow { u = .today } else { u = .later }
            } else {
                u = .none
            }
            rows.append(IslCalReminderRow(reminder: r, urgency: u))
        }
        rows.sort { a, b in
            if a.urgency != b.urgency { return a.urgency.rawValue < b.urgency.rawValue }
            let ad = a.reminder.due ?? .distantFuture, bd = b.reminder.due ?? .distantFuture
            if ad != bd { return ad < bd }
            return a.reminder.id < b.reminder.id
        }
        return Array(rows.prefix(max(limit, 0)))
    }
}

public enum IslCalFormat {
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded(.up)), 0)
        if s < 60 { return "\(s) с" }
        let m = (s + 59) / 60
        if m < 60 { return "\(m) мин" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) ч" : "\(h) ч \(r) мин"
    }

    public static func compactClock(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded(.up)), 0)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func label(_ c: IslCalCountdown) -> String {
        switch c {
        case .until(_, let s): "через " + countdown(s)
        case .remaining(_, let s): "осталось " + countdown(s)
        }
    }

    public static func time(_ date: Date, tz: TimeZone) -> String {
        let cal = IslCalDays.calendar(tz)
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func range(_ e: IslCalEvent, tz: TimeZone) -> String {
        e.isAllDay ? "Весь день" : time(e.start, tz: tz) + "–" + time(e.end, tz: tz)
    }

    public static func dayTitle(_ day: Date, now: Date, tz: TimeZone) -> String {
        let cal = IslCalDays.calendar(tz)
        let d = cal.startOfDay(for: day)
        let today = cal.startOfDay(for: now)
        let diff = cal.dateComponents([.day], from: today, to: d).day ?? 0
        if diff == 0 { return "Сегодня" }
        if diff == 1 { return "Завтра" }
        let names = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
        let months = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
        let c = cal.dateComponents([.weekday, .day, .month], from: d)
        return "\(names[(c.weekday ?? 1) - 1]), \(c.day ?? 0) \(months[(c.month ?? 1) - 1])"
    }
}

// Pure aggregate: the live source is injected, time comes from the caller.
public final class IslCalEngine {
    public private(set) var events: [IslCalEvent] = []
    public private(set) var reminders: [IslCalReminder] = []
    public private(set) var infos: [IslCalInfo] = []
    public private(set) var denied = false
    public var settings: IslCalSettings
    public var timeZone: TimeZone
    private let source: IslCalSource
    private var lastLoad: Date?
    public var reloadEvery: TimeInterval = 300
    public var onChange: (() -> Void)?

    public init(source: IslCalSource, settings: IslCalSettings = IslCalSettings(), timeZone: TimeZone = .current) {
        self.source = source
        self.settings = settings.sanitized
        self.timeZone = timeZone
    }

    public func start(now: Date) {
        switch source.access {
        case .granted:
            reload(now: now)
        case .denied:
            denied = true
            onChange?()
        case .unknown:
            source.requestAccess { [weak self] ok in
                guard let self else { return }
                self.denied = !ok
                if ok { self.reload(now: now) } else { self.onChange?() }
            }
        }
    }

    public func tick(now: Date) {
        guard source.access.isGranted else { return }
        if lastLoad.map({ now.timeIntervalSince($0) >= reloadEvery || now < $0 }) ?? true { reload(now: now) }
    }

    public func reload(now: Date) {
        guard source.access.isGranted else { return }
        lastLoad = now
        let cal = IslCalDays.calendar(timeZone)
        let from = cal.startOfDay(for: now).addingTimeInterval(-86_400)
        let to = (cal.date(byAdding: .day, value: max(settings.daysAhead, 2) + 1, to: from) ?? from.addingTimeInterval(9 * 86_400))
        infos = source.calendars()
        events = source.events(from: from, to: to)
        if settings.showReminders {
            source.reminders { [weak self] list in
                guard let self else { return }
                self.reminders = list
                self.onChange?()
            }
        } else {
            reminders = []
        }
        onChange?()
    }

    public var visibleEvents: [IslCalEvent] { IslCalSelector.visible(events, settings: settings) }

    public func countdown(now: Date) -> IslCalCountdown? {
        IslCalSelector.countdown(visibleEvents, now: now, leadMinutes: settings.leadMinutes)
    }

    public func activity(now: Date) -> IslActivity? { IslCalActivityFactory.activity(countdown(now: now), now: now) }

    public func agenda(now: Date) -> [IslCalAgendaDay] {
        IslCalAgenda.build(visibleEvents, now: now, days: settings.daysAhead, tz: timeZone)
    }

    public func reminderRows(now: Date) -> [IslCalReminderRow] {
        settings.showReminders ? IslCalReminders.select(reminders, now: now, tz: timeZone, limit: settings.remindersLimit) : []
    }
}
