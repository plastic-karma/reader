//
//  RefreshScheduler.swift
//  reader
//

import Foundation
import Observation
import SwiftData

/// Drives periodic refreshes and edition boundaries while the app runs,
/// plus manual ⌘R / "Create Edition Now". UI state (spinner, interval and
/// cadence settings, next-edition date) lives here on the main actor; the
/// actual work happens on the RefreshEngine model actor.
@MainActor
@Observable
final class RefreshScheduler {

    static let intervalDefaultsKey = "refreshIntervalMinutes"
    static let editionFrequencyDefaultsKey = "editionFrequency"
    static let editionTimeDefaultsKey = "editionTimeOfDayMinutes"
    static let editionWeekdayDefaultsKey = "editionWeekday"

    private(set) var isRefreshing = false
    /// Coalesces double-fired "Create Edition Now" while the engine works;
    /// also the UI's disabled state for the action.
    private(set) var isCreatingEdition = false
    /// The upcoming cadence boundary, recomputed on every loop iteration —
    /// feeds the edition-mode "next edition …" caption. nil = manual cadence.
    private(set) var nextEditionDate: Date?

    /// Minutes between automatic refreshes; 0 or less means manual-only.
    var intervalMinutes: Int {
        didSet {
            guard intervalMinutes != oldValue else { return }
            UserDefaults.standard.set(intervalMinutes, forKey: Self.intervalDefaultsKey)
            // Mid-refresh the running loop reads the new value before its
            // next sleep; restarting now would cancel in-flight work.
            // Rescheduling must not itself refresh: picking "Manually" means
            // stop, not "refresh once more".
            if !isRefreshing {
                restartLoop(refreshFirst: false)
            }
        }
    }

    // Edition cadence mirrors — the same didSet contract as intervalMinutes.
    // Raw values are persisted as set; EditionCadence.make clamps at
    // assembly, so stale or hand-edited defaults can never crash the loop.

    var editionFrequency: EditionCadence.Frequency {
        didSet {
            guard editionFrequency != oldValue else { return }
            UserDefaults.standard.set(
                editionFrequency.rawValue, forKey: Self.editionFrequencyDefaultsKey)
            if !isRefreshing {
                restartLoop(refreshFirst: false)
            }
        }
    }

    var editionTimeOfDayMinutes: Int {
        didSet {
            guard editionTimeOfDayMinutes != oldValue else { return }
            UserDefaults.standard.set(
                editionTimeOfDayMinutes, forKey: Self.editionTimeDefaultsKey)
            if !isRefreshing {
                restartLoop(refreshFirst: false)
            }
        }
    }

    var editionWeekday: Int {
        didSet {
            guard editionWeekday != oldValue else { return }
            UserDefaults.standard.set(editionWeekday, forKey: Self.editionWeekdayDefaultsKey)
            if !isRefreshing {
                restartLoop(refreshFirst: false)
            }
        }
    }

    /// The three mirrors assembled (and clamped) for the engine.
    private var editionCadence: EditionCadence {
        EditionCadence.make(
            frequencyRaw: editionFrequency.rawValue,
            minutesOfDay: editionTimeOfDayMinutes,
            weekday: editionWeekday
        )
    }

    private let engine: RefreshEngine
    private var loopTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        engine = RefreshEngine(modelContainer: modelContainer)
        let stored = UserDefaults.standard.object(forKey: Self.intervalDefaultsKey) as? Int
        intervalMinutes = stored ?? 30
        let cadence = EditionCadence.make(
            frequencyRaw: UserDefaults.standard.string(forKey: Self.editionFrequencyDefaultsKey),
            minutesOfDay: UserDefaults.standard.object(forKey: Self.editionTimeDefaultsKey) as? Int,
            weekday: UserDefaults.standard.object(forKey: Self.editionWeekdayDefaultsKey) as? Int
        )
        editionFrequency = cadence.frequency
        editionTimeOfDayMinutes = cadence.minutesOfDay
        editionWeekday = cadence.weekday
    }

    /// Idempotent; called when the main scene appears. Refreshes immediately,
    /// then repeats every `intervalMinutes` / wakes at edition boundaries.
    func start() {
        guard loopTask == nil else { return }
        restartLoop()
    }

    /// Manual refresh. Coalesces: a click during an in-flight refresh is a no-op.
    func refreshNow() {
        guard !isRefreshing else { return }
        restartLoop()
    }

    /// Refresh a single feed immediately (e.g. right after adding it).
    func refreshFeed(_ id: PersistentIdentifier) {
        Task {
            await engine.refresh(feedID: id)
        }
    }

    /// Manual "Create Edition Now": batches everything currently on device —
    /// deliberately no refresh first ("to now" means what's here, and the
    /// button should feel instant). Publishes even when nothing is pending,
    /// mirroring the empty-boundary rule.
    func createEditionNow() {
        guard !isCreatingEdition else { return }
        isCreatingEdition = true
        Task {
            defer { isCreatingEdition = false }
            let now = Date.now
            await engine.publishEdition(scheduledFor: now, isManual: true, publishedAt: now)
            // A manual edition can only push boundaries later (the
            // every-2-days anchor), never earlier, so the sleeping loop is
            // merely early — but restart anyway so nextEditionDate reflects
            // the new anchor immediately rather than at the next wake.
            if !isRefreshing {
                restartLoop(refreshFirst: false)
            }
        }
    }

    private func restartLoop(refreshFirst: Bool = true) {
        loopTask?.cancel()
        loopTask = Task {
            var shouldRefresh = refreshFirst
            while !Task.isCancelled {
                if shouldRefresh {
                    await runOneRefresh()
                }
                // Sync-then-publish: the due check always runs AFTER any
                // refresh in this iteration — at launch (start → refresh
                // first) a catch-up edition therefore includes the freshly
                // synced articles.
                nextEditionDate = await engine.publishDueEditionIfNeeded(
                    cadence: editionCadence, now: .now, calendar: .current)

                let refreshDelay: TimeInterval? =
                    intervalMinutes > 0 ? TimeInterval(intervalMinutes * 60) : nil
                // Clamped ≥ 1 s: a boundary landing "now" must not hot-loop.
                let boundaryDelay: TimeInterval? =
                    nextEditionDate.map { max($0.timeIntervalSinceNow, 1) }
                // Manual refresh + manual cadence → nothing to wait for:
                // stop, exactly today's interval-0 behavior.
                guard let delay = [refreshDelay, boundaryDelay].compactMap({ $0 }).min() else {
                    break
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
                // Auto-refresh users refresh on every wake, so a boundary
                // wake publishes a maximally fresh edition; manual-refresh
                // users opted out of auto-fetching and just publish.
                shouldRefresh = intervalMinutes > 0
            }
        }
    }

    private func runOneRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await engine.refreshAll()
    }
}
