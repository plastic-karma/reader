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

/// Quiet empty states: a serif italic line in half ink, centered on the
/// paper — plus, where there's something to do, one rust pill and a text
/// action.
struct EmptyStateView: View {
    let state: EmptyState
    /// Extra secondary line under the description — .noEditions shows the
    /// live "N articles waiting · next edition …" caption here.
    var detail: String?
    var action: (() -> Void)?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(Theme.serif(state == .noSelection ? 16 : 14).italic())
                .foregroundStyle(Theme.ink.opacity(state == .noSelection ? 0.4 : 0.45))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 260)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            actions
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch state {
        case .noFeeds:
            "Add an RSS feed or a Gmail newsletter rule to start reading."
        case .noSelection:
            "Choose an article from the list."
        case .allCaughtUp:
            "All caught up. Nothing unread."
        case .noStarred:
            "No starred articles yet."
        case .noSavedLinks:
            "No saved links yet. Right-click a link in any article and choose “Save Link”."
        case .noEditions:
            "Articles gather here until an edition is published. Publish one now, or pick a schedule in Settings."
        case .editionCaughtUp:
            "You’ve read everything in this edition."
        case .emptyEdition:
            "This edition has no articles."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .noFeeds:
            VStack(spacing: 4) {
                if let action {
                    Button("Add Feed", action: action)
                        .buttonStyle(AccentPillButtonStyle())
                }
                if let secondaryAction {
                    Button("Add Newsletter Rule", action: secondaryAction)
                        .buttonStyle(AccentTextButtonStyle())
                }
            }
        case .noEditions:
            VStack(spacing: 4) {
                if let action {
                    Button("Publish Edition Now", action: action)
                        .buttonStyle(AccentPillButtonStyle())
                }
                if let secondaryAction {
                    Button("Edition Settings…", action: secondaryAction)
                        .buttonStyle(AccentTextButtonStyle())
                }
            }
        default:
            EmptyView()
        }
    }
}
