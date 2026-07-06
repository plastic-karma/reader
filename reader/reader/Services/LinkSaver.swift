//
//  LinkSaver.swift
//  reader
//

import Foundation
import Observation
import SwiftData

/// Main-actor facade for saving links, mirroring RefreshScheduler: UI state
/// lives here, the work happens on the LinkArchiver model actor. Injected
/// from readerApp via .environment; the reading pane's context menu reaches
/// it with @Environment(LinkSaver.self).
@MainActor
@Observable
final class LinkSaver {

    /// Saves currently in flight. The placeholder rows appearing in the
    /// Saved view are the primary feedback; this exists for anything that
    /// wants a progress affordance.
    private(set) var activeSaveCount = 0

    private let archiver: LinkArchiver

    init(modelContainer: ModelContainer) {
        archiver = LinkArchiver(modelContainer: modelContainer)
        // Convert placeholders orphaned by a quit-mid-download into visible
        // failures, provably before any new save can be in flight.
        Task { [archiver] in
            await archiver.markAbandonedSaves()
        }
    }

    /// Fire-and-forget: returns immediately; the placeholder article appears
    /// in the Saved view via @Query, results and errors land on the article
    /// itself (contentHTML / downloadError / downloadedAt). Safe to call with
    /// any URL (non-http(s) is a no-op) and repeatedly with the same URL
    /// (retry / snapshot refresh — the row updates in place).
    func save(_ url: URL) {
        Task {
            activeSaveCount += 1
            defer { activeSaveCount -= 1 }
            await archiver.save(url)
        }
    }
}
