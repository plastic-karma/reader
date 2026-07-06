//
//  ContentView.swift
//  reader
//
//  Created by Benni Rogge on 7/5/26.
//

import AppKit
import SwiftUI
import SwiftData

enum ArticleFilter: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case all = "All"
    case starred = "Starred"
    case saved = "Saved"

    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RefreshScheduler.self) private var scheduler
    @Environment(LinkSaver.self) private var linkSaver
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @State private var selectedArticle: Article?
    @State private var filter: ArticleFilter = .unread
    @State private var isAddingFeed = false
    @State private var feedPendingDeletion: Feed?
    @State private var feedPendingRename: Feed?
    @State private var renameText = ""
    @State private var hostWindow: NSWindow?
    @State private var keyDownMonitor: Any?

    var body: some View {
        NavigationSplitView {
            Group {
                articleList
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
                        .disabled(subscriptionFeeds.isEmpty)
                    }
                }
                ToolbarItem {
                    // ⌘⇧A lives on the equivalent menu-bar command, not here —
                    // duplicating it would make the shortcut ambiguous.
                    Button {
                        withAnimation {
                            Article.markAllRead(in: modelContext)
                        }
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    .disabled(totalUnreadCount == 0)
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
        .background(HostWindowReader(window: $hostWindow))
        .onAppear {
            installKeyDownMonitor()
        }
        .onDisappear {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
            keyDownMonitor = nil
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
        .alert(
            "Rename Feed",
            isPresented: Binding(
                get: { feedPendingRename != nil },
                set: { if !$0 { feedPendingRename = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let feed = feedPendingRename, !name.isEmpty {
                    feed.title = name
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Kind-aware membership: saved-link articles live only under .saved and
    /// subscription articles never do — this is what makes the
    /// .onChange(of: filter) retention drop cross-kind selections.
    private func matches(_ article: Article, _ filter: ArticleFilter) -> Bool {
        let isSaved = article.feed?.isSavedLinksFeed == true
        switch filter {
        case .unread: return !isSaved && !article.isRead
        case .all: return !isSaved
        case .starred: return !isSaved && article.isStarred
        case .saved: return isSaved
        }
    }

    /// Everything the sidebar shows as feed sections. Filtered by exclusion
    /// so future subscription kinds stay visible by default.
    private var subscriptionFeeds: [Feed] {
        feeds.filter { !$0.isSavedLinksFeed }
    }

    /// Unread across all subscriptions — drives the mark-all-read toolbar
    /// button's disabled state. Saved links never count: they are excluded
    /// from the global action too, so button and action stay in agreement.
    private var totalUnreadCount: Int {
        subscriptionFeeds.reduce(0) { $0 + $1.unreadCount }
    }

    /// The hidden feed backing the Saved segment; nil until the first save.
    private var savedFeed: Feed? {
        feeds.first { $0.isSavedLinksFeed }
    }

    /// Saved links newest-first (sortDate == save time). Read state never
    /// filters this list, so — unlike visibleArticles(for:) — no
    /// selected-article escape hatch is needed for mark-as-read stability.
    private var savedArticles: [Article] {
        (savedFeed?.articles ?? []).sorted { $0.sortDate > $1.sortDate }
    }

    /// Filtered + sorted rows for one feed. The currently selected article is
    /// always included so mark-as-read doesn't yank it out of the unread list
    /// and drop the selection.
    private func visibleArticles(for feed: Feed) -> [Article] {
        feed.articles
            .filter { $0 == selectedArticle || matches($0, filter) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// Drives a section's disclosure triangle. Stored inverted so a brand-new
    /// feed (isCollapsed == false) starts expanded.
    private func expansion(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { !feed.isCollapsed },
            set: { feed.isCollapsed = !$0 }
        )
    }

    private func setAllCollapsed(_ collapsed: Bool) {
        withAnimation {
            for feed in subscriptionFeeds {
                feed.isCollapsed = collapsed
            }
        }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ArticleFilter.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if filter == .saved {
                if savedArticles.isEmpty {
                    EmptyStateView(state: .noSavedLinks)
                } else {
                    revealingSelection(of: savedList(savedArticles))
                }
            } else if subscriptionFeeds.isEmpty {
                EmptyStateView(state: .noFeeds) { isAddingFeed = true }
            } else {
                let sections = subscriptionFeeds.map { (feed: $0, articles: visibleArticles(for: $0)) }
                let allEmpty = sections.allSatisfy { $0.articles.isEmpty }
                // All mode never short-circuits: its sections are the only UI
                // carrying a feed's error glyph and Delete Feed menu, which must
                // stay reachable even when every feed is empty.
                if allEmpty, filter == .unread {
                    EmptyStateView(state: .allCaughtUp)
                } else if allEmpty, filter == .starred {
                    EmptyStateView(state: .noStarred)
                } else {
                    revealingSelection(of: list(sections: sections))
                }
            }
        }
    }

    /// Wraps a list so programmatic selection changes (j/k) scroll the
    /// selected row into view. Shared by the sectioned subscription list and
    /// the flat saved list.
    private func revealingSelection(of listView: some View) -> some View {
        ScrollViewReader { proxy in
            listView.onChange(of: selectedArticle) { _, newValue in
                // j/k can move the selection offscreen; reveal it.
                if let newValue {
                    proxy.scrollTo(newValue.persistentModelID)
                }
            }
        }
    }

    private func savedList(_ articles: [Article]) -> some View {
        List(selection: $selectedArticle) {
            ForEach(articles) { article in
                ArticleRowView(article: article)
                    .tag(article)
                    .contextMenu {
                        savedArticleMenu(for: article)
                    }
            }
        }
        .listStyle(.sidebar)
    }

    private func list(sections: [(feed: Feed, articles: [Article])]) -> some View {
        List(selection: $selectedArticle) {
            ForEach(sections, id: \.feed) { feed, articles in
                // In All mode every feed stays visible (with a hint when it
                // has nothing yet); filtered modes hide silent feeds.
                if !articles.isEmpty || filter == .all {
                    Section(isExpanded: expansion(for: feed)) {
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
                        Button(feed.isCollapsed ? "Expand" : "Collapse") {
                            withAnimation { feed.isCollapsed.toggle() }
                        }
                        Button("Collapse All") { setAllCollapsed(true) }
                        Button("Expand All") { setAllCollapsed(false) }
                        Divider()
                        Button("Mark All as Read") {
                            withAnimation {
                                feed.markAllRead()
                            }
                        }
                        .disabled(feed.unreadCount == 0)
                        Button("Rename…") {
                            renameText = feed.title
                            feedPendingRename = feed
                        }
                        Button("Copy Feed URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(feed.feedURL.absoluteString, forType: .string)
                        }
                        Divider()
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

    /// j/k must work no matter which pane has key focus — clicking into the
    /// article's WKWebView steals first responder, which would silence a
    /// focus-scoped onKeyPress — so navigation keys are intercepted by a
    /// window-scoped monitor instead.
    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard
                    event.window === hostWindow,
                    hostWindow?.attachedSheet == nil,
                    !(hostWindow?.firstResponder is NSText),
                    event.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                        .isEmpty
                else { return event }
                switch event.charactersIgnoringModifiers {
                case "j":
                    selectNextUnread()
                    return nil
                case "k":
                    selectPreviousUnread()
                    return nil
                default:
                    return event
                }
            }
        }
    }

    /// Visible articles in display order — the traversal order for j/k. In
    /// the Saved view that's the flat saved list; otherwise feeds sorted by
    /// title, articles newest-first, skipping collapsed feeds (folded
    /// articles are out of view, so navigation must not land the selection
    /// on an unrendered row).
    private var flattenedVisibleArticles: [Article] {
        if filter == .saved {
            return savedArticles
        }
        return subscriptionFeeds.flatMap { $0.isCollapsed ? [] : visibleArticles(for: $0) }
    }

    private func selectNextUnread() {
        let all = flattenedVisibleArticles
        guard !all.isEmpty else { return }
        let start = selectedArticle.flatMap { all.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if let next = all[start...].first(where: { !$0.isRead }) {
            selectedArticle = next
        }
    }

    private func selectPreviousUnread() {
        let all = flattenedVisibleArticles
        guard !all.isEmpty else { return }
        let end = selectedArticle.flatMap { all.firstIndex(of: $0) } ?? all.count
        if let previous = all[..<end].last(where: { !$0.isRead }) {
            selectedArticle = previous
        }
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

    @ViewBuilder
    private func savedArticleMenu(for article: Article) -> some View {
        articleMenu(for: article)
        if let link = article.link {
            Button("Open in Browser") {
                NSWorkspace.shared.open(link)
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
            if article.downloadError != nil {
                Button("Retry Download") {
                    linkSaver.save(link)
                }
            }
        }
        Divider()
        Button("Remove from Saved", role: .destructive) {
            removeSaved(article)
        }
    }

    private func removeSaved(_ article: Article) {
        // Clear the selection before delete — the detail pane must never
        // render a deleted model.
        if selectedArticle == article {
            selectedArticle = nil
        }
        withAnimation {
            modelContext.delete(article)
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

/// Captures the NSWindow hosting this SwiftUI hierarchy so the key monitor
/// can ignore events belonging to other windows, sheets, or alerts.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== view.window {
                window = view.window
            }
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
        .environment(LinkSaver(modelContainer: container))
}
