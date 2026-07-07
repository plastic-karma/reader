//
//  RefreshEngine.swift
//  reader
//

import Foundation
import SwiftData

/// Owns all feed refreshing on its own SwiftData context, off the main actor.
/// Only `PersistentIdentifier`s and Sendable value types cross its boundary;
/// main-context `@Query` views pick up saves automatically (same container).
@ModelActor
actor RefreshEngine {

    private static let maxConcurrentFetches = 4

    // Newsletter sync tuning. The overlap re-lists a day behind the
    // watermark, absorbing clock skew and delayed delivery; dedupe by
    // stableID makes the re-list free.
    private static let newsletterBackfillDays = 30
    private static let newsletterWatermarkOverlap: TimeInterval = 24 * 3600
    private static let maxNewsletterMessagesPerSync = 200

    // Newsletters routinely carry dozens of images; cap the downloads and
    // fetch them in a sliding window (the LinkArchiver pattern) so one dead
    // host can't stack 30 s timeouts end to end.
    private static let maxImagesPerArticle = 50
    private static let maxConcurrentImageFetches = 6

    private let fetcher = FeedFetcher()
    private let imageCache = ImageCache()
    /// Production mail provider. Inline default because @ModelActor
    /// generates init(modelContainer:); construction is side-effect-free.
    /// Tests bypass it entirely via refreshNewsletter(feedID:using:).
    private let mailClient: any MailProviderClient = GmailMailClient.live()

    /// Article payload prepared entirely off the model graph — image
    /// downloads happen while building these, so no SwiftData model is ever
    /// held across a suspension point.
    private struct PreparedArticle {
        let stableID: String
        let title: String
        let author: String?
        let link: URL?
        let publishedAt: Date?
        let summary: String?
        let contentHTML: String
    }

    func refreshAll() async {
        // The hidden saved-links feed has a non-http sentinel URL; fetching
        // it would only stamp a permanent lastError. Snapshots never
        // auto-refresh.
        let ids = ((try? modelContext.fetch(FetchDescriptor<Feed>())) ?? [])
            .filter { !$0.isSavedLinksFeed }
            .map(\.persistentModelID)
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            var started = 0
            while started < Self.maxConcurrentFetches, let id = iterator.next() {
                group.addTask { await self.refresh(feedID: id) }
                started += 1
            }
            while await group.next() != nil {
                if let id = iterator.next() {
                    group.addTask { await self.refresh(feedID: id) }
                }
            }
        }
    }

    /// One feed: fetch → parse → prepare (images) → insert → bookkeeping.
    /// Errors land in `feed.lastError`; one bad feed never fails a batch.
    func refresh(feedID: PersistentIdentifier) async {
        // Snapshot everything the network phase needs, then let go of the
        // model: the user may delete the feed while we're suspended.
        guard let snapshot = feedModel(for: feedID) else { return }
        // Defense in depth for direct callers (refreshFeed after Add Feed).
        guard !snapshot.isSavedLinksFeed else { return }
        // First real source-kind dispatch: newsletter feeds have a sentinel
        // URL and sync through a mail provider, not HTTP+FeedParser.
        if snapshot.isNewsletterFeed {
            await refreshNewsletter(feedID: feedID, using: mailClient)
            return
        }
        let url = snapshot.feedURL
        let etag = snapshot.etag
        let lastModified = snapshot.lastModified
        let knownIDs = Set(snapshot.articles.map(\.stableID))

        enum Outcome {
            case notModified
            case prepared([PreparedArticle], homepageURL: URL?, etag: String?, lastModified: String?)
            case failed(String)
        }
        let outcome: Outcome
        do {
            switch try await fetcher.fetch(url: url, etag: etag, lastModified: lastModified) {
            case .notModified:
                outcome = .notModified
            case .fetched(let data, let newETag, let newLastModified):
                let parsed = try FeedParser.parse(data: data, sourceURL: url)
                let fresh = parsed.items.filter { !knownIDs.contains($0.stableID) }
                let articles = await prepare(fresh, feedURL: url)
                outcome = .prepared(
                    articles,
                    homepageURL: parsed.homepageURL,
                    etag: newETag,
                    lastModified: newLastModified
                )
            }
        } catch {
            outcome = .failed(shortDescription(of: error))
        }

        // Re-resolve after the suspensions; bail out if the feed was deleted.
        guard let feed = feedModel(for: feedID) else { return }
        switch outcome {
        case .notModified:
            feed.lastError = nil
        case .prepared(let articles, let homepageURL, let newETag, let newLastModified):
            insert(articles, into: feed, homepageURL: homepageURL)
            feed.etag = newETag
            feed.lastModified = newLastModified
            feed.lastError = nil
        case .failed(let message):
            feed.lastError = message
        }
        feed.lastFetchedAt = Date.now
        do {
            try modelContext.save()
        } catch {
            // A failed save leaves this long-lived context dirty and would
            // poison every later save — discard the transaction, then record
            // just the failure so the error glyph can show it.
            modelContext.rollback()
            if let feed = feedModel(for: feedID) {
                feed.lastError = "Could not save: \(error.localizedDescription)"
                feed.lastFetchedAt = Date.now
                try? modelContext.save()
            }
        }
    }

    /// Shared ingest path and the test seam for upsert semantics.
    func ingest(_ parsed: ParsedFeed, intoFeedWithID id: PersistentIdentifier) async throws {
        guard let snapshot = feedModel(for: id) else { return }
        let feedURL = snapshot.feedURL
        let knownIDs = Set(snapshot.articles.map(\.stableID))
        let fresh = parsed.items.filter { !knownIDs.contains($0.stableID) }
        let articles = await prepare(fresh, feedURL: feedURL)
        guard let feed = feedModel(for: id) else { return }
        insert(articles, into: feed, homepageURL: parsed.homepageURL)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// One newsletter rule feed: list matching headers → regex-filter →
    /// fetch new bodies → prepare (same sanitize/image pipeline as RSS) →
    /// insert + save → archive in the mailbox → bookkeeping. Also the test
    /// seam: tests pass a stub provider.
    ///
    /// Ordering invariants:
    /// - Articles are durable *before* the mailbox is touched — a crash in
    ///   between leaves mail in the inbox, which self-heals next sync; the
    ///   reverse order could archive mail the reader never stored.
    /// - The watermark advances only when ingest persisted AND archiving
    ///   succeeded, so failed archives always stay inside the re-list
    ///   window and missed messages are never skipped.
    func refreshNewsletter(feedID: PersistentIdentifier, using client: any MailProviderClient) async {
        guard let snapshot = feedModel(for: feedID), snapshot.isNewsletterFeed else { return }
        let rule = snapshot.newsletterRule
        let knownIDs = Set(snapshot.articles.map(\.stableID))
        let watermark = snapshot.newsletterLastSyncedAt
        let feedURL = snapshot.feedURL
        // Captured before listing so messages arriving mid-sync fall after
        // the next watermark and get re-listed.
        let syncStartedAt = Date.now

        // Value phase — models released, mirroring the RSS path.
        var prepared: [PreparedArticle] = []
        var archiveIDs: [String] = []
        var failure: String?
        do {
            guard let rule else {
                throw MailProviderError.invalidRule("Newsletter rule is incomplete — edit it to set a sender")
            }
            // Compile before any network call so a bad pattern fails fast.
            let regex = try NewsletterRule.compiledSubjectRegex(from: rule.subjectPattern)
            let since = watermark.map { $0.addingTimeInterval(-Self.newsletterWatermarkOverlap) }
                ?? syncStartedAt.addingTimeInterval(-TimeInterval(Self.newsletterBackfillDays) * 86400)
            let headers = try await client.messageHeaders(
                matching: MailQuery(sender: rule.sender, since: since))
            let matched = headers.filter {
                NewsletterRule.matches(subject: $0.subject, compiled: regex)
            }
            let fresh = matched
                .filter { !knownIDs.contains($0.id) }
                .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                .prefix(Self.maxNewsletterMessagesPerSync)
            var items: [ParsedItem] = []
            items.reserveCapacity(fresh.count)
            for header in fresh {
                // One failed body fetch fails the whole sync: the watermark
                // stays put, so nothing is ever skipped — the RSS path's
                // all-or-nothing fetch semantics.
                items.append(GmailMessageParser.parsedItem(
                    from: try await client.message(id: header.id)))
            }
            prepared = await prepare(items, feedURL: feedURL)
            if rule.archiveAfterIngest {
                // Self-healing set: new matches AND known-but-still-inboxed
                // ones (a failed markProcessed keeps isUnprocessed true).
                // Messages older than `since` are never listed, so a rule
                // can never archive mail that predates it.
                archiveIDs = matched.filter(\.isUnprocessed).map(\.id)
            }
        } catch {
            failure = shortDescription(of: error)
        }

        // Model phase 1 — re-resolve (the feed may have been deleted while
        // we were suspended; bail without touching the mailbox) and persist
        // the articles.
        guard let feed = feedModel(for: feedID) else { return }
        if let failure {
            feed.lastError = failure
            feed.lastFetchedAt = Date.now
            saveRecordingFailure(feedID: feedID)
            return
        }
        insert(prepared, into: feed, homepageURL: nil)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let survivor = feedModel(for: feedID) {
                survivor.lastError = "Could not save: \(error.localizedDescription)"
                survivor.lastFetchedAt = Date.now
                try? modelContext.save()
            }
            return
        }

        // Mailbox phase — archive + mark read, best-effort per sync.
        var archiveFailure: String?
        if !archiveIDs.isEmpty {
            do {
                try await client.markProcessed(ids: archiveIDs)
            } catch {
                archiveFailure = shortDescription(of: error)
            }
        }

        // Model phase 2 — bookkeeping after the archive suspension.
        guard let survivor = feedModel(for: feedID) else { return }
        if let archiveFailure {
            survivor.lastError = archiveFailure
        } else {
            survivor.lastError = nil
            survivor.newsletterLastSyncedAt = syncStartedAt
        }
        survivor.lastFetchedAt = Date.now
        saveRecordingFailure(feedID: feedID)
    }

    /// Save, falling back to the rollback-then-record-the-error pattern the
    /// RSS path uses, so a failed save never poisons this long-lived context.
    private func saveRecordingFailure(feedID: PersistentIdentifier) {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let feed = feedModel(for: feedID) {
                feed.lastError = "Could not save: \(error.localizedDescription)"
                feed.lastFetchedAt = Date.now
                try? modelContext.save()
            }
        }
    }

    // MARK: - Editions

    /// Sweeps every unassigned non-saved-links article into a new edition.
    /// The first edition ever therefore sweeps the entire pre-existing
    /// library (everything is unassigned); read/starred state is untouched,
    /// and an empty sweep still creates the edition — a boundary with
    /// nothing new is an honest "all caught up".
    ///
    /// Deliberately await-free: numbering, the sweep, and the save cannot
    /// interleave with other actor work, which is what makes
    /// `Edition.number` collision-free without a #Unique constraint (see
    /// Edition). Adding an `await` in here is a correctness regression.
    ///
    /// Returns nil after a failed save (rolled back). Due-ness derives from
    /// the persisted latest edition, so the scheduler's next wake retries.
    @discardableResult
    func publishEdition(
        scheduledFor: Date,
        isManual: Bool,
        publishedAt: Date = .now
    ) -> PersistentIdentifier? {
        let number = (latestEdition()?.number ?? 0) + 1
        let unassigned = (try? modelContext.fetch(
            FetchDescriptor<Article>(predicate: #Predicate { $0.edition == nil })
        )) ?? []
        let savedKind = SourceKind.savedLinks.rawValue
        let swept = unassigned.filter { $0.feed?.sourceKind != savedKind }
        let edition = Edition(
            number: number,
            publishedAt: publishedAt,
            scheduledFor: scheduledFor,
            isManual: isManual
        )
        modelContext.insert(edition)
        for article in swept {
            article.edition = edition
        }
        do {
            try modelContext.save()
            return edition.persistentModelID
        } catch {
            modelContext.rollback()
            return nil
        }
    }

    /// Publishes at most one edition when a cadence boundary has elapsed —
    /// multi-boundary gaps collapse into a single catch-up whose
    /// scheduledFor is the most recent elapsed boundary. Returns the next
    /// future boundary for the scheduler's sleep; nil when the cadence is
    /// manual. Await-free for the same reason as `publishEdition`.
    func publishDueEditionIfNeeded(
        cadence: EditionCadence,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        if let due = EditionSchedule.dueBoundary(
            cadence: cadence,
            lastScheduledFor: latestEdition()?.scheduledFor,
            now: now,
            calendar: calendar
        ) {
            publishEdition(scheduledFor: due, isManual: false, publishedAt: now)
        }
        return EditionSchedule.nextBoundary(
            cadence: cadence,
            lastScheduledFor: latestEdition()?.scheduledFor,
            now: now,
            calendar: calendar
        )
    }

    private func latestEdition() -> Edition? {
        var descriptor = FetchDescriptor<Edition>(
            sortBy: [SortDescriptor(\.number, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Sanitize, cache images locally, rewrite img sources — pure value work,
    /// safe to suspend on downloads.
    private func prepare(_ items: [ParsedItem], feedURL: URL) async -> [PreparedArticle] {
        var prepared: [PreparedArticle] = []
        for item in items {
            let sanitized = HTMLProcessor.strippingTrackingPixels(
                html: HTMLProcessor.sanitize(html: item.contentHTML))
            let base = item.link ?? feedURL
            let remotes = Array(
                HTMLProcessor.extractImageURLs(html: sanitized, baseURL: base)
                    .prefix(Self.maxImagesPerArticle))
            var mapping: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                var iterator = remotes.makeIterator()
                var started = 0
                while started < Self.maxConcurrentImageFetches, let remote = iterator.next() {
                    group.addTask { [imageCache] in
                        (remote.absoluteString, await imageCache.cache(remote))
                    }
                    started += 1
                }
                while let (remote, asset) = await group.next() {
                    if let asset {
                        mapping[remote] = "\(LocalAssetSchemeHandler.scheme)://\(asset)"
                    }
                    if let next = iterator.next() {
                        group.addTask { [imageCache] in
                            (next.absoluteString, await imageCache.cache(next))
                        }
                    }
                }
            }
            let content = mapping.isEmpty
                ? sanitized
                : HTMLProcessor.rewriteImageSources(html: sanitized, baseURL: base, mapping: mapping)
            prepared.append(PreparedArticle(
                stableID: item.stableID,
                title: item.title,
                author: item.author,
                link: item.link,
                publishedAt: item.publishedAt,
                summary: excerpt(for: item),
                contentHTML: content
            ))
        }
        return prepared
    }

    /// Inserts only unseen items; never touches existing articles, so
    /// isRead/isStarred/firstSeenAt survive every refresh. The known-ID set
    /// is recomputed here to close the window opened by `prepare`'s awaits.
    private func insert(_ articles: [PreparedArticle], into feed: Feed, homepageURL: URL?) {
        if feed.homepageURL == nil {
            feed.homepageURL = homepageURL
        }
        let known = Set(feed.articles.map(\.stableID))
        for item in articles where !known.contains(item.stableID) {
            let article = Article(
                stableID: item.stableID,
                title: item.title,
                author: item.author,
                link: item.link,
                publishedAt: item.publishedAt,
                summary: item.summary,
                contentHTML: item.contentHTML
            )
            modelContext.insert(article)
            article.feed = feed
        }
    }

    private func excerpt(for item: ParsedItem) -> String? {
        let source = item.summaryHTML ?? item.contentHTML
        guard !source.isEmpty else { return nil }
        let excerpt = HTMLProcessor.plainTextExcerpt(from: source, maxLength: 300)
        return excerpt.isEmpty ? nil : excerpt
    }

    private func feedModel(for id: PersistentIdentifier) -> Feed? {
        var descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func shortDescription(of error: Error) -> String {
        switch error {
        case let error as MailProviderError:
            return error.errorDescription ?? "Gmail sync failed"
        case let error as FeedFetcher.FetchError:
            return error.errorDescription ?? "Fetch failed"
        case FeedParseError.notAFeed:
            return "Not an RSS or Atom feed"
        case FeedParseError.malformed(let detail):
            return "Malformed feed: \(detail)"
        case let error as URLError:
            return error.localizedDescription
        default:
            return error.localizedDescription
        }
    }
}
