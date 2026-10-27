import Foundation

public extension IslSectionIDs {
    static let calendar: IslSectionID = "calendar"
    static let notifications: IslSectionID = "notifications"
    static let timer: IslSectionID = "timer"
    static let accessories: IslSectionID = "accessories"
    static let lyrics: IslSectionID = "lyrics"
    static let queue: IslSectionID = "queue"
    static let downloads: IslSectionID = "downloads"
    static let watch: IslSectionID = "watch"
}

public extension IslPriority {
    static let calendar = 55
    static let download = 58
    static let notification = 64
    static let calendarSoon = 66
    static let accessory = 72
    static let watch = 74
    static let calendarImminent = 76
}

public enum IslExtModules {
    public static let all: [ModuleID] = [.notchCalendar, .notchNotifications, .notchTimer, .notchAccessories, .notchLyrics, .notchQueue,
                                         .notchLiveEq, .notchDownloads, .notchWatch, .notchMascot]

    public static let descriptors: [IslSectionDescriptor] = [
        IslSectionDescriptor(id: IslSectionIDs.calendar, title: "Календарь", symbol: "calendar", summary: "Месяц, ближайшие встречи и напоминания", defaultOrder: 100, module: .notchCalendar),
        IslSectionDescriptor(id: IslSectionIDs.notifications, title: "Уведомления", symbol: "bell.badge", summary: "Недавние системные уведомления", defaultOrder: 110, module: .notchNotifications),
        IslSectionDescriptor(id: IslSectionIDs.timer, title: "Таймер", symbol: "timer", summary: "Таймер, секундомер и помодоро", defaultOrder: 120, module: .notchTimer),
        IslSectionDescriptor(id: IslSectionIDs.accessories, title: "Аксессуары", symbol: "airpodspro", summary: "Наушники, клавиатура, мышь и их заряд", defaultOrder: 130, module: .notchAccessories),
        IslSectionDescriptor(id: IslSectionIDs.lyrics, title: "Тексты", symbol: "quote.bubble", summary: "Текст песни синхронно с музыкой", defaultOrder: 140, module: .notchLyrics),
        IslSectionDescriptor(id: IslSectionIDs.queue, title: "Очередь", symbol: "list.bullet", summary: "Следующие треки плеера", defaultOrder: 150, module: .notchQueue),
        IslSectionDescriptor(id: IslSectionIDs.downloads, title: "Загрузки", symbol: "arrow.down.circle", summary: "Файлы, которые скачиваются в папку загрузок", defaultOrder: 160, module: .notchDownloads),
        IslSectionDescriptor(id: IslSectionIDs.watch, title: "Наблюдение", symbol: "eye", summary: "Следит за областью экрана и сообщает об изменении", defaultOrder: 180, module: .notchWatch)
    ]
}

public enum IslExtText {
    public static func trimmed(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max - 1)) + "…"
    }

    public static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
