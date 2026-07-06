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
    private let imageCache = ImageCache()

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

    /// One feed: fetch → parse → prepare (images) → insert → bookkeeping.
    /// Errors land in `feed.lastError`; one bad feed never fails a batch.
    func refresh(feedID: PersistentIdentifier) async {
        // Snapshot everything the network phase needs, then let go of the
        // model: the user may delete the feed while we're suspended.
        guard let snapshot = feedModel(for: feedID) else { return }
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

    /// Sanitize, cache images locally, rewrite img sources — pure value work,
    /// safe to suspend on downloads.
    private func prepare(_ items: [ParsedItem], feedURL: URL) async -> [PreparedArticle] {
        var prepared: [PreparedArticle] = []
        for item in items {
            let sanitized = HTMLProcessor.sanitize(html: item.contentHTML)
            let base = item.link ?? feedURL
            var mapping: [String: String] = [:]
            for remote in HTMLProcessor.extractImageURLs(html: sanitized, baseURL: base) {
                if let asset = await imageCache.cache(remote) {
                    mapping[remote.absoluteString] = "\(LocalAssetSchemeHandler.scheme)://\(asset)"
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
