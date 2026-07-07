//
//  NewsletterSettingsView.swift
//  reader
//

import SwiftUI

/// The Newsletters settings tab: Google OAuth client configuration and
/// account sign-in state. Rules themselves are managed from the main
/// window (toolbar + feed context menus), not here.
struct NewsletterSettingsView: View {
    @Environment(GmailAccountController.self) private var account
    @AppStorage(MailAccountDefaults.clientIDKey) private var clientID = ""

    private var clientIDIsValid: Bool {
        GoogleOAuthClient.redirectScheme(forClientID: clientID) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    "Client ID:",
                    text: $clientID,
                    prompt: Text("1234-abc.apps.googleusercontent.com"))
                .autocorrectionDisabled()
                if !clientID.isEmpty, !clientIDIsValid {
                    Text("Not an iOS-type Google OAuth client ID.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text("One-time setup: create your own Google Cloud OAuth "
                    + "client (application type “iOS”) and paste its ID here. "
                    + "The walkthrough lives in docs/gmail-setup.md.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Google OAuth Client")
            }

            Section {
                switch account.status {
                case .signedOut:
                    Button("Sign in with Google…") {
                        account.signIn()
                    }
                    .disabled(!clientIDIsValid)
                case .signingIn:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for Google…")
                    }
                case .signedIn(let email):
                    LabeledContent("Signed in as:", value: email)
                    Button("Sign Out") {
                        Task {
                            await account.signOut()
                        }
                    }
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        account.signIn()
                    }
                    .disabled(!clientIDIsValid)
                }
            } header: {
                Text("Account")
            }
        }
        .formStyle(.grouped)
    }
}
