//
//  Edition.swift
//  reader
//

import Foundation
import SwiftData

/// A published batch of articles: everything that arrived between the
/// previous edition and this one's boundary, revealed together. Editions are
/// the unit of the "edition mode" back-catalog.
@Model
nonisolated final class Edition {
    /// 1-based, strictly sequential. Deliberately NOT #Unique: SwiftData
    /// unique constraints upsert on collision, which would silently merge
    /// editions if numbering ever went wrong — a visible duplicate beats
    /// invisible data loss. Uniqueness is guaranteed by construction
    /// instead: every Edition is created by RefreshEngine.publishEdition,
    /// which computes the number and inserts with no suspension point in
    /// between (single-writer invariant).
    var number: Int
    /// Wall-clock moment the edition was actually created.
    var publishedAt: Date
    /// Nominal boundary this edition covers: the cadence grid point for
    /// scheduled editions (== publishedAt for manual ones, == the most
    /// recent elapsed boundary for catch-ups). Monotonically non-decreasing
    /// in `number` — the due-check compares against the latest edition's
    /// scheduledFor.
    var scheduledFor: Date
    /// Created via "Create Edition Now" rather than the cadence.
    var isManual: Bool
    /// Nullify: deleting an edition returns its articles to the pending
    /// pool (they join the next edition). Feed cascade-deletes just shrink
    /// an edition; empty editions are legal.
    @Relationship(deleteRule: .nullify, inverse: \Article.edition)
    var articles: [Article] = []

    init(number: Int, publishedAt: Date, scheduledFor: Date, isManual: Bool) {
        self.number = number
        self.publishedAt = publishedAt
        self.scheduledFor = scheduledFor
        self.isManual = isManual
    }
}

extension Edition {
    /// Picker/masthead label: "Edition #12 · Mon, Jul 7", appending the year
    /// only when `scheduledFor` falls outside `now`'s year, and " (manual)"
    /// for hand-made editions. Parameters exist for deterministic tests;
    /// UI callers use the defaults.
    func displayLabel(
        relativeTo now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: scheduledFor) != calendar.component(.year, from: now) {
            style = style.year()
        }
        let suffix = isManual ? " (manual)" : ""
        return "Edition #\(number) · \(scheduledFor.formatted(style))\(suffix)"
    }
}
