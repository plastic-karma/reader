//
//  EditionContext.swift
//  reader
//

import Foundation
import Observation
import SwiftData

/// Which lens the sidebar shows: everything (today's behavior) or one
/// edition at a time.
nonisolated enum ViewMode: String {
    case global
    case editions
}

/// Which edition the edition-mode list shows. `.latest` is sticky
/// follow-newest — a publish auto-advances the view; `.specific` pins an
/// older edition for back-catalog reading.
nonisolated enum EditionSelection: Hashable {
    case latest
    case specific(PersistentIdentifier)
}

/// Cross-scene edition-mode UI state: the Global/Editions mode (persisted)
/// and the edition selection (deliberately per-launch). Lives in the
/// environment like LinkSaver, so ContentView and the menu-bar commands
/// share one instance.
@MainActor
@Observable
final class EditionContext {

    static let modeDefaultsKey = "viewMode"

    var mode: ViewMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        }
    }

    /// Deliberately not persisted: every launch opens on the latest edition.
    var selection: EditionSelection = .latest

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        mode = raw.flatMap(ViewMode.init(rawValue:)) ?? .global
    }

    /// The edition the selection resolves to. Input must be newest-first.
    /// `.latest` and a stale `.specific` (edition since deleted) both
    /// resolve to the newest; nil only when no editions exist.
    func resolve(from editionsNewestFirst: [Edition]) -> Edition? {
        switch selection {
        case .latest:
            return editionsNewestFirst.first
        case .specific(let id):
            return editionsNewestFirst.first { $0.persistentModelID == id }
                ?? editionsNewestFirst.first
        }
    }

    /// Fetch-based resolve for the menu-bar commands, which have no @Query.
    func resolveActiveEdition(in context: ModelContext) -> Edition? {
        resolve(from: editionsNewestFirst(in: context))
    }

    /// ⌘[ — move to the next-older edition; no-op at the oldest.
    func selectOlder(in context: ModelContext) {
        let editions = editionsNewestFirst(in: context)
        guard let current = resolve(from: editions),
              let index = editions.firstIndex(where: { $0 === current }),
              index + 1 < editions.count
        else { return }
        selection = .specific(editions[index + 1].persistentModelID)
    }

    /// ⌘] — move to the next-newer edition; landing on the newest re-arms
    /// follow-latest. No-op when already on the newest.
    func selectNewer(in context: ModelContext) {
        let editions = editionsNewestFirst(in: context)
        guard let current = resolve(from: editions),
              let index = editions.firstIndex(where: { $0 === current }),
              index > 0
        else { return }
        selection = index - 1 == 0
            ? .latest
            : .specific(editions[index - 1].persistentModelID)
    }

    private func editionsNewestFirst(in context: ModelContext) -> [Edition] {
        let descriptor = FetchDescriptor<Edition>(
            sortBy: [SortDescriptor(\.number, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
