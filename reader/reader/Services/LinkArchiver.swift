//
//  LinkArchiver.swift
//  reader
//

import Foundation
import SwiftData

/// Archives web pages the user saves from the reading pane. One download per
/// save — a snapshot, never auto-refreshed — processed exactly like feed
/// article content (sanitize → extract → cache images → rewrite srcs) so it
/// renders offline under the reading pane's CSP. Mirrors RefreshEngine's
/// discipline: the model phase before the network never suspends, only
/// Sendable values cross awaits, models are re-resolved afterwards, and a
/// failed save is rolled back before recording the error.
@ModelActor
actor LinkArchiver {

    /// Snapshot payload prepared entirely off the model graph.
    private struct PreparedSnapshot {
        let title: String
        let summary: String?
        let contentHTML: String
    }

    private enum Outcome {
        case prepared(PreparedSnapshot)
        case failed(String)
    }

    /// Images cached per snapshot, document order; the remainder stay remote
    /// and render as CSP-blocked placeholders (same as any failed download).
    private static let maxImageDownloads = 50

    /// Saved pages routinely reference dozens of images on hosts that
    /// black-hole a non-browser user agent; downloading them one at a time
    /// serializes those 30 s timeouts into a minutes-long "Downloading…".
    private static let maxConcurrentImageFetches = 6

    private let fetcher = PageFetcher()
    private let imageCache = ImageCache()
    /// Coalesces concurrent saves of the same canonical URL (ImageCache's
    /// inFlight pattern): the second caller joins the first download.
    private var inFlight: [String: Task<Void, Never>] = [:]

    // MARK: - Entry points

    /// The one production entry point. Inserts/refreshes a placeholder row
    /// immediately (instant sidebar feedback), then downloads and processes
    /// the page. Every failure lands on `article.downloadError`; calling
    /// again with the same URL retries / refreshes the snapshot. Non-http(s)
    /// URLs are ignored. Never throws.
    func save(_ url: URL) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        let stableID = Self.canonicalStableID(for: url)
        if let running = inFlight[stableID] {
            await running.value
            return
        }
        let task = Task {
            await self.performSave(url: url, stableID: stableID) {
                try await self.fetcher.fetch(url: url)
            }
        }
        inFlight[stableID] = task
        await task.value
        inFlight[stableID] = nil
    }

    /// Test seam (RefreshEngine.ingest analog): the full save pipeline —
    /// lazy hidden-feed creation, placeholder, extraction, in-place update,
    /// failure recording — with only the network phase replaced by `fetched`.
    func ingest(_ fetched: Result<PageFetcher.FetchedPage, any Error>, savedAs url: URL) async {
        await performSave(url: url, stableID: Self.canonicalStableID(for: url)) {
            try fetched.get()
        }
    }

    /// Launch sweep: placeholders orphaned by quitting mid-download become
    /// visible failures instead of eternal "Downloading…" rows. Called once
    /// from LinkSaver.init, before any save can be in flight.
    func markAbandonedSaves() {
        guard let feed = existingSavedLinksFeed() else { return }
        var flagged = false
        for article in feed.articles where article.downloadedAt == nil && article.downloadError == nil {
            article.downloadError = "Interrupted — save the link again to retry"
            flagged = true
        }
        if flagged {
            try? modelContext.save()
        }
    }

    /// Dedup key for saved URLs: the fragment is stripped (same document,
    /// different anchor), the query is kept (a different query is routinely a
    /// different page). No other normalization — two URLs redirecting to one
    /// page stay two snapshots.
    nonisolated static func canonicalStableID(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Pipeline

    /// Placeholder → fetch/prepare (value work) → re-resolve and apply.
    /// `fetch` runs exactly once.
    private func performSave(
        url: URL,
        stableID: String,
        fetch: () async throws -> PageFetcher.FetchedPage
    ) async {
        guard let articleID = insertPlaceholder(url: url, stableID: stableID) else { return }

        let outcome: Outcome
        do {
            outcome = .prepared(await prepare(try await fetch(), savedURL: url))
        } catch {
            outcome = .failed(shortDescription(of: error))
        }

        // Re-resolve after the suspensions; respect deletion mid-flight.
        guard let article = articleModel(for: articleID) else { return }
        switch outcome {
        case .prepared(let snapshot):
            article.title = snapshot.title
            article.summary = snapshot.summary
            article.contentHTML = snapshot.contentHTML
            article.downloadError = nil
            article.downloadedAt = .now
        case .failed(let message):
            article.downloadError = message
            if article.downloadedAt == nil {
                // Never had a good snapshot; a failed re-save keeps the old one.
                article.contentHTML = Self.failureHTML(for: url, message: message)
            }
        }
        do {
            try modelContext.save()
        } catch {
            // Same rationale as RefreshEngine: a failed save would poison the
            // long-lived context — discard, then record just the failure.
            modelContext.rollback()
            if let article = articleModel(for: articleID) {
                article.downloadError = "Could not save: \(error.localizedDescription)"
                try? modelContext.save()
            }
        }
    }

    /// No suspensions: hidden feed + placeholder exist and are saved before
    /// any network I/O — actor serialization makes this race-free for
    /// concurrent saves and lazy feed creation. Returns nil (after rollback)
    /// when the context save fails. For an existing article (re-save) only
    /// downloadError is cleared; title/summary/content stay readable while
    /// the refresh runs.
    private func insertPlaceholder(url: URL, stableID: String) -> PersistentIdentifier? {
        let feed = savedLinksFeed()
        let article: Article
        if let existing = feed.articles.first(where: { $0.stableID == stableID }) {
            existing.downloadError = nil
            article = existing
        } else {
            let inserted = Article(
                stableID: stableID,
                title: url.host() ?? url.absoluteString,
                link: url,
                summary: "Downloading…",
                contentHTML: Self.placeholderHTML(for: url)
            )
            modelContext.insert(inserted)
            inserted.feed = feed
            article = inserted
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return nil
        }
        return article.persistentModelID
    }

    /// Sanitize (before extraction — script bodies routinely contain literal
    /// "</article>" that would derail the block regexes), extract the main
    /// content, cache images locally, rewrite img sources — pure value work,
    /// safe to suspend on downloads. Relative images resolve against the
    /// post-redirect final URL; the title's host fallback uses the URL the
    /// user saved.
    private func prepare(_ page: PageFetcher.FetchedPage, savedURL: URL) async -> PreparedSnapshot {
        let sanitized = HTMLProcessor.sanitize(html: page.html)
        let extracted = PageExtractor.extract(fromSanitizedHTML: sanitized, sourceURL: savedURL)
        let remotes = Array(
            HTMLProcessor.extractImageURLs(html: extracted.contentHTML, baseURL: page.finalURL)
                .prefix(Self.maxImageDownloads))
        // Sliding window (the refreshAll pattern): failed hosts time out in
        // parallel instead of stacking their 30 s budgets end to end.
        var mapping: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var iterator = remotes.makeIterator()
            var started = 0
            while started < Self.maxConcurrentImageFetches, let remote = iterator.next() {
                group.addTask { [imageCache] in (remote.absoluteString, await imageCache.cache(remote)) }
                started += 1
            }
            while let (remote, asset) = await group.next() {
                if let asset {
                    mapping[remote] = "\(LocalAssetSchemeHandler.scheme)://\(asset)"
                }
                if let next = iterator.next() {
                    group.addTask { [imageCache] in (next.absoluteString, await imageCache.cache(next)) }
                }
            }
        }
        let content = mapping.isEmpty
            ? extracted.contentHTML
            : HTMLProcessor.rewriteImageSources(
                html: extracted.contentHTML, baseURL: page.finalURL, mapping: mapping)
        let excerpt = HTMLProcessor.plainTextExcerpt(from: extracted.contentHTML, maxLength: 300)
        return PreparedSnapshot(
            title: extracted.title,
            summary: excerpt.isEmpty ? nil : excerpt,
            contentHTML: content
        )
    }

    // MARK: - Model lookups

    /// Fetch-or-create; exactly-once by actor serialization (the placeholder
    /// phase never suspends), #Unique(feedURL) backstops. The caller's save
    /// persists a fresh insert.
    private func savedLinksFeed() -> Feed {
        if let existing = existingSavedLinksFeed() {
            return existing
        }
        let feed = Feed(
            feedURL: Feed.savedLinksFeedURL,
            title: "Saved Links",
            sourceKind: .savedLinks
        )
        modelContext.insert(feed)
        return feed
    }

    private func existingSavedLinksFeed() -> Feed? {
        let feeds = (try? modelContext.fetch(FetchDescriptor<Feed>())) ?? []
        return feeds.first { $0.isSavedLinksFeed }
    }

    /// RefreshEngine.feedModel(for:) analog on Article.
    private func articleModel(for id: PersistentIdentifier) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func shortDescription(of error: any Error) -> String {
        switch error {
        case let error as PageFetcher.FetchError:
            return error.errorDescription ?? "Download failed"
        case let error as URLError:
            return error.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Stub HTML

    private nonisolated static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private nonisolated static func placeholderHTML(for url: URL) -> String {
        let escaped = escapeHTML(url.absoluteString)
        return "<p>Downloading <a href=\"\(escaped)\">\(escaped)</a>…</p>"
    }

    private nonisolated static func failureHTML(for url: URL, message: String) -> String {
        let escaped = escapeHTML(url.absoluteString)
        return """
        <p>Couldn’t save this page: \(escapeHTML(message))</p>
        <p><a href="\(escaped)">Open the original in your browser</a></p>
        """
    }
}
