//
//  GmailMessageParserTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class GmailMessageParserTests: XCTestCase {

    // MARK: - base64url

    func testBase64URLDecodesURLSafeAlphabet() {
        // "PHA-…" contains "-" where classic base64 has "+".
        let data = GmailMessageParser.data(base64URLEncoded: "PHA-aOlsbG8gbGF0aW48L3A-")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.first, UInt8(ascii: "<"))
    }

    func testBase64URLRepadsAllRemainders() {
        // 0 missing: "TWFu" ("Man"), 1 missing: "SGVsbG8" ("Hello"),
        // 2 missing: "_w" (0xFF).
        XCTAssertEqual(
            GmailMessageParser.data(base64URLEncoded: "TWFu"),
            Data("Man".utf8))
        XCTAssertEqual(
            GmailMessageParser.data(base64URLEncoded: "SGVsbG8"),
            Data("Hello".utf8))
        XCTAssertEqual(
            GmailMessageParser.data(base64URLEncoded: "_w"),
            Data([0xFF]))
    }

    func testBase64URLRejectsGarbage() {
        XCTAssertNil(GmailMessageParser.data(base64URLEncoded: "!!!"))
    }

    // MARK: - messages.list

    func testMessageListParsesIDsAndToken() throws {
        let page = try GmailMessageParser.messageList(
            from: Data(GmailFixtures.listPageOne.utf8))
        XCTAssertEqual(page.messages?.map(\.id), ["m1", "m2"])
        XCTAssertEqual(page.nextPageToken, "page2")
    }

    func testEmptyListPageHasNoMessagesKey() throws {
        let page = try GmailMessageParser.messageList(
            from: Data(GmailFixtures.listEmpty.utf8))
        XCTAssertNil(page.messages)
        XCTAssertNil(page.nextPageToken)
    }

    func testUndecodableJSONThrowsInvalidResponse() {
        XCTAssertThrowsError(
            try GmailMessageParser.messageList(from: Data("not json".utf8))
        ) { error in
            guard case MailProviderError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    // MARK: - metadata headers

    func testMetadataHeaderDecodesSubjectFromAndInternalDate() throws {
        let header = try GmailMessageParser.messageHeader(
            from: Data(GmailFixtures.metadataInbox.utf8))
        XCTAssertEqual(header.id, "m1")
        XCTAssertEqual(header.subject, "Café digest")
        XCTAssertEqual(header.from, "José <news@example.com>")
        XCTAssertTrue(header.isUnprocessed)
        let date = try XCTUnwrap(header.date)
        XCTAssertEqual(date.timeIntervalSince1970, 1_751_791_234.567, accuracy: 0.001)
    }

    func testHeaderLookupIsCaseInsensitiveAndArchivedIsProcessed() throws {
        let header = try GmailMessageParser.messageHeader(
            from: Data(GmailFixtures.metadataArchived.utf8))
        XCTAssertEqual(header.subject, "Archived one", "\"subject\" key must match Subject")
        XCTAssertEqual(header.from, "news@example.com")
        XCTAssertFalse(header.isUnprocessed)
    }

    func testMissingInternalDateFallsBackToDateHeader() throws {
        let header = try GmailMessageParser.messageHeader(
            from: Data(GmailFixtures.metadataDateHeaderOnly.utf8))
        let date = try XCTUnwrap(header.date)
        XCTAssertEqual(date.timeIntervalSince1970, 1_751_788_834, accuracy: 1)
    }

    // MARK: - full message part walk

    func testMultipartAlternativePrefersHTMLAndKeepsPlain() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullMultipartAlternative.utf8))
        let html = try XCTUnwrap(message.bodyHTML)
        XCTAssertTrue(html.hasPrefix("<h1>Money Stuff</h1>"))
        XCTAssertTrue(html.contains("Café &amp; markets — onward!"))
        let plain = try XCTUnwrap(message.bodyText)
        XCTAssertTrue(plain.hasSuffix("Line two."))
    }

    func testNestedRelatedHTMLLeafIsFound() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullNestedRelated.utf8))
        XCTAssertEqual(message.bodyHTML, "<p>Nested <b>rich</b> body</p>")
        XCTAssertEqual(message.bodyText, "Hello plain world.\n\nSecond paragraph & <more>.")
    }

    func testPlainOnlyMessageHasNoHTMLBody() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullPlainOnly.utf8))
        XCTAssertNil(message.bodyHTML)
        XCTAssertEqual(message.bodyText, "Hello plain world.\n\nSecond paragraph & <more>.")
    }

    func testLatin1CharsetDecodesThroughQuotedContentType() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullLatin1.utf8))
        XCTAssertEqual(message.bodyHTML, "<p>héllo latin</p>")
    }

    // MARK: - parsedItem mapping

    func testParsedItemMapsAllFields() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullMultipartAlternative.utf8))
        let item = GmailMessageParser.parsedItem(from: message)

        XCTAssertEqual(item.stableID, "full1")
        XCTAssertEqual(item.title, "Café digest")
        XCTAssertEqual(item.author, "Matt Levine")
        XCTAssertEqual(item.link, URL(string: "https://mail.google.com/mail/#all/full1"))
        XCTAssertEqual(
            try XCTUnwrap(item.publishedAt).timeIntervalSince1970,
            1_751_791_234.567, accuracy: 0.001)
        XCTAssertNil(item.summaryHTML, "Engine derives the excerpt from content")
        XCTAssertEqual(item.contentHTML, message.bodyHTML)
    }

    func testParsedItemPlainOnlyFallsBackToEscapedParagraphs() throws {
        let message = try GmailMessageParser.mailMessage(
            from: Data(GmailFixtures.fullPlainOnly.utf8))
        let item = GmailMessageParser.parsedItem(from: message)

        XCTAssertEqual(item.title, "(no subject)")
        XCTAssertEqual(
            item.contentHTML,
            "<p>Hello plain world.</p><p>Second paragraph &amp; &lt;more&gt;.</p>")
    }

    func testOversizeHTMLFallsBackToPlainThenStub() {
        let header = MailMessageHeader(
            id: "big1", subject: "Big", from: "b@x.com", date: nil, isUnprocessed: true)
        let oversized = String(repeating: "x", count: 64)

        let withPlain = GmailMessageParser.parsedItem(
            from: MailMessage(header: header, bodyHTML: oversized, bodyText: "tiny"),
            maxBodyBytes: 32)
        XCTAssertEqual(withPlain.contentHTML, "<p>tiny</p>")

        let withoutAnything = GmailMessageParser.parsedItem(
            from: MailMessage(header: header, bodyHTML: oversized, bodyText: nil),
            maxBodyBytes: 32)
        XCTAssertTrue(withoutAnything.contentHTML.contains("Open in Gmail"))
        XCTAssertTrue(withoutAnything.contentHTML.contains("#all/big1"))
    }

    // MARK: - htmlFromPlainText

    func testPlainTextCRLFAndSingleNewlines() {
        XCTAssertEqual(
            GmailMessageParser.htmlFromPlainText("A\r\n\r\nB"),
            "<p>A</p><p>B</p>")
        XCTAssertEqual(
            GmailMessageParser.htmlFromPlainText("line one\nline two"),
            "<p>line one<br>line two</p>")
        XCTAssertEqual(GmailMessageParser.htmlFromPlainText(""), "<p></p>")
    }
}
