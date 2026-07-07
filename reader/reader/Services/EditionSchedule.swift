//
//  EditionSchedule.swift
//  reader
//

import Foundation

/// Pure cadence-grid math for edition boundaries. Everything — the moment
/// "now", the calendar, the last published boundary — is injected, so the
/// whole type is deterministic under test with fixed dates and timezones
/// (the FeedDates approach: no clock abstraction, just parameters).
///
/// Grid semantics:
/// - daily/weekly boundaries form an absolute wall-clock grid (06:00 every
///   day / every Monday 06:00); manual editions never move that grid.
/// - every2Days is anchored on the last edition's day — publishing an
///   edition (manual included) restarts the two-day count from there.
/// - Calendar arithmetic throughout keeps boundaries at the configured
///   local time across DST transitions (a skipped 02:30 rolls forward).
nonisolated enum EditionSchedule {

    /// The boundary a new automatic edition should cover right now: the
    /// latest grid point at-or-before `now` that `lastScheduledFor` hasn't
    /// covered yet. Exactly one Date even when many boundaries elapsed —
    /// a multi-boundary gap collapses into a single catch-up at the most
    /// recent grid point. nil = nothing due (or manual cadence).
    ///
    /// With no prior edition, the latest elapsed grid point is immediately
    /// due: switching Daily on at 09:00 publishes the inaugural sweep at
    /// once instead of hiding the whole library until tomorrow 06:00.
    static func dueBoundary(
        cadence: EditionCadence,
        lastScheduledFor: Date?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch cadence.frequency {
        case .manual:
            return nil
        case .daily, .weekly:
            guard let candidate = latestGridPoint(
                onOrBefore: now, matching: gridComponents(cadence), calendar: calendar
            ) else { return nil }
            if let last = lastScheduledFor, candidate <= last { return nil }
            return candidate
        case .every2Days:
            guard let last = lastScheduledFor else {
                // Bootstrap: no anchor yet, behave like daily.
                return dueBoundary(
                    cadence: dailyEquivalent(of: cadence),
                    lastScheduledFor: nil, now: now, calendar: calendar
                )
            }
            return everyTwoDayBoundaries(after: last, cadence: cadence, now: now, calendar: calendar)
                .latestAtOrBeforeNow
        }
    }

    /// The earliest boundary strictly after `now` — the scheduler's next
    /// wake-up. Always in the future even when an elapsed boundary went
    /// unpublished (that is dueBoundary's job on the next wake). nil =
    /// manual cadence.
    static func nextBoundary(
        cadence: EditionCadence,
        lastScheduledFor: Date?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch cadence.frequency {
        case .manual:
            return nil
        case .daily, .weekly:
            return calendar.nextDate(
                after: now, matching: gridComponents(cadence), matchingPolicy: .nextTime
            )
        case .every2Days:
            guard let last = lastScheduledFor else {
                return nextBoundary(
                    cadence: dailyEquivalent(of: cadence),
                    lastScheduledFor: nil, now: now, calendar: calendar
                )
            }
            return everyTwoDayBoundaries(after: last, cadence: cadence, now: now, calendar: calendar)
                .earliestAfterNow
        }
    }

    // MARK: - Absolute grid (daily/weekly)

    private static func gridComponents(_ cadence: EditionCadence) -> DateComponents {
        var components = DateComponents(hour: cadence.hour, minute: cadence.minute, second: 0)
        if cadence.frequency == .weekly {
            components.weekday = cadence.weekday
        }
        return components
    }

    private static func dailyEquivalent(of cadence: EditionCadence) -> EditionCadence {
        var daily = cadence
        daily.frequency = .daily
        return daily
    }

    /// Latest grid point at-or-before `instant`. `nextDate(direction:
    /// .backward)` matches strictly before its reference date, so the
    /// reference is nudged forward one second to make an exact-boundary
    /// `instant` count as elapsed; the nudge can admit a grid point inside
    /// (instant, instant+1s], which the verification step walks back past.
    private static func latestGridPoint(
        onOrBefore instant: Date,
        matching components: DateComponents,
        calendar: Calendar
    ) -> Date? {
        guard let candidate = calendar.nextDate(
            after: instant.addingTimeInterval(1),
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        ) else { return nil }
        if candidate <= instant { return candidate }
        return calendar.nextDate(
            after: candidate,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    // MARK: - Anchored grid (every2Days)

    /// Candidates sit at the cadence time-of-day on lastBoundary's day + 2k
    /// days (k ≥ 1). The walk is bounded by half the day-gap between the
    /// last edition and `now` — a handful of iterations in practice.
    private static func everyTwoDayBoundaries(
        after lastBoundary: Date,
        cadence: EditionCadence,
        now: Date,
        calendar: Calendar
    ) -> (latestAtOrBeforeNow: Date?, earliestAfterNow: Date?) {
        let anchorDay = calendar.startOfDay(for: lastBoundary)
        var latestAtOrBefore: Date?
        var step = 1
        while true {
            guard
                let day = calendar.date(byAdding: .day, value: 2 * step, to: anchorDay),
                let candidate = calendar.date(
                    bySettingHour: cadence.hour, minute: cadence.minute, second: 0, of: day
                )
            else { return (latestAtOrBefore, nil) }
            if candidate > now {
                return (latestAtOrBefore, candidate)
            }
            latestAtOrBefore = candidate
            step += 1
        }
    }
}
