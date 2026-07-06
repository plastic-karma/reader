//
//  AddFeedSheet.swift
//  reader
//

import SwiftUI
import SwiftData

/// Registers a feed by URL. M1: inserts directly without fetching; the M3
/// refresh milestone adds fetch-and-parse validation with a preview.
struct AddFeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var urlString = ""
    @State private var errorMessage: String?

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
            .onSubmit(addFeed)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addFeed)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func addFeed() {
        guard let url = normalizedURL(from: urlString) else {
            errorMessage = "Enter a valid http(s) feed URL."
            return
        }
        do {
            let existing = try modelContext.fetch(FetchDescriptor<Feed>())
            guard !existing.contains(where: { $0.feedURL == url }) else {
                errorMessage = "This feed is already added."
                return
            }
            let feed = Feed(feedURL: url, title: url.host() ?? url.absoluteString)
            modelContext.insert(feed)
            dismiss()
        } catch {
            errorMessage = "Could not save the feed: \(error.localizedDescription)"
        }
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
}
