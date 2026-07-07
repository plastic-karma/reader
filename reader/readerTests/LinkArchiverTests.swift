//
//  LinkArchiverTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

final class LinkArchiverTests: XCTestCase {

    private let pageURL = URL(string: "https://example.com/posts/actors")!

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self, Edition.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func page(_ html: String, finalURL: URL? = nil) -> PageFetcher.FetchedPage {
        PageFetcher.FetchedPage(html: html, finalURL: finalURL ?? pageURL)
    }

    // MARK: - Hidden feed

    func testFirstSaveLazilyCreatesHiddenFeedExactlyOnce() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)
        await archiver.ingest(
            .success(page(PageFixtures.savedPageV2)),
            savedAs: URL(string: "https://example.com/other")!
        )

        try await MainActor.run {
            let feeds = try container.mainContext.fetch(FetchDescriptor<Feed>())
            XCTAssertEqual(feeds.count, 1)
            let feed = try XCTUnwrap(feeds.first)
            XCTAssertEqual(feed.feedURL, Feed.savedLinksFeedURL)
            XCTAssertEqual(feed.sourceKind, SourceKind.savedLinks.rawValue)
            XCTAssertEqual(feed.title, "Saved Links")
            XCTAssertEqual(feed.articles.count, 2)
        }
    }

    // MARK: - Snapshot processing

    func testSaveProducesProcessedSnapshotArticle() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        // The script contains a literal "</article>" — passing this test
        // locks in the sanitize-before-extract ordering.
        await archiver.ingest(.success(page(PageFixtures.scriptedArticlePage)), savedAs: pageURL)

        try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            XCTAssertEqual(article.title, "Scripted Page")
            XCTAssertTrue(article.contentHTML.contains("MARKER-AFTER-SCRIPT"))
            XCTAssertFalse(article.contentHTML.contains("<script"))
            XCTAssertFalse(article.contentHTML.contains("fake"))
            XCTAssertEqual(article.link, self.pageURL)
            XCTAssertEqual(article.stableID, LinkArchiver.canonicalStableID(for: self.pageURL))
            let summary = try XCTUnwrap(article.summary)
            XCTAssertTrue(summary.hasPrefix("The quick brown fox"))
            XCTAssertLessThanOrEqual(summary.count, 300)
            XCTAssertFalse(article.isRead)
            XCTAssertNil(article.downloadError)
            XCTAssertNotNil(article.downloadedAt)
            XCTAssertNil(article.publishedAt)
        }
    }

    // MARK: - Re-save semantics

    func testResaveUpdatesSnapshotWithoutDuplicating() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)
        await archiver.ingest(.success(page(PageFixtures.savedPageV2)), savedAs: pageURL)

        try await MainActor.run {
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            XCTAssertEqual(articles.count, 1)
            let article = try XCTUnwrap(articles.first)
            XCTAssertEqual(article.title, "Version Two")
            XCTAssertTrue(article.contentHTML.contains("V2-MARKER"))
            XCTAssertFalse(article.contentHTML.contains("V1-MARKER"))
        }
    }

    func testResavePreservesStarAndFirstSeenAt() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)
        let firstSeen = try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            article.isStarred = true
            try container.mainContext.save()
            return article.firstSeenAt
        }

        await archiver.ingest(.success(page(PageFixtures.savedPageV2)), savedAs: pageURL)

        try await MainActor.run {
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            XCTAssertEqual(articles.count, 1)
            let article = try XCTUnwrap(articles.first)
            XCTAssertTrue(article.isStarred)
            XCTAssertEqual(article.firstSeenAt, firstSeen)
            XCTAssertEqual(article.title, "Version Two")
        }
    }

    // MARK: - Canonical stableID

    func testFragmentOnlyVariantsMapToSameArticle() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(
            .success(page(PageFixtures.savedPageV1)),
            savedAs: URL(string: "https://example.com/doc#intro")!
        )
        await archiver.ingest(
            .success(page(PageFixtures.savedPageV2)),
            savedAs: URL(string: "https://example.com/doc#details")!
        )

        let count = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<Article>()).count
        }
        XCTAssertEqual(count, 1)
    }

    func testQueryVariantsMapToDistinctArticles() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(
            .success(page(PageFixtures.savedPageV1)),
            savedAs: URL(string: "https://example.com/story?page=1")!
        )
        await archiver.ingest(
            .success(page(PageFixtures.savedPageV2)),
            savedAs: URL(string: "https://example.com/story?page=2")!
        )

        let count = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<Article>()).count
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - Failure handling

    func testFailureSetsDownloadErrorAndErrorNoteContent() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.failure(URLError(.timedOut)), savedAs: pageURL)

        try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            XCTAssertNotNil(article.downloadError)
            XCTAssertNil(article.downloadedAt)
            XCTAssertTrue(article.contentHTML.contains("Open the original"))
        }
    }

    func testFailedResaveKeepsLastGoodSnapshot() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)
        await archiver.ingest(
            .failure(PageFetcher.FetchError.badStatus(503)),
            savedAs: pageURL
        )

        try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            XCTAssertEqual(article.downloadError, "HTTP 503")
            XCTAssertTrue(article.contentHTML.contains("V1-MARKER"))
            XCTAssertNotNil(article.downloadedAt)
        }
    }

    func testSuccessfulRetryClearsDownloadError() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.ingest(.failure(URLError(.notConnectedToInternet)), savedAs: pageURL)
        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)

        try await MainActor.run {
            let article = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Article>()).first
            )
            XCTAssertNil(article.downloadError)
            XCTAssertNotNil(article.downloadedAt)
            XCTAssertTrue(article.contentHTML.contains("V1-MARKER"))
        }
    }

    // MARK: - Guards

    func testSaveIgnoresNonHTTPURL() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)

        await archiver.save(URL(string: "file:///etc/hosts")!)

        try await MainActor.run {
            XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Feed>()).count, 0)
            XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Article>()).count, 0)
        }
    }

    // MARK: - Refresh gating

    func testRefreshAllSkipsSavedLinksFeed() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)
        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)

        let engine = RefreshEngine(modelContainer: container)
        await engine.refreshAll()

        try await MainActor.run {
            let feed = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            )
            XCTAssertNil(feed.lastFetchedAt)
            XCTAssertNil(feed.lastError)
        }
    }

    func testRefreshFeedIgnoresSavedLinksFeed() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)
        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)

        let feedID = try await MainActor.run {
            try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            ).persistentModelID
        }
        let engine = RefreshEngine(modelContainer: container)
        await engine.refresh(feedID: feedID)

        try await MainActor.run {
            let feed = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            )
            XCTAssertNil(feed.lastFetchedAt)
            XCTAssertNil(feed.lastError)
        }
    }

    // MARK: - Mark all read exclusion

    func testMarkAllReadSkipsSavedLinkArticles() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)
        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)

        try await MainActor.run {
            let feed = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Example")
            container.mainContext.insert(feed)
            let article = Article(stableID: "post-1", title: "Feed Post")
            container.mainContext.insert(article)
            article.feed = feed
            try container.mainContext.save()

            Article.markAllRead(in: container.mainContext)

            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            let feedArticle = try XCTUnwrap(articles.first { $0.stableID == "post-1" })
            let savedArticle = try XCTUnwrap(articles.first { $0.stableID != "post-1" })
            XCTAssertTrue(feedArticle.isRead)
            XCTAssertFalse(savedArticle.isRead)
        }
    }

    // MARK: - Abandoned placeholders

    func testMarkAbandonedSavesFlagsInterruptedPlaceholders() async throws {
        let container = try await makeContainer()
        let archiver = LinkArchiver(modelContainer: container)
        // One completed snapshot…
        await archiver.ingest(.success(page(PageFixtures.savedPageV1)), savedAs: pageURL)
        // …and one hand-planted interrupted placeholder (as if the app quit
        // mid-download).
        try await MainActor.run {
            let feed = try XCTUnwrap(
                try container.mainContext.fetch(FetchDescriptor<Feed>()).first
            )
            let placeholder = Article(
                stableID: "https://example.com/interrupted",
                title: "example.com",
                link: URL(string: "https://example.com/interrupted")!,
                summary: "Downloading…"
            )
            container.mainContext.insert(placeholder)
            placeholder.feed = feed
            try container.mainContext.save()
        }

        await archiver.markAbandonedSaves()

        try await MainActor.run {
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            let interrupted = try XCTUnwrap(articles.first { $0.stableID.hasSuffix("interrupted") })
            let completed = try XCTUnwrap(articles.first { !$0.stableID.hasSuffix("interrupted") })
            XCTAssertNotNil(interrupted.downloadError)
            XCTAssertNil(completed.downloadError)
            XCTAssertNotNil(completed.downloadedAt)
        }
    }
}
