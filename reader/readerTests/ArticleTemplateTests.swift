//
//  ArticleTemplateTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class ArticleTemplateTests: XCTestCase {

    func testPageEmbedsContentAndCSP() {
        let page = ArticleTemplate.page(contentHTML: "<p>Hello</p>")
        XCTAssertTrue(page.contains("<p>Hello</p>"))
        XCTAssertTrue(page.contains("Content-Security-Policy"))
        XCTAssertTrue(page.contains(ArticleTemplate.contentSecurityPolicy))
    }

    func testCSPAllowsOnlyLocalAssetsAndInlineStyle() {
        // The offline-rendering guarantee: nothing loads by default, images
        // and the bundled reading face only via the local scheme, styles
        // only inline.
        let csp = ArticleTemplate.contentSecurityPolicy
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("img-src reader-asset:"))
        XCTAssertTrue(csp.contains("font-src reader-asset:"))
        XCTAssertTrue(csp.contains("style-src 'unsafe-inline'"))
        XCTAssertFalse(csp.contains("script-src"))
    }

    func testHeaderRendersTitleAndByline() {
        let page = ArticleTemplate.page(
            contentHTML: "<p>Body</p>",
            header: ArticleTemplate.Header(
                title: "Zen 6's L2",
                feedTitle: "Chips & Cheese",
                author: nil,
                date: "July 7, 2026"
            )
        )
        XCTAssertTrue(page.contains("Zen 6&#39;s L2"))
        XCTAssertTrue(page.contains("Chips &amp; Cheese"))
        XCTAssertTrue(page.contains("July 7, 2026"))
        // No author → exactly one separator span (feed · date).
        XCTAssertEqual(page.components(separatedBy: "class=\"reader-sep\"").count - 1, 1)
    }

    func testNoHeaderMeansNoHeaderMarkup() {
        let page = ArticleTemplate.page(contentHTML: "<p>Body</p>")
        XCTAssertFalse(page.contains("reader-head\""))
        XCTAssertTrue(page.contains("<p>Body</p>"))
    }

    func testEscapingNeutralizesMarkup() {
        let escaped = ArticleTemplate.escaped(#"<img src="x" onerror='y'> & more"#)
        XCTAssertFalse(escaped.contains("<"))
        XCTAssertFalse(escaped.contains("\""))
        XCTAssertEqual(
            escaped,
            "&lt;img src=&quot;x&quot; onerror=&#39;y&#39;&gt; &amp; more"
        )
    }
}
