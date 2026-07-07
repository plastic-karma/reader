//
//  NewsletterSyncTests.swift
//  readerTests
//

import XCTest
import SwiftData
@testable import reader

final class NewsletterSyncTests: XCTestCase {

    // MARK: - Doubles

    private actor SyncRecorder {
        private(set) var queries: [MailQuery] = []
        private(set) var bodyFetches: [String] = []
        private(set) var archivedBatches: [[String]] = []

        func record(query: MailQuery) {
            queries.append(query)
        }

        func record(fetchedBody id: String) {
            bodyFetches.append(id)
        }

        func record(archived ids: [String]) {
            archivedBatches.append(ids)
        }
    }

    private struct StubMailClient: MailProviderClient {
        let recorder: SyncRecorder
        var headers: [MailMessageHeader] = []
        var messages: [String: MailMessage] = [:]
        var headersError: MailProviderError?
        var messageError: MailProviderError?
        var archiveError: MailProviderError?
        var headersDelayMilliseconds = 0

        func messageHeaders(matching query: MailQuery) async throws -> [MailMessageHeader] {
            await recorder.record(query: query)
            if headersDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(headersDelayMilliseconds))
            }
            if let headersError {
                throw headersError
            }
            return headers
        }

        func message(id: String) async throws -> MailMessage {
            await recorder.record(fetchedBody: id)
            if let messageError {
                throw messageError
            }
            guard let message = messages[id] else {
                throw MailProviderError.invalidResponse("no stub body for \(id)")
            }
            return message
        }

        func markProcessed(ids: [String]) async throws {
            await recorder.record(archived: ids)
            if let archiveError {
                throw archiveError
            }
        }
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
    private func insertNewsletterFeed(
        into container: ModelContainer,
        sender: String? = "news@example.com",
        pattern: String? = nil,
        archive: Bool = true
    ) throws -> PersistentIdentifier {
        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: "Test Rule",
            sourceKind: .newsletter
        )
        feed.newsletterSender = sender
        feed.newsletterSubjectPattern = pattern
        feed.newsletterArchiveAfterIngest = archive
        container.mainContext.insert(feed)
        try container.mainContext.save()
        return feed.persistentModelID
    }

    @MainActor
    private func articleStableIDs(in container: ModelContainer) throws -> Set<String> {
        Set(try container.mainContext.fetch(FetchDescriptor<Article>()).map(\.stableID))
    }

    @MainActor
    private func withNewsletterFeed(
        in container: ModelContainer,
        _ body: (Feed) throws -> Void
    ) throws {
        let feed = try XCTUnwrap(
            try container.mainContext.fetch(FetchDescriptor<Feed>())
                .first { $0.isNewsletterFeed }
        )
        try body(feed)
    }

    @MainActor
    private func withArticle(
        stableID: String,
        in container: ModelContainer,
        _ body: (Article) throws -> Void
    ) throws {
        let article = try XCTUnwrap(
            try container.mainContext.fetch(FetchDescriptor<Article>())
                .first { $0.stableID == stableID }
        )
        try body(article)
    }

    private func header(
        _ id: String,
        subject: String,
        unprocessed: Bool = true,
        daysAgo: Double = 1
    ) -> MailMessageHeader {
        MailMessageHeader(
            id: id,
            subject: subject,
            from: "Sender Name <news@example.com>",
            date: Date.now.addingTimeInterval(-daysAgo * 86400),
            isUnprocessed: unprocessed
        )
    }

    private func message(_ id: String, subject: String, html: String) -> MailMessage {
        MailMessage(
            header: header(id, subject: subject),
            bodyHTML: html,
            bodyText: nil
        )
    }

    // MARK: - Ingest

    func testFirstSyncIngestsMatchedSanitizesAndArchives() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container, pattern: "money")
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let syncStart = Date.now
        let client = StubMailClient(
            recorder: recorder,
            headers: [
                header("m1", subject: "Money Stuff #1", unprocessed: true, daysAgo: 2),
                header("m2", subject: "Receipt #9", unprocessed: true, daysAgo: 1.5),
                header("m3", subject: "money weekly", unprocessed: false, daysAgo: 1),
            ],
            messages: [
                "m1": message(
                    "m1", subject: "Money Stuff #1",
                    html: #"<p>Markets!</p><script>alert(1)</script><img src="https://t.example/o.gif" width="1" height="1">"#),
                "m3": message("m3", subject: "money weekly", html: "<p>Weekly wrap.</p>"),
            ])

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let ids = try await articleStableIDs(in: container)
        XCTAssertEqual(ids, ["m1", "m3"], "Only regex matches ingest")
        try await withArticle(stableID: "m1", in: container) { article in
            XCTAssertEqual(article.title, "Money Stuff #1")
            XCTAssertEqual(article.author, "Sender Name")
            XCTAssertNotNil(article.publishedAt)
            XCTAssertFalse(article.contentHTML.contains("<script"), "Engine sanitize pipeline runs")
            XCTAssertFalse(article.contentHTML.contains("t.example"), "Tracking pixel stripped pre-cache")
            XCTAssertEqual(article.summary, "Markets!")
        }

        let fetches = await recorder.bodyFetches
        XCTAssertEqual(fetches, ["m1", "m3"], "Bodies fetched oldest-first, unmatched skipped")
        let archived = await recorder.archivedBatches
        XCTAssertEqual(archived, [["m1"]], "Only matched + still-inboxed ids archive")

        try await withNewsletterFeed(in: container) { feed in
            XCTAssertNil(feed.lastError)
            XCTAssertNotNil(feed.lastFetchedAt)
            let watermark = try XCTUnwrap(feed.newsletterLastSyncedAt)
            XCTAssertGreaterThanOrEqual(watermark, syncStart.addingTimeInterval(-5))
        }
    }

    func testResyncCreatesNoDuplicatesAndNoRearchiveOfProcessed() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        var client = StubMailClient(
            recorder: recorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)],
            messages: ["m1": message("m1", subject: "Issue 1", html: "<p>One</p>")])

        await engine.refreshNewsletter(feedID: feedID, using: client)
        // Second sync: Gmail now reports the message archived.
        client.headers = [header("m1", subject: "Issue 1", unprocessed: false)]
        await engine.refreshNewsletter(feedID: feedID, using: client)

        let ids = try await articleStableIDs(in: container)
        XCTAssertEqual(ids, ["m1"], "stableID dedupe holds across syncs")
        let fetches = await recorder.bodyFetches
        XCTAssertEqual(fetches, ["m1"], "Known ids are never re-fetched")
        let archived = await recorder.archivedBatches
        XCTAssertEqual(archived, [["m1"]], "Processed messages are not re-archived")
    }

    // MARK: - Archive semantics

    func testFailedArchiveKeepsArticlesHoldsWatermarkThenSelfHeals() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)

        let failingRecorder = SyncRecorder()
        let failing = StubMailClient(
            recorder: failingRecorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)],
            messages: ["m1": message("m1", subject: "Issue 1", html: "<p>One</p>")],
            archiveError: .http(500))
        await engine.refreshNewsletter(feedID: feedID, using: failing)

        let idsAfterFailure = try await articleStableIDs(in: container)
        XCTAssertEqual(idsAfterFailure, ["m1"], "Ingest is durable before archiving")
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertEqual(feed.lastError, "Gmail: HTTP 500")
            XCTAssertNil(feed.newsletterLastSyncedAt, "Watermark must not advance past a failed archive")
        }

        // Next sync: same message, still in the inbox — the archive set
        // self-heals even though the article already exists.
        let healingRecorder = SyncRecorder()
        let healing = StubMailClient(
            recorder: healingRecorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)])
        await engine.refreshNewsletter(feedID: feedID, using: healing)

        let archived = await healingRecorder.archivedBatches
        XCTAssertEqual(archived, [["m1"]], "Known-but-inboxed ids re-enter the archive set")
        let fetches = await healingRecorder.bodyFetches
        XCTAssertTrue(fetches.isEmpty, "No body re-fetch for known ids")
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertNil(feed.lastError)
            XCTAssertNotNil(feed.newsletterLastSyncedAt, "Watermark advances once archiving succeeds")
        }
    }

    func testArchiveToggleOffMakesNoMailboxCalls() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container, archive: false)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(
            recorder: recorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)],
            messages: ["m1": message("m1", subject: "Issue 1", html: "<p>One</p>")])

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let archived = await recorder.archivedBatches
        XCTAssertTrue(archived.isEmpty)
        let ids = try await articleStableIDs(in: container)
        XCTAssertEqual(ids, ["m1"])
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertNotNil(feed.newsletterLastSyncedAt, "No archive step needed → sync is complete")
        }
    }

    // MARK: - Failure paths

    func testHeadersFailureRecordsErrorAndInsertsNothing() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let client = StubMailClient(recorder: SyncRecorder(), headersError: .notSignedIn)

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let ids = try await articleStableIDs(in: container)
        XCTAssertTrue(ids.isEmpty)
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertEqual(feed.lastError, "Gmail: sign in required (Settings → Newsletters)")
            XCTAssertNotNil(feed.lastFetchedAt)
            XCTAssertNil(feed.newsletterLastSyncedAt)
        }
    }

    func testBodyFetchFailureFailsSyncBeforeAnyArchiving() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(
            recorder: recorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)],
            messageError: .rateLimited)

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let ids = try await articleStableIDs(in: container)
        XCTAssertTrue(ids.isEmpty)
        let archived = await recorder.archivedBatches
        XCTAssertTrue(archived.isEmpty, "Nothing may be archived when ingest failed")
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertEqual(feed.lastError, "Gmail: rate limited — will retry next refresh")
            XCTAssertNil(feed.newsletterLastSyncedAt)
        }
    }

    func testInvalidPatternFailsBeforeAnyProviderCall() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container, pattern: "[unclosed")
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(recorder: recorder)

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let queries = await recorder.queries
        XCTAssertTrue(queries.isEmpty, "A bad pattern must fail before any network call")
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertTrue(feed.lastError?.hasPrefix("Invalid subject pattern") == true)
        }
    }

    func testMissingSenderFailsBeforeAnyProviderCall() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container, sender: nil)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(recorder: recorder)

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let queries = await recorder.queries
        XCTAssertTrue(queries.isEmpty)
        try await withNewsletterFeed(in: container) { feed in
            XCTAssertTrue(feed.lastError?.contains("incomplete") == true)
        }
    }

    // MARK: - Query windows + rule breadth

    func testBackfillAndOverlapWindows() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(recorder: recorder)

        // First sync: no watermark → 30-day backfill.
        await engine.refreshNewsletter(feedID: feedID, using: client)
        let firstQueries = await recorder.queries
        let backfillSince = try XCTUnwrap(firstQueries.first?.since)
        XCTAssertEqual(
            backfillSince.timeIntervalSinceNow, -30 * 86400,
            accuracy: 120, "nil watermark → 30-day backfill")

        // Second sync: watermark set → the query re-lists 24 h behind it.
        let watermark = Date(timeIntervalSince1970: 1_751_000_000)
        try await withNewsletterFeed(in: container) { feed in
            feed.newsletterLastSyncedAt = watermark
        }
        try await MainActor.run {
            try container.mainContext.save()
        }
        await engine.refreshNewsletter(feedID: feedID, using: client)
        let allQueries = await recorder.queries
        XCTAssertEqual(allQueries.count, 2)
        XCTAssertEqual(
            allQueries[1].since.timeIntervalSince1970,
            watermark.timeIntervalSince1970 - 24 * 3600,
            accuracy: 1, "Watermark re-lists one day behind itself")
        XCTAssertEqual(allQueries[1].sender, "news@example.com")
    }

    func testNilPatternMatchesEverything() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container, pattern: nil)
        let engine = RefreshEngine(modelContainer: container)
        let client = StubMailClient(
            recorder: SyncRecorder(),
            headers: [
                header("a", subject: "Anything", unprocessed: false, daysAgo: 2),
                header("b", subject: "Else entirely", unprocessed: false, daysAgo: 1),
            ],
            messages: [
                "a": message("a", subject: "Anything", html: "<p>A</p>"),
                "b": message("b", subject: "Else entirely", html: "<p>B</p>"),
            ])

        await engine.refreshNewsletter(feedID: feedID, using: client)

        let ids = try await articleStableIDs(in: container)
        XCTAssertEqual(ids, ["a", "b"])
    }

    // MARK: - Deletion + dispatch

    func testFeedDeletedMidSyncNeverTouchesMailboxOrStore() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)
        let recorder = SyncRecorder()
        let client = StubMailClient(
            recorder: recorder,
            headers: [header("m1", subject: "Issue 1", unprocessed: true)],
            messages: ["m1": message("m1", subject: "Issue 1", html: "<p>One</p>")],
            headersDelayMilliseconds: 300)

        let sync = Task {
            await engine.refreshNewsletter(feedID: feedID, using: client)
        }
        // Let the sync snapshot the feed and suspend inside the provider
        // call, then delete the rule out from under it.
        try await Task.sleep(for: .milliseconds(50))
        try await MainActor.run {
            let feeds = try container.mainContext.fetch(FetchDescriptor<Feed>())
            for feed in feeds {
                container.mainContext.delete(feed)
            }
            try container.mainContext.save()
        }
        await sync.value

        let ids = try await articleStableIDs(in: container)
        XCTAssertTrue(ids.isEmpty, "No insert into a deleted feed")
        let archived = await recorder.archivedBatches
        XCTAssertTrue(archived.isEmpty, "Never mutate the mailbox for a deleted rule")
    }

    func testRefreshDispatchRoutesNewsletterAwayFromHTTPFetch() async throws {
        let container = try await makeContainer()
        let feedID = try await insertNewsletterFeed(into: container)
        let engine = RefreshEngine(modelContainer: container)

        // Through the public refresh path the engine uses its live Gmail
        // client. On CI's unsigned test host that fails fast (no usable
        // credentials); on a developer Mac that shares the real app's
        // Keychain the sync can even succeed. Either way it must NOT fall
        // through to FeedFetcher, whose sentinel-URL failure reads
        // "unsupported URL".
        await engine.refresh(feedID: feedID)

        try await withNewsletterFeed(in: container) { feed in
            XCTAssertNotNil(
                feed.lastFetchedAt,
                "The newsletter path ran to completion and kept its bookkeeping")
            if let error = feed.lastError {
                XCTAssertFalse(
                    error.localizedCaseInsensitiveContains("unsupported url"),
                    "Sentinel URL must never reach the HTTP fetcher")
            }
        }
    }

    func testRefreshAllIncludesNewslettersAndSkipsSavedLinks() async throws {
        let container = try await makeContainer()
        _ = try await insertNewsletterFeed(into: container)
        try await MainActor.run {
            let saved = Feed(
                feedURL: Feed.savedLinksFeedURL,
                title: "Saved Links",
                sourceKind: .savedLinks)
            container.mainContext.insert(saved)
            try container.mainContext.save()
        }
        let engine = RefreshEngine(modelContainer: container)

        await engine.refreshAll()

        try await MainActor.run {
            let feeds = try container.mainContext.fetch(FetchDescriptor<Feed>())
            let newsletter = try XCTUnwrap(feeds.first { $0.isNewsletterFeed })
            let saved = try XCTUnwrap(feeds.first { $0.isSavedLinksFeed })
            XCTAssertNotNil(newsletter.lastFetchedAt, "refreshAll must include newsletter feeds")
            XCTAssertNil(saved.lastFetchedAt, "refreshAll must keep skipping the saved-links feed")
        }
    }
}
