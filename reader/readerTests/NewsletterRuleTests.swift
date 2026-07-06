//
//  NewsletterRuleTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class NewsletterRuleTests: XCTestCase {

    // MARK: - Subject regex compilation + matching

    func testNilAndBlankPatternsCompileToNilAndMatchEverything() throws {
        for pattern in [nil, "", "   "] {
            let compiled = try NewsletterRule.compiledSubjectRegex(from: pattern)
            XCTAssertNil(compiled)
            XCTAssertTrue(NewsletterRule.matches(subject: "Anything at all", compiled: compiled))
            XCTAssertTrue(NewsletterRule.matches(subject: "", compiled: compiled))
        }
    }

    func testMatchingIsCaseInsensitiveAndPartial() throws {
        let compiled = try NewsletterRule.compiledSubjectRegex(from: "money stuff")
        XCTAssertTrue(NewsletterRule.matches(
            subject: "Money Stuff: Everything Is Securities Fraud", compiled: compiled))
        XCTAssertFalse(NewsletterRule.matches(
            subject: "Weekly digest", compiled: compiled))
    }

    func testAnchorsAndAlternationWork() throws {
        let compiled = try NewsletterRule.compiledSubjectRegex(from: "^(Stratechery|Sharp Tech)")
        XCTAssertTrue(NewsletterRule.matches(
            subject: "Stratechery: The AI Bill", compiled: compiled))
        XCTAssertTrue(NewsletterRule.matches(
            subject: "sharp tech interview", compiled: compiled))
        XCTAssertFalse(NewsletterRule.matches(
            subject: "Re: Stratechery: The AI Bill", compiled: compiled))
    }

    func testInvalidPatternThrowsPatternError() {
        XCTAssertThrowsError(try NewsletterRule.compiledSubjectRegex(from: "[unclosed")) { error in
            guard case NewsletterRule.PatternError.invalid = error else {
                return XCTFail("Expected PatternError.invalid, got \(error)")
            }
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?
                    .hasPrefix("Invalid subject pattern") == true
            )
        }
    }

    // MARK: - Feed.newsletterRule assembly

    func testRuleIsNilForNonNewsletterFeeds() {
        let rss = Feed(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Blog")
        rss.newsletterSender = "news@example.com"
        XCTAssertNil(rss.newsletterRule)
        XCTAssertFalse(rss.isNewsletterFeed)
    }

    func testRuleIsNilWithoutSender() {
        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: "Money Stuff",
            sourceKind: .newsletter
        )
        XCTAssertNil(feed.newsletterRule)
        feed.newsletterSender = "   "
        XCTAssertNil(feed.newsletterRule)
    }

    func testRuleAssemblyTrimsSenderAndDefaultsArchiveOn() {
        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: "Money Stuff",
            sourceKind: .newsletter
        )
        feed.newsletterSender = " money@bloomberg.net "
        feed.newsletterSubjectPattern = ""

        let rule = feed.newsletterRule
        XCTAssertEqual(rule?.sender, "money@bloomberg.net")
        XCTAssertNil(rule?.subjectPattern, "Empty pattern normalizes to nil")
        XCTAssertEqual(rule?.archiveAfterIngest, true, "Archive defaults on when unset")
        XCTAssertTrue(feed.isNewsletterFeed)
    }

    func testRuleHonorsExplicitArchiveToggleAndPattern() {
        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: "Stratechery",
            sourceKind: .newsletter
        )
        feed.newsletterSender = "email@stratechery.com"
        feed.newsletterSubjectPattern = "^Stratechery"
        feed.newsletterArchiveAfterIngest = false

        let rule = feed.newsletterRule
        XCTAssertEqual(rule?.subjectPattern, "^Stratechery")
        XCTAssertEqual(rule?.archiveAfterIngest, false)
    }

    // MARK: - Sentinel URL

    func testNewsletterFeedURLsAreInternalSchemeAndUnique() {
        let first = Feed.makeNewsletterFeedURL()
        let second = Feed.makeNewsletterFeedURL()
        XCTAssertEqual(first.scheme, "reader-internal")
        XCTAssertEqual(first.host, "newsletter")
        XCTAssertNotEqual(first, second, "Each rule needs its own #Unique-satisfying URL")
    }

    func testNewsletterFeedIsNotSavedLinksFeed() {
        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: "Rule",
            sourceKind: .newsletter
        )
        XCTAssertFalse(feed.isSavedLinksFeed)
        XCTAssertTrue(feed.isNewsletterFeed)
    }
}
