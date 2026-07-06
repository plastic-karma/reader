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
}
