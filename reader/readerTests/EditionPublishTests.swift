//
//  EditionPublishTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

/// RefreshEngine.publishEdition / publishDueEditionIfNeeded semantics:
/// sweep membership, numbering, empty editions, and the due/catch-up
/// contract. All dates are fixed and flow through the `now:`/`calendar:`
/// parameters — no clock seam. Tests run on the main actor and hop onto the
/// engine per call; assertions re-fetch from the main context.
final class EditionPublishTests: XCTestCase {

    // MARK: - Publish sweep

    @MainActor
    func testFirstEditionSweepsEntireLibraryPreservingReadState() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let feedA = try makeFeed("a.example", in: container)
        let feedB = try makeFeed("b.example", in: container)
        try addArticle("a-1", to: feedA, in: container, isRead: true, isStarred: true)
        try addArticle("a-2", to: feedA, in: container)
        try addArticle("b-1", to: feedB, in: container)

        let id = await engine.publishEdition(
            scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)
        XCTAssertNotNil(id)

        let editions = try container.mainContext.fetch(FetchDescriptor<Edition>())
        XCTAssertEqual(editions.count, 1)
        let edition = try XCTUnwrap(editions.first)
        XCTAssertEqual(edition.number, 1)
        XCTAssertEqual(edition.articles.count, 3)
        let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
        XCTAssertTrue(articles.allSatisfy { $0.edition != nil })
        let flagged = try XCTUnwrap(articles.first { $0.stableID == "a-1" })
        XCTAssertTrue(flagged.isRead)
        XCTAssertTrue(flagged.isStarred)
        XCTAssertFalse(try XCTUnwrap(articles.first { $0.stableID == "a-2" }).isRead)
    }

    @MainActor
    func testSecondPublishSweepsOnlyArticlesSinceLastEdition() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let feed = try makeFeed("a.example", in: container)
        try addArticle("old-1", to: feed, in: container)

        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)
        try addArticle("new-1", to: feed, in: container)
        try addArticle("new-2", to: feed, in: container)
        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 7, 6, 0), isManual: false)

        let editions = try container.mainContext
            .fetch(FetchDescriptor<Edition>(sortBy: [SortDescriptor(\.number)]))
        XCTAssertEqual(editions.map(\.number), [1, 2])
        XCTAssertEqual(Set(editions[0].articles.map(\.stableID)), ["old-1"])
        XCTAssertEqual(Set(editions[1].articles.map(\.stableID)), ["new-1", "new-2"])
    }

    @MainActor
    func testSavedLinkArticlesAreNeverAssignedToEditions() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let rss = try makeFeed("a.example", in: container)
        let saved = try makeFeed("saved", kind: .savedLinks, in: container)
        try addArticle("a-1", to: rss, in: container)
        try addArticle("s-1", to: saved, in: container)

        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)

        let edition = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Edition>()).first)
        XCTAssertEqual(edition.articles.map(\.stableID), ["a-1"])
        let savedArticle = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Article>())
                .first { $0.stableID == "s-1" })
        XCTAssertNil(savedArticle.edition)
    }

    @MainActor
    func testPublishWithNothingPendingCreatesEmptyEdition() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)

        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)
        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 7, 6, 0), isManual: false)

        let editions = try container.mainContext
            .fetch(FetchDescriptor<Edition>(sortBy: [SortDescriptor(\.number)]))
        XCTAssertEqual(editions.map(\.number), [1, 2])
        XCTAssertTrue(editions.allSatisfy(\.articles.isEmpty))
    }

    @MainActor
    func testNumbersAreSequentialAcrossManualAndScheduledEditions() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let manualAt = utcDate(2026, 7, 6, 22, 15)

        await engine.publishEdition(
            scheduledFor: manualAt, isManual: true, publishedAt: manualAt)
        await engine.publishEdition(
            scheduledFor: utcDate(2026, 7, 7, 6, 0), isManual: false,
            publishedAt: utcDate(2026, 7, 7, 6, 0, 30))
        await engine.publishEdition(
            scheduledFor: utcDate(2026, 7, 7, 9, 0), isManual: true,
            publishedAt: utcDate(2026, 7, 7, 9, 0))

        let editions = try container.mainContext
            .fetch(FetchDescriptor<Edition>(sortBy: [SortDescriptor(\.number)]))
        XCTAssertEqual(editions.map(\.number), [1, 2, 3])
        XCTAssertEqual(editions.map(\.isManual), [true, false, true])
        // Stored fields round-trip; manual editions carry
        // scheduledFor == publishedAt by caller convention.
        XCTAssertEqual(editions[0].scheduledFor, manualAt)
        XCTAssertEqual(editions[0].publishedAt, manualAt)
        XCTAssertEqual(editions[1].scheduledFor, utcDate(2026, 7, 7, 6, 0))
    }

    // MARK: - Due check

    @MainActor
    func testPublishDueNoOpsForManualCadence() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)

        let next = await engine.publishDueEditionIfNeeded(
            cadence: .default, now: utcDate(2026, 7, 6, 9, 0), calendar: utcCalendar())

        XCTAssertNil(next)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Edition>()).count, 0)
    }

    @MainActor
    func testPublishDueNoOpsBeforeBoundaryAndReturnsNextWakeUp() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)

        let next = await engine.publishDueEditionIfNeeded(
            cadence: daily(), now: utcDate(2026, 7, 6, 9, 0), calendar: utcCalendar())

        XCTAssertEqual(next, utcDate(2026, 7, 7, 6, 0))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Edition>()).count, 1)
    }

    @MainActor
    func testMultiBoundaryGapPublishesExactlyOneCatchUpAtLatestBoundary() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 1, 6, 0), isManual: false)

        let next = await engine.publishDueEditionIfNeeded(
            cadence: daily(), now: utcDate(2026, 7, 6, 9, 0), calendar: utcCalendar())

        XCTAssertEqual(next, utcDate(2026, 7, 7, 6, 0))
        let editions = try container.mainContext
            .fetch(FetchDescriptor<Edition>(sortBy: [SortDescriptor(\.number)]))
        XCTAssertEqual(editions.count, 2)
        XCTAssertEqual(editions.last?.scheduledFor, utcDate(2026, 7, 6, 6, 0))
        XCTAssertEqual(editions.last?.isManual, false)
    }

    @MainActor
    func testPublishDueWithNoEditionsPublishesInauguralImmediately() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let feed = try makeFeed("a.example", in: container)
        try addArticle("a-1", to: feed, in: container)

        let next = await engine.publishDueEditionIfNeeded(
            cadence: daily(), now: utcDate(2026, 7, 6, 9, 0), calendar: utcCalendar())

        XCTAssertEqual(next, utcDate(2026, 7, 7, 6, 0))
        let edition = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Edition>()).first)
        XCTAssertEqual(edition.scheduledFor, utcDate(2026, 7, 6, 6, 0))
        XCTAssertEqual(edition.articles.map(\.stableID), ["a-1"])
    }

    @MainActor
    func testArticlesInsertedAfterPublishStayUnassigned() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let feed = try makeFeed("a.example", in: container)
        try addArticle("old-1", to: feed, in: container)
        await engine.publishEdition(scheduledFor: utcDate(2026, 7, 6, 6, 0), isManual: false)

        try addArticle("late-1", to: feed, in: container)

        let late = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Article>())
                .first { $0.stableID == "late-1" })
        XCTAssertNil(late.edition)
    }

    @MainActor
    func testDuePublishAfterIngestIncludesFreshArticles() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let feedID = try makeFeed("a.example", in: container).persistentModelID
        let parsed = try FeedParser.parse(
            data: Data(Fixtures.rss2Basic.utf8),
            sourceURL: URL(string: "https://a.example/feed.xml")!
        )

        // The scheduler's contract: refresh first, then the due check —
        // freshly ingested articles must make the catch-up edition.
        try await engine.ingest(parsed, intoFeedWithID: feedID)
        await engine.publishDueEditionIfNeeded(
            cadence: daily(), now: utcDate(2026, 7, 6, 9, 0), calendar: utcCalendar())

        let edition = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<Edition>()).first)
        XCTAssertEqual(edition.articles.count, parsed.items.count)
    }

    @MainActor
    func testEveryTwoDaysDueShiftsAfterManualPublish() async throws {
        let container = try makeContainer()
        let engine = RefreshEngine(modelContainer: container)
        let manualAt = utcDate(2026, 7, 6, 22, 0)
        await engine.publishEdition(scheduledFor: manualAt, isManual: true, publishedAt: manualAt)

        // The day after a manual edition nothing is due…
        let nextAfterQuietDay = await engine.publishDueEditionIfNeeded(
            cadence: every2Days(), now: utcDate(2026, 7, 7, 7, 0), calendar: utcCalendar())
        XCTAssertEqual(nextAfterQuietDay, utcDate(2026, 7, 8, 6, 0))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Edition>()).count, 1)

        // …and two days after it, the re-anchored boundary fires.
        await engine.publishDueEditionIfNeeded(
            cadence: every2Days(), now: utcDate(2026, 7, 8, 7, 0), calendar: utcCalendar())

        let editions = try container.mainContext
            .fetch(FetchDescriptor<Edition>(sortBy: [SortDescriptor(\.number)]))
        XCTAssertEqual(editions.count, 2)
        XCTAssertEqual(editions.last?.scheduledFor, utcDate(2026, 7, 8, 6, 0))
    }

    // MARK: - Helpers (model access stays on the main actor)

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self, Edition.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    @discardableResult
    private func makeFeed(
        _ host: String,
        kind: SourceKind = .rss,
        in container: ModelContainer
    ) throws -> Feed {
        let url = kind == .savedLinks
            ? Feed.savedLinksFeedURL
            : URL(string: "https://\(host)/feed.xml")!
        let feed = Feed(feedURL: url, title: host, sourceKind: kind)
        container.mainContext.insert(feed)
        try container.mainContext.save()
        return feed
    }

    @MainActor
    @discardableResult
    private func addArticle(
        _ stableID: String,
        to feed: Feed,
        in container: ModelContainer,
        isRead: Bool = false,
        isStarred: Bool = false
    ) throws -> Article {
        let article = Article(
            stableID: stableID,
            title: stableID,
            isRead: isRead,
            isStarred: isStarred
        )
        container.mainContext.insert(article)
        article.feed = feed
        try container.mainContext.save()
        return article
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

    private func daily(_ minutesOfDay: Int = 360) -> EditionCadence {
        EditionCadence(frequency: .daily, minutesOfDay: minutesOfDay, weekday: 2)
    }

    private func every2Days(_ minutesOfDay: Int = 360) -> EditionCadence {
        EditionCadence(frequency: .every2Days, minutesOfDay: minutesOfDay, weekday: 2)
    }
}
