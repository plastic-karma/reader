//
//  EditionContextTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

/// EditionContext selection semantics (follow-latest, pinning, stale-id
/// fallback, ⌘[/⌘] navigation) and the Edition display label.
final class EditionContextTests: XCTestCase {

    // MARK: - resolve

    @MainActor
    func testLatestResolvesToNewestAndEmptyToNil() throws {
        let container = try makeContainer()
        let context = makeLeakedContext()

        XCTAssertNil(context.resolve(from: []))

        let editions = insertEditions(1...3, into: container)
        let newestFirst = Array(editions.reversed())
        XCTAssertEqual(context.resolve(from: newestFirst)?.number, 3)
    }

    @MainActor
    func testSpecificPinsAndStaleIDFallsBackToNewest() throws {
        let container = try makeContainer()
        let context = makeLeakedContext()
        let editions = insertEditions(1...3, into: container)
        let newestFirst = Array(editions.reversed())

        context.selection = .specific(editions[1].persistentModelID)
        XCTAssertEqual(context.resolve(from: newestFirst)?.number, 2)

        // Delete the pinned edition: the stale id resolves to the newest
        // instead of showing nothing.
        let staleID = editions[1].persistentModelID
        container.mainContext.delete(editions[1])
        try container.mainContext.save()
        context.selection = .specific(staleID)
        let remaining = try fetchNewestFirst(in: container)
        XCTAssertEqual(context.resolve(from: remaining)?.number, 3)
    }

    // MARK: - Older/newer navigation

    @MainActor
    func testSelectOlderWalksBackAndStopsAtOldest() throws {
        let container = try makeContainer()
        let context = makeLeakedContext()
        insertEditions(1...3, into: container)
        try container.mainContext.save()

        context.selectOlder(in: container.mainContext)
        XCTAssertEqual(resolvedNumber(context, in: container), 2)

        context.selectOlder(in: container.mainContext)
        XCTAssertEqual(resolvedNumber(context, in: container), 1)

        // Boundary: already at the oldest — no-op.
        context.selectOlder(in: container.mainContext)
        XCTAssertEqual(resolvedNumber(context, in: container), 1)
    }

    @MainActor
    func testSelectNewerWalksForwardAndReArmsFollowLatest() throws {
        let container = try makeContainer()
        let context = makeLeakedContext()
        let editions = insertEditions(1...3, into: container)
        try container.mainContext.save()

        context.selection = .specific(editions[0].persistentModelID)

        context.selectNewer(in: container.mainContext)
        XCTAssertEqual(resolvedNumber(context, in: container), 2)
        XCTAssertEqual(context.selection, .specific(editions[1].persistentModelID))

        // Landing on the newest re-arms follow-latest…
        context.selectNewer(in: container.mainContext)
        XCTAssertEqual(context.selection, .latest)
        XCTAssertEqual(resolvedNumber(context, in: container), 3)

        // …and from there, newer is a no-op.
        context.selectNewer(in: container.mainContext)
        XCTAssertEqual(context.selection, .latest)
    }

    @MainActor
    func testNavigationNoOpsWithNoEditions() throws {
        let container = try makeContainer()
        let context = makeLeakedContext()

        context.selectOlder(in: container.mainContext)
        context.selectNewer(in: container.mainContext)

        XCTAssertEqual(context.selection, .latest)
    }

    // MARK: - Display label

    func testDisplayLabelFormatsNumberDateAndManualSuffix() {
        let scheduled = utcDate(2026, 7, 6, 6, 0)
        let now = utcDate(2026, 7, 7, 12, 0)
        let edition = Edition(
            number: 12, publishedAt: scheduled, scheduledFor: scheduled, isManual: false)

        let label = edition.displayLabel(
            relativeTo: now, calendar: utcCalendar(), locale: Locale(identifier: "en_US"))

        XCTAssertTrue(label.hasPrefix("Edition #12 · "), label)
        XCTAssertTrue(label.contains("Jul"), label)
        XCTAssertTrue(label.contains("6"), label)
        XCTAssertFalse(label.contains("2026"), "Same-year labels stay short: \(label)")
        XCTAssertFalse(label.contains("(manual)"), label)

        let manual = Edition(
            number: 13, publishedAt: scheduled, scheduledFor: scheduled, isManual: true)
        let manualLabel = manual.displayLabel(
            relativeTo: now, calendar: utcCalendar(), locale: Locale(identifier: "en_US"))
        XCTAssertTrue(manualLabel.hasSuffix(" (manual)"), manualLabel)
    }

    func testDisplayLabelAppendsYearWhenNotCurrent() {
        let scheduled = utcDate(2025, 12, 31, 6, 0)
        let now = utcDate(2026, 7, 7, 12, 0)
        let edition = Edition(
            number: 3, publishedAt: scheduled, scheduledFor: scheduled, isManual: false)

        let label = edition.displayLabel(
            relativeTo: now, calendar: utcCalendar(), locale: Locale(identifier: "en_US"))

        XCTAssertTrue(label.contains("2025"), label)
    }

    // MARK: - Helpers

    /// Deallocating ANY app-module @Observable crashes this toolchain with
    /// "malloc: pointer being freed was not allocated" (Xcode 26.4.1 +
    /// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor; reproduced with the
    /// pre-existing GmailAccountController too, so it is not specific to
    /// EditionContext). The app never deallocates these objects — readerApp
    /// holds them for the process lifetime — so tests mirror that reality by
    /// deliberately leaking the instance. Revisit on toolchain updates.
    @MainActor
    private func makeLeakedContext() -> EditionContext {
        let context = EditionContext()
        _ = Unmanaged.passRetained(context)
        return context
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self, Edition.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Inserts editions numbered by `numbers`, oldest-first, and returns
    /// them in that order.
    @MainActor
    @discardableResult
    private func insertEditions(
        _ numbers: ClosedRange<Int>,
        into container: ModelContainer
    ) -> [Edition] {
        numbers.map { number in
            let edition = Edition(
                number: number,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(number) * 86400),
                scheduledFor: Date(timeIntervalSince1970: TimeInterval(number) * 86400),
                isManual: false
            )
            container.mainContext.insert(edition)
            return edition
        }
    }

    @MainActor
    private func fetchNewestFirst(in container: ModelContainer) throws -> [Edition] {
        try container.mainContext.fetch(FetchDescriptor<Edition>(
            sortBy: [SortDescriptor(\.number, order: .reverse)]
        ))
    }

    @MainActor
    private func resolvedNumber(_ context: EditionContext, in container: ModelContainer) -> Int? {
        context.resolveActiveEdition(in: container.mainContext)?.number
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        return utcCalendar().date(from: components)!
    }
}
