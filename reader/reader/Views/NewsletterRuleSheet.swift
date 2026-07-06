//
//  NewsletterRuleSheet.swift
//  reader
//

import SwiftUI
import SwiftData

/// What the rule sheet is editing: a fresh rule or an existing rule feed.
enum NewsletterSheetTarget: Identifiable {
    case new
    case edit(Feed)

    var id: String {
        switch self {
        case .new:
            return "new"
        case .edit(let feed):
            return feed.feedURL.absoluteString
        }
    }
}

/// Add/edit a newsletter rule (sender + optional subject regex), mirroring
/// AddFeedSheet's structure. The Test button lists the sender's last 30
/// days of subjects with live match marks, so a regex can be tuned before
/// the rule ever touches the mailbox.
struct NewsletterRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RefreshScheduler.self) private var scheduler
    @Environment(GmailAccountController.self) private var account

    let target: NewsletterSheetTarget

    @State private var name = ""
    @State private var sender = ""
    @State private var pattern = ""
    @State private var archiveAfterIngest = true
    @State private var testResults: [MailMessageHeader]?
    @State private var isTesting = false
    @State private var errorMessage: String?

    private var editedFeed: Feed? {
        if case .edit(let feed) = target {
            return feed
        }
        return nil
    }

    private var trimmedSender: String {
        sender.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespaces)
    }

    private var patternError: String? {
        do {
            _ = try NewsletterRule.compiledSubjectRegex(from: pattern)
            return nil
        } catch {
            return (error as? any LocalizedError)?.errorDescription ?? "Invalid subject pattern"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editedFeed == nil ? "Add Newsletter Rule" : "Edit Newsletter Rule")
                .font(.headline)

            TextField("Name", text: $name, prompt: Text("Money Stuff"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    "Sender",
                    text: $sender,
                    prompt: Text("money@bloomberg.net or bloomberg.net"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: sender) {
                    errorMessage = nil
                    testResults = nil
                }
                Text("Gmail “from:” matching — an address or a domain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    "Subject pattern (optional)",
                    text: $pattern,
                    prompt: Text("^Money Stuff"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                if let patternError {
                    Text(patternError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Case-insensitive regex against the subject; empty imports everything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Archive and mark read in Gmail after import", isOn: $archiveAfterIngest)

            testSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Test Against Recent Mail", action: runTest)
                    .disabled(!account.isSignedIn || trimmedSender.isEmpty || isTesting)
                if !account.isSignedIn {
                    Text("Sign in under Settings → Newsletters first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editedFeed == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedSender.isEmpty || patternError != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: populateFromTarget)
    }

    @ViewBuilder
    private var testSection: some View {
        if isTesting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching the sender's recent messages…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let testResults {
            if testResults.isEmpty {
                Text("No messages from this sender in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Match marks re-evaluate locally as the pattern changes —
                // no re-fetch needed while tuning the regex.
                let compiled = (try? NewsletterRule.compiledSubjectRegex(from: pattern)) ?? nil
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(testResults, id: \.id) { header in
                            let matches = NewsletterRule.matches(
                                subject: header.subject, compiled: compiled)
                            HStack(spacing: 6) {
                                Image(systemName: matches ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(matches ? .green : .secondary)
                                Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                                    .lineLimit(1)
                                Spacer()
                                if let date = header.date {
                                    Text(date, format: .dateTime.day().month())
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .font(.callout)
                            .opacity(matches ? 1 : 0.55)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func populateFromTarget() {
        guard let feed = editedFeed else { return }
        name = feed.title
        sender = feed.newsletterSender ?? ""
        pattern = feed.newsletterSubjectPattern ?? ""
        archiveAfterIngest = feed.newsletterArchiveAfterIngest ?? true
    }

    private func runTest() {
        isTesting = true
        testResults = nil
        errorMessage = nil
        let sender = trimmedSender
        Task {
            defer { isTesting = false }
            do {
                let headers = try await account.testHeaders(sender: sender)
                testResults = Array(
                    headers
                        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                        .prefix(20))
            } catch {
                errorMessage = (error as? MailProviderError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func save() {
        let senderValue = trimmedSender
        guard !senderValue.isEmpty, patternError == nil else { return }
        let nameValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = nameValue.isEmpty ? senderValue : nameValue
        let patternValue = trimmedPattern.isEmpty ? nil : trimmedPattern

        if let feed = editedFeed {
            let ruleChanged = feed.newsletterSender != senderValue
                || feed.newsletterSubjectPattern != patternValue
            feed.title = title
            feed.newsletterSender = senderValue
            feed.newsletterSubjectPattern = patternValue
            feed.newsletterArchiveAfterIngest = archiveAfterIngest
            if ruleChanged {
                // A changed rule re-evaluates the full 30-day window on its
                // next sync; stableID dedupe makes the re-list safe.
                feed.newsletterLastSyncedAt = nil
            }
            do {
                try modelContext.save()
                scheduler.refreshFeed(feed.persistentModelID)
                dismiss()
            } catch {
                modelContext.rollback()
                errorMessage = "Could not save the rule: \(error.localizedDescription)"
            }
            return
        }

        let feed = Feed(
            feedURL: Feed.makeNewsletterFeedURL(),
            title: title,
            sourceKind: .newsletter)
        feed.newsletterSender = senderValue
        feed.newsletterSubjectPattern = patternValue
        feed.newsletterArchiveAfterIngest = archiveAfterIngest
        modelContext.insert(feed)
        do {
            try modelContext.save()
            scheduler.refreshFeed(feed.persistentModelID)
            dismiss()
        } catch {
            // Undo the insert: @Query would otherwise show a phantom feed
            // that the error message claims was never saved.
            modelContext.delete(feed)
            errorMessage = "Could not save the rule: \(error.localizedDescription)"
        }
    }
}
