//
//  readerTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

final class ModelSchemaTests: XCTestCase {

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    func testInsertFeedAndArticleRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let feed = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Example")
        context.insert(feed)
        let article = Article(stableID: "id-1", title: "Hello, world")
        article.feed = feed
        try context.save()

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.articles.count, 1)
        XCTAssertEqual(feeds.first?.articles.first?.title, "Hello, world")
        XCTAssertEqual(feeds.first?.unreadCount, 1)
    }

    @MainActor
    func testFeedDeleteCascadesToArticles() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let feed = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Example")
        context.insert(feed)
        for i in 0..<3 {
            let article = Article(stableID: "id-\(i)", title: "Article \(i)")
            article.feed = feed
        }
        try context.save()

        context.delete(feed)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Feed>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Article>()).count, 0)
    }

    @MainActor
    func testArticleSortDateFallsBackToFirstSeen() throws {
        let firstSeen = Date(timeIntervalSince1970: 1_000_000)
        let undated = Article(stableID: "a", title: "Undated", firstSeenAt: firstSeen)
        XCTAssertEqual(undated.sortDate, firstSeen)

        let published = Date(timeIntervalSince1970: 2_000_000)
        let dated = Article(stableID: "b", title: "Dated", publishedAt: published, firstSeenAt: firstSeen)
        XCTAssertEqual(dated.sortDate, published)
    }
}
