import Foundation

public enum UnitCategory: String, CaseIterable, Sendable {
    case length, mass, temperature, volume, area, speed, data, time, currency

    public var title: String {
        switch self {
        case .length: "Длина"
        case .mass: "Масса"
        case .temperature: "Температура"
        case .volume: "Объём"
        case .area: "Площадь"
        case .speed: "Скорость"
        case .data: "Данные"
        case .time: "Время"
        case .currency: "Валюта"
        }
    }
}

public struct UnitDef: Equatable, Sendable {
    public var id: String
    public var category: UnitCategory
    public var factor: Double
    public var symbolEn: String
    public var symbolRu: String
    public var aliases: [String]
    public var exactAliases: [String] = []

    public func symbol(cyrillic: Bool) -> String { cyrillic ? symbolRu : symbolEn }
}

public enum UnitText {
    public static func fold(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        for ch in ["°", "º", "˚", "."] { t = t.replacingOccurrences(of: ch, with: "") }
        t = t.replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        return parts.joined(separator: " ")
    }

    public static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}

public enum UnitCatalog {
    private static func u(_ id: String, _ cat: UnitCategory, _ factor: Double, _ en: String, _ ru: String, _ aliases: String, exact: String = "") -> UnitDef {
        UnitDef(id: id, category: cat, factor: factor, symbolEn: en, symbolRu: ru,
                aliases: aliases.split(separator: "|").map(String.init), exactAliases: exact.isEmpty ? [] : exact.split(separator: "|").map(String.init))
    }

    public static let all: [UnitDef] = [
        u("nm", .length, 1e-9, "nm", "нм", "nm|нм|нанометр|нанометра|нанометров|nanometer|nanometers"),
        u("um", .length, 1e-6, "µm", "мкм", "um|µm|мкм|микрометр|микрометра|микрометров|micron|microns|micrometer"),
        u("mm", .length, 0.001, "mm", "мм", "mm|мм|миллиметр|миллиметра|миллиметров|миллиметры|millimeter|millimeters|millimetre|millimetres"),
        u("cm", .length, 0.01, "cm", "см", "cm|см|сантиметр|сантиметра|сантиметров|сантиметры|centimeter|centimeters|centimetre|centimetres"),
        u("dm", .length, 0.1, "dm", "дм", "dm|дм|дециметр|дециметра|дециметров|decimeter|decimeters"),
        u("m", .length, 1, "m", "м", "m|м|метр|метра|метров|метры|метре|meter|meters|metre|metres"),
        u("km", .length, 1000, "km", "км", "km|км|километр|километра|километров|километры|километре|kilometer|kilometers|kilometre|kilometres"),
        u("in", .length, 0.0254, "in", "дюйм", "in|inch|inches|дюйм|дюйма|дюймов|дюймы|\""),
        u("ft", .length, 0.3048, "ft", "фут", "ft|foot|feet|фут|фута|футов|футы"),
        u("yd", .length, 0.9144, "yd", "ярд", "yd|yard|yards|ярд|ярда|ярдов|ярды"),
        u("mi", .length, 1609.344, "mi", "миль", "mi|mile|miles|миля|мили|миль|миле|милю|милями"),
        u("nmi", .length, 1852, "nmi", "мор. миля", "nmi|морская миля|морских миль|морские мили|nautical mile|nautical miles"),

        u("mg", .mass, 1e-6, "mg", "мг", "mg|мг|миллиграмм|миллиграмма|миллиграммов|milligram|milligrams"),
        u("g", .mass, 0.001, "g", "г", "g|г|гр|грамм|грамма|граммов|граммы|gram|grams|gramme|grammes"),
        u("kg", .mass, 1, "kg", "кг", "kg|кг|килограмм|килограмма|килограммов|килограммы|кило|kilogram|kilograms|kilo|kilos"),
        u("t", .mass, 1000, "t", "т", "t|т|тонна|тонны|тонн|тонне|tonne|tonnes|metric ton|metric tons"),
        u("lb", .mass, 0.45359237, "lb", "фунт", "lb|lbs|pound|pounds|фунт|фунта|фунтов|фунты"),
        u("oz", .mass, 0.028349523125, "oz", "унция", "oz|ounce|ounces|унция|унции|унций"),
        u("st", .mass, 6.35029318, "st", "стоун", "stone|stones|стоун|стоуна|стоунов"),
        u("ct", .mass, 0.0002, "ct", "карат", "ct|carat|carats|карат|карата|каратов"),

        u("c", .temperature, 1, "°C", "°C", "c|с|celsius|centigrade|цельсий|цельсия|цельсию|градус цельсия|градуса цельсия|градусов цельсия|градусы цельсия|градус c|градусов c|градус с|градусов с|degrees celsius|degrees c|degree c|deg c|цельсию|градусов по цельсию"),
        u("f", .temperature, 1, "°F", "°F", "f|ф|fahrenheit|фаренгейт|фаренгейта|градус фаренгейта|градуса фаренгейта|градусов фаренгейта|градусы фаренгейта|градус f|градусов f|градус ф|градусов ф|degrees fahrenheit|degrees f|degree f|deg f|фаренгейты|фаренгейту|градусов по фаренгейту"),
        u("k", .temperature, 1, "K", "K", "k|kelvin|kelvins|кельвин|кельвина|кельвинов|кельвины"),

        u("ml", .volume, 0.001, "ml", "мл", "ml|мл|миллилитр|миллилитра|миллилитров|миллилитры|milliliter|milliliters|millilitre|millilitres|cm3|см3|cc|куб см|кубсантиметр"),
        u("cl", .volume, 0.01, "cl", "сл", "cl|сл|сантилитр|сантилитра|сантилитров|centiliter|centilitre"),
        u("l", .volume, 1, "l", "л", "l|л|литр|литра|литров|литры|литре|liter|liters|litre|litres"),
        u("m3", .volume, 1000, "m³", "м³", "m3|м3|куб м|кубометр|кубометра|кубометров|кубический метр|кубических метров|cubic meter|cubic meters|cubic metre"),
        u("tsp", .volume, 0.00492892159375, "tsp", "ч. л.", "tsp|teaspoon|teaspoons|чл|чайная ложка|чайных ложек|чайные ложки"),
        u("tbsp", .volume, 0.01478676478125, "tbsp", "ст. л.", "tbsp|tablespoon|tablespoons|стл|столовая ложка|столовых ложек|столовые ложки"),
        u("floz", .volume, 0.0295735295625, "fl oz", "жидк. унц.", "floz|fl oz|fluid ounce|fluid ounces|жидкая унция|жидких унций"),
        u("cup", .volume, 0.2365882365, "cup", "стакан", "cup|cups|стакан|стакана|стаканов|стаканы"),
        u("pt", .volume, 0.473176473, "pt", "пинта", "pt|pint|pints|пинта|пинты|пинт"),
        u("qt", .volume, 0.946352946, "qt", "кварта", "qt|quart|quarts|кварта|кварты|кварт"),
        u("gal", .volume, 3.785411784, "gal", "галлон", "gal|gallon|gallons|галлон|галлона|галлонов|галлоны"),

        u("mm2", .area, 1e-6, "mm²", "мм²", "mm2|мм2|sq mm|кв мм|квадратный миллиметр|квадратных миллиметров"),
        u("cm2", .area, 1e-4, "cm²", "см²", "cm2|см2|sq cm|кв см|квадратный сантиметр|квадратных сантиметров"),
        u("m2", .area, 1, "m²", "м²", "m2|м2|sqm|sq m|кв м|квм|квадратный метр|квадратных метра|квадратных метров|квадратные метры|square meter|square meters|square metre|square metres"),
        u("ar", .area, 100, "ar", "сотка", "сотка|сотки|соток|сотку|ar"),
        u("ha", .area, 10000, "ha", "га", "ha|га|гектар|гектара|гектаров|гектары|hectare|hectares"),
        u("km2", .area, 1e6, "km²", "км²", "km2|км2|sq km|кв км|квадратный километр|квадратных километров|square kilometer|square kilometers|square kilometre"),
        u("in2", .area, 0.00064516, "in²", "дюйм²", "in2|sq in|square inch|square inches|кв дюйм|квадратный дюйм|квадратных дюймов"),
        u("ft2", .area, 0.09290304, "ft²", "фут²", "ft2|sqft|sq ft|square foot|square feet|кв фут|квадратный фут|квадратных футов"),
        u("yd2", .area, 0.83612736, "yd²", "ярд²", "yd2|sq yd|square yard|square yards|кв ярд|квадратный ярд"),
        u("acre", .area, 4046.8564224, "ac", "акр", "ac|acre|acres|акр|акра|акров|акры"),
        u("mi2", .area, 2589988.110336, "mi²", "миля²", "mi2|sq mi|square mile|square miles|кв миля|квадратная миля|квадратных миль"),

        u("ms_", .speed, 1, "m/s", "м/с", "m/s|м/с|mps|метр в секунду|метров в секунду|meter per second|meters per second"),
        u("kmh", .speed, 1000.0 / 3600.0, "km/h", "км/ч", "km/h|км/ч|kmh|kmph|kph|кмч|километр в час|километров в час|kilometer per hour|kilometers per hour|kilometres per hour"),
        u("mph", .speed, 1609.344 / 3600.0, "mph", "миль/ч", "mph|mi/h|миль/ч|миль в час|мили в час|мили/ч|miles per hour|mile per hour"),
        u("kn", .speed, 1852.0 / 3600.0, "kn", "уз", "kn|kt|kts|knot|knots|узел|узла|узлов|узлы|уз"),
        u("fps", .speed, 0.3048, "ft/s", "фут/с", "ft/s|fps|фут/с|футов в секунду|foot per second|feet per second"),
        u("mach", .speed, 340.29, "Ma", "Мах", "mach|мах|число маха"),

        u("bit", .data, 0.125, "bit", "бит", "bit|bits|бит|бита|битов|биты"),
        u("kbit", .data, 125, "kbit", "кбит", "kbit|kbits|кбит|килобит|килобита|килобитов|kilobit|kilobits"),
        u("mbit", .data, 125_000, "Mbit", "Мбит", "mbit|mbits|мбит|мегабит|мегабита|мегабитов|megabit|megabits"),
        u("gbit", .data, 125_000_000, "Gbit", "Гбит", "gbit|gbits|гбит|гигабит|гигабита|гигабитов|gigabit|gigabits"),
        u("byte", .data, 1, "B", "Б", "byte|bytes|байт|байта|байтов|байты|б", exact: "B"),
        u("kb", .data, 1000, "KB", "КБ", "kb|kbyte|kilobyte|kilobytes|кб|килобайт|килобайта|килобайтов"),
        u("mb", .data, 1_000_000, "MB", "МБ", "mb|mbyte|megabyte|megabytes|мб|мегабайт|мегабайта|мегабайтов"),
        u("gb", .data, 1_000_000_000, "GB", "ГБ", "gb|gbyte|gigabyte|gigabytes|гб|гигабайт|гигабайта|гигабайтов|гиг"),
        u("tb", .data, 1_000_000_000_000, "TB", "ТБ", "tb|tbyte|terabyte|terabytes|тб|терабайт|терабайта|терабайтов"),
        u("pb", .data, 1_000_000_000_000_000, "PB", "ПБ", "pb|petabyte|petabytes|пб|петабайт|петабайта|петабайтов"),
        u("kib", .data, 1024, "KiB", "КиБ", "kib|киб|кибибайт|кибибайта|kibibyte|kibibytes"),
        u("mib", .data, 1_048_576, "MiB", "МиБ", "mib|миб|мебибайт|мебибайта|mebibyte|mebibytes"),
        u("gib", .data, 1_073_741_824, "GiB", "ГиБ", "gib|гиб|гибибайт|гибибайта|gibibyte|gibibytes"),
        u("tib", .data, 1_099_511_627_776, "TiB", "ТиБ", "tib|тиб|тебибайт|тебибайта|tebibyte|tebibytes"),

        u("us", .time, 1e-6, "µs", "мкс", "us|µs|мкс|микросекунда|микросекунды|микросекунд|microsecond|microseconds"),
        u("ms", .time, 0.001, "ms", "мс", "ms|мс|миллисекунда|миллисекунды|миллисекунд|millisecond|milliseconds"),
        u("s", .time, 1, "s", "с", "s|sec|secs|second|seconds|с|сек|секунда|секунды|секунд|секунду"),
        u("min", .time, 60, "min", "мин", "min|mins|minute|minutes|мин|минута|минуты|минут|минуту"),
        u("h", .time, 3600, "h", "ч", "h|hr|hrs|hour|hours|ч|час|часа|часов|часы"),
        u("d", .time, 86400, "d", "дн", "d|day|days|д|дн|день|дня|дней|дни|сутки|суток|сут"),
        u("wk", .time, 604_800, "wk", "нед", "w|wk|wks|week|weeks|нед|неделя|недели|недель|неделю"),
        u("mo", .time, 2_592_000, "mo", "мес", "mo|mos|month|months|мес|месяц|месяца|месяцев|месяцы"),
        u("yr", .time, 31_536_000, "yr", "г.", "y|yr|yrs|year|years|год|года|лет|годы|годов")
    ]

    static let byAlias: [String: [UnitDef]] = {
        var m: [String: [UnitDef]] = [:]
        for d in all { for a in d.aliases { m[UnitText.fold(a), default: []].append(d) } }
        return m
    }()

    static let byExact: [String: [UnitDef]] = {
        var m: [String: [UnitDef]] = [:]
        for d in all { for a in d.exactAliases { m[a, default: []].append(d) } }
        return m
    }()

    public static func lookup(_ text: String) -> [UnitDef] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let e = byExact[trimmed] { return e }
        var f = UnitText.fold(trimmed)
        if let r = byAlias[f] { return r }
        for lead in ["in the ", "the ", "a ", "an "] where f.hasPrefix(lead) { f = String(f.dropFirst(lead.count)); if let r = byAlias[f] { return r } }
        if f.count >= 4, f.hasSuffix("s"), let r = byAlias[String(f.dropLast())] { return r }
        return []
    }

    public static func convertTemperature(_ v: Double, from: String, to: String) -> Double {
        let celsius: Double
        switch from {
        case "f": celsius = (v - 32) * 5 / 9
        case "k": celsius = v - 273.15
        default: celsius = v
        }
        switch to {
        case "f": return celsius * 9 / 5 + 32
        case "k": return celsius + 273.15
        default: return celsius
        }
    }

    public static func defaults(for cat: UnitCategory) -> [String] {
        switch cat {
        case .length: ["m", "km", "cm", "mi", "ft", "in"]
        case .mass: ["kg", "g", "lb", "oz", "t"]
        case .temperature: ["c", "f", "k"]
        case .volume: ["l", "ml", "gal", "cup", "floz"]
        case .area: ["m2", "ha", "ft2", "acre", "km2"]
        case .speed: ["kmh", "ms_", "mph", "kn"]
        case .data: ["byte", "kb", "mb", "gb", "tb"]
        case .time: ["s", "min", "h", "d", "wk"]
        case .currency: []
        }
    }
}
