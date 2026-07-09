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

/// Focus mode binding exposed to the menu bar (View ▸ Focus Mode, ⌘⏎).
struct ReaderFocusModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var readerFocusMode: Binding<Bool>? {
        get { self[ReaderFocusModeKey.self] }
        set { self[ReaderFocusModeKey.self] = newValue }
    }
}

/// Two warm papers side by side: the list pane on the darker sheet, the
/// article on the brighter one. No toolbar, no window title — chrome sits
/// quiet at the edges, and focus mode (⌘⏎) folds the list away entirely.
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
    @State private var isFocusMode = false
    @State private var isAddingFeed = false
    @State private var newsletterSheetTarget: NewsletterSheetTarget?
    @State private var feedPendingDeletion: Feed?
    @State private var feedPendingRename: Feed?
    @State private var renameText = ""
    @State private var hostWindow: NSWindow?
    @State private var keyDownMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 300)
                .frame(width: isFocusMode ? 0 : 300, alignment: .leading)
                .clipped()
            detailPane
        }
        .ignoresSafeArea()
        .frame(minWidth: 700, minHeight: 440)
        .background(Theme.page)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38), value: isFocusMode)
        .focusedSceneValue(\.readerFocusMode, $isFocusMode)
        .preferredColorScheme(.light)
        .tint(Theme.accent)
        .background(HostWindowReader(window: $hostWindow))
        .task {
            scheduler.start()
        }
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

    // MARK: - Panes

    private var listPane: some View {
        VStack(spacing: 0) {
            lensRow
            filterRow
            if isEditionMode, filter != .saved, !editions.isEmpty {
                masthead
            }
            listBody
            bottomBar
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.list)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let article = selectedArticle {
            ReadingPaneView(article: article, isFocused: $isFocusMode)
        } else {
            EmptyStateView(state: .noSelection)
                .background(Theme.page)
        }
    }

    // MARK: - List chrome

    /// Top row: room for the traffic lights, then the Global / Editions
    /// lens as plain text. The menu-bar View commands (⌘1/⌘2) mirror it.
    private var lensRow: some View {
        HStack(spacing: 12) {
            Spacer()
            InkTab(
                label: "Global",
                size: 11,
                inactiveOpacity: 0.45,
                isActive: editionContext.mode == .global
            ) {
                editionContext.mode = .global
            }
            .help("All articles as they arrive (⌘1)")
            InkTab(
                label: "Editions",
                size: 11,
                inactiveOpacity: 0.45,
                isActive: editionContext.mode == .editions
            ) {
                editionContext.mode = .editions
            }
            .help("Batched, numbered editions (⌘2)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// Plain-text filters plus one unread total — the segmented box, gone
    /// quiet.
    private var filterRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            ForEach(ArticleFilter.allCases) { choice in
                InkTab(label: choice.rawValue, isActive: filter == choice) {
                    filter = choice
                }
            }
            Spacer()
            Text(totalUnreadCount == 0 ? "caught up" : "\(totalUnreadCount) unread")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// Edition-mode masthead: the issue number set in Literata, ‹ › to page
    /// through back issues, and the pending caption underneath. Hidden on
    /// the Saved segment (saved links are editionless) and while no
    /// editions exist (the .noEditions state owns that surface).
    private var masthead: some View {
        @Bindable var editionContext = editionContext
        let current = activeEdition
        let currentIndex = current.flatMap { edition in
            editions.firstIndex { $0 === edition }
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Edition", selection: $editionContext.selection) {
                        ForEach(editions) { edition in
                            Text(edition.displayLabel())
                                .tag(pickerSelection(for: edition))
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Publish Edition Now") {
                        createEditionNow()
                    }
                    .disabled(scheduler.isCreatingEdition)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(current.map { "Edition #\($0.number)" } ?? "Editions")
                            .font(Theme.serif(17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if let current {
                            Text(current.dateLabel().uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.ink.opacity(0.5))
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Theme.inkSoft.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                Spacer()
                QuietIconButton(
                    idleOpacity: 0.55,
                    width: 22,
                    height: 20,
                    help: "Older edition (⌘[)",
                    action: { editionContext.selectOlder(in: modelContext) }
                ) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .medium))
                }
                .disabled(currentIndex.map { $0 >= editions.count - 1 } ?? true)
                QuietIconButton(
                    idleOpacity: 0.55,
                    width: 22,
                    height: 20,
                    help: "Newer edition (⌘])",
                    action: { editionContext.selectNewer(in: modelContext) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .disabled(currentIndex.map { $0 <= 0 } ?? true)
            }
            if let pendingCaption {
                Text(pendingCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// Quiet feed management, at the bottom and out of the eye line:
    /// refresh, mark read, add.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            if scheduler.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 26)
            } else {
                QuietIconButton(
                    help: "Refresh all feeds",
                    action: { scheduler.refreshNow() }
                ) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(subscriptionFeeds.isEmpty)
            }
            QuietIconButton(
                help: "Mark all as read",
                action: {
                    withAnimation {
                        // activeEdition is nil in global mode (full sweep)
                        // and non-nil in edition mode whenever this button
                        // is enabled (totalUnreadCount is 0 without one).
                        Article.markAllRead(in: modelContext, within: activeEdition)
                    }
                }
            ) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
            }
            .disabled(totalUnreadCount == 0)
            addMenu
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairlineSoft).frame(height: 1)
        }
    }

    @State private var hoveringAddMenu = false

    private var addMenu: some View {
        Menu {
            Button("Add Feed…") {
                isAddingFeed = true
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Add Newsletter Rule…") {
                newsletterSheetTarget = .new
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 28, height: 26)
                .background(
                    hoveringAddMenu ? Theme.ink.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(hoveringAddMenu ? 1 : 0.4)
        .onHover { hoveringAddMenu = $0 }
        .help("Add feed or newsletter rule")
    }

    // MARK: - Membership

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

    /// Articles not yet revealed by any edition. Saved links never count —
    /// they are editionless by design.
    private var waitingCount: Int {
        subscriptionFeeds.reduce(0) { count, feed in
            count + feed.articles.count { $0.edition == nil }
        }
    }

    /// Masthead/onboarding caption: what's pending and when it reveals.
    /// nil when there is nothing informative to say (manual cadence and
    /// nothing waiting).
    private var pendingCaption: String? {
        let waiting = waitingCount
        if let next = scheduler.nextEditionDate {
            let day = next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return waiting > 0
                ? "Next edition \(day) · \(waiting) waiting"
                : "Next edition \(day)"
        }
        guard waiting > 0 else { return nil }
        return waiting == 1
            ? "1 article waiting for the next edition"
            : "\(waiting) articles waiting for the next edition"
    }

    /// Everything the sidebar shows as feed sections. Filtered by exclusion
    /// so future subscription kinds stay visible by default.
    private var subscriptionFeeds: [Feed] {
        feeds.filter { !$0.isSavedLinksFeed }
    }

    /// Unread across all subscriptions — drives the mark-all-read button's
    /// disabled state and the filter-row total. Saved links never count:
    /// they are excluded from the global action too, so button and action
    /// stay in agreement. In edition mode both the count and the action
    /// scope to the active edition (and zero with no editions keeps the
    /// button disabled, so it can never fall back to marking the world
    /// read).
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

    private func setAllCollapsed(_ collapsed: Bool) {
        withAnimation {
            for feed in subscriptionFeeds {
                feed.isCollapsed = collapsed
            }
        }
    }

    // MARK: - List body

    @ViewBuilder
    private var listBody: some View {
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
                detail: pendingCaption,
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(articles) { article in
                    row(for: article, menu: { savedArticleMenu(for: article) })
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private func list(sections: [(feed: Feed, articles: [Article])]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.feed) { feed, articles in
                    // In All mode every feed stays visible (with a hint when
                    // it has nothing yet); filtered modes hide silent feeds.
                    // Edition mode hides them even under All — a newspaper
                    // shows only sections that ran, and feed management
                    // (error glyph, Delete) stays one toggle away in global
                    // mode.
                    if !articles.isEmpty || (filter == .all && !isEditionMode) {
                        FeedSectionView(
                            feed: feed,
                            unreadCount: feed.unreadCount(within: activeEdition),
                            showsEmptyHint: articles.isEmpty
                        ) {
                            ForEach(articles) { article in
                                row(for: article, menu: { articleMenu(for: article) })
                            }
                        } menu: {
                            feedMenu(for: feed)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func feedMenu(for feed: Feed) -> some View {
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

    private func row(for article: Article, @ViewBuilder menu: () -> some View) -> some View {
        ArticleRowView(article: article, isSelected: selectedArticle == article)
            .padding(.horizontal, 8)
            .id(article.persistentModelID)
            .onTapGesture { selectedArticle = article }
            .contextMenu { menu() }
    }

    // MARK: - Editions

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

    // MARK: - Keyboard

    /// j/k and focus-mode Esc must work no matter which pane has key focus —
    /// clicking into the article's WKWebView steals first responder, which
    /// would silence a focus-scoped onKeyPress — so navigation keys are
    /// intercepted by a window-scoped monitor instead.
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
                case "\u{1B}":  // Esc leaves focus mode; otherwise not ours.
                    guard isFocusMode else { return event }
                    isFocusMode = false
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

    // MARK: - Menus

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

/// One feed's slice of the list: uppercase header, then rows unless the
/// feed is folded. A dedicated view (not a builder on ContentView) so that
/// Observation registers the isCollapsed/title/lastError reads against this
/// view — LazyVStack evaluates section content outside ContentView.body,
/// where those reads wouldn't reliably re-render on toggle. Clicking the
/// header folds/unfolds (the old sidebar's disclosure triangle, gone
/// quiet); the context menu keeps the bulk actions.
private struct FeedSectionView<Rows: View, MenuItems: View>: View {
    let feed: Feed
    let unreadCount: Int
    /// All-filter hint for a feed with nothing yet ("No articles yet").
    let showsEmptyHint: Bool
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        header
            .padding(.top, 14)
        if !feed.isCollapsed {
            if showsEmptyHint {
                Text("No articles yet")
                    .font(Theme.serif(12).italic())
                    .foregroundStyle(Theme.ink.opacity(0.35))
                    .padding(.horizontal, 16)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
            } else {
                rows()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(feed.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.ink.opacity(0.45))
                .lineLimit(1)
            if feed.isCollapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
            if let lastError = feed.lastError {
                Text("!")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 1))
                    .help(lastError)
            }
            Spacer()
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { feed.isCollapsed.toggle() }
        }
        .help(feed.isCollapsed ? "Show articles" : "Hide articles")
        .contextMenu { menu() }
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
