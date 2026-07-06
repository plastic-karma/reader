//
//  FeedDatesTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class FeedDatesTests: XCTestCase {

    // MARK: RFC 822 (RSS pubDate)

    func testParsesRFC822WithWeekdayAndGMT() throws {
        let date = try XCTUnwrap(FeedDates.parse("Tue, 10 Jun 2003 04:00:00 GMT"))
        XCTAssertEqual(date, utcDate(2003, 6, 10, 4, 0, 0))
    }

    func testParsesRFC822WithoutWeekday() throws {
        let date = try XCTUnwrap(FeedDates.parse("10 Jun 2003 04:00:00 GMT"))
        XCTAssertEqual(date, utcDate(2003, 6, 10, 4, 0, 0))
    }

    func testParsesRFC822WithNumericZoneOffset() throws {
        let date = try XCTUnwrap(FeedDates.parse("Thu, 05 Oct 2023 08:30:00 +0200"))
        XCTAssertEqual(date, utcDate(2023, 10, 5, 6, 30, 0))
    }

    func testParsesRFC822WithTwoDigitYear() throws {
        let date = try XCTUnwrap(FeedDates.parse("Sat, 05 Oct 02 08:30:00 GMT"))
        XCTAssertEqual(date, utcDate(2002, 10, 5, 8, 30, 0))
    }

    func testParsesRFC822WithoutSeconds() throws {
        let date = try XCTUnwrap(FeedDates.parse("Tue, 10 Jun 2003 04:00 GMT"))
        XCTAssertEqual(date, utcDate(2003, 6, 10, 4, 0, 0))
    }

    // MARK: ISO 8601 (Atom published/updated)

    func testParsesISO8601() throws {
        let date = try XCTUnwrap(FeedDates.parse("2023-10-05T08:30:00Z"))
        XCTAssertEqual(date, utcDate(2023, 10, 5, 8, 30, 0))
    }

    func testParsesISO8601WithFractionalSeconds() throws {
        let date = try XCTUnwrap(FeedDates.parse("2023-10-05T08:30:00.500Z"))
        XCTAssertEqual(
            date.timeIntervalSince1970,
            utcDate(2023, 10, 5, 8, 30, 0).timeIntervalSince1970 + 0.5,
            accuracy: 0.001
        )
    }

    func testParsesISO8601WithNumericOffset() throws {
        let date = try XCTUnwrap(FeedDates.parse("2023-10-05T08:30:00+02:00"))
        XCTAssertEqual(date, utcDate(2023, 10, 5, 6, 30, 0))
    }

    // MARK: Edge cases

    func testTrimsSurroundingWhitespace() throws {
        let date = try XCTUnwrap(FeedDates.parse("  Tue, 10 Jun 2003 04:00:00 GMT\n"))
        XCTAssertEqual(date, utcDate(2003, 6, 10, 4, 0, 0))
    }

    func testGarbageStringReturnsNil() {
        XCTAssertNil(FeedDates.parse("not a date"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(FeedDates.parse(""))
        XCTAssertNil(FeedDates.parse("   "))
    }

    // MARK: Helpers

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!
    }
}
