//
//  readerApp.swift
//  reader
//
//  Created by Benni Rogge on 7/5/26.
//

import SwiftUI
import SwiftData

@main
struct readerApp: App {
    private static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Feed.self,
            Article.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var scheduler = RefreshScheduler(modelContainer: readerApp.sharedModelContainer)

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedModelContainer)
        .environment(scheduler)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Feeds") {
                    scheduler.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scheduler.isRefreshing)
            }
        }
    }
}
