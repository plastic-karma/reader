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
}

struct EmptyStateView: View {
    let state: EmptyState
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
        }
    }
}
