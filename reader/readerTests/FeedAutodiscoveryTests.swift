//
//  FeedAutodiscoveryTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class FeedAutodiscoveryTests: XCTestCase {

    private let base = URL(string: "https://blog.example.com/posts/index.html")!

    func testFindsRSSAndAtomAlternatesInDocumentOrder() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="https://blog.example.com/feed.xml">
        <link rel="alternate" type="application/atom+xml" href="https://blog.example.com/atom.xml">
        <link rel="icon" href="/favicon.ico">
        </head><body></body></html>
        """
        XCTAssertEqual(
            FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base),
            [
                URL(string: "https://blog.example.com/feed.xml")!,
                URL(string: "https://blog.example.com/atom.xml")!,
            ]
        )
    }

    func testResolvesRelativeHrefAgainstBase() {
        let html = #"<link rel="alternate" type="application/rss+xml" href="/feed.xml">"#
        XCTAssertEqual(
            FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base),
            [URL(string: "https://blog.example.com/feed.xml")!]
        )
    }

    func testAttributeOrderAndCaseAreIrrelevant() {
        let html = #"<LINK HREF="feed.xml" TYPE="APPLICATION/RSS+XML" REL="ALTERNATE">"#
        XCTAssertEqual(
            FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base),
            [URL(string: "https://blog.example.com/posts/feed.xml")!]
        )
    }

    func testIgnoresNonFeedAndNonAlternateLinks() {
        let html = """
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="text/html" href="/en/">
        <link rel="preload" type="application/rss+xml" href="/feed.xml">
        <link rel="alternate" href="/no-type.xml">
        """
        XCTAssertEqual(FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base), [])
    }

    func testHandlesMIMEParametersAndWhitespaceRelTokens() {
        // rel tokens are separated by any ASCII whitespace; type may carry
        // parameters — both are spec-legal and must still match.
        let html = "<link rel=\"alternate\tnofollow\" type=\"application/rss+xml; charset=utf-8\" href=\"/feed.xml\">"
        XCTAssertEqual(
            FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base),
            [URL(string: "https://blog.example.com/feed.xml")!]
        )
    }

    func testDeduplicatesRepeatedHrefs() {
        let html = """
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        """
        XCTAssertEqual(
            FeedAutodiscovery.feedURLs(inHTML: html, baseURL: base).count,
            1
        )
    }
}
