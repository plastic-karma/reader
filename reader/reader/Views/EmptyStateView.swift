//
//  EmptyStateView.swift
//  reader
//

import SwiftUI

enum EmptyState {
    case noFeeds
    case noSelection
    case allCaughtUp
    case noStarred
    case noSavedLinks
    case noEditions
    case editionCaughtUp
    case emptyEdition
}

struct EmptyStateView: View {
    let state: EmptyState
    /// Extra secondary line under the description — .noEditions shows the
    /// live "N articles waiting · next edition …" caption here.
    var detail: String?
    var action: (() -> Void)?
    var secondaryAction: (() -> Void)?

    var body: some View {
        switch state {
        case .noFeeds:
            ContentUnavailableView {
                Label("No Feeds", systemImage: "dot.radiowaves.up.forward")
            } description: {
                Text("Add an RSS feed or a Gmail newsletter rule to start reading.")
            } actions: {
                if let action {
                    Button("Add Feed", action: action)
                }
                if let secondaryAction {
                    Button("Add Newsletter Rule", action: secondaryAction)
                }
            }
        case .noSelection:
            ContentUnavailableView(
                "No Article Selected",
                systemImage: "doc.richtext",
                description: Text("Choose an article from the list.")
            )
        case .allCaughtUp:
            ContentUnavailableView(
                "All Caught Up",
                systemImage: "checkmark.circle",
                description: Text("No unread articles.")
            )
        case .noStarred:
            ContentUnavailableView(
                "No Starred Articles",
                systemImage: "star",
                description: Text("Star articles to find them here.")
            )
        case .noSavedLinks:
            ContentUnavailableView(
                "No Saved Links",
                systemImage: "bookmark",
                description: Text("Right-click a link in any article and choose “Save Link”.")
            )
        case .noEditions:
            ContentUnavailableView {
                Label("No Editions Yet", systemImage: "newspaper")
            } description: {
                Text("Articles gather here until an edition is published. Create one now, or pick a schedule in Settings.")
                if let detail {
                    Text(detail)
                }
            } actions: {
                if let action {
                    Button("Create Edition Now", action: action)
                }
                if let secondaryAction {
                    Button("Edition Settings…", action: secondaryAction)
                }
            }
        case .editionCaughtUp:
            ContentUnavailableView(
                "Edition Read",
                systemImage: "checkmark.circle",
                description: Text("You've read everything in this edition.")
            )
        case .emptyEdition:
            ContentUnavailableView(
                "Empty Edition",
                systemImage: "newspaper",
                description: Text("This edition has no articles.")
            )
        }
    }
}
