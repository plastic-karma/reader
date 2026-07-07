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
            Edition.self,
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
    @State private var gmailAccount = GmailAccountController()
    @State private var editionContext = EditionContext()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedModelContainer)
        .environment(scheduler)
        .environment(linkSaver)
        .environment(gmailAccount)
        .environment(editionContext)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Feeds") {
                    scheduler.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scheduler.isRefreshing)
                Button("Create Edition Now") {
                    createEditionNow()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(scheduler.isCreatingEdition)
                Button("Mark All as Read") {
                    markAllRead()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                viewModeCommands
            }
        }

        Settings {
            SettingsView()
                .environment(scheduler)
                .environment(gmailAccount)
        }
    }

    /// View-menu block: mode switch (⌘1/⌘2) + edition back-catalog
    /// navigation (⌘[/⌘]).
    private var viewModeCommands: some View {
        @Bindable var editionContext = editionContext
        return Group {
            Picker("View Mode", selection: $editionContext.mode) {
                Text("Global")
                    .tag(ViewMode.global)
                    .keyboardShortcut("1", modifiers: .command)
                Text("Editions")
                    .tag(ViewMode.editions)
                    .keyboardShortcut("2", modifiers: .command)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Older Edition") {
                editionContext.selectOlder(in: Self.sharedModelContainer.mainContext)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(editionContext.mode != .editions)
            Button("Newer Edition") {
                editionContext.selectNewer(in: Self.sharedModelContainer.mainContext)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(editionContext.mode != .editions)
        }
    }

    private func createEditionNow() {
        scheduler.createEditionNow()
        // Show what was just made: re-arm follow-latest so the new edition
        // appears as soon as the engine's save lands.
        editionContext.selection = .latest
    }

    private func markAllRead() {
        let context = Self.sharedModelContainer.mainContext
        withAnimation {
            if editionContext.mode == .editions {
                // Nil must always mean "global", never "no edition
                // resolved" — with no editions there is nothing to mark.
                guard let edition = editionContext.resolveActiveEdition(in: context) else { return }
                Article.markAllRead(in: context, within: edition)
            } else {
                Article.markAllRead(in: context)
            }
        }
    }
}
