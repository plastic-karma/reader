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
    @Environment(EditionContext.self) private var editionContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query(sort: \Edition.number, order: .reverse) private var editions: [Edition]
    @State private var selectedArticle: Article?
    @State private var filter: ArticleFilter = .unread
    @State private var isAddingFeed = false
    @State private var newsletterSheetTarget: NewsletterSheetTarget?
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
                    modePicker
                }
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
                            // activeEdition is nil in global mode (full sweep)
                            // and non-nil in edition mode whenever this button
                            // is enabled (totalUnreadCount is 0 without one).
                            Article.markAllRead(in: modelContext, within: activeEdition)
                        }
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    .disabled(totalUnreadCount == 0)
                }
                ToolbarItem {
                    Menu {
                        Button("Add Feed…") {
                            isAddingFeed = true
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        Button("Add Newsletter Rule…") {
                            newsletterSheetTarget = .new
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
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
        // Filter, mode, and edition switches are navigation boundaries:
        // retention only papers over in-place mutations, not a selection
        // that never matched. Deliberately no guard on `editions` changing —
        // when a publish auto-advances follow-latest, the article being read
        // stays selected via the retention clause.
        .onChange(of: filter) { _, _ in
            dropSelectionIfHidden()
        }
        .onChange(of: editionContext.mode) { _, _ in
            dropSelectionIfHidden()
        }
        .onChange(of: editionContext.selection) { _, _ in
            dropSelectionIfHidden()
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedSheet()
        }
        .sheet(item: $newsletterSheetTarget) { target in
            NewsletterRuleSheet(target: target)
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
    /// subscription articles never do — this is what makes the selection
    /// retention drop cross-kind selections. `edition` is the edition-mode
    /// gate (nil = no gate, i.e. global mode); saved links bypass it, so the
    /// Saved view is identical in both modes.
    private func matches(_ article: Article, _ filter: ArticleFilter, within edition: Edition?) -> Bool {
        let isSaved = article.feed?.isSavedLinksFeed == true
        if !isSaved, let edition, article.edition != edition {
            return false
        }
        switch filter {
        case .unread: return !isSaved && !article.isRead
        case .all: return !isSaved
        case .starred: return !isSaved && article.isStarred
        case .saved: return isSaved
        }
    }

    private var isEditionMode: Bool {
        editionContext.mode == .editions
    }

    /// The gate `matches` applies: nil in global mode. Also nil in edition
    /// mode with no editions at all — `editionModeIsEmpty` short-circuits
    /// every consumer before that nil could mean "show everything".
    private var activeEdition: Edition? {
        isEditionMode ? editionContext.resolve(from: editions) : nil
    }

    private var editionModeIsEmpty: Bool {
        isEditionMode && editions.isEmpty
    }

    /// Everything the sidebar shows as feed sections. Filtered by exclusion
    /// so future subscription kinds stay visible by default.
    private var subscriptionFeeds: [Feed] {
        feeds.filter { !$0.isSavedLinksFeed }
    }

    /// Unread across all subscriptions — drives the mark-all-read toolbar
    /// button's disabled state. Saved links never count: they are excluded
    /// from the global action too, so button and action stay in agreement.
    /// In edition mode both the count and the action scope to the active
    /// edition (and zero with no editions keeps the button disabled, so it
    /// can never fall back to marking the world read).
    private var totalUnreadCount: Int {
        if editionModeIsEmpty { return 0 }
        return subscriptionFeeds.reduce(0) { $0 + $1.unreadCount(within: activeEdition) }
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
            .filter { $0 == selectedArticle || matches($0, filter, within: activeEdition) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// Global ↔ Editions lens switch. Lives in the toolbar (not the sidebar
    /// stack) so global mode's sidebar stays pixel-identical to today; the
    /// menu-bar View commands (⌘1/⌘2) mirror it.
    private var modePicker: some View {
        @Bindable var editionContext = editionContext
        return Picker("View Mode", selection: $editionContext.mode) {
            Label("Global", systemImage: "tray.full")
                .tag(ViewMode.global)
            Label("Editions", systemImage: "newspaper")
                .tag(ViewMode.editions)
        }
        .pickerStyle(.segmented)
        .help("Switch between all articles and editions")
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
            if isEditionMode, filter != .saved, !editions.isEmpty {
                editionBar
            }
            if filter == .saved {
                if savedArticles.isEmpty {
                    EmptyStateView(state: .noSavedLinks)
                } else {
                    revealingSelection(of: savedList(savedArticles))
                }
            } else if subscriptionFeeds.isEmpty {
                // Root cause first: with no feeds at all, onboarding beats
                // the no-editions state.
                EmptyStateView(
                    state: .noFeeds,
                    action: { isAddingFeed = true },
                    secondaryAction: { newsletterSheetTarget = .new })
            } else if editionModeIsEmpty {
                EmptyStateView(
                    state: .noEditions,
                    action: { createEditionNow() },
                    secondaryAction: { openSettings() })
            } else {
                let sections = subscriptionFeeds.map { (feed: $0, articles: visibleArticles(for: $0)) }
                let allEmpty = sections.allSatisfy { $0.articles.isEmpty }
                // All mode never short-circuits: its sections are the only UI
                // carrying a feed's error glyph and Delete Feed menu, which must
                // stay reachable even when every feed is empty. (In edition
                // mode that management lens is global mode's job — see
                // list(sections:) — so empty editions do short-circuit.)
                if allEmpty, isEditionMode {
                    if filter == .unread {
                        EmptyStateView(state: .editionCaughtUp)
                    } else if filter == .starred {
                        EmptyStateView(state: .noStarred)
                    } else {
                        EmptyStateView(state: .emptyEdition)
                    }
                } else if allEmpty, filter == .unread {
                    EmptyStateView(state: .allCaughtUp)
                } else if allEmpty, filter == .starred {
                    EmptyStateView(state: .noStarred)
                } else {
                    revealingSelection(of: list(sections: sections))
                }
            }
        }
    }

    /// Edition-mode masthead: which edition is on screen, the back-catalog
    /// picker, and the manual publish action. Hidden on the Saved segment
    /// (saved links are editionless) and while no editions exist (the
    /// .noEditions state owns that surface).
    private var editionBar: some View {
        @Bindable var editionContext = editionContext
        return HStack {
            Menu {
                Picker("Edition", selection: $editionContext.selection) {
                    ForEach(editions) { edition in
                        Text(edition.displayLabel())
                            .tag(pickerSelection(for: edition))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Create Edition Now") {
                    createEditionNow()
                }
                .disabled(scheduler.isCreatingEdition)
            } label: {
                Label(activeEdition?.displayLabel() ?? "Editions", systemImage: "newspaper")
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The newest edition's picker row tags `.latest`, so choosing it
    /// re-arms follow-newest instead of pinning; every other row pins.
    private func pickerSelection(for edition: Edition) -> EditionSelection {
        edition === editions.first ? .latest : .specific(edition.persistentModelID)
    }

    private func createEditionNow() {
        scheduler.createEditionNow()
        // Show what was just made: the @Query advances this to the new
        // edition as soon as the engine's save lands.
        editionContext.selection = .latest
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
                // has nothing yet); filtered modes hide silent feeds. Edition
                // mode hides them even under All — a newspaper shows only
                // sections that ran, and feed management (error glyph,
                // Delete) stays one toggle away in global mode.
                if !articles.isEmpty || (filter == .all && !isEditionMode) {
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
                        let unreadCount = feed.unreadCount(within: activeEdition)
                        if unreadCount > 0 {
                            Text("\(unreadCount)")
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
                                feed.markAllRead(within: activeEdition)
                            }
                        }
                        .disabled(feed.unreadCount(within: activeEdition) == 0)
                        Button("Rename…") {
                            renameText = feed.title
                            feedPendingRename = feed
                        }
                        if feed.isNewsletterFeed {
                            // The sentinel URL is meaningless to copy; rule
                            // editing takes that slot instead.
                            Button("Edit Newsletter Rule…") {
                                newsletterSheetTarget = .edit(feed)
                            }
                        } else {
                            Button("Copy Feed URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(feed.feedURL.absoluteString, forType: .string)
                            }
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
        // The no-editions onboarding state renders no rows, so j/k must
        // not be able to select into the hidden pending pool.
        if editionModeIsEmpty {
            return []
        }
        return subscriptionFeeds.flatMap { $0.isCollapsed ? [] : visibleArticles(for: $0) }
    }

    /// Shared guard for every navigation boundary (filter, mode, or edition
    /// switch): drop a selection that is no longer visible.
    private func dropSelectionIfHidden() {
        guard let article = selectedArticle else { return }
        if editionModeIsEmpty, article.feed?.isSavedLinksFeed != true {
            selectedArticle = nil
            return
        }
        if !matches(article, filter, within: activeEdition) {
            selectedArticle = nil
        }
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
        for: Feed.self, Article.self, Edition.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
        .environment(RefreshScheduler(modelContainer: container))
        .environment(LinkSaver(modelContainer: container))
        .environment(EditionContext())
}
