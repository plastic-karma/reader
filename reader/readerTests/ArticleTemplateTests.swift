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
        // only via the local scheme, styles only inline.
        let csp = ArticleTemplate.contentSecurityPolicy
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("img-src reader-asset:"))
        XCTAssertTrue(csp.contains("style-src 'unsafe-inline'"))
        XCTAssertFalse(csp.contains("script-src"))
    }
}
