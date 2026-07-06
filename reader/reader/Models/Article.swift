//
//  Article.swift
//  reader
//

import Foundation
import SwiftData

@Model
nonisolated final class Article {
    #Unique<Article>([\.feed, \.stableID])

    /// Dedup key computed at parse time: guid/atom-id, else link, else a hash
    /// of title + date. Unique per feed, stable across refreshes.
    var stableID: String
    var title: String
    var author: String?
    var link: URL?
    /// nil when the feed omits the date or it fails to parse.
    var publishedAt: Date?
    /// When this article first appeared in a refresh — stable fallback sort key.
    var firstSeenAt: Date
    /// Plain-text excerpt for list rows.
    var summary: String?
    /// Sanitized HTML with image sources rewritten to cached local assets.
    var contentHTML: String
    var isRead: Bool
    var isStarred: Bool
    var feed: Feed?
    /// Saved-link snapshots only; nil for feed articles and after a
    /// successful (re-)download. Short human-readable failure reason.
    var downloadError: String? = nil
    /// Saved-link snapshots only: when the page content was last downloaded
    /// successfully. nil for feed articles and for never-completed saves.
    var downloadedAt: Date? = nil

    init(
        stableID: String,
        title: String,
        author: String? = nil,
        link: URL? = nil,
        publishedAt: Date? = nil,
        firstSeenAt: Date = .now,
        summary: String? = nil,
        contentHTML: String = "",
        isRead: Bool = false,
        isStarred: Bool = false
    ) {
        self.stableID = stableID
        self.title = title
        self.author = author
        self.link = link
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

extension Article {
    /// Newest-first list ordering, falling back to arrival time for undated items.
    var sortDate: Date {
        publishedAt ?? firstSeenAt
    }

    /// ⌘⇧A: marks every unread *feed* article read. Saved-link articles live
    /// only under the Saved view and are deliberately excluded.
    nonisolated static func markAllRead(in context: ModelContext) {
        let unread = (try? context.fetch(
            FetchDescriptor<Article>(predicate: #Predicate { !$0.isRead })
        )) ?? []
        let savedKind = SourceKind.savedLinks.rawValue
        for article in unread where article.feed?.sourceKind != savedKind {
            article.isRead = true
        }
    }
}
