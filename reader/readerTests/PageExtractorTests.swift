//
//  PageExtractorTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class PageExtractorTests: XCTestCase {

    private let sourceURL = URL(string: "https://example.com/posts/actors")!

    // MARK: - Title

    func testTitlePrefersOGTitleOverTitleTag() {
        let title = PageExtractor.title(inHTML: PageFixtures.articlePage, sourceURL: sourceURL)
        XCTAssertEqual(title, "Understanding Swift Actors & Isolation")
    }

    func testTitleAcceptsOGTitleDeclaredViaNameAttribute() {
        let html = #"<head><meta name="og:title" content="Named Variant"><title>Fallback</title></head>"#
        XCTAssertEqual(PageExtractor.title(inHTML: html, sourceURL: sourceURL), "Named Variant")
    }

    func testTitleFallsBackToTitleTagDecodingEntitiesAndCollapsingWhitespace() {
        let title = PageExtractor.title(inHTML: PageFixtures.titleEntityPage, sourceURL: sourceURL)
        XCTAssertEqual(title, "Ben&Jerry\u{2019}s Guide")
    }

    func testTitleFallsBackToHostWhenPageHasNoTitle() {
        let title = PageExtractor.title(inHTML: "<body><p>Untitled.</p></body>", sourceURL: sourceURL)
        XCTAssertEqual(title, "example.com")
    }

    // MARK: - Content tiers

    func testContentUsesFirstArticleElement() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.articlePage)
        XCTAssertTrue(content.contains("The quick brown fox"))
        XCTAssertTrue(content.contains("second paragraph"))
        // Tier-1/2 candidates keep their inner <header> (the headline).
        XCTAssertTrue(content.contains("Understanding Swift Actors"))
        // Page chrome outside the article never leaks in.
        XCTAssertFalse(content.contains("Example Blog</h1>"))
        XCTAssertFalse(content.contains("© Example Blog"))
    }

    func testSiblingCommentArticlesAreNotMerged() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.articlePage)
        XCTAssertFalse(content.contains("First comment"))
        XCTAssertFalse(content.contains("Second comment"))
    }

    func testShortTeaserArticleFallsThroughToMain() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.teaserThenMainPage)
        XCTAssertTrue(content.contains("Main content continues"))
        XCTAssertFalse(content.contains("Teaser one"))
    }

    func testContentFallsBackToBodyWithChromeStripped() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.bodyChromePage)
        XCTAssertTrue(content.contains("The quick brown fox"))
        XCTAssertFalse(content.contains("Site Header"))
        XCTAssertFalse(content.contains("Home"))
        XCTAssertFalse(content.contains("Related posts sidebar"))
        XCTAssertFalse(content.contains("Legal fine print"))
    }

    func testContentFallsBackToWholeInputWithoutBodyTag() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.bareFragment)
        XCTAssertTrue(content.contains("The quick brown fox"))
        XCTAssertTrue(content.contains(#"<div class="post">"#))
    }

    // MARK: - Fragment cleanup

    func testCleanupRemovesStyleLinkNoscriptAndComments() {
        let content = PageExtractor.mainContent(inHTML: PageFixtures.bodyChromePage)
        XCTAssertFalse(content.contains("hotpink"))
        XCTAssertFalse(content.lowercased().contains("<style"))
        XCTAssertFalse(content.lowercased().contains("<link"))
        XCTAssertFalse(content.contains("tracking.gif"))
        XCTAssertFalse(content.contains("rendering starts here"))
    }

    func testSanitizeBeforeExtractKeepsArticleWholeDespiteScriptedClosingTag() {
        // Unsanitized, the literal "</article>" inside the script would
        // truncate the tier-1 capture; the documented contract is
        // sanitize-first, which removes the script body wholesale.
        let sanitized = HTMLProcessor.sanitize(html: PageFixtures.scriptedArticlePage)
        let content = PageExtractor.mainContent(inHTML: sanitized)
        XCTAssertTrue(content.contains("MARKER-AFTER-SCRIPT"))
        XCTAssertFalse(content.contains("fake"))
    }
}
