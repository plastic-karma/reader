//
//  MarkAllReadTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

/// Feed.markAllRead() (per-feed) and Article.markAllRead(in:) (global).
/// The global action's saved-links exclusion is covered in
/// LinkArchiverTests.testMarkAllReadSkipsSavedLinkArticles.
final class MarkAllReadTests: XCTestCase {

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self, Edition.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func makeFeed(
        _ host: String,
        kind: SourceKind = .rss,
        in container: ModelContainer
    ) -> Feed {
        let url = kind == .savedLinks
            ? Feed.savedLinksFeedURL
            : URL(string: "https://\(host)/feed.xml")!
        let feed = Feed(feedURL: url, title: host, sourceKind: kind)
        container.mainContext.insert(feed)
        return feed
    }

    @MainActor
    private func makeEdition(_ number: Int, in container: ModelContainer) -> Edition {
        let edition = Edition(number: number, publishedAt: .now, scheduledFor: .now, isManual: false)
        container.mainContext.insert(edition)
        return edition
    }

    @MainActor
    @discardableResult
    private func addArticle(
        _ stableID: String,
        to feed: Feed,
        in container: ModelContainer,
        isRead: Bool = false,
        isStarred: Bool = false
    ) -> Article {
        let article = Article(
            stableID: stableID,
            title: stableID,
            isRead: isRead,
            isStarred: isStarred
        )
        container.mainContext.insert(article)
        article.feed = feed
        return article
    }

    // MARK: - Per feed

    @MainActor
    func testFeedMarkAllReadMarksOnlyThatFeed() throws {
        let container = try makeContainer()
        let feedA = makeFeed("a.example", in: container)
        let feedB = makeFeed("b.example", in: container)
        addArticle("a-1", to: feedA, in: container)
        addArticle("a-2", to: feedA, in: container)
        let untouched = addArticle("b-1", to: feedB, in: container)

        feedA.markAllRead()

        XCTAssertEqual(feedA.unreadCount, 0)
        XCTAssertTrue(feedA.articles.allSatisfy(\.isRead))
        XCTAssertFalse(untouched.isRead)
        XCTAssertEqual(feedB.unreadCount, 1)
    }

    @MainActor
    func testFeedMarkAllReadPreservesStarsAndIsIdempotent() throws {
        let container = try makeContainer()
        let feed = makeFeed("a.example", in: container)
        let starred = addArticle("a-1", to: feed, in: container, isStarred: true)
        addArticle("a-2", to: feed, in: container, isRead: true)

        feed.markAllRead()
        feed.markAllRead()

        XCTAssertEqual(feed.unreadCount, 0)
        XCTAssertTrue(starred.isStarred)
    }

    // MARK: - Global

    @MainActor
    func testGlobalMarkAllReadSpansAllFeeds() throws {
        let container = try makeContainer()
        let feedA = makeFeed("a.example", in: container)
        let feedB = makeFeed("b.example", in: container)
        addArticle("a-1", to: feedA, in: container)
        addArticle("b-1", to: feedB, in: container)
        addArticle("b-2", to: feedB, in: container, isRead: true)

        Article.markAllRead(in: container.mainContext)

        let unread = try container.mainContext.fetch(
            FetchDescriptor<Article>(predicate: #Predicate { !$0.isRead })
        )
        XCTAssertTrue(unread.isEmpty)
        XCTAssertEqual(feedA.unreadCount, 0)
        XCTAssertEqual(feedB.unreadCount, 0)
    }

    // MARK: - Edition scoped

    @MainActor
    func testEditionScopedGlobalMarkAllReadMarksOnlyThatEdition() throws {
        let container = try makeContainer()
        let feed = makeFeed("a.example", in: container)
        let saved = makeFeed("saved", kind: .savedLinks, in: container)
        let editionA = makeEdition(1, in: container)
        let editionB = makeEdition(2, in: container)
        let inA = addArticle("a-1", to: feed, in: container)
        inA.edition = editionA
        let inB = addArticle("a-2", to: feed, in: container)
        inB.edition = editionB
        let pending = addArticle("a-3", to: feed, in: container)
        let savedArticle = addArticle("s-1", to: saved, in: container)

        Article.markAllRead(in: container.mainContext, within: editionA)

        XCTAssertTrue(inA.isRead)
        XCTAssertFalse(inB.isRead)
        XCTAssertFalse(pending.isRead)
        XCTAssertFalse(savedArticle.isRead)

        // The nil-scoped call still means "everything" — and still never
        // touches saved links.
        Article.markAllRead(in: container.mainContext)
        XCTAssertTrue(inB.isRead)
        XCTAssertTrue(pending.isRead)
        XCTAssertFalse(savedArticle.isRead)
    }

    @MainActor
    func testEditionScopedFeedMarkAllReadScopesToFeedAndEdition() throws {
        let container = try makeContainer()
        let feedA = makeFeed("a.example", in: container)
        let feedB = makeFeed("b.example", in: container)
        let edition = makeEdition(1, in: container)
        let inEdition = addArticle("a-1", to: feedA, in: container)
        inEdition.edition = edition
        let pending = addArticle("a-2", to: feedA, in: container)
        let otherFeed = addArticle("b-1", to: feedB, in: container)
        otherFeed.edition = edition

        feedA.markAllRead(within: edition)

        XCTAssertTrue(inEdition.isRead)
        XCTAssertFalse(pending.isRead)
        XCTAssertFalse(otherFeed.isRead)
        XCTAssertEqual(feedA.unreadCount(within: edition), 0)
        XCTAssertEqual(feedA.unreadCount, 1)
        XCTAssertEqual(feedB.unreadCount(within: edition), 1)
    }

    @MainActor
    func testNilEditionScopeMatchesUnscopedBehavior() throws {
        let container = try makeContainer()
        let feed = makeFeed("a.example", in: container)
        let edition = makeEdition(1, in: container)
        let inEdition = addArticle("a-1", to: feed, in: container)
        inEdition.edition = edition
        addArticle("a-2", to: feed, in: container)

        XCTAssertEqual(feed.unreadCount(within: nil), feed.unreadCount)

        feed.markAllRead(within: nil)

        XCTAssertEqual(feed.unreadCount, 0)
        XCTAssertTrue(feed.articles.allSatisfy(\.isRead))
    }
}
