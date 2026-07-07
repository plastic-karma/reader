//
//  SettingsView.swift
//  reader
//

import SwiftUI

struct SettingsView: View {
    @Environment(RefreshScheduler.self) private var scheduler

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }
            Tab("Newsletters", systemImage: "envelope") {
                NewsletterSettingsView()
            }
        }
        .frame(width: 460)
    }

    private var generalSettings: some View {
        @Bindable var scheduler = scheduler
        return Form {
            Section("Refresh") {
                Picker("Refresh feeds:", selection: $scheduler.intervalMinutes) {
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Manually").tag(0)
                }
            }
            Section("Editions") {
                Picker("Publish editions:", selection: $scheduler.editionFrequency) {
                    Text("Manually").tag(EditionCadence.Frequency.manual)
                    Text("Daily").tag(EditionCadence.Frequency.daily)
                    Text("Every 2 days").tag(EditionCadence.Frequency.every2Days)
                    Text("Weekly").tag(EditionCadence.Frequency.weekly)
                }
                if scheduler.editionFrequency == .weekly {
                    Picker("On:", selection: $scheduler.editionWeekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if scheduler.editionFrequency != .manual {
                    DatePicker(
                        "At:",
                        selection: editionTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Maps the persisted minutes-after-midnight scalar onto the Date value
    /// a time-of-day DatePicker needs, anchored on today (the day part is
    /// irrelevant and discarded on the way back).
    private var editionTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: scheduler.editionTimeOfDayMinutes / 60,
                    minute: scheduler.editionTimeOfDayMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                scheduler.editionTimeOfDayMinutes =
                    (components.hour ?? 6) * 60 + (components.minute ?? 0)
            }
        )
    }
}
