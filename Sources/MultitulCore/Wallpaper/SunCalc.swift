import Foundation

public struct SunLocation: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let tzIdentifier: String

    public init(lat: Double, lon: Double, tzIdentifier: String) {
        self.lat = lat
        self.lon = lon
        self.tzIdentifier = tzIdentifier
    }

    public static let saintPetersburg = SunLocation(lat: 59.94, lon: 30.31, tzIdentifier: "Europe/Moscow")
    public var timeZone: TimeZone { TimeZone(identifier: tzIdentifier) ?? TimeZone(identifier: "UTC")! }
}

public enum PolarState: Equatable, Sendable { case midnightSun, polarNight }

// NOAA solar calculator, ported 1:1 from the old LiveWallpaper (`Sun`), parameterised by location.
public struct SunCalc: Sendable {
    public let location: SunLocation

    public init(location: SunLocation = .saintPetersburg) { self.location = location }

    public static let spb = SunCalc()

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = location.timeZone
        return c
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    private static func eqAndDecl(jd: Double) -> (eq: Double, decl: Double) {
        let t = (jd - 2451545.0) / 36525.0
        var l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t) + sin(rad(3 * m)) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(omega))
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let obliq = 23 + (26 + seconds / 60) / 60 + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(obliq)) * sin(rad(appLong))))
        let y = tan(rad(obliq / 2)) * tan(rad(obliq / 2))
        let eq = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        return (eq, decl)
    }

    private func hourAngleValue(decl: Double) -> Double {
        cos(Self.rad(90.833)) / (cos(Self.rad(location.lat)) * cos(Self.rad(decl))) - tan(Self.rad(location.lat)) * tan(Self.rad(decl))
    }

    private func hourAngle(decl: Double) -> Double? {
        let v = hourAngleValue(decl: decl)
        guard abs(v) <= 1 else { return nil }
        return Self.deg(acos(v))
    }

    private func utcMidnight(of day: Date) -> Date? {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: c)
    }

    public func events(on day: Date) -> (rise: Date, set: Date)? {
        guard let midnight = utcMidnight(of: day) else { return nil }
        let lon = location.lon
        let jd0 = midnight.timeIntervalSince1970 / 86400 + 2440587.5
        let first = Self.eqAndDecl(jd: jd0 + 0.5)
        guard let ha0 = hourAngle(decl: first.decl) else { return nil }
        let noon0 = 720 - 4 * lon - first.eq
        let riseGuess = noon0 - 4 * ha0, setGuess = noon0 + 4 * ha0
        let r = Self.eqAndDecl(jd: jd0 + riseGuess / 1440), s = Self.eqAndDecl(jd: jd0 + setGuess / 1440)
        guard let har = hourAngle(decl: r.decl), let has = hourAngle(decl: s.decl) else { return nil }
        let riseMin = 720 - 4 * lon - r.eq - 4 * har
        let setMin = 720 - 4 * lon - s.eq + 4 * has
        return (midnight.addingTimeInterval(riseMin * 60), midnight.addingTimeInterval(setMin * 60))
    }

    // nil when the day has a normal sunrise and sunset.
    public func polarState(on day: Date) -> PolarState? {
        guard events(on: day) == nil, let midnight = utcMidnight(of: day) else { return nil }
        let jd0 = midnight.timeIntervalSince1970 / 86400 + 2440587.5
        let v = hourAngleValue(decl: Self.eqAndDecl(jd: jd0 + 0.5).decl)
        return v < -1 ? .midnightSun : .polarNight
    }

    public func isDay(_ now: Date) -> Bool {
        if let e = events(on: now) { return now >= e.rise && now < e.set }
        return polarState(on: now) == .midnightSun
    }

    // First sunrise or sunset strictly after `now`, looking up to `horizonDays` ahead (polar gaps are skipped).
    public func nextEvent(after now: Date, horizonDays: Int = 400) -> Date? {
        for k in 0...horizonDays {
            guard let d = calendar.date(byAdding: .day, value: k, to: now), let e = events(on: d) else { continue }
            let upcoming = [e.rise, e.set].filter { $0 > now }
            if let t = upcoming.min() { return t }
        }
        return nil
    }

    // When to re-evaluate the day/night state: the next event (+1 s margin), but never later than 24 h from now.
    public func nextRefresh(after now: Date) -> Date {
        let cap = now.addingTimeInterval(86400)
        guard let e = nextEvent(after: now) else { return cap }
        return min(e.addingTimeInterval(1), cap)
    }

    public func hhmmss(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = location.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    public func hhmm(_ d: Date) -> String { String(hhmmss(d).dropLast(3)) }
}
