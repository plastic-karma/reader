//
//  MailHeaderDecodingTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class MailHeaderDecodingTests: XCTestCase {

    // MARK: - decodedHeader

    func testPlainHeaderPassesThroughUnchanged() {
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("Money Stuff: Plain ASCII"),
            "Money Stuff: Plain ASCII"
        )
        XCTAssertEqual(MailHeaderDecoding.decodedHeader(""), "")
    }

    func testBEncodedUTF8Word() {
        // base64("Hello, World") == "SGVsbG8sIFdvcmxk"
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?UTF-8?B?SGVsbG8sIFdvcmxk?="),
            "Hello, World"
        )
    }

    func testQEncodedLatin1WordWithUnderscoreSpaces() {
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?ISO-8859-1?Q?Caf=E9_au_lait?="),
            "Café au lait"
        )
    }

    func testLowercaseEncodingLetterAndMixedText() {
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("Fwd: =?utf-8?q?R=C3=A9sum=C3=A9?= attached"),
            "Fwd: Résumé attached"
        )
    }

    func testWhitespaceBetweenAdjacentEncodedWordsIsDropped() {
        // base64("Hel") == "SGVs", base64("lo") == "bG8="
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?UTF-8?B?SGVs?= =?UTF-8?B?bG8=?="),
            "Hello"
        )
    }

    func testWhitespaceBeforePlainTextIsKept() {
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?UTF-8?B?SGVsbG8=?= there"),
            "Hello there"
        )
    }

    func testUnpaddedBase64IsTolerated() {
        // base64("lo") without padding.
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?UTF-8?B?bG8?="),
            "lo"
        )
    }

    func testUnknownCharsetFallsBackToUTF8WhenValid() {
        // "Hello" is valid UTF-8, so an unknown charset still decodes.
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("=?X-BOGUS?B?SGVsbG8=?="),
            "Hello"
        )
    }

    func testUndecodableTokenPassesThroughVerbatim() {
        // base64("////") decodes to 0xFF 0xFF 0xFF — invalid UTF-8, unknown charset.
        let token = "=?X-BOGUS?B?////?="
        XCTAssertEqual(MailHeaderDecoding.decodedHeader(token), token)
    }

    func testMalformedQEscapePassesThroughVerbatim() {
        let token = "=?UTF-8?Q?bad=ZZescape?="
        XCTAssertEqual(MailHeaderDecoding.decodedHeader(token), token)
    }

    func testGapAfterUndecodableTokenIsKept() {
        let bogus = "=?X-BOGUS?B?////?="
        XCTAssertEqual(
            MailHeaderDecoding.decodedHeader("\(bogus) =?UTF-8?B?SGVsbG8=?="),
            "\(bogus) Hello"
        )
    }

    // MARK: - displayName

    func testDisplayNameFromNameAndAddress() {
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: "Ben Thompson <ben@stratechery.com>"),
            "Ben Thompson"
        )
    }

    func testDisplayNameStripsQuotesAndEscapes() {
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: #""Levine, Matt" <m@bloomberg.net>"#),
            "Levine, Matt"
        )
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: #""The \"Daily\"" <d@news.com>"#),
            #"The "Daily""#
        )
    }

    func testDisplayNameDecodesEncodedWords() {
        // base64("José") == "Sm9zw6k="
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: "=?UTF-8?B?Sm9zw6k=?= <j@example.com>"),
            "José"
        )
    }

    func testBareAddressReturnsAddress() {
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: "money@bloomberg.net"),
            "money@bloomberg.net"
        )
    }

    func testAngleOnlyHeaderReturnsAddress() {
        XCTAssertEqual(
            MailHeaderDecoding.displayName(fromHeader: "<ben@stratechery.com>"),
            "ben@stratechery.com"
        )
    }

    func testEmptyHeaderStaysEmpty() {
        XCTAssertEqual(MailHeaderDecoding.displayName(fromHeader: ""), "")
    }
}
