import Foundation

public struct IslCalEvent: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var calendarTitle: String
    public var colorHex: String?
    public var location: String?
    public var isCancelled: Bool

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendarID: String = "cal", calendarTitle: String = "",
                colorHex: String? = nil, location: String? = nil, isCancelled: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.colorHex = colorHex
        self.location = location
        self.isCancelled = isCancelled
    }

    public var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }

    public var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Без названия" : title }
}

public struct IslCalReminder: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var due: Date?
    public var dueHasTime: Bool
    public var completed: Bool
    public var priority: Int
    public var listTitle: String

    public init(id: String, title: String, due: Date? = nil, dueHasTime: Bool = true, completed: Bool = false, priority: Int = 0, listTitle: String = "") {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.completed = completed
        self.priority = priority
        self.listTitle = listTitle
    }
}

public struct IslCalInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var colorHex: String?

    public init(id: String, title: String, colorHex: String? = nil) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}

public enum IslCalAccess: Equatable, Sendable {
    case unknown, granted, denied

    public var isGranted: Bool { self == .granted }
}

public protocol IslCalSource: AnyObject {
    var access: IslCalAccess { get }
    func requestAccess(_ done: @escaping (Bool) -> Void)
    func calendars() -> [IslCalInfo]
    func events(from: Date, to: Date) -> [IslCalEvent]
    func reminders(_ done: @escaping ([IslCalReminder]) -> Void)
}

public struct IslCalSettings: Equatable, Sendable {
    public static let leadRange = 5...180
    public static let daysRange = 1...14
    public static let remindersRange = 1...10

    public var leadMinutes = 60
    public var daysAhead = 7
    public var showAllDay = true
    public var showReminders = true
    public var remindersLimit = 5
    public var countdownInClosed = true
    public var hiddenCalendars = Set<String>()

    public init() {}

    public var sanitized: IslCalSettings {
        var s = self
        s.leadMinutes = ToolsClamp.int(leadMinutes, Self.leadRange)
        s.daysAhead = ToolsClamp.int(daysAhead, Self.daysRange)
        s.remindersLimit = ToolsClamp.int(remindersLimit, Self.remindersRange)
        s.hiddenCalendars = hiddenCalendars.filter { !$0.isEmpty && $0.count <= 200 }
        return s
    }
}

public final class IslCalSettingsStore {
    private let a: KVAccess
    static let prefix = "notch.calendar."

    public init(_ kv: KeyValueStoring = UserDefaults.standard) { a = KVAccess(kv: kv) }

    public func load() -> IslCalSettings {
        var s = IslCalSettings()
        let p = Self.prefix
        s.leadMinutes = a.int(p + "leadMinutes", s.leadMinutes)
        s.daysAhead = a.int(p + "daysAhead", s.daysAhead)
        s.showAllDay = a.bool(p + "showAllDay", s.showAllDay)
        s.showReminders = a.bool(p + "showReminders", s.showReminders)
        s.remindersLimit = a.int(p + "remindersLimit", s.remindersLimit)
        s.countdownInClosed = a.bool(p + "countdownInClosed", s.countdownInClosed)
        s.hiddenCalendars = Set(a.strings(p + "hiddenCalendars") ?? [])
        return s.sanitized
    }

    public func save(_ settings: IslCalSettings) {
        let s = settings.sanitized
        let b = IslCalSettings()
        let p = Self.prefix
        a.put(p + "leadMinutes", s.leadMinutes, b.leadMinutes)
        a.put(p + "daysAhead", s.daysAhead, b.daysAhead)
        a.put(p + "showAllDay", s.showAllDay, b.showAllDay)
        a.put(p + "showReminders", s.showReminders, b.showReminders)
        a.put(p + "remindersLimit", s.remindersLimit, b.remindersLimit)
        a.put(p + "countdownInClosed", s.countdownInClosed, b.countdownInClosed)
        if s.hiddenCalendars.isEmpty { a.kv.removeObject(forKey: p + "hiddenCalendars") } else { a.kv.set(s.hiddenCalendars.sorted(), forKey: p + "hiddenCalendars") }
    }
}

public enum IslCalZone {
    // All-day events are floating: the wall-clock date must stay the same when the device time zone changes.
    public static func reanchor(_ date: Date, from source: TimeZone, to target: TimeZone) -> Date {
        var src = Calendar(identifier: .gregorian)
        src.timeZone = source
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = target
        let c = src.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return dst.date(from: c) ?? date
    }

    public static func floatingAllDay(_ e: IslCalEvent, from source: TimeZone, to target: TimeZone) -> IslCalEvent {
        guard e.isAllDay, source != target else { return e }
        var out = e
        out.start = reanchor(e.start, from: source, to: target)
        out.end = reanchor(e.end, from: source, to: target)
        return out
    }
}
