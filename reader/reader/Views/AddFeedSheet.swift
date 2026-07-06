//
//  AddFeedSheet.swift
//  reader
//

import SwiftUI
import SwiftData

/// Registers a feed by URL: fetches and parses it once for a preview
/// (title + item count), then inserts on confirm and triggers an immediate
/// refresh of just that feed.
struct AddFeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RefreshScheduler.self) private var scheduler

    private enum Phase: Equatable {
        case editing
        case validating
        case validated(title: String, itemCount: Int, homepageURL: URL?)
    }

    @State private var urlString = ""
    @State private var phase: Phase = .editing
    @State private var errorMessage: String?
    private let fetcher = FeedFetcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Feed")
                .font(.headline)
            TextField(
                "Feed URL",
                text: $urlString,
                prompt: Text("https://example.com/feed.xml")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(primaryAction)
            .onChange(of: urlString) {
                // Editing the URL invalidates a previous validation.
                phase = .editing
                errorMessage = nil
            }
            .disabled(phase == .validating)

            if case .validated(let title, let itemCount, _) = phase {
                Label {
                    Text("\(title) — \(itemCount) article\(itemCount == 1 ? "" : "s")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if phase == .validating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking feed…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryButtonTitle, action: primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryButtonDisabled)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var primaryButtonTitle: String {
        if case .validated = phase {
            return "Add"
        }
        return "Validate"
    }

    private var primaryButtonDisabled: Bool {
        phase == .validating
            || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func primaryAction() {
        switch phase {
        case .editing:
            validate()
        case .validating:
            break
        case .validated(let title, _, let homepageURL):
            add(title: title, homepageURL: homepageURL)
        }
    }

    private func validate() {
        guard let url = normalizedURL(from: urlString) else {
            errorMessage = "Enter a valid http(s) feed URL."
            return
        }
        if isDuplicate(url) {
            errorMessage = "This feed is already added."
            return
        }
        errorMessage = nil
        phase = .validating
        Task {
            do {
                let result = try await fetcher.fetch(url: url, etag: nil, lastModified: nil)
                guard case .fetched(let data, _, _) = result else {
                    throw FeedFetcher.FetchError.badStatus(304)
                }
                let parsed = try FeedParser.parse(data: data, sourceURL: url)
                phase = .validated(
                    title: parsed.title ?? url.host() ?? url.absoluteString,
                    itemCount: parsed.items.count,
                    homepageURL: parsed.homepageURL
                )
            } catch FeedParseError.notAFeed {
                phase = .editing
                errorMessage = "That URL isn't an RSS or Atom feed."
            } catch FeedParseError.malformed {
                phase = .editing
                errorMessage = "The feed couldn't be parsed."
            } catch {
                phase = .editing
                errorMessage = "Couldn't load the feed: \(error.localizedDescription)"
            }
        }
    }

    private func add(title: String, homepageURL: URL?) {
        guard let url = normalizedURL(from: urlString) else { return }
        guard !isDuplicate(url) else {
            errorMessage = "This feed is already added."
            return
        }
        let feed = Feed(feedURL: url, title: title, homepageURL: homepageURL)
        modelContext.insert(feed)
        do {
            try modelContext.save()
            scheduler.refreshFeed(feed.persistentModelID)
            dismiss()
        } catch {
            // Undo the insert: @Query would otherwise show a phantom feed
            // that the error message claims was never saved.
            modelContext.delete(feed)
            errorMessage = "Could not save the feed: \(error.localizedDescription)"
        }
    }

    private func isDuplicate(_ url: URL) -> Bool {
        let existing = (try? modelContext.fetch(FetchDescriptor<Feed>())) ?? []
        return existing.contains { $0.feedURL == url }
    }

    private func normalizedURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host() != nil
        else { return nil }
        return url
    }
}

#Preview {
    AddFeedSheet()
        .modelContainer(for: [Feed.self, Article.self], inMemory: true)
        .environment(RefreshScheduler(modelContainer: try! ModelContainer(
            for: Feed.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )))
}
