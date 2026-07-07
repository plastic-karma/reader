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

    // Newsletter-rule fields, set only when sourceKind == .newsletter.
    // Optional + nil-defaulted so existing stores migrate in place — the
    // same pattern as Article's saved-link-only fields.

    /// Provider-native sender operand the rule pulls from (an address or
    /// domain; Gmail `from:` semantics).
    var newsletterSender: String? = nil
    /// Subject regex source; nil or empty admits every message from the sender.
    var newsletterSubjectPattern: String? = nil
    /// Archive + mark read in the mailbox after ingest. Read as `?? true`.
    var newsletterArchiveAfterIngest: Bool? = nil
    /// Sync watermark. Advanced only after a sync that both persisted its
    /// articles and completed its mailbox archiving — never on failure, so
    /// missed messages always stay inside the next re-list window.
    /// nil = never synced (full backfill).
    var newsletterLastSyncedAt: Date? = nil

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

    /// Fresh sentinel URL for a newsletter rule feed. Non-http like
    /// `savedLinksFeedURL`, so AddFeedSheet can never collide with it; the
    /// UUID keeps `#Unique(feedURL)` satisfied across many rules.
    static func makeNewsletterFeedURL() -> URL {
        URL(string: "reader-internal://newsletter/\(UUID().uuidString)")!
    }

    var isNewsletterFeed: Bool {
        sourceKind == SourceKind.newsletter.rawValue
    }

    /// The rule assembled from the newsletter fields, or nil when this isn't
    /// a newsletter feed or the sender is missing — the refresh engine
    /// surfaces nil as `lastError` instead of crashing the sync.
    var newsletterRule: NewsletterRule? {
        guard isNewsletterFeed,
              let sender = newsletterSender?.trimmingCharacters(in: .whitespaces),
              !sender.isEmpty else { return nil }
        return NewsletterRule(
            sender: sender,
            subjectPattern: newsletterSubjectPattern.flatMap { $0.isEmpty ? nil : $0 },
            archiveAfterIngest: newsletterArchiveAfterIngest ?? true
        )
    }
}
