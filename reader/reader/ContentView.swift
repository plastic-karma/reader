//
//  ContentView.swift
//  reader
//
//  Created by Benni Rogge on 7/5/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RefreshScheduler.self) private var scheduler
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @State private var selectedArticle: Article?
    @State private var isAddingFeed = false
    @State private var feedPendingDeletion: Feed?

    var body: some View {
        NavigationSplitView {
            Group {
                if feeds.isEmpty {
                    EmptyStateView(state: .noFeeds) { isAddingFeed = true }
                } else {
                    articleList
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
            .toolbar {
                ToolbarItem {
                    if scheduler.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            scheduler.refreshNow()
                        } label: {
                            Label("Refresh All", systemImage: "arrow.clockwise")
                        }
                        .disabled(feeds.isEmpty)
                    }
                }
                ToolbarItem {
                    Button {
                        isAddingFeed = true
                    } label: {
                        Label("Add Feed", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .task {
                scheduler.start()
            }
        } detail: {
            if let article = selectedArticle {
                ArticleDetailPlaceholder(article: article)
            } else {
                EmptyStateView(state: .noSelection)
            }
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedSheet()
        }
        .confirmationDialog(
            "Delete “\(feedPendingDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { feedPendingDeletion != nil },
                set: { if !$0 { feedPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Feed", role: .destructive) {
                if let feed = feedPendingDeletion {
                    delete(feed)
                }
            }
        } message: {
            Text("This removes the feed and all of its articles.")
        }
    }

    private var articleList: some View {
        List(selection: $selectedArticle) {
            ForEach(feeds) { feed in
                Section {
                    let articles = feed.articles.sorted { $0.sortDate > $1.sortDate }
                    if articles.isEmpty {
                        Text("No articles yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(articles) { article in
                            ArticleRowView(article: article)
                                .tag(article)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(feed.title)
                            .lineLimit(1)
                        if let lastError = feed.lastError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(lastError)
                        }
                        Spacer()
                        if feed.unreadCount > 0 {
                            Text("\(feed.unreadCount)")
                                .font(.caption)
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .contextMenu {
                        Button("Delete Feed…", role: .destructive) {
                            feedPendingDeletion = feed
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func delete(_ feed: Feed) {
        if selectedArticle?.feed == feed {
            selectedArticle = nil
        }
        withAnimation {
            modelContext.delete(feed)
        }
    }
}

/// Minimal detail view until the M4 reading pane (WKWebView + cached images) lands.
private struct ArticleDetailPlaceholder: View {
    let article: Article

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    if let feedTitle = article.feed?.title {
                        Text(feedTitle)
                    }
                    if let author = article.author {
                        Text(author)
                    }
                    Text(article.sortDate, format: .dateTime.day().month().year())
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Divider()
                if let summary = article.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Feed.self, Article.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
        .environment(RefreshScheduler(modelContainer: container))
}
