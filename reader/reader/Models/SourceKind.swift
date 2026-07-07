//
//  SourceKind.swift
//  reader
//

import Foundation

/// Where a feed's content comes from. Stored as a raw string on `Feed.sourceKind`
/// so adding kinds later (Substack, IMAP newsletters) needs no schema migration.
nonisolated enum SourceKind: String, CaseIterable, Sendable {
    case rss
    /// The hidden singleton feed that holds user-saved page snapshots.
    case savedLinks
    /// A newsletter rule: articles pulled from the user's mailbox by
    /// sender (+ optional subject regex). One feed per rule.
    case newsletter
}
