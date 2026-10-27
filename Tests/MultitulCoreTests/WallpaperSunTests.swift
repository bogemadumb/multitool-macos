import Testing
import Foundation
@testable import MultitulCore

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

// Expected values were produced by running the old LiveWallpaper `Sun` enum (main.swift, 2026-10-23) on these inputs.
private let oldEvents: [(day: String, rise: Double, set: Double)] = [
    ("2024-02-29", 1709182738.915, 1709220274.912),
    ("2025-12-31", 1767164454.465, 1767186176.651),
    ("2026-01-15", 1768459562.243, 1768483846.395),
    ("2026-03-20", 1773979250.978, 1774023178.417),
    ("2026-04-30", 1777514406.705, 1777571616.294),
    ("2026-05-25", 1779670838.041, 1779735135.547),
    ("2026-06-21", 1782002110.868, 1782069956.777),
    ("2026-07-20", 1784509962.308, 1784573766.316),
    ("2026-09-23", 1790135101.136, 1790178958.366),
    ("2026-10-23", 1792731448.016, 1792765656.215),
    ("2026-12-21", 1797836405.518, 1797857609.229)
]

private let oldNext: [(at: String, isDay: Bool, next: Double)] = [
    ("2026-01-15T03:00:00+03:00", false, 1768459562.243),
    ("2026-01-15T12:00:00+03:00", true, 1768483846.395),
    ("2026-01-15T17:00:00+03:00", false, 1768545868.551),
    ("2026-06-21T02:00:00+03:00", false, 1782002110.868),
    ("2026-06-21T23:50:00+03:00", false, 1782088524.885),
    ("2026-10-23T08:30:00+03:00", true, 1792765656.215),
    ("2026-10-23T23:59:59+03:00", false, 1792817998.935),
    ("2026-12-21T10:00:00+03:00", false, 1797836405.518)
]

private let tromso = SunCalc(location: SunLocation(lat: 69.65, lon: 18.96, tzIdentifier: "Europe/Oslo"))

@Suite struct WallpaperSunTests {
    @Test func sunriseAndSunsetMatchOldAppForSaintPetersburg() throws {
        for e in oldEvents {
            let ev = try #require(SunCalc.spb.events(on: iso(e.day + "T12:00:00+03:00")))
            #expect(abs(ev.rise.timeIntervalSince1970 - e.rise) < 0.01, "rise \(e.day)")
            #expect(abs(ev.set.timeIntervalSince1970 - e.set) < 0.01, "set \(e.day)")
        }
    }

    @Test func isDayAndNextEventMatchOldApp() throws {
        for n in oldNext {
            let t = iso(n.at)
            #expect(SunCalc.spb.isDay(t) == n.isDay, "isDay \(n.at)")
            let next = try #require(SunCalc.spb.nextEvent(after: t))
            #expect(abs(next.timeIntervalSince1970 - n.next) < 0.01, "next \(n.at)")
        }
    }

    @Test func whiteNightsStillHaveEvents() {
        for d in ["2026-06-01", "2026-06-21", "2026-07-10"] {
            #expect(SunCalc.spb.events(on: iso(d + "T12:00:00+03:00")) != nil)
            #expect(SunCalc.spb.polarState(on: iso(d + "T12:00:00+03:00")) == nil)
        }
    }

    @Test func refreshTimerIsEventPlusOneSecondWhenWithinADay() throws {
        let t = iso("2026-01-15T03:00:00+03:00")
        #expect(abs(SunCalc.spb.nextRefresh(after: t).timeIntervalSince1970 - (1768459562.243 + 1)) < 0.01)
        let late = iso("2026-06-21T23:50:00+03:00")
        #expect(abs(SunCalc.spb.nextRefresh(after: late).timeIntervalSince1970 - (1782088524.885 + 1)) < 0.01)
    }

    @Test func refreshAlwaysAfterNowAndNeverLaterThanADay() {
        var t = iso("2026-01-01T00:00:00+03:00")
        for _ in 0..<400 {
            let r = SunCalc.spb.nextRefresh(after: t)
            #expect(r > t && r <= t.addingTimeInterval(86400))
            t = t.addingTimeInterval(86400 * 0.93)
        }
    }

    @Test func midnightSunMeansDayAndNoEvents() {
        let t = iso("2026-06-21T12:00:00+02:00")
        #expect(tromso.events(on: t) == nil)
        #expect(tromso.polarState(on: t) == .midnightSun)
        #expect(tromso.isDay(t))
        #expect(tromso.isDay(iso("2026-06-21T01:00:00+02:00")))
    }

    @Test func polarNightMeansNightAndNoEvents() {
        let t = iso("2026-12-21T12:00:00+01:00")
        #expect(tromso.events(on: t) == nil)
        #expect(tromso.polarState(on: t) == .polarNight)
        #expect(!tromso.isDay(t))
    }

    @Test func polarNextEventSkipsTheGapAndRefreshIsCapped() throws {
        let now = iso("2026-12-21T12:00:00+01:00")
        let next = try #require(tromso.nextEvent(after: now))
        #expect(next > now)
        let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/Oslo")!, from: next)
        #expect(comps.year == 2027 && comps.month == 1)
        #expect(tromso.events(on: next) != nil)
        #expect(tromso.nextRefresh(after: now) == now.addingTimeInterval(86400))

        let summer = iso("2026-06-21T12:00:00+02:00")
        let nextSummer = try #require(tromso.nextEvent(after: summer))
        #expect(nextSummer > summer.addingTimeInterval(86400 * 10))
        #expect(tromso.nextRefresh(after: summer) == summer.addingTimeInterval(86400))
    }

    @Test func midnightSunEndsWithABriefNightThenDay() throws {
        let start = iso("2026-07-10T12:00:00+02:00")
        let first = try #require(tromso.nextEvent(after: start))
        #expect(tromso.isDay(start))
        #expect(!tromso.isDay(first.addingTimeInterval(-3600)))
        #expect(tromso.isDay(first.addingTimeInterval(3600)))
        let second = try #require(tromso.nextEvent(after: first))
        #expect(second > first)
        #expect(second.timeIntervalSince(start) < 86400 * 40)
    }

    @Test func formatsClockInLocationTimeZone() throws {
        let e = try #require(SunCalc.spb.events(on: iso("2026-01-15T12:00:00+03:00")))
        #expect(SunCalc.spb.hhmmss(e.rise).count == 8)
        #expect(SunCalc.spb.hhmm(e.rise) == String(SunCalc.spb.hhmmss(e.rise).prefix(5)))
        #expect(SunCalc.spb.hhmm(e.rise) == "09:46")
    }
}
