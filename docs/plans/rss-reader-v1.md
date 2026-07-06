# Focused RSS Reader — macOS App: Design & Implementation Plan

> **Status:** implemented (M1–M5, one commit per milestone, `bridge test` green after each). Remaining human smoke tests: add a real feed, confirm articles arrive and images render offline (§Verification). UI tests are skipped in the shared scheme's headless test action — run them from Xcode.

## Context

The user wants a beautiful, *focused* reader for blogs and newsletters. Long-term vision: RSS feeds first, then non-RSS sources (e.g. Substack), and eventually newsletters pulled from email via IMAP. **This plan covers only the first pass**: a native macOS RSS reader that

- lets the user register RSS/Atom feed URLs,
- periodically downloads feeds in the background *while the app runs* and detects new items,
- tracks read/unread state per article,
- uses an email-client layout: left sidebar with unread items **grouped by feed**, right pane rendering article **HTML with all images downloaded and cached locally** (offline-capable reading).

Decisions agreed with the user:
- **Hand-rolled RSS 2.0 + Atom parser** on Foundation's `XMLParser` — zero third-party dependencies (also avoids hand-editing pbxproj for SPM from the Linux container).
- **Images downloaded & cached to disk at refresh time**; the reading pane serves local copies only.
- **Refresh while the app runs** (configurable timer + manual ⌘R); no login items/helpers yet.

Repo state: stock Xcode SwiftUI+SwiftData template, macOS-only (deployment target 26.3, Xcode 26.4.1, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 5 language mode). The pbxproj uses synchronized folders, so **new .swift files under `reader/reader/` and `reader/readerTests/` join their targets automatically — no pbxproj edits for source files**. The sandbox currently has **no network-client entitlement** (must be added). Builds/tests run through the container→host bridge (`bridge build --scheme reader`, `bridge test --scheme reader`; whole test action only, no per-test runs).

## Key design choices

| Decision | Choice | Why |
|---|---|---|
| Data model | `Feed` + `Article` (delete template `Item`); `sourceKind` string on Feed | Cheap future-proofing for Substack/IMAP without speculative protocol hierarchies |
| Article dedup | `stableID` = guid/atom-id → link → SHA256(title+date), unique per feed | Survives feeds that regenerate guids; idempotent re-ingest |
| Layout | **Two-column** `NavigationSplitView`: grouped article list (one `Section` per feed) left, reading pane right | Exactly what the user asked for; Mac-idiomatic (NetNewsWire compact / Mail style) |
| Serving cached images to WKWebView | **`WKURLSchemeHandler`** with custom `reader-asset://<sha256>.<ext>` scheme | Location-independent URLs safe to persist in DB; avoids `file://`+sandbox quirks; composes with strict CSP (`img-src reader-asset:`) for offline-verified rendering |
| Network entitlement | One-line pbxproj build setting `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` ×2 configs | Same entitlement-driving build-setting family the project already uses (`ENABLE_APP_SANDBOX`); smallest safe hand-edit from Linux |
| Test fixtures | Swift raw-string literals (`#"""…"""#`) in `Fixtures.swift`, not bundle resources | Guaranteed to work with synchronized folders; zero pbxproj resource-phase risk |
| Feed autodiscovery (paste blog URL → find feed) | Deferred to M5 fast-follow | Doubles Add-Feed validation complexity; not needed to prove the core loop |

## 1. SwiftData models

New: `reader/reader/Models/Feed.swift`, `Models/Article.swift`, `Models/SourceKind.swift`. Delete `reader/reader/Item.swift`; update schema in `readerApp.swift` to `[Feed.self, Article.self]` (nothing shipped — no migration needed).

```swift
@Model final class Feed {
    #Unique<Feed>([\.feedURL])
    var feedURL: URL; var title: String
    var homepageURL: URL?; var iconURL: URL?
    var sourceKind: String            // "rss" for now (SourceKind enum rawValue)
    var addedAt: Date; var lastFetchedAt: Date?
    var lastError: String?            // nil = healthy; glyph + tooltip in sidebar
    var etag: String?; var lastModified: String?   // conditional GET state
    @Relationship(deleteRule: .cascade, inverse: \Article.feed) var articles: [Article]
}

@Model final class Article {
    #Unique<Article>([\.feed, \.stableID])
    var stableID: String              // dedup key computed at parse time
    var title: String; var author: String?; var link: URL?
    var publishedAt: Date?            // nil if missing/unparseable
    var firstSeenAt: Date             // stable fallback sort key
    var summary: String?              // plain-text excerpt for list rows
    var contentHTML: String           // sanitized + image-rewritten
    var isRead: Bool; var isStarred: Bool
    var feed: Feed?
}
```

Upsert on refresh: query existing `stableID`s per feed once, insert only new items; never overwrite `isRead`/`isStarred`/`firstSeenAt`. V1 skips content updates for existing articles (avoids re-running image caching).

## 2. Fetching + parsing (`Services/`)

**All types in `Services/` get explicit `nonisolated` annotations** — under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` unannotated types silently pin to the main actor (warnings only in Swift 5 mode).

- `FeedFetcher.swift` — `nonisolated struct`; ephemeral `URLSession`, sends `If-None-Match`/`If-Modified-Since`, returns `.notModified` (304) or `.fetched(Data, etag:, lastModified:)`; custom User-Agent, 30 s timeout.
- `FeedParser.swift` — `nonisolated final class` wrapping an `XMLParserDelegate` state machine; detects RSS (`<rss>`/`<rdf>`) vs Atom (`<feed>`) at root. RSS: `item/title|link|guid|pubDate|dc:creator|description|content:encoded`; Atom: `entry/title|id|published|updated|author/name|summary|content`, link via `rel="alternate"` href. `content:encoded` preferred over `description`; Atom `content` over `summary`. CDATA via `foundCDATA` (UTF-8, Latin-1 fallback). Output: `Sendable` value types `ParsedFeed`/`ParsedItem`.
- `FeedDates.swift` — cascade of cached `en_US_POSIX` formatters: RFC 822 variants (±weekday, `zzz`/`Z` zones, 2-digit year) then ISO 8601 ±fractional seconds. Unparseable → nil.

## 3. Refresh engine (`Services/`)

- `RefreshEngine.swift` — `@ModelActor actor`: `refreshAll()` (bounded TaskGroup, 4 concurrent feeds) and `refresh(feedID: PersistentIdentifier)`. Per feed: fetch → parse → sanitize/rewrite HTML → cache images → upsert → update etag/lastError/lastFetchedAt → save. Errors caught per feed into `feed.lastError`; one bad feed never fails the batch. Only `PersistentIdentifier`s and value types cross actor boundaries. Main-context `@Query` views pick up saves automatically (same container).
- `RefreshScheduler.swift` — `@MainActor @Observable`: cancellable `Task` loop (`refreshAll()` then `Task.sleep(interval)`), `refreshNow()` cancels the sleep and coalesces; `intervalMinutes` mirrors `@AppStorage("refreshIntervalMinutes")` (default 30). Created in `readerApp`, injected via `.environment`, started on scene activation.

Known risk: `@ModelActor` + default-MainActor toolchain sharp edges. Fallback (same public API): plain `actor` owning the `ModelContainer`, fresh `ModelContext` per operation.

## 4. Image caching pipeline

- `Services/HTMLProcessor.swift` — pure `nonisolated` functions: `sanitize(html:)` strips `<script>/<iframe>/<object>/<embed>/<form>` and `on*=` attributes via regex (defense in depth; CSP is the real enforcement — no third-party HTML parser available); `extractImageURLs(html:baseURL:)` handles absolute + relative `src`, lazy-load `data-src`, strips `srcset/sizes`; `rewriteImageSources(html:mapping:)` swaps srcs to `reader-asset://<file>`.
- `Services/ImageCache.swift` — `actor`; `cache(_ remote: URL) async -> String?` downloads once, dedupes by SHA256(URL) filename in `Application Support/ImageCache/`, in-flight dedup via `[URL: Task]`. Failed downloads leave the remote URL in place (CSP blocks it → broken-image placeholder; acceptable v1). Orphan-file GC explicitly out of scope for v1.
- `Reading/LocalAssetSchemeHandler.swift` — `@MainActor WKURLSchemeHandler`; resolves `reader-asset://<sha>.<ext>` from the cache dir, MIME via `UTType`. Must be registered on the `WKWebViewConfiguration` at creation.

## 5. Reading pane (`Reading/`)

- `ArticleTemplate.swift` — HTML wrapper: CSP `default-src 'none'; img-src reader-asset:; style-src 'unsafe-inline'`; reading CSS (`max-width: 42em`, system font stack, `img { max-width:100% }`, `prefers-color-scheme: dark`, `pre/code` overflow).
- `ArticleWebView.swift` — `NSViewRepresentable` WKWebView; `loadHTMLString(_, baseURL: nil)`; coordinator tracks last-loaded article ID to avoid reload loops; navigation delegate: `.linkActivated` → `NSWorkspace.shared.open` + `.cancel`.
- `ReadingPaneView.swift` — SwiftUI article header (title, feed name, byline, date) above the web view (native typography/selection for chrome), web view below. Mark-as-read fires on list selection change.

## 6. UI shell (`Views/`, `Settings/`)

Rewrite `ContentView.swift` as **two-column `NavigationSplitView`**: sidebar = article list grouped in `Section`s per feed (header: feed title + unread badge + error glyph), detail = reading pane.

- Filter picker at sidebar top: Unread / All / Starred. **Selection-retention fix**: the unread filter always includes the currently selected article, so mark-as-read doesn't yank it out of the list and drop selection.
- `Views/AddFeedSheet.swift` — URL field → validate by fetching+parsing once → preview (title, item count) → confirm inserts `Feed` + triggers immediate refresh. Inline errors.
- `Views/ArticleRowView.swift` (unread dot, title, summary excerpt, relative date), `Views/EmptyStateView.swift` (no feeds / all caught up / no selection).
- Feed section context menu: Mark All as Read, Rename, Copy Feed URL, Delete (confirm; cascade).
- Toolbar + `.commands`: ⌘R Refresh All (spinner while refreshing), ⌘N Add Feed, ⌘⇧A Mark All Read. j/k next/prev-unread in M5.
- `Settings/SettingsView.swift` — Settings scene: refresh interval picker (15/30/60 min/manual), wired to scheduler via `@AppStorage`.

## 7. Entitlement (the only pbxproj edit)

In `reader/reader.xcodeproj/project.pbxproj`, add to both app-target config blocks (`6F4DD8F12FFB652C009AFF23` Debug, line ~398 area; `6F4DD8F22FFB652C009AFF23` Release, line ~428 area), alphabetically after `ENABLE_APP_SANDBOX = YES;`:

```
ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;
```

Fallback if the M3 live-fetch smoke test hits a sandbox denial: create `reader/reader.entitlements` (outside the synchronized folder) with `com.apple.security.app-sandbox` + `com.apple.security.network.client`, and set `CODE_SIGN_ENTITLEMENTS = reader.entitlements;` in the same two blocks.

## 8. Tests (`reader/readerTests/`, XCTest, fixtures as string literals)

- `Fixtures.swift` — RSS/Atom sample documents as raw-string literals.
- `FeedParserTests.swift` — RSS 2.0 + Atom basics, CDATA, HTML entities in titles, `content:encoded` preference, guid → link → hash fallback chain, Atom link-rel selection.
- `FeedDatesTests.swift` — RFC 822 variants, ISO 8601 ± fractional seconds, garbage → nil.
- `HTMLProcessorTests.swift` — img extraction (absolute/relative/`data-src`), srcset stripping, script/on*-attribute stripping, rewrite mapping.
- `UpsertTests.swift` — in-memory `ModelContainer`; double-refresh → no dupes, `isRead` preserved, feed delete cascades.

Test target does **not** set default-MainActor isolation — annotate tests `@MainActor` where they touch main-actor app types. Leave `readerUITests` stubs untouched.

## 9. Milestones (each ends with `bridge build` + `bridge test` green)

1. **M1 Foundation** — models (delete `Item.swift`), schema swap in `readerApp.swift`, pbxproj entitlement line, split-view skeleton in `ContentView.swift` with Add Feed (bare insert, no fetch), feed delete, empty states.
2. **M2 Parser** — `FeedParser`, `FeedDates`, `HTMLProcessor` as pure logic + all fixture-based tests. No UI change; `bridge test` is the deliverable.
3. **M3 Live refresh** — `FeedFetcher`, `RefreshEngine`, `RefreshScheduler`, Add-Feed validation preview, toolbar/⌘R, unread badges + error glyphs, `UpsertTests`. Human smoke test on a real feed validates the network entitlement.
4. **M4 Reading pane + images** — `ImageCache`, `LocalAssetSchemeHandler`, template, `ArticleWebView`, `ReadingPaneView`, ingest-path image caching, mark-as-read, links → browser. Human check: image-heavy feed renders offline.
5. **M5 Polish** — j/k navigation, mark-all-read command/context menus, Settings interval UI, feed autodiscovery (`<link rel="alternate" type="application/rss+xml">` scan of pasted blog URLs), dark-mode template tuning.

## 10. File layout (all additive via synchronized folders)

```
reader/reader/
  readerApp.swift                    (modify: schema, scheduler, commands, Settings scene)
  ContentView.swift                  (rewrite: NavigationSplitView shell)
  Models/   Feed.swift, Article.swift, SourceKind.swift
  Services/ FeedFetcher.swift, FeedParser.swift, FeedDates.swift,
            HTMLProcessor.swift, ImageCache.swift,
            RefreshEngine.swift, RefreshScheduler.swift,
            FeedAutodiscovery.swift  (M5)
  Reading/  ArticleWebView.swift, ArticleTemplate.swift,
            LocalAssetSchemeHandler.swift, ReadingPaneView.swift
  Views/    SidebarView.swift, ArticleRowView.swift,
            AddFeedSheet.swift, EmptyStateView.swift
  Settings/ SettingsView.swift
reader/readerTests/
  Fixtures.swift, FeedParserTests.swift, FeedDatesTests.swift,
  HTMLProcessorTests.swift, UpsertTests.swift
reader/reader.xcodeproj/project.pbxproj  (modify: 1 build setting × 2 configs)
```

`Item.swift` deleted; `readerTests.swift` stub replaced by the real test files.

## Verification

- After every milestone: `bridge build --scheme reader` and `bridge test --scheme reader` must pass (requires the host bridge worker running; check `bridge status` first).
- M2 is verified almost entirely by unit tests (parser/date/HTML edge cases).
- M3/M4 need a human-in-the-loop smoke test on the Mac (add a real feed such as a Substack RSS URL `https://<name>.substack.com/feed`, watch articles arrive, open one, confirm images render, then disconnect network and confirm offline rendering) — the bridge can build/test but cannot drive the running GUI.
- The entitlement edit is validated empirically at M3 (first live fetch); the entitlements-file fallback is fully specified in §7.

## Risks

1. **Default MainActor isolation** silently serializing refresh work — mitigated by explicit `nonisolated` on everything in `Services/`.
2. **`@ModelActor` macro friction** under this toolchain — fallback: plain `actor` owning the container, same API.
3. **Bridge runs the whole test action** including UI-test stubs launching the app headless — leave stubs alone; treat flakes as a separate follow-up.
4. **Feed wilds** (bad dates, ignored conditional GET, encoding oddities) — nil dates + `firstSeenAt` ordering, idempotent upsert, UTF-8/Latin-1 CDATA fallback.
5. **Pbxproj hand-edit** — kept to two identical lines in existing blocks; no new object IDs or phases.

## Future milestones (out of scope now, architecture-ready)

- Substack/non-RSS sources: new `SourceKind` + a branch in the engine's fetch/parse entry point.
- IMAP newsletter ingestion: a new source kind producing the same `ParsedItem` shape; the HTML sanitize → image-cache → render pipeline is already exactly what email newsletters need.
- Background refresh with app closed (login item / menu-bar helper), orphaned-image GC, OPML import/export.
