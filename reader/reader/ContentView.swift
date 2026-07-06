//
//  ContentView.swift
//  reader
//
//  Created by Benni Rogge on 7/5/26.
//

import SwiftUI
import SwiftData

enum ArticleFilter: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case all = "All"
    case starred = "Starred"

    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RefreshScheduler.self) private var scheduler
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @State private var selectedArticle: Article?
    @State private var filter: ArticleFilter = .unread
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
                ReadingPaneView(article: article)
            } else {
                EmptyStateView(state: .noSelection)
            }
        }
        .onChange(of: selectedArticle) { _, newValue in
            newValue?.isRead = true
        }
        .onChange(of: filter) { _, newFilter in
            // A filter switch is a navigation boundary: retention only papers
            // over in-place mutations, not a selection that never matched.
            if let article = selectedArticle, !matches(article, newFilter) {
                selectedArticle = nil
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

    private func matches(_ article: Article, _ filter: ArticleFilter) -> Bool {
        switch filter {
        case .unread: return !article.isRead
        case .all: return true
        case .starred: return article.isStarred
        }
    }

    /// Filtered + sorted rows for one feed. The currently selected article is
    /// always included so mark-as-read doesn't yank it out of the unread list
    /// and drop the selection.
    private func visibleArticles(for feed: Feed) -> [Article] {
        feed.articles
            .filter { $0 == selectedArticle || matches($0, filter) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var articleList: some View {
        let sections = feeds.map { (feed: $0, articles: visibleArticles(for: $0)) }
        let allEmpty = sections.allSatisfy { $0.articles.isEmpty }
        return VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ArticleFilter.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // All mode never short-circuits: its sections are the only UI
            // carrying a feed's error glyph and Delete Feed menu, which must
            // stay reachable even when every feed is empty.
            if allEmpty, filter == .unread {
                EmptyStateView(state: .allCaughtUp)
            } else if allEmpty, filter == .starred {
                EmptyStateView(state: .noStarred)
            } else {
                filteredList(sections: sections)
            }
        }
    }

    private func filteredList(sections: [(feed: Feed, articles: [Article])]) -> some View {
        List(selection: $selectedArticle) {
            ForEach(sections, id: \.feed) { feed, articles in
                // In All mode every feed stays visible (with a hint when it
                // has nothing yet); filtered modes hide silent feeds.
                if !articles.isEmpty || filter == .all {
                    Section {
                        if articles.isEmpty {
                            Text("No articles yet")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(articles) { article in
                                ArticleRowView(article: article)
                                    .tag(article)
                                    .contextMenu {
                                        articleMenu(for: article)
                                    }
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
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func articleMenu(for article: Article) -> some View {
        Button(article.isRead ? "Mark as Unread" : "Mark as Read") {
            article.isRead.toggle()
        }
        Button(article.isStarred ? "Unstar" : "Star") {
            article.isStarred.toggle()
        }
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

#Preview {
    let container = try! ModelContainer(
        for: Feed.self, Article.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
        .environment(RefreshScheduler(modelContainer: container))
}
