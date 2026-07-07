//
//  EditionCadence.swift
//  reader
//

import Foundation

/// How often editions publish. A struct of three scalars (not an enum with
/// payloads) because it mirrors three UserDefaults values and three bindable
/// scheduler properties one-to-one — the `intervalMinutes` pattern.
nonisolated struct EditionCadence: Equatable, Sendable {

    enum Frequency: String, CaseIterable, Sendable {
        case manual
        case daily
        case every2Days
        case weekly
    }

    var frequency: Frequency
    /// Minutes after local midnight the edition reveals; 0..<1440.
    var minutesOfDay: Int
    /// Calendar convention, 1 = Sunday … 7 = Saturday; read only for .weekly.
    var weekday: Int

    /// Manual-only at 06:00 Mondays — the shipping default: nothing
    /// publishes until the user picks a frequency.
    static let `default` = EditionCadence(frequency: .manual, minutesOfDay: 6 * 60, weekday: 2)

    var hour: Int { minutesOfDay / 60 }
    var minute: Int { minutesOfDay % 60 }

    /// Lenient assembly from persisted raw values: an unknown frequency
    /// string falls back to .manual (never crashes on stale defaults),
    /// minutes and weekday are clamped into range.
    static func make(frequencyRaw: String?, minutesOfDay: Int?, weekday: Int?) -> EditionCadence {
        EditionCadence(
            frequency: frequencyRaw.flatMap(Frequency.init(rawValue:)) ?? Self.default.frequency,
            minutesOfDay: min(1439, max(0, minutesOfDay ?? Self.default.minutesOfDay)),
            weekday: min(7, max(1, weekday ?? Self.default.weekday))
        )
    }
}
