//
//  SettingsView.swift
//  reader
//

import SwiftUI

struct SettingsView: View {
    @Environment(RefreshScheduler.self) private var scheduler

    var body: some View {
        @Bindable var scheduler = scheduler
        Form {
            Picker("Refresh feeds:", selection: $scheduler.intervalMinutes) {
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
                Text("Every hour").tag(60)
                Text("Manually").tag(0)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
