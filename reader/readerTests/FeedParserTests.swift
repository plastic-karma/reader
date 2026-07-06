//
//  FeedParserTests.swift
//  reader
//

import XCTest
@testable import reader

final class FeedParserTests: XCTestCase {

    private func parse(
        _ fixture: String,
        sourceURL: URL = URL(string: "https://example.com/feed.xml")!
    ) throws -> ParsedFeed {
        try FeedParser.parse(data: Data(fixture.utf8), sourceURL: sourceURL)
    }

    // MARK: - RSS 2.0

    func testRSS2FeedMetadata() throws {
        let feed = try parse(Fixtures.rss2Basic)
        XCTAssertEqual(feed.title, "Example Blog")
        XCTAssertEqual(feed.homepageURL, URL(string: "https://example.com/"))
        XCTAssertEqual(feed.items.count, 2)
    }

    func testRSS2FirstItemFields() throws {
        let feed = try parse(Fixtures.rss2Basic)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.title, "Apple’s Quiet Update")
        XCTAssertEqual(item.stableID, "post-1001")
        XCTAssertEqual(item.author, "Jane Doe")
        XCTAssertEqual(item.link, URL(string: "https://example.com/posts/quiet-update"))
        // Mon, 02 Jun 2025 09:30:00 GMT
        XCTAssertEqual(item.publishedAt, Date(timeIntervalSince1970: 1_748_856_600))
    }

    func testRSS2PrefersContentEncodedAndPreservesCDATA() throws {
        let feed = try parse(Fixtures.rss2Basic)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.contentHTML, "<p>The <em>full</em> story, with details.</p>")
        // summaryHTML stays the raw description; CDATA payload is untouched,
        // so the &amp; inside it must survive literally.
        XCTAssertEqual(item.summaryHTML, "<p>A short &amp; sweet summary.</p>")
    }

    func testRSS2FallsBackToDescriptionWithoutContentEncoded() throws {
        let feed = try parse(Fixtures.rss2Basic)
        let item = try XCTUnwrap(feed.items.last)
        XCTAssertEqual(item.stableID, "post-1002")
        XCTAssertEqual(item.author, "John Smith")
        XCTAssertEqual(item.contentHTML, "Plain description only.")
        XCTAssertEqual(item.summaryHTML, "Plain description only.")
        XCTAssertNotNil(item.publishedAt)
    }

    // MARK: - stableID fallback chain

    func testStableIDFallsBackToLinkWhenGuidMissing() throws {
        let feed = try parse(Fixtures.rssNoGuids)
        XCTAssertEqual(feed.items.count, 2)
        XCTAssertEqual(feed.items.first?.stableID, "https://linkline.example.net/posts/first")
        XCTAssertEqual(feed.items.last?.stableID, "https://linkline.example.net/posts/second")
    }

    func testStableIDFallsBackToDeterministicHash() throws {
        let first = try parse(Fixtures.rssBareItems)
        let second = try parse(Fixtures.rssBareItems)

        let id = try XCTUnwrap(first.items.first?.stableID)
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })

        XCTAssertEqual(first.items.map(\.stableID), second.items.map(\.stableID))
        XCTAssertNotEqual(first.items.first?.stableID, first.items.last?.stableID)
    }

    // MARK: - Atom

    func testAtomFeedMetadataUsesAlternateLinkNotSelf() throws {
        let feed = try parse(
            Fixtures.atomBasic,
            sourceURL: URL(string: "https://atom.example.org/feed.xml")!
        )
        XCTAssertEqual(feed.title, "Atom Journal")
        XCTAssertEqual(feed.homepageURL, URL(string: "https://atom.example.org/"))
        XCTAssertEqual(feed.items.count, 2)
    }

    func testAtomEntryFields() throws {
        let feed = try parse(Fixtures.atomBasic)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.stableID, "urn:uuid:entry-1")
        XCTAssertEqual(item.title, "Entry One")
        XCTAssertEqual(item.author, "Ada Lovelace")
        XCTAssertEqual(item.link, URL(string: "https://atom.example.org/entries/one"))
        // 2025-06-04T08:15:30Z (published, not updated)
        XCTAssertEqual(item.publishedAt, Date(timeIntervalSince1970: 1_749_024_930))
    }

    func testAtomContentPreferredOverSummary() throws {
        let feed = try parse(Fixtures.atomBasic)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.contentHTML, "<p>Full <strong>content</strong> here.</p>")
        XCTAssertEqual(item.summaryHTML, "A short abstract.")
    }

    func testAtomEntryFallbacks() throws {
        let feed = try parse(Fixtures.atomBasic)
        let item = try XCTUnwrap(feed.items.last)
        // Link without a rel attribute counts as alternate.
        XCTAssertEqual(item.link, URL(string: "https://atom.example.org/entries/two"))
        XCTAssertEqual(item.contentHTML, "Only a summary.")
        XCTAssertEqual(item.summaryHTML, "Only a summary.")
        // No <published>: falls back to <updated> 2025-06-05T10:00:00Z.
        XCTAssertEqual(item.publishedAt, Date(timeIntervalSince1970: 1_749_117_600))
    }

    func testAtomXHTMLContentReconstructsMarkup() throws {
        let feed = try parse(Fixtures.atomXHTMLContent)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(
            item.contentHTML,
            #"<div xmlns="http://www.w3.org/1999/xhtml">Hello <b>world</b> &amp; more<br/>done</div>"#
        )
        XCTAssertEqual(item.summaryHTML, "Plain summary.")
        XCTAssertEqual(item.title, "Inline Markup")
    }

    // MARK: - Errors

    func testHTMLDocumentThrowsNotAFeed() {
        XCTAssertThrowsError(try parse(Fixtures.notAFeedHTML)) { error in
            guard case FeedParseError.notAFeed = error else {
                return XCTFail("expected notAFeed, got \(error)")
            }
        }
    }

    func testMalformedXMLThrowsMalformed() {
        XCTAssertThrowsError(try parse(Fixtures.malformedXML)) { error in
            guard case FeedParseError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }
}
