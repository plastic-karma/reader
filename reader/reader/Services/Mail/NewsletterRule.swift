//
//  NewsletterRule.swift
//  reader
//

import Foundation

/// One newsletter subscription rule: which sender to pull from the mailbox
/// and, optionally, which subjects qualify. Assembled from the backing
/// Feed's newsletter fields. Provider-agnostic: sender filtering is done by
/// the mail provider (Gmail `from:` today, IMAP `SEARCH FROM` later), but
/// subject matching always runs client-side through this type so every
/// provider behaves identically.
nonisolated struct NewsletterRule: Sendable, Equatable {
    /// Provider-native sender operand (an address or domain).
    let sender: String
    /// Regex source applied to the decoded Subject; nil means every message
    /// from the sender matches.
    let subjectPattern: String?
    /// Archive + mark read in the mailbox after a message is ingested.
    let archiveAfterIngest: Bool

    enum PatternError: Error, LocalizedError, Equatable {
        case invalid(reason: String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason):
                return "Invalid subject pattern: \(reason)"
            }
        }
    }

    /// Compiles a subject pattern for repeated matching. nil/blank patterns
    /// compile to nil, which `matches` treats as match-everything.
    /// Case-insensitive and unanchored: "payments" matches
    /// "Re: Payments update"; authors can still anchor with ^ and $.
    static func compiledSubjectRegex(from pattern: String?) throws -> NSRegularExpression? {
        guard let pattern,
              !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw PatternError.invalid(reason: (error as NSError).localizedDescription)
        }
    }

    /// Whether a message subject qualifies under a regex from
    /// `compiledSubjectRegex`. A nil regex admits everything.
    static func matches(subject: String, compiled: NSRegularExpression?) -> Bool {
        guard let compiled else { return true }
        let range = NSRange(subject.startIndex..., in: subject)
        return compiled.firstMatch(in: subject, options: [], range: range) != nil
    }
}
