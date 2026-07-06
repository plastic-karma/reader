//
//  PageFetcherTests.swift
//  readerTests
//

import XCTest
@testable import reader

/// Charset decode chain only — `fetch` itself stays untested, like
/// FeedFetcher's network path.
final class PageFetcherTests: XCTestCase {

    func testDecodeHonorsResponseTextEncodingName() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in ISO-8859-1
        XCTAssertEqual(
            PageFetcher.decodeHTML(data: latin1, textEncodingName: "iso-8859-1"),
            "café"
        )
    }

    func testDecodeFallsBackToMetaCharsetTag() {
        let html = #"<html><head><meta charset="iso-8859-1"></head><body>caf\#u{E9}</body></html>"#
        var data = Data(html.unicodeScalars.map { UInt8($0.value < 256 ? $0.value : 0x3F) })
        XCTAssertEqual(PageFetcher.metaCharsetName(in: data), "iso-8859-1")
        let decoded = PageFetcher.decodeHTML(data: data, textEncodingName: nil)
        XCTAssertTrue(decoded.contains("café"))
        // The http-equiv form is recognized too.
        let httpEquiv = #"<meta http-equiv="content-type" content="text/html; charset=windows-1252">"#
        data = Data(httpEquiv.utf8)
        XCTAssertEqual(PageFetcher.metaCharsetName(in: data), "windows-1252")
    }

    func testDecodeFallsBackToStrictThenLossyUTF8() {
        // Valid UTF-8 without any declaration decodes exactly.
        XCTAssertEqual(
            PageFetcher.decodeHTML(data: Data("héllo".utf8), textEncodingName: nil),
            "héllo"
        )
        // Garbage bytes never fail — replacement characters at worst.
        let garbage = Data([0x68, 0x69, 0xFF, 0xFE, 0xFD])
        let decoded = PageFetcher.decodeHTML(data: garbage, textEncodingName: nil)
        XCTAssertTrue(decoded.hasPrefix("hi"))
        XCTAssertTrue(decoded.contains("\u{FFFD}"))
    }

    func testUnknownDeclaredEncodingFallsThroughChain() {
        let utf8 = Data("plain".utf8)
        XCTAssertEqual(
            PageFetcher.decodeHTML(data: utf8, textEncodingName: "not-a-real-charset"),
            "plain"
        )
    }

    func testMetaCharsetScanIgnoresDeclarationsBeyondPrefix() {
        let padding = String(repeating: "<!-- pad -->", count: 200)  // > 2048 bytes
        let html = "<html><head>\(padding)<meta charset=\"iso-8859-1\"></head></html>"
        XCTAssertNil(PageFetcher.metaCharsetName(in: Data(html.utf8)))
    }
}
