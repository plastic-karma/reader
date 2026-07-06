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

    private let fetcher = FeedFetcher()

    func refreshAll() async {
        let ids = (try? modelContext.fetch(FetchDescriptor<Feed>()))?.map(\.persistentModelID) ?? []
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

    /// One feed: fetch → parse → ingest → bookkeeping. Errors land in
    /// `feed.lastError`; one bad feed never fails a batch.
    func refresh(feedID: PersistentIdentifier) async {
        guard let feed = feedModel(for: feedID) else { return }
        let url = feed.feedURL
        let etag = feed.etag
        let lastModified = feed.lastModified

        // Network happens against snapshotted values only: the model must not
        // be touched across the suspension (the user may delete it meanwhile).
        enum Outcome {
            case notModified
            case parsed(ParsedFeed, etag: String?, lastModified: String?)
            case failed(String)
        }
        let outcome: Outcome
        do {
            switch try await fetcher.fetch(url: url, etag: etag, lastModified: lastModified) {
            case .notModified:
                outcome = .notModified
            case .fetched(let data, let newETag, let newLastModified):
                let parsed = try FeedParser.parse(data: data, sourceURL: url)
                outcome = .parsed(parsed, etag: newETag, lastModified: newLastModified)
            }
        } catch {
            outcome = .failed(shortDescription(of: error))
        }

        // Re-resolve after the suspension; bail out if the feed was deleted.
        guard let feed = feedModel(for: feedID) else { return }
        switch outcome {
        case .notModified:
            feed.lastError = nil
        case .parsed(let parsed, let newETag, let newLastModified):
            ingest(parsed, into: feed)
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
    func ingest(_ parsed: ParsedFeed, intoFeedWithID id: PersistentIdentifier) throws {
        guard let feed = feedModel(for: id) else { return }
        ingest(parsed, into: feed)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Inserts only unseen items; never touches existing articles, so
    /// isRead/isStarred/firstSeenAt survive every refresh.
    private func ingest(_ parsed: ParsedFeed, into feed: Feed) {
        if feed.homepageURL == nil {
            feed.homepageURL = parsed.homepageURL
        }
        let known = Set(feed.articles.map(\.stableID))
        for item in parsed.items where !known.contains(item.stableID) {
            let article = Article(
                stableID: item.stableID,
                title: item.title,
                author: item.author,
                link: item.link,
                publishedAt: item.publishedAt,
                summary: excerpt(for: item),
                contentHTML: HTMLProcessor.sanitize(html: item.contentHTML)
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
