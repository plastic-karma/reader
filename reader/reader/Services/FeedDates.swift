//
//  FeedDates.swift
//  reader
//

import Foundation

/// Parses the date formats found in real-world feeds: RFC 822 variants
/// (RSS `pubDate`) and ISO 8601 (Atom `published`/`updated`).
nonisolated enum FeedDates {

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in rfc822Formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        for formatter in iso8601Formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    // DateFormatter is documented thread-safe for formatting/parsing, so caching shared instances is sound.
    nonisolated(unsafe) private static let rfc822Formatters: [DateFormatter] = {
        // "yy" parses a 4-digit year literally and applies the two-digit-year
        // pivot only to exactly-two-digit input, so the "yy" variants must come
        // before the "yyyy" fallbacks (which would read "02" as the year 2).
        let formats = [
            "EEE, dd MMM yy HH:mm:ss zzz",
            "EEE, dd MMM yy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm zzz",
            "EEE, dd MMM yy HH:mm Z",
            "dd MMM yy HH:mm:ss zzz",
            "dd MMM yy HH:mm:ss Z",
            "dd MMM yy HH:mm zzz",
            "dd MMM yy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm Z",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    // ISO8601DateFormatter is documented thread-safe, so caching shared instances is sound.
    nonisolated(unsafe) private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()
}
