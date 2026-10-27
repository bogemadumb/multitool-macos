import Foundation

public enum FanText {
    public static let noFans = "На этом Маке нет вентиляторов"
    public static let noFansDetail = "Датчик числа вентиляторов (FNum) пуст: у Мака без вентиляторов, например MacBook Air, управлять нечем. Модуль ничего не пишет в SMC."
    public static let unverified = "не проверено на железе"
    public static let helperHint = "Запись оборотов идёт через root-помощник multitul-ctl: его нужно установить (install-root.sh)."

    public static func faultTitle(_ k: FanEngine.Fault.Kind) -> String {
        switch k {
        case .sensorLost: "Пропали датчики температуры"
        case .fanReadLost: "Не читаются вентиляторы"
        case .thermalPressure: "Растёт тепловая нагрузка"
        case .writeFailed: "Не удалось записать обороты"
        case .watchdog: "Сторож: управление зависло"
        case .reclaimed: "Система забирает управление"
        }
    }

    public static func status(_ state: FanEngine.State, restorePending: Bool, asleep: Bool) -> String {
        if restorePending { return "Не удалось вернуть вентиляторы системе, повторяю" }
        if asleep { return "Сон: вентиляторы у системы" }
        switch state {
        case .stopped: return "Модуль выключен"
        case .noFans: return noFans
        case .unsupported(let why): return "Вентиляторы есть, но управление не поддерживается: \(why)"
        case .system: return "Вентиляторами управляет система"
        case .manual: return "Ручные обороты"
        case .curve: return "Работает кривая"
        }
    }

    public static func rpm(_ v: Double) -> String { "\(Int(v.rounded())) об/мин" }
}
