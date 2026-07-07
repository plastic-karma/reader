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
            for: Feed.self, Article.self, Edition.self,
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
    func testEditionRoundTripWithArticles() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let feed = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Example")
        context.insert(feed)
        let edition = Edition(number: 1, publishedAt: .now, scheduledFor: .now, isManual: false)
        context.insert(edition)
        for i in 0..<2 {
            let article = Article(stableID: "id-\(i)", title: "Article \(i)")
            context.insert(article)
            article.feed = feed
            article.edition = edition
        }
        try context.save()

        let editions = try context.fetch(FetchDescriptor<Edition>())
        XCTAssertEqual(editions.count, 1)
        XCTAssertEqual(editions.first?.articles.count, 2)
        let articles = try context.fetch(FetchDescriptor<Article>())
        XCTAssertTrue(articles.allSatisfy { $0.edition?.number == 1 })
    }

    @MainActor
    func testEditionDeleteNullifiesArticlesBackToPending() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let feed = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Example")
        context.insert(feed)
        let edition = Edition(number: 1, publishedAt: .now, scheduledFor: .now, isManual: false)
        context.insert(edition)
        let article = Article(stableID: "id-1", title: "Hello")
        context.insert(article)
        article.feed = feed
        article.edition = edition
        try context.save()

        context.delete(edition)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Edition>()).count, 0)
        let survivors = try context.fetch(FetchDescriptor<Article>())
        XCTAssertEqual(survivors.count, 1)
        XCTAssertNil(survivors.first?.edition)
    }

    @MainActor
    func testFeedDeleteCascadeShrinksEdition() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let doomed = Feed(feedURL: URL(string: "https://doomed.example/feed.xml")!, title: "Doomed")
        let survivor = Feed(feedURL: URL(string: "https://kept.example/feed.xml")!, title: "Kept")
        context.insert(doomed)
        context.insert(survivor)
        let edition = Edition(number: 1, publishedAt: .now, scheduledFor: .now, isManual: false)
        context.insert(edition)
        for (i, feed) in [doomed, doomed, survivor].enumerated() {
            let article = Article(stableID: "id-\(i)", title: "Article \(i)")
            context.insert(article)
            article.feed = feed
            article.edition = edition
        }
        try context.save()

        context.delete(doomed)
        try context.save()

        let editions = try context.fetch(FetchDescriptor<Edition>())
        XCTAssertEqual(editions.count, 1)
        XCTAssertEqual(editions.first?.articles.count, 1)
        XCTAssertEqual(editions.first?.articles.first?.stableID, "id-2")
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
