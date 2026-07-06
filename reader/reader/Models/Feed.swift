//
//  Feed.swift
//  reader
//

import Foundation
import SwiftData

@Model
nonisolated final class Feed {
    #Unique<Feed>([\.feedURL])

    var feedURL: URL
    var title: String
    var homepageURL: URL?
    var iconURL: URL?
    var sourceKind: String
    var addedAt: Date
    var lastFetchedAt: Date?
    /// nil means the last fetch succeeded; otherwise a short human-readable reason.
    var lastError: String?
    var etag: String?
    var lastModified: String?
    /// Sidebar UI state: whether this feed's article list is folded away.
    /// Persisted so the fold survives relaunches and filter switches.
    var isCollapsed: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article] = []

    init(
        feedURL: URL,
        title: String,
        homepageURL: URL? = nil,
        sourceKind: SourceKind = .rss,
        addedAt: Date = .now
    ) {
        self.feedURL = feedURL
        self.title = title
        self.homepageURL = homepageURL
        self.sourceKind = sourceKind.rawValue
        self.addedAt = addedAt
    }
}

extension Feed {
    var unreadCount: Int {
        articles.count { !$0.isRead }
    }

    /// Marks every unread article in this feed read. Skips already-read
    /// articles so repeat invocations don't dirty untouched models.
    func markAllRead() {
        for article in articles where !article.isRead {
            article.isRead = true
        }
    }

    /// Sentinel URL of the hidden feed that stores saved-link snapshots.
    /// Deliberately non-http: AddFeedSheet's URL normalizer admits only
    /// http(s), so no user-entered feed can collide with it.
    static let savedLinksFeedURL = URL(string: "reader-internal://saved-links")!

    var isSavedLinksFeed: Bool {
        sourceKind == SourceKind.savedLinks.rawValue
    }
}
