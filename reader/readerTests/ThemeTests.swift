//
//  ThemeTests.swift
//  readerTests
//

import AppKit
import XCTest
@testable import reader

final class ThemeTests: XCTestCase {

    /// The reading face ships in the app bundle (tests are app-hosted, so
    /// Bundle.main is reader.app) — if the synchronized-folder resource
    /// pipeline ever drops the Fonts directory, this fails before a user
    /// sees Georgia.
    func testLiterataResourcesAreBundled() {
        for name in ["Literata", "Literata-Italic"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            XCTAssertNotNil(url, "\(name).ttf missing from the app bundle")
        }
    }

    /// readerApp.init registered the face for the process before any test
    /// runs, so the family must be visible to the font manager.
    func testLiterataIsRegistered() {
        XCTAssertTrue(
            NSFontManager.shared.availableFontFamilies.contains("Literata"),
            "Literata did not register — native serif text is falling back"
        )
    }

    func testCompactAge() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(now.compactAge(relativeTo: now), "now")
        XCTAssertEqual(now.addingTimeInterval(-30).compactAge(relativeTo: now), "now")
        XCTAssertEqual(now.addingTimeInterval(-5 * 60).compactAge(relativeTo: now), "5m")
        XCTAssertEqual(now.addingTimeInterval(-2 * 3600).compactAge(relativeTo: now), "2h")
        XCTAssertEqual(now.addingTimeInterval(-26 * 3600).compactAge(relativeTo: now), "1d")
        XCTAssertEqual(now.addingTimeInterval(-9 * 86400).compactAge(relativeTo: now), "1w")
        XCTAssertEqual(now.addingTimeInterval(-40 * 86400).compactAge(relativeTo: now), "1mo")
        XCTAssertEqual(now.addingTimeInterval(-800 * 86400).compactAge(relativeTo: now), "2y")
        // Future dates (clock skew, bad feed data) clamp to "now".
        XCTAssertEqual(now.addingTimeInterval(3600).compactAge(relativeTo: now), "now")
    }
}
