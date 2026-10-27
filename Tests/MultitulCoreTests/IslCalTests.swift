import Testing
import Foundation
@testable import MultitulCore

private typealias F = ExtFix

@Suite struct IslCalSelectionTests {
    @Test func visibleDropsCancelledAndHiddenCalendars() {
        var s = IslCalSettings()
        s.hiddenCalendars = ["home"]
        let list = [F.event("a", start: F.at(600)), F.event("b", start: F.at(600), cancelled: true), F.event("c", start: F.at(600), calendar: "home")]
        #expect(IslCalSelector.visible(list, settings: s).map(\.id) == ["a"])
    }

    @Test func visibleDropsAllDayWhenDisabled() {
        var s = IslCalSettings()
        s.showAllDay = false
        let list = [F.event("a", start: F.at(600)), F.event("b", start: F.date(2026, 10, 23), minutes: 1439, allDay: true)]
        #expect(IslCalSelector.visible(list, settings: s).map(\.id) == ["a"])
        s.showAllDay = true
        #expect(IslCalSelector.visible(list, settings: s).count == 2)
    }

    @Test func eligibleExcludesAllDayZeroLengthAndVeryLong() {
        #expect(IslCalSelector.eligible(F.event("a", start: F.at(60))))
        #expect(!IslCalSelector.eligible(F.event("b", start: F.at(60), allDay: true)))
        #expect(!IslCalSelector.eligible(F.event("c", start: F.at(60), minutes: 0)))
        #expect(!IslCalSelector.eligible(F.event("d", start: F.at(60), minutes: 12 * 60)))
        #expect(IslCalSelector.eligible(F.event("e", start: F.at(60), minutes: 11 * 60 + 59)))
        #expect(!IslCalSelector.eligible(F.event("f", start: F.at(60), cancelled: true)))
    }

    @Test func ongoingIsSortedByEndAndExcludesFinished() {
        let list = [F.event("late", start: F.at(-600), minutes: 60), F.event("soon", start: F.at(-600), minutes: 20), F.event("done", start: F.at(-3600), minutes: 30)]
        #expect(IslCalSelector.ongoing(list, now: F.now).map(\.id) == ["soon", "late"])
    }

    @Test func eventEndingExactlyNowIsNotOngoing() {
        let e = F.event("a", start: F.at(-3600), minutes: 60)
        #expect(IslCalSelector.ongoing([e], now: F.now).isEmpty)
        #expect(IslCalSelector.ongoing([e], now: F.at(-1)).count == 1)
    }

    @Test func eventStartingExactlyNowIsOngoingNotUpcoming() {
        let e = F.event("a", start: F.now)
        #expect(IslCalSelector.ongoing([e], now: F.now).count == 1)
        #expect(IslCalSelector.upcoming([e], now: F.now).isEmpty)
    }

    @Test func upcomingIsSortedAndLimited() {
        let list = [F.event("c", start: F.at(3000)), F.event("a", start: F.at(600)), F.event("b", start: F.at(1200)), F.event("past", start: F.at(-600))]
        #expect(IslCalSelector.upcoming(list, now: F.now).map(\.id) == ["a", "b", "c"])
        #expect(IslCalSelector.upcoming(list, now: F.now, limit: 2).map(\.id) == ["a", "b"])
        #expect(IslCalSelector.next(list, now: F.now)?.id == "a")
    }

    @Test func upcomingTieBreaksByIdentifier() {
        let list = [F.event("b", start: F.at(600)), F.event("a", start: F.at(600))]
        #expect(IslCalSelector.upcoming(list, now: F.now).map(\.id) == ["a", "b"])
    }
}

@Suite struct IslCalCountdownTests {
    @Test func countdownStartsInsideTheLeadWindow() {
        let e = F.event("a", start: F.at(45 * 60))
        let c = IslCalSelector.countdown([e], now: F.now, leadMinutes: 60)
        #expect(c == .until(e, 2700))
        #expect(c?.seconds == 2700 && c?.event.id == "a")
    }

    @Test func noCountdownBeyondTheLeadWindow() {
        #expect(IslCalSelector.countdown([F.event("a", start: F.at(61 * 60))], now: F.now, leadMinutes: 60) == nil)
    }

    @Test func leadWindowBoundaryIsInclusive() {
        #expect(IslCalSelector.countdown([F.event("a", start: F.at(3600))], now: F.now, leadMinutes: 60) != nil)
        #expect(IslCalSelector.countdown([F.event("a", start: F.at(3601))], now: F.now, leadMinutes: 60) == nil)
    }

    @Test func customLeadWindow() {
        let e = F.event("a", start: F.at(20 * 60))
        #expect(IslCalSelector.countdown([e], now: F.now, leadMinutes: 15) == nil)
        #expect(IslCalSelector.countdown([e], now: F.now, leadMinutes: 30) != nil)
    }

    @Test func ongoingEventShowsRemainingTime() {
        let e = F.event("a", start: F.at(-600), minutes: 60)
        #expect(IslCalSelector.countdown([e], now: F.now, leadMinutes: 60) == .remaining(e, 3000))
    }

    @Test func imminentNextEventBeatsTheOngoingOne() {
        let cur = F.event("cur", start: F.at(-600), minutes: 60)
        let next = F.event("next", start: F.at(240))
        #expect(IslCalSelector.countdown([cur, next], now: F.now, leadMinutes: 60)?.event.id == "next")
    }

    @Test func ongoingEventBeatsADistantNextEvent() {
        let cur = F.event("cur", start: F.at(-600), minutes: 60)
        let next = F.event("next", start: F.at(20 * 60))
        #expect(IslCalSelector.countdown([cur, next], now: F.now, leadMinutes: 60) == .remaining(cur, 3000))
    }

    @Test func allDayEventsNeverCountDown() {
        let e = F.event("a", start: F.date(2026, 10, 24), minutes: 1439, allDay: true)
        #expect(IslCalSelector.countdown([e], now: F.at(23 * 3600 + 1), leadMinutes: 60) == nil)
    }

    @Test func nothingMeansNoCountdown() {
        #expect(IslCalSelector.countdown([], now: F.now, leadMinutes: 60) == nil)
    }

    @Test func activityStagesAreBucketed() {
        #expect(IslCalActivityFactory.stage(30) == "1")
        #expect(IslCalActivityFactory.stage(200) == "5")
        #expect(IslCalActivityFactory.stage(500) == "10")
        #expect(IslCalActivityFactory.stage(1500) == "30")
        #expect(IslCalActivityFactory.stage(3000) == "60")
    }

    @Test func activityPriorityRisesAsTheEventApproaches() {
        func prio(_ s: TimeInterval) -> Int {
            let e = F.event("a", start: F.at(s))
            return IslCalActivityFactory.activity(IslCalSelector.countdown([e], now: F.now, leadMinutes: 60), now: F.now)!.priority
        }
        #expect(prio(3000) == IslPriority.calendar)
        #expect(prio(200) == IslPriority.calendarSoon)
        #expect(prio(30) == IslPriority.calendarImminent)
    }

    @Test func activityExpiresWhenTheEventStarts() {
        let e = F.event("a", start: F.at(600))
        let a = IslCalActivityFactory.activity(.until(e, 600), now: F.now)
        #expect(a?.expiresAt == e.start && a?.section == IslSectionIDs.calendar && a?.peeks == true)
        #expect(a?.isExpired(at: e.start) == true)
    }

    @Test func ongoingActivityExpiresAtTheEnd() {
        let e = F.event("a", start: F.at(-600), minutes: 60)
        let a = IslCalActivityFactory.activity(.remaining(e, 3000), now: F.now)
        #expect(a?.expiresAt == e.end && a?.token == "r|a")
    }

    @Test func tokenChangesWhenTheStageChanges() {
        let e = F.event("a", start: F.at(3000))
        let t1 = IslCalActivityFactory.activity(.until(e, 3000), now: F.now)?.token
        let t2 = IslCalActivityFactory.activity(.until(e, 250), now: F.now)?.token
        let t3 = IslCalActivityFactory.activity(.until(e, 240), now: F.now)?.token
        #expect(t1 != t2 && t2 == t3)
    }

    @Test func noCountdownMeansNoActivity() {
        #expect(IslCalActivityFactory.activity(nil, now: F.now) == nil)
    }

    @Test func calendarActivityLosesToTimerButBeatsMusic() {
        var arbiter = IslArbiter()
        let cal = IslCalActivityFactory.activity(.until(F.event("a", start: F.at(600)), 600), now: F.now)!
        let music = IslFix.activity("music", "music", priority: IslPriority.music, started: 0)
        let timer = IslFix.activity("timer", "timer", priority: IslPriority.timer, started: 0)
        #expect(arbiter.resolve([music, cal], now: IslFix.at(0)).winner?.id == "calendar")
        var other = IslArbiter()
        #expect(other.resolve([music, cal, timer], now: IslFix.at(0)).winner?.id == "timer")
    }
}

@Suite struct IslCalDaysTests {
    @Test func singleDayAllDayEventWithInclusiveEnd() {
        let e = IslCalEvent(id: "a", title: "A", start: F.date(2026, 10, 24), end: F.date(2026, 10, 24, 23, 59, 59), isAllDay: true)
        #expect(IslCalDays.coveredDays(e, tz: F.msk) == [F.date(2026, 10, 24)])
    }

    @Test func singleDayAllDayEventWithExclusiveEnd() {
        let e = IslCalEvent(id: "a", title: "A", start: F.date(2026, 10, 24), end: F.date(2026, 10, 25), isAllDay: true)
        #expect(IslCalDays.coveredDays(e, tz: F.msk) == [F.date(2026, 10, 24)])
    }

    @Test func multiDayAllDayEventCoversEveryDay() {
        let e = IslCalEvent(id: "a", title: "A", start: F.date(2026, 10, 24), end: F.date(2026, 10, 27), isAllDay: true)
        #expect(IslCalDays.coveredDays(e, tz: F.msk).count == 3)
    }

    @Test func timedEventCrossingMidnightCoversTwoDays() {
        let e = F.event("a", start: F.date(2026, 10, 23, 23, 0), minutes: 120)
        #expect(IslCalDays.coveredDays(e, tz: F.msk) == [F.date(2026, 10, 23), F.date(2026, 10, 24)])
    }

    @Test func eventEndingExactlyAtMidnightStaysInOneDay() {
        let e = F.event("a", start: F.date(2026, 10, 23, 22, 0), minutes: 120)
        #expect(IslCalDays.coveredDays(e, tz: F.msk) == [F.date(2026, 10, 23)])
    }

    @Test func zeroLengthEventCoversItsDay() {
        let e = F.event("a", start: F.date(2026, 10, 23, 9, 0), minutes: 0)
        #expect(IslCalDays.coveredDays(e, tz: F.msk).count == 1)
    }

    @Test func sameInstantFallsOnDifferentDaysInDifferentZones() {
        let e = F.event("a", start: F.date(2026, 10, 24, 1, 0, tz: F.msk), minutes: 30)
        #expect(IslCalDays.touches(e, day: F.date(2026, 10, 24, tz: F.msk), tz: F.msk))
        #expect(IslCalDays.touches(e, day: F.date(2026, 10, 23, tz: F.la), tz: F.la))
        #expect(!IslCalDays.touches(e, day: F.date(2026, 10, 24, tz: F.la), tz: F.la))
    }

    @Test func floatingAllDayKeepsTheWallClockDateWhenTheZoneChanges() {
        let e = IslCalEvent(id: "a", title: "A", start: F.date(2026, 10, 24, tz: F.msk), end: F.date(2026, 10, 25, tz: F.msk), isAllDay: true)
        let moved = IslCalZone.floatingAllDay(e, from: F.msk, to: F.la)
        #expect(moved.start == F.date(2026, 10, 24, tz: F.la) && moved.end == F.date(2026, 10, 25, tz: F.la))
        #expect(IslCalDays.coveredDays(moved, tz: F.la) == [F.date(2026, 10, 24, tz: F.la)])
    }

    @Test func floatingConversionLeavesTimedEventsAlone() {
        let e = F.event("a", start: F.date(2026, 10, 24, 10, 0))
        #expect(IslCalZone.floatingAllDay(e, from: F.msk, to: F.la) == e)
    }

    @Test func sameZoneConversionIsANoOp() {
        let e = IslCalEvent(id: "a", title: "A", start: F.date(2026, 10, 24), end: F.date(2026, 10, 25), isAllDay: true)
        #expect(IslCalZone.floatingAllDay(e, from: F.msk, to: F.msk) == e)
    }
}

@Suite struct IslCalAgendaTests {
    @Test func daysAreGroupedWithAllDayFirst() {
        let allDay = IslCalEvent(id: "ad", title: "ad", start: F.date(2026, 10, 23), end: F.date(2026, 10, 24), isAllDay: true)
        let list = [F.event("b", start: F.date(2026, 10, 23, 15, 0)), F.event("a", start: F.date(2026, 10, 23, 13, 0)), allDay, F.event("n", start: F.date(2026, 10, 24, 9, 0))]
        let agenda = IslCalAgenda.build(list, now: F.now, days: 3, tz: F.msk)
        #expect(agenda.count == 2)
        #expect(agenda[0].items.map(\.event.id) == ["ad", "a", "b"])
        #expect(agenda[0].items.map(\.kind) == [.allDay, .timed, .timed])
        #expect(agenda[1].items.map(\.event.id) == ["n"])
    }

    @Test func eventsAlreadyEndedTodayAreHidden() {
        let list = [F.event("gone", start: F.date(2026, 10, 23, 9, 0), minutes: 30), F.event("now", start: F.date(2026, 10, 23, 11, 30), minutes: 60)]
        #expect(IslCalAgenda.build(list, now: F.now, days: 1, tz: F.msk)[0].items.map(\.event.id) == ["now"])
    }

    @Test func multiDayEventContinuesOnLaterDays() {
        let e = F.event("trip", start: F.date(2026, 10, 23, 22, 0), minutes: 26 * 60)
        let agenda = IslCalAgenda.build([e], now: F.now, days: 3, tz: F.msk)
        #expect(agenda.count == 2)
        #expect(agenda[0].items[0].kind == .timed && agenda[1].items[0].kind == .continuing)
    }

    @Test func daysBeyondTheHorizonAreCut() {
        let list = [F.event("a", start: F.date(2026, 10, 23, 15, 0)), F.event("z", start: F.date(2026, 10, 28, 15, 0))]
        #expect(IslCalAgenda.build(list, now: F.now, days: 2, tz: F.msk).flatMap { $0.items.map(\.event.id) } == ["a"])
    }

    @Test func emptyDaysAreSkipped() {
        let agenda = IslCalAgenda.build([F.event("far", start: F.date(2026, 10, 26, 9, 0))], now: F.now, days: 7, tz: F.msk)
        #expect(agenda.count == 1 && agenda[0].day == F.date(2026, 10, 26))
    }

    @Test func agendaUsesTheRequestedZone() {
        let e = F.event("a", start: F.date(2026, 10, 24, 1, 0, tz: F.msk), minutes: 30)
        let msk = IslCalAgenda.build([e], now: F.now, days: 3, tz: F.msk)
        let la = IslCalAgenda.build([e], now: F.now, days: 3, tz: F.la)
        #expect(msk[0].day == F.date(2026, 10, 24, tz: F.msk))
        #expect(la[0].day == F.date(2026, 10, 23, tz: F.la))
    }
}

@Suite struct IslCalMonthTests {
    @Test func octoberTwentySixStartsOnThursdayWithMondayFirst() {
        let grid = IslCalMonthGrid.build(year: 2026, month: 10, events: [], now: F.now, tz: F.msk)
        #expect(grid.count == 5 && grid.allSatisfy { $0.count == 7 })
        #expect(grid[0].filter(\.inMonth).map(\.day) == [1, 2, 3, 4])
        #expect(grid[0][3].day == 1 && !grid[0][2].inMonth)
        #expect(grid.flatMap { $0 }.filter(\.inMonth).count == 31)
    }

    @Test func sundayFirstShiftsTheLeadingBlanks() {
        let grid = IslCalMonthGrid.build(year: 2026, month: 10, events: [], now: F.now, tz: F.msk, firstWeekday: 1)
        #expect(grid[0].filter(\.inMonth).first?.day == 1 && grid[0][4].day == 1)
    }

    @Test func todayAndEventCountsAreMarked() {
        let events = [F.event("a", start: F.date(2026, 10, 23, 15, 0)), F.event("b", start: F.date(2026, 10, 23, 16, 0)), F.event("c", start: F.date(2026, 10, 24, 9, 0))]
        let cells = IslCalMonthGrid.build(year: 2026, month: 10, events: events, now: F.now, tz: F.msk).flatMap { $0 }
        #expect(cells.first { $0.isToday }?.day == 23)
        #expect(cells.first { $0.day == 23 && $0.inMonth }?.eventCount == 2)
        #expect(cells.first { $0.day == 24 && $0.inMonth }?.eventCount == 1)
        #expect(cells.first { $0.day == 25 && $0.inMonth }?.eventCount == 0)
    }

    @Test func februaryOfALeapYearHasTwentyNineDays() {
        let cells = IslCalMonthGrid.build(year: 2028, month: 2, events: [], now: F.now, tz: F.msk).flatMap { $0 }
        #expect(cells.filter(\.inMonth).count == 29)
    }

    @Test func monthShiftWrapsTheYear() {
        #expect(IslCalMonthGrid.shift(year: 2026, month: 12, by: 1) == (2027, 1))
        #expect(IslCalMonthGrid.shift(year: 2026, month: 1, by: -1) == (2025, 12))
        #expect(IslCalMonthGrid.shift(year: 2026, month: 10, by: 14) == (2027, 12))
    }

    @Test func titleAndWeekdayHeaders() {
        #expect(IslCalMonthGrid.title(year: 2026, month: 10) == "Октябрь 2026")
        #expect(IslCalMonthGrid.title(year: 2026, month: 13) == "")
        #expect(IslCalMonthGrid.weekdaySymbols() == ["пн", "вт", "ср", "чт", "пт", "сб", "вс"])
        #expect(IslCalMonthGrid.weekdaySymbols(firstWeekday: 1).first == "вс")
    }
}

@Suite struct IslCalReminderTests {
    private func r(_ id: String, due: Date?, time: Bool = true, done: Bool = false) -> IslCalReminder {
        IslCalReminder(id: id, title: id, due: due, dueHasTime: time, completed: done)
    }

    @Test func overdueThenTodayThenLaterThenUndated() {
        let list = [r("none", due: nil), r("later", due: F.date(2026, 10, 25, 9, 0)), r("today", due: F.date(2026, 10, 23, 18, 0)), r("late", due: F.date(2026, 10, 22, 9, 0))]
        let rows = IslCalReminders.select(list, now: F.now, tz: F.msk, limit: 10)
        #expect(rows.map(\.id) == ["late", "today", "later", "none"])
        #expect(rows.map(\.urgency) == [.overdue, .today, .later, .none])
    }

    @Test func completedAreDropped() {
        #expect(IslCalReminders.select([r("a", due: nil, done: true), r("b", due: nil)], now: F.now, tz: F.msk, limit: 5).map(\.id) == ["b"])
    }

    @Test func dateOnlyReminderForTodayIsNotOverdue() {
        let rows = IslCalReminders.select([r("a", due: F.date(2026, 10, 23, 0, 0), time: false)], now: F.now, tz: F.msk, limit: 5)
        #expect(rows[0].urgency == .today)
    }

    @Test func timedReminderEarlierTodayIsOverdue() {
        #expect(IslCalReminders.select([r("a", due: F.date(2026, 10, 23, 8, 0))], now: F.now, tz: F.msk, limit: 5)[0].urgency == .overdue)
    }

    @Test func limitIsRespected() {
        let list = (0..<8).map { r("r\($0)", due: nil) }
        #expect(IslCalReminders.select(list, now: F.now, tz: F.msk, limit: 3).count == 3)
        #expect(IslCalReminders.select(list, now: F.now, tz: F.msk, limit: 0).isEmpty)
    }
}

@Suite struct IslCalFormatTests {
    @Test func countdownTexts() {
        #expect(IslCalFormat.countdown(30) == "30 с")
        #expect(IslCalFormat.countdown(60) == "1 мин")
        #expect(IslCalFormat.countdown(61) == "2 мин")
        #expect(IslCalFormat.countdown(3600) == "1 ч")
        #expect(IslCalFormat.countdown(3900) == "1 ч 5 мин")
        #expect(IslCalFormat.countdown(-5) == "0 с")
    }

    @Test func compactClock() {
        #expect(IslCalFormat.compactClock(125) == "2:05")
        #expect(IslCalFormat.compactClock(3725) == "1:02:05")
    }

    @Test func labelsDistinguishUntilAndRemaining() {
        let e = F.event("a", start: F.at(600))
        #expect(IslCalFormat.label(.until(e, 600)) == "через 10 мин")
        #expect(IslCalFormat.label(.remaining(e, 1500)) == "осталось 25 мин")
    }

    @Test func timeRangeUsesTheGivenZone() {
        let e = F.event("a", start: F.date(2026, 10, 23, 9, 5), minutes: 85)
        #expect(IslCalFormat.range(e, tz: F.msk) == "9:05–10:30")
        #expect(IslCalFormat.range(e, tz: F.utc) == "6:05–7:30")
        #expect(IslCalFormat.range(F.event("d", start: F.now, allDay: true), tz: F.msk) == "Весь день")
    }

    @Test func dayTitles() {
        #expect(IslCalFormat.dayTitle(F.date(2026, 10, 23), now: F.now, tz: F.msk) == "Сегодня")
        #expect(IslCalFormat.dayTitle(F.date(2026, 10, 24), now: F.now, tz: F.msk) == "Завтра")
        #expect(IslCalFormat.dayTitle(F.date(2026, 10, 26), now: F.now, tz: F.msk) == "пн, 26 окт")
    }
}

@Suite struct IslCalEngineTests {
    private func engine(_ src: ExtFakeCalSource, _ s: IslCalSettings = IslCalSettings()) -> IslCalEngine { IslCalEngine(source: src, settings: s, timeZone: F.msk) }

    @Test func startLoadsEventsAndBuildsAnActivity() {
        let src = ExtFakeCalSource()
        src.eventList = [F.event("a", start: F.at(900))]
        let e = engine(src)
        e.start(now: F.now)
        #expect(e.events.count == 1 && !e.denied)
        #expect(e.activity(now: F.now)?.title == "a")
    }

    @Test func deniedAccessIsReportedAndNothingLoads() {
        let src = ExtFakeCalSource()
        src.access = .denied
        let e = engine(src)
        e.start(now: F.now)
        #expect(e.denied && e.events.isEmpty && e.activity(now: F.now) == nil)
    }

    @Test func unknownAccessAsksOnceAndLoadsWhenGranted() {
        let src = ExtFakeCalSource()
        src.access = .unknown
        src.eventList = [F.event("a", start: F.at(900))]
        let e = engine(src)
        e.start(now: F.now)
        #expect(src.requested == 1 && e.events.count == 1 && !e.denied)
    }

    @Test func refusedPromptMarksDenied() {
        let src = ExtFakeCalSource()
        src.access = .unknown
        src.granted = false
        let e = engine(src)
        e.start(now: F.now)
        #expect(e.denied && e.events.isEmpty)
    }

    @Test func tickReloadsOnlyAfterTheInterval() {
        let src = ExtFakeCalSource()
        let e = engine(src)
        e.start(now: F.now)
        let n = src.eventQueries.count
        e.tick(now: F.at(60))
        #expect(src.eventQueries.count == n)
        e.tick(now: F.at(301))
        #expect(src.eventQueries.count == n + 1)
    }

    @Test func tickReloadsWhenTheClockJumpsBack() {
        let src = ExtFakeCalSource()
        let e = engine(src)
        e.start(now: F.now)
        let n = src.eventQueries.count
        e.tick(now: F.at(-3600))
        #expect(src.eventQueries.count == n + 1)
    }

    @Test func hiddenCalendarsDoNotProduceActivities() {
        let src = ExtFakeCalSource()
        src.eventList = [F.event("a", start: F.at(900), calendar: "home")]
        var s = IslCalSettings()
        s.hiddenCalendars = ["home"]
        let e = engine(src, s)
        e.start(now: F.now)
        #expect(e.activity(now: F.now) == nil && e.agenda(now: F.now).isEmpty)
    }

    @Test func remindersArriveAsynchronously() {
        let src = ExtFakeCalSource()
        src.deferReminders = true
        let e = engine(src)
        var changes = 0
        e.onChange = { changes += 1 }
        e.start(now: F.now)
        #expect(e.reminders.isEmpty)
        src.pendingReminders?([IslCalReminder(id: "r", title: "r")])
        #expect(e.reminders.count == 1 && changes >= 2)
        #expect(e.reminderRows(now: F.now).count == 1)
    }

    @Test func remindersCanBeSwitchedOff() {
        let src = ExtFakeCalSource()
        src.reminderList = [IslCalReminder(id: "r", title: "r")]
        var s = IslCalSettings()
        s.showReminders = false
        let e = engine(src, s)
        e.start(now: F.now)
        #expect(e.reminderRows(now: F.now).isEmpty)
    }

    @Test func eventQueryWindowStartsYesterdayAndCoversTheHorizon() {
        let src = ExtFakeCalSource()
        let e = engine(src)
        e.start(now: F.now)
        let q = src.eventQueries[0]
        #expect(q.0 == F.date(2026, 10, 22) && q.1 >= F.date(2026, 10, 30))
    }
}

@Suite struct IslCalSettingsTests {
    @Test func defaultsLeaveTheStoreEmpty() {
        let kv = WndMemoryStore()
        IslCalSettingsStore(kv).save(IslCalSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func roundTrip() {
        let kv = WndMemoryStore()
        var s = IslCalSettings()
        s.leadMinutes = 30
        s.daysAhead = 3
        s.showAllDay = false
        s.remindersLimit = 2
        s.hiddenCalendars = ["x", "y"]
        IslCalSettingsStore(kv).save(s)
        #expect(IslCalSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("notch.calendar.") })
    }

    @Test func outOfRangeValuesAreClamped() {
        var s = IslCalSettings()
        s.leadMinutes = 9999
        s.daysAhead = 0
        s.remindersLimit = -4
        let c = s.sanitized
        #expect(c.leadMinutes == 180 && c.daysAhead == 1 && c.remindersLimit == 1)
    }
}
