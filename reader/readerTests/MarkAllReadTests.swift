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
            for: Feed.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func makeFeed(_ host: String, in container: ModelContainer) -> Feed {
        let feed = Feed(feedURL: URL(string: "https://\(host)/feed.xml")!, title: host)
        container.mainContext.insert(feed)
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
}
