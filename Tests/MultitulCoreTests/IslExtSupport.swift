import Foundation
@testable import MultitulCore

enum ExtFix {
    static let msk = TimeZone(identifier: "Europe/Moscow")!
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let utc = TimeZone(identifier: "UTC")!

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, tz: TimeZone = msk) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    static let now = date(2026, 10, 23, 12, 0)

    static func event(_ id: String, start: Date, minutes: Int = 60, title: String = "", allDay: Bool = false, calendar: String = "work", cancelled: Bool = false) -> IslCalEvent {
        IslCalEvent(id: id, title: title.isEmpty ? id : title, start: start, end: start.addingTimeInterval(TimeInterval(minutes) * 60), isAllDay: allDay, calendarID: calendar,
                    calendarTitle: calendar, isCancelled: cancelled)
    }

    static func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
}

final class ExtFakeCalSource: IslCalSource {
    var access = IslCalAccess.granted
    var granted = true
    var eventList: [IslCalEvent] = []
    var reminderList: [IslCalReminder] = []
    var requested = 0
    var eventQueries: [(Date, Date)] = []
    var deferReminders = false
    var pendingReminders: (([IslCalReminder]) -> Void)?

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        requested += 1
        access = granted ? .granted : .denied
        done(granted)
    }

    func calendars() -> [IslCalInfo] { [IslCalInfo(id: "work", title: "Работа"), IslCalInfo(id: "home", title: "Дом")] }

    func events(from: Date, to: Date) -> [IslCalEvent] {
        eventQueries.append((from, to))
        return eventList.filter { $0.end > from && $0.start < to }
    }

    func reminders(_ done: @escaping ([IslCalReminder]) -> Void) {
        if deferReminders { pendingReminders = done } else { done(reminderList) }
    }
}
