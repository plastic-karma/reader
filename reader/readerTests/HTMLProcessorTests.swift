//
//  HTMLProcessorTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class HTMLProcessorTests: XCTestCase {

    // MARK: - sanitize

    func testSanitizeRemovesScriptIncludingContent() {
        let html = #"""
        <p>Before</p>
        <script type="text/javascript">
            if (1 > 0) { alert("xss"); }
        </script>
        <p>After</p>
        """#
        let sanitized = HTMLProcessor.sanitize(html: html)
        XCTAssertFalse(sanitized.lowercased().contains("script"))
        XCTAssertFalse(sanitized.contains("alert"))
        XCTAssertTrue(sanitized.contains("<p>Before</p>"))
        XCTAssertTrue(sanitized.contains("<p>After</p>"))
    }

    func testSanitizeRemovesSelfClosingScript() {
        let html = #"<p>A</p><script src="https://evil.example/x.js"/><p>B</p>"#
        XCTAssertEqual(HTMLProcessor.sanitize(html: html), "<p>A</p><p>B</p>")
    }

    func testSanitizeRemovesIframeIncludingContent() {
        let html = #"<div>Keep<iframe src="https://tracker.example/embed">fallback</iframe>ing</div>"#
        XCTAssertEqual(HTMLProcessor.sanitize(html: html), "<div>Keeping</div>")
    }

    func testSanitizeRemovesObjectFormAndEmbed() {
        let html = #"<p>Stay</p><object data="movie.swf">alt text</object><form action="/f"><input type="text"></form><embed src="a.mov">"#
        XCTAssertEqual(HTMLProcessor.sanitize(html: html), "<p>Stay</p>")
    }

    func testSanitizeStripsEventHandlerAttributesButKeepsTags() {
        let html = #"<img src="a.png" onerror="alert(1)"><a href="/x" onclick='steal()'>link</a><div onmouseover=hover()>text</div>"#
        XCTAssertEqual(
            HTMLProcessor.sanitize(html: html),
            #"<img src="a.png"><a href="/x">link</a><div>text</div>"#
        )
    }

    func testSanitizeStripsSrcsetAndSizesButKeepsSrc() {
        let html = #"<img src="https://cdn.example.com/a.png" srcset="a-480.png 480w, a-800.png 800w" sizes="(max-width: 600px) 480px, 800px" alt="pic">"#
        XCTAssertEqual(
            HTMLProcessor.sanitize(html: html),
            #"<img src="https://cdn.example.com/a.png" alt="pic">"#
        )
    }

    // MARK: - extractImageURLs

    func testExtractImageURLsAbsolute() {
        let html = #"<p>text</p><img src="https://cdn.example.com/a.png" alt=""><img src="http://cdn.example.com/b.jpg">"#
        XCTAssertEqual(
            HTMLProcessor.extractImageURLs(html: html, baseURL: nil),
            [
                URL(string: "https://cdn.example.com/a.png")!,
                URL(string: "http://cdn.example.com/b.jpg")!,
            ]
        )
    }

    func testExtractImageURLsResolvesRelativeAgainstBase() {
        let base = URL(string: "https://blog.example.com/posts/hello/")!
        let html = #"<img src="images/inline.png"><img src="/banner.jpg">"#
        XCTAssertEqual(
            HTMLProcessor.extractImageURLs(html: html, baseURL: base),
            [
                URL(string: "https://blog.example.com/posts/hello/images/inline.png")!,
                URL(string: "https://blog.example.com/banner.jpg")!,
            ]
        )
    }

    func testExtractImageURLsPrefersDataSrcOverSrc() {
        let html = #"<img src="https://cdn.example.com/placeholder.gif" data-src="https://cdn.example.com/real.png">"#
        XCTAssertEqual(
            HTMLProcessor.extractImageURLs(html: html, baseURL: nil),
            [URL(string: "https://cdn.example.com/real.png")!]
        )
    }

    func testExtractImageURLsExcludesNonHTTPSchemesAndDeduplicates() {
        let html = #"""
        <img src="data:image/gif;base64,R0lGOD">
        <img src="file:///etc/passwd">
        <img src="relative/without-base.png">
        <img src="https://cdn.example.com/a.png">
        <img data-src="https://cdn.example.com/a.png" src="https://cdn.example.com/thumb.png">
        """#
        XCTAssertEqual(
            HTMLProcessor.extractImageURLs(html: html, baseURL: nil),
            [URL(string: "https://cdn.example.com/a.png")!]
        )
    }

    // MARK: - rewriteImageSources

    func testRewriteImageSourcesMapsImgAndDropsLazyAttributes() {
        let html = #"<p>Intro</p><img data-src="https://cdn.example.com/real.png" src="spacer.gif" srcset="real-2x.png 2x" sizes="100vw" alt="hero">"#
        let mapping = ["https://cdn.example.com/real.png": "reader-asset://abc123.png"]
        XCTAssertEqual(
            HTMLProcessor.rewriteImageSources(html: html, baseURL: nil, mapping: mapping),
            #"<p>Intro</p><img src="reader-asset://abc123.png" alt="hero">"#
        )
    }

    func testRewriteImageSourcesResolvesRelativeSourceAgainstBase() {
        let base = URL(string: "https://blog.example.com/posts/hello/")!
        let html = #"<img src="images/pic.png">"#
        let mapping = ["https://blog.example.com/posts/hello/images/pic.png": "reader-asset://pic.png"]
        XCTAssertEqual(
            HTMLProcessor.rewriteImageSources(html: html, baseURL: base, mapping: mapping),
            #"<img src="reader-asset://pic.png">"#
        )
    }

    func testRewriteImageSourcesLeavesUnmappedImagesUntouched() {
        let html = #"<img src="https://cdn.example.com/unmapped.png" srcset="u-2x.png 2x"><p>text</p>"#
        XCTAssertEqual(
            HTMLProcessor.rewriteImageSources(
                html: html,
                baseURL: nil,
                mapping: ["https://cdn.example.com/other.png": "reader-asset://o.png"]
            ),
            html
        )
    }

    // MARK: - decodeHTMLEntities

    func testDecodeHTMLEntitiesNamed() {
        XCTAssertEqual(
            HTMLProcessor.decodeHTMLEntities("Fish &amp; Chips &mdash; &ldquo;tasty&rdquo;&hellip;"),
            "Fish & Chips \u{2014} \u{201C}tasty\u{201D}\u{2026}"
        )
        XCTAssertEqual(
            HTMLProcessor.decodeHTMLEntities("&lt;em&gt;&nbsp;&copy;"),
            "<em>\u{00A0}\u{00A9}"
        )
    }

    func testDecodeHTMLEntitiesNumericDecimalAndHex() {
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("It&#8217;s"), "It\u{2019}s")
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("It&#x2019;s"), "It\u{2019}s")
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&#x1F600;"), "\u{1F600}")
    }

    func testDecodeHTMLEntitiesDecodesAmpersandLast() {
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&amp;lt;"), "&lt;")
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&amp;#8217;"), "&#8217;")
    }

    func testDecodeHTMLEntitiesSinglePassNeverReDecodes() {
        // Per the HTML spec entity decoding is one left-to-right pass:
        // a decoded "&" must not combine with following text and decode again.
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&#38;amp;"), "&amp;")
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&#38;lt;"), "&lt;")
        XCTAssertEqual(HTMLProcessor.decodeHTMLEntities("&unknown;"), "&unknown;")
    }

    // MARK: - plainTextExcerpt

    func testPlainTextExcerptStripsTagsAndCollapsesWhitespace() {
        let html = "<h1>Title</h1>\n<p>First    paragraph.</p>\n<p>Second&nbsp;&amp;\n\nlast.</p>"
        XCTAssertEqual(
            HTMLProcessor.plainTextExcerpt(from: html, maxLength: 200),
            "Title First paragraph. Second & last."
        )
    }

    func testPlainTextExcerptTruncatesWithEllipsisWithinBudget() {
        let result = HTMLProcessor.plainTextExcerpt(
            from: "<p>The quick brown fox jumps over the lazy dog</p>",
            maxLength: 12
        )
        XCTAssertEqual(result, "The quick b\u{2026}")
        XCTAssertEqual(result.count, 12)
    }

    func testPlainTextExcerptReturnsShortInputUnchanged() {
        XCTAssertEqual(HTMLProcessor.plainTextExcerpt(from: "<p>Short note</p>", maxLength: 50), "Short note")
        XCTAssertEqual(HTMLProcessor.plainTextExcerpt(from: "Exact", maxLength: 5), "Exact")
    }
}
