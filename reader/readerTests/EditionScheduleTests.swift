//
//  EditionScheduleTests.swift
//  readerTests
//

import XCTest
@testable import reader

/// Pure grid math: every case pins `now`, the last boundary, and the
/// calendar/timezone, so the suite is deterministic with no clock seam.
/// Reference week: Monday 2026-07-06 … Sunday 2026-07-12.
final class EditionScheduleTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    // MARK: - Manual

    func testManualCadenceHasNoBoundaries() {
        let cal = calendar(in: utc)
        let now = date(utc, 2026, 7, 6, 9, 0)
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: .default, lastScheduledFor: nil, now: now, calendar: cal))
        XCTAssertNil(EditionSchedule.nextBoundary(
            cadence: .default, lastScheduledFor: nil, now: now, calendar: cal))
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: .default, lastScheduledFor: date(utc, 2026, 7, 1, 6, 0), now: now, calendar: cal))
    }

    // MARK: - Daily

    func testDailyNextBoundarySameDayBeforeTimeAndNextDayAfter() {
        let cal = calendar(in: utc)
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: daily(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 5, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: daily(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 23, 30), calendar: cal),
            date(utc, 2026, 7, 7, 6, 0)
        )
    }

    func testDailyDueOnlyWhenGridPointUncovered() {
        let cal = calendar(in: utc)
        // Today's boundary already covered → nothing due.
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: daily(), lastScheduledFor: date(utc, 2026, 7, 6, 6, 0),
            now: date(utc, 2026, 7, 6, 9, 0), calendar: cal))
        // Yesterday covered, today's boundary elapsed → today is due.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: date(utc, 2026, 7, 5, 6, 0),
                now: date(utc, 2026, 7, 6, 9, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
        // Before today's boundary nothing new has elapsed.
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: daily(), lastScheduledFor: date(utc, 2026, 7, 5, 6, 0),
            now: date(utc, 2026, 7, 6, 5, 0), calendar: cal))
    }

    func testExactBoundaryInstantCountsAsDue() {
        let cal = calendar(in: utc)
        let boundary = date(utc, 2026, 7, 6, 6, 0)
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: date(utc, 2026, 7, 5, 6, 0),
                now: boundary, calendar: cal),
            boundary
        )
        // …and the next wake from the exact instant is tomorrow, not "now".
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: daily(), lastScheduledFor: boundary, now: boundary, calendar: cal),
            date(utc, 2026, 7, 7, 6, 0)
        )
    }

    func testMultiDayGapYieldsOnlyLatestBoundary() {
        let cal = calendar(in: utc)
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: date(utc, 2026, 6, 26, 6, 0),
                now: date(utc, 2026, 7, 6, 9, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
        // Before today's grid point the catch-up lands on yesterday's.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: date(utc, 2026, 6, 26, 6, 0),
                now: date(utc, 2026, 7, 6, 5, 0), calendar: cal),
            date(utc, 2026, 7, 5, 6, 0)
        )
    }

    func testNoPriorEditionMakesLatestElapsedBoundaryDue() {
        let cal = calendar(in: utc)
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 9, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 5, 0), calendar: cal),
            date(utc, 2026, 7, 5, 6, 0)
        )
        // Weekly bootstrap: the most recent Monday 06:00.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: weekly(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 9, 12, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
    }

    // MARK: - Weekly

    func testWeeklyMatchesConfiguredWeekdayAndTime() {
        let cal = calendar(in: utc)
        // From Thursday, the next Monday-06:00 boundary.
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: weekly(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 9, 12, 0), calendar: cal),
            date(utc, 2026, 7, 13, 6, 0)
        )
        // Previous Monday covered → this Monday is due.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: weekly(), lastScheduledFor: date(utc, 2026, 6, 29, 6, 0),
                now: date(utc, 2026, 7, 9, 12, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
    }

    func testWeeklyMultiWeekGapPicksLatestWeek() {
        let cal = calendar(in: utc)
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: weekly(), lastScheduledFor: date(utc, 2026, 6, 15, 6, 0),
                now: date(utc, 2026, 7, 9, 12, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
    }

    // MARK: - Every 2 days

    func testEveryTwoDaysAnchorsOnLastEditionDay() {
        let cal = calendar(in: utc)
        let lastMonday = date(utc, 2026, 7, 6, 6, 0)
        // Tuesday: nothing due yet, next boundary Wednesday 06:00.
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: every2Days(), lastScheduledFor: lastMonday,
            now: date(utc, 2026, 7, 7, 9, 0), calendar: cal))
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: every2Days(), lastScheduledFor: lastMonday,
                now: date(utc, 2026, 7, 7, 9, 0), calendar: cal),
            date(utc, 2026, 7, 8, 6, 0)
        )
        // Wednesday after 06:00: due, and the following boundary is Friday.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: every2Days(), lastScheduledFor: lastMonday,
                now: date(utc, 2026, 7, 8, 7, 0), calendar: cal),
            date(utc, 2026, 7, 8, 6, 0)
        )
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: every2Days(), lastScheduledFor: lastMonday,
                now: date(utc, 2026, 7, 8, 7, 0), calendar: cal),
            date(utc, 2026, 7, 10, 6, 0)
        )
    }

    func testManualEditionShiftsEveryTwoDaysAnchorButNotDailyGrid() {
        let cal = calendar(in: utc)
        let manualTuesdayNight = date(utc, 2026, 7, 7, 22, 0)
        // every2Days re-anchors: next boundary Thursday 06:00, nothing due Wednesday.
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: every2Days(), lastScheduledFor: manualTuesdayNight,
                now: date(utc, 2026, 7, 7, 23, 0), calendar: cal),
            date(utc, 2026, 7, 9, 6, 0)
        )
        XCTAssertNil(EditionSchedule.dueBoundary(
            cadence: every2Days(), lastScheduledFor: manualTuesdayNight,
            now: date(utc, 2026, 7, 8, 9, 0), calendar: cal))
        // The daily grid is absolute: Wednesday 06:00 still fires.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: daily(), lastScheduledFor: manualTuesdayNight,
                now: date(utc, 2026, 7, 8, 9, 0), calendar: cal),
            date(utc, 2026, 7, 8, 6, 0)
        )
    }

    func testEveryTwoDaysMultiGapPicksLatestEvenStep() {
        let cal = calendar(in: utc)
        let lastMonday = date(utc, 2026, 7, 6, 6, 0)
        // Candidates July 8, 10, 12, 14 … — the following Monday 09:00 sits
        // past the 12th, so that's the single catch-up boundary.
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: every2Days(), lastScheduledFor: lastMonday,
                now: date(utc, 2026, 7, 13, 9, 0), calendar: cal),
            date(utc, 2026, 7, 12, 6, 0)
        )
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: every2Days(), lastScheduledFor: lastMonday,
                now: date(utc, 2026, 7, 13, 9, 0), calendar: cal),
            date(utc, 2026, 7, 14, 6, 0)
        )
    }

    func testEveryTwoDaysBootstrapsLikeDaily() {
        let cal = calendar(in: utc)
        XCTAssertEqual(
            EditionSchedule.dueBoundary(
                cadence: every2Days(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 9, 0), calendar: cal),
            date(utc, 2026, 7, 6, 6, 0)
        )
        XCTAssertEqual(
            EditionSchedule.nextBoundary(
                cadence: every2Days(), lastScheduledFor: nil,
                now: date(utc, 2026, 7, 6, 9, 0), calendar: cal),
            date(utc, 2026, 7, 7, 6, 0)
        )
    }

    // MARK: - DST (Europe/Berlin, 2026: spring-forward Mar 29, fall-back Oct 25)

    func testDailyBoundariesAcrossBerlinSpringForwardAndFallBack() {
        let cal = calendar(in: berlin)
        // Spring forward (02:00→03:00): consecutive 06:00 boundaries sit
        // 23 h apart in absolute time; the new one is 06:00 CEST = 04:00 UTC.
        let springNext = EditionSchedule.nextBoundary(
            cadence: daily(), lastScheduledFor: date(berlin, 2026, 3, 28, 6, 0),
            now: date(berlin, 2026, 3, 28, 7, 0), calendar: cal)
        XCTAssertEqual(springNext, date(utc, 2026, 3, 29, 4, 0))
        XCTAssertEqual(
            springNext?.timeIntervalSince(date(berlin, 2026, 3, 28, 6, 0)),
            23 * 3600
        )
        // Fall back (03:00→02:00): 25 h apart; 06:00 CET = 05:00 UTC.
        let fallNext = EditionSchedule.nextBoundary(
            cadence: daily(), lastScheduledFor: date(berlin, 2026, 10, 24, 6, 0),
            now: date(berlin, 2026, 10, 24, 7, 0), calendar: cal)
        XCTAssertEqual(fallNext, date(utc, 2026, 10, 25, 5, 0))
        XCTAssertEqual(
            fallNext?.timeIntervalSince(date(berlin, 2026, 10, 24, 6, 0)),
            25 * 3600
        )
    }

    func testGapTimeBoundaryRollsForwardOnSpringForwardDay() throws {
        let cal = calendar(in: berlin)
        // 02:30 does not exist on 2026-03-29 in Berlin. The boundary must
        // stay on that civil day, land at or after 03:00 local, and remain
        // strictly increasing (Foundation's exact roll-forward instant is an
        // implementation detail).
        let boundary = try XCTUnwrap(EditionSchedule.nextBoundary(
            cadence: daily(2 * 60 + 30), lastScheduledFor: nil,
            now: date(berlin, 2026, 3, 28, 23, 0), calendar: cal))
        XCTAssertEqual(cal.component(.day, from: boundary), 29)
        let localMinutes = cal.component(.hour, from: boundary) * 60
            + cal.component(.minute, from: boundary)
        XCTAssertGreaterThanOrEqual(localMinutes, 3 * 60)
        XCTAssertGreaterThan(boundary, date(berlin, 2026, 3, 28, 2, 30))
    }

    // MARK: - Cadence assembly

    func testCadenceMakeClampsAndFallsBack() {
        XCTAssertEqual(
            EditionCadence.make(frequencyRaw: nil, minutesOfDay: nil, weekday: nil),
            .default
        )
        XCTAssertEqual(
            EditionCadence.make(frequencyRaw: "hourly", minutesOfDay: nil, weekday: nil).frequency,
            .manual
        )
        let clamped = EditionCadence.make(frequencyRaw: "daily", minutesOfDay: -5, weekday: 0)
        XCTAssertEqual(clamped.frequency, .daily)
        XCTAssertEqual(clamped.minutesOfDay, 0)
        XCTAssertEqual(clamped.weekday, 1)
        let clampedHigh = EditionCadence.make(frequencyRaw: "weekly", minutesOfDay: 5000, weekday: 9)
        XCTAssertEqual(clampedHigh.minutesOfDay, 1439)
        XCTAssertEqual(clampedHigh.weekday, 7)
    }

    // MARK: - Helpers

    private func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ timeZone: TimeZone,
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!
    }

    private func daily(_ minutesOfDay: Int = 360) -> EditionCadence {
        EditionCadence(frequency: .daily, minutesOfDay: minutesOfDay, weekday: 2)
    }

    private func weekly(_ weekday: Int = 2, minutesOfDay: Int = 360) -> EditionCadence {
        EditionCadence(frequency: .weekly, minutesOfDay: minutesOfDay, weekday: weekday)
    }

    private func every2Days(_ minutesOfDay: Int = 360) -> EditionCadence {
        EditionCadence(frequency: .every2Days, minutesOfDay: minutesOfDay, weekday: 2)
    }
}
