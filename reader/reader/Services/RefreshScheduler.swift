//
//  RefreshScheduler.swift
//  reader
//

import Foundation
import Observation
import SwiftData

/// Drives periodic refreshes while the app runs, plus manual ⌘R. UI state
/// (spinner, interval setting) lives here on the main actor; the actual work
/// happens on the RefreshEngine model actor.
@MainActor
@Observable
final class RefreshScheduler {

    static let intervalDefaultsKey = "refreshIntervalMinutes"

    private(set) var isRefreshing = false

    /// Minutes between automatic refreshes; 0 or less means manual-only.
    var intervalMinutes: Int {
        didSet {
            guard intervalMinutes != oldValue else { return }
            UserDefaults.standard.set(intervalMinutes, forKey: Self.intervalDefaultsKey)
            // Mid-refresh the running loop reads the new value before its
            // next sleep; restarting now would cancel in-flight work.
            if !isRefreshing {
                restartLoop()
            }
        }
    }

    private let engine: RefreshEngine
    private var loopTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        engine = RefreshEngine(modelContainer: modelContainer)
        let stored = UserDefaults.standard.object(forKey: Self.intervalDefaultsKey) as? Int
        intervalMinutes = stored ?? 30
    }

    /// Idempotent; called when the main scene appears. Refreshes immediately,
    /// then repeats every `intervalMinutes`.
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

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task {
            while !Task.isCancelled {
                await runOneRefresh()
                let minutes = intervalMinutes
                guard minutes > 0 else { break }
                do {
                    try await Task.sleep(for: .seconds(minutes * 60))
                } catch {
                    break
                }
            }
        }
    }

    private func runOneRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await engine.refreshAll()
    }
}
