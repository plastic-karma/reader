//
//  UpsertTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

final class UpsertTests: XCTestCase {

    private let feedURL = URL(string: "https://example.com/feed.xml")!

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func insertFeed(into container: ModelContainer) throws -> PersistentIdentifier {
        let feed = Feed(feedURL: feedURL, title: "Example")
        container.mainContext.insert(feed)
        try container.mainContext.save()
        return feed.persistentModelID
    }

    private func parsedFixture() throws -> ParsedFeed {
        try FeedParser.parse(data: Data(Fixtures.rss2Basic.utf8), sourceURL: feedURL)
    }

    func testDoubleIngestCreatesNoDuplicates() async throws {
        let container = try await makeContainer()
        let feedID = try await insertFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let parsed = try parsedFixture()

        try await engine.ingest(parsed, intoFeedWithID: feedID)
        try await engine.ingest(parsed, intoFeedWithID: feedID)

        let count = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<Article>()).count
        }
        XCTAssertEqual(count, parsed.items.count)
    }

    func testReingestPreservesReadAndStarred() async throws {
        let container = try await makeContainer()
        let feedID = try await insertFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let parsed = try parsedFixture()

        try await engine.ingest(parsed, intoFeedWithID: feedID)
        let firstSeen = try await MainActor.run {
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            let first = try XCTUnwrap(articles.first)
            first.isRead = true
            first.isStarred = true
            try container.mainContext.save()
            return first.firstSeenAt
        }

        try await engine.ingest(parsed, intoFeedWithID: feedID)

        try await MainActor.run {
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            XCTAssertEqual(articles.count, parsed.items.count)
            let flagged = articles.filter { $0.isRead && $0.isStarred }
            XCTAssertEqual(flagged.count, 1)
            XCTAssertEqual(flagged.first?.firstSeenAt, firstSeen)
        }
    }

    func testIngestSanitizesContentAndDerivesExcerpt() async throws {
        let container = try await makeContainer()
        let feedID = try await insertFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)

        let dirty = ParsedFeed(
            title: "Dirty",
            homepageURL: nil,
            items: [
                ParsedItem(
                    stableID: "dirty-1",
                    title: "Scripted",
                    author: nil,
                    link: nil,
                    publishedAt: nil,
                    summaryHTML: "<p>Short <b>summary</b> text.</p>",
                    contentHTML: "<p>Before</p><script>alert(1)</script><p>After</p>"
                )
            ]
        )
        try await engine.ingest(dirty, intoFeedWithID: feedID)

        try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            XCTAssertFalse(article.contentHTML.contains("<script"))
            XCTAssertTrue(article.contentHTML.contains("<p>Before</p>"))
            XCTAssertEqual(article.summary, "Short summary text.")
        }
    }

    func testIngestSetsHomepageURLOnlyWhenMissing() async throws {
        let container = try await makeContainer()
        let feedID = try await insertFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let parsed = try parsedFixture()

        try await engine.ingest(parsed, intoFeedWithID: feedID)

        try await MainActor.run {
            let feed = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            )
            XCTAssertEqual(feed.homepageURL, URL(string: "https://example.com/"))
        }

        // A later refresh reporting a different homepage must not overwrite it.
        let other = ParsedFeed(
            title: "Example",
            homepageURL: URL(string: "https://other.example.org/"),
            items: []
        )
        try await engine.ingest(other, intoFeedWithID: feedID)

        try await MainActor.run {
            let feed = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            )
            XCTAssertEqual(feed.homepageURL, URL(string: "https://example.com/"))
        }
    }
}
