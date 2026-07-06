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
    @State private var linkSaver = LinkSaver(modelContainer: readerApp.sharedModelContainer)

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedModelContainer)
        .environment(scheduler)
        .environment(linkSaver)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Feeds") {
                    scheduler.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scheduler.isRefreshing)
                Button("Mark All as Read") {
                    markAllRead()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(scheduler)
        }
    }

    private func markAllRead() {
        Article.markAllRead(in: Self.sharedModelContainer.mainContext)
    }
}
