# Newsletters from Gmail — Design & Implementation Plan

> **Status:** implemented (M1–M5, one PR per milestone: #7 #8 #9 #10 #11, `bridge test` green after each). Remaining human smoke tests: create the Google Cloud OAuth client per `docs/gmail-setup.md`, sign in, add a rule for a real newsletter, confirm the article renders offline and the message is archived + read in Gmail.

## Context

The reader ingests RSS/Atom feeds and saved web pages. This plan adds the third anticipated source (`docs/plans/rss-reader-v1.md` named it from day one): email newsletters — including paid ones tied to the user's main Gmail address — pulled directly from Gmail. The user registers rules of **sender + optional subject regex**; matching messages become articles and stop cluttering the inbox.

Product decisions (user-confirmed):
- **Gmail REST API + OAuth**; the user creates their own Google Cloud OAuth client (~10 min one-time, `docs/gmail-setup.md`). No backend server, no third-party dependencies. Code sits behind a **provider protocol so IMAP can be added later**.
- After ingesting a matched message the app **archives it + marks it read** in Gmail (`gmail.modify`), per-rule toggle, default on.
- **One sidebar feed per rule**, behaving exactly like RSS feeds.

Environment facts that shaped the design:
- macOS-only app; App Sandbox with the outgoing-network entitlement already present; zero SPM deps (CryptoKit / AuthenticationServices / Security are system frameworks).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` → every non-UI mail type is explicitly `nonisolated` or an actor.
- `RefreshEngine.prepare/insert` already provide sanitize → image-cache → CSP-safe rewrite → stableID-deduped insert preserving isRead/isStarred — reused verbatim for email HTML.
- Sidebar/filters/refresh are exclusion-based (`!isSavedLinksFeed`) → newsletter feeds inherit badges, error glyph, collapse, j/k, delete, refresh for free.
- Tests: XCTest, string fixtures, injected-value seams, in-memory ModelContainer; whole suite via `bridge test`. CI runs an unsigned test host → the data-protection Keychain is untouchable there by construction, so `KeychainStore` stays a thin wrapper behind a `TokenStoring` seam.

## Architecture

```
Settings UI ──► GmailAccountController (@MainActor @Observable: sign-in/out, status, Test rule)
                    │ reads/writes: KeychainStore (tokens) + UserDefaults (clientID, email)
                    ▼
RefreshScheduler ─► RefreshEngine (@ModelActor)  ← unchanged scheduling/spinner/⌘R
                    ├─ .rss        → FeedFetcher + FeedParser (unchanged)
                    ├─ .newsletter → refreshNewsletter(feedID:using: MailProviderClient)
                    │                  └─ GmailMailClient (REST; HTTPTransport closure seam)
                    │                  └─ (future) IMAPMailClient
                    └─ shared prepare/insert/lastError/save-rollback path (reused verbatim)
```

Auth state flows between Settings UI and engine through **Keychain + UserDefaults as source of truth** — no object threading. Newsletter refresh lives **inside RefreshEngine** (not a second actor): it reuses the correctness-critical prepare/insert/rollback code and the whole scheduling path; the dispatch is a few lines. `@ModelActor` generates `init(modelContainer:)`, so the production client is an inline-default stored property (`GmailMailClient.live()`, side-effect-free construction) and tests inject stubs via `refreshNewsletter(feedID:using:)` — the same seam pattern as `ingest(_:intoFeedWithID:)`.

## Data model (lightweight auto-migration only)

- `SourceKind`: `case newsletter` (string-backed, no schema change).
- `Feed`: nil-defaulted optionals — `newsletterSender`, `newsletterSubjectPattern`, `newsletterArchiveAfterIngest` (read `?? true`), `newsletterLastSyncedAt` (watermark; deliberately not `lastFetchedAt`, which is stamped on failures too) — plus `makeNewsletterFeedURL()` (sentinel `reader-internal://newsletter/<uuid>`; non-http so AddFeedSheet can't collide, UUID satisfies `#Unique(feedURL)`), `isNewsletterFeed`, `newsletterRule`.
- `Article`: unchanged. Mapping: stableID = Gmail message id, title = RFC 2047-decoded Subject, author = From display name, publishedAt = internalDate (ms; Date-header fallback via FeedDates), link = `https://mail.google.com/mail/#all/<id>`, contentHTML = decoded html part (fallback: paragraph-ized plain text; stub with Gmail link). Cross-rule duplicates allowed by design (`#Unique` is per-feed).

## Key algorithms

**Per-rule sync (`refreshNewsletter`)** — constants: 30-day backfill, 24 h watermark overlap, 5×100 list pages, 200 messages/sync, 2 MB body cap, 50 images/article.
1. Snapshot rule + knownIDs + watermark; `syncStartedAt` captured before listing (mid-sync arrivals get re-listed next time). Bad/incomplete rule fails before any network call.
2. `since = watermark − 24h ?? now − 30d`; list headers (`from:(sender) after:<epoch>` — **no `label:` clause**, dedupe and self-heal need archived messages listed); client-side regex filter; fetch new bodies oldest-first (one failed get fails the sync — watermark holds, nothing skipped); shared `prepare`.
3. Archive set = `matched.filter(\.isUnprocessed)` — new messages AND known-but-still-inboxed ones. Self-healing without extra query clauses; messages predating the rule are never listed ⇒ never archived.
4. **Articles are durable before Gmail is touched**, and **the watermark advances only when ingest persisted AND archiving succeeded** — the two ordering invariants everything else leans on. Feed deleted mid-sync ⇒ bail before insert *and* before archive.
5. Errors → `feed.lastError` ("Gmail: sign in required (Settings → Newsletters)", "…session expired…", "Invalid subject pattern", "Gmail: rate limited…", "Gmail: HTTP n") → existing sidebar glyph.

**Auth** — PKCE S256 (RFC 7636 vector-tested) via `ASWebAuthenticationSession(.customScheme)` (no Info.plist registration; anchor = key window since sign-in starts from Settings); iOS-type client = secret-less; token exchange/refresh through the `HTTPTransport` closure seam; `GoogleTokenProvider` actor: 60 s expiry slack, **single-flight refresh** (a cold refreshAll fires one grant, not four), `invalid_grant` → authExpired keeping the Keychain item, cache-drop on failure so sign-out is honored.

**Ingest privacy** — `HTMLProcessor.strippingTrackingPixels` removes declared 0/1-sized `<img>`s *before* `ImageCache` fetches (the render-time CSP can't prevent the ingest-time beacon); image downloads capped and run in the LinkArchiver sliding-window pattern.

## UI

- Settings → tabs (General | Newsletters): client-ID field with live validation, sign-in/out state machine.
- Rules: toolbar ＋ menu ("Add Feed…" ⌘N / "Add Newsletter Rule…"), sidebar context menu "Edit Newsletter Rule…" replacing the meaningless "Copy Feed URL" on rule feeds, empty-state secondary action. `NewsletterRuleSheet`: name/sender/pattern (live regex validation) /archive toggle + **Test Against Recent Mail** (last 30 days of subjects, match marks re-evaluated locally while typing). Editing sender/pattern resets the watermark → 30-day re-evaluation under the new rule (dedupe makes it safe).

## Testing

~90 newsletter-related cases across seven files, all offline (string fixtures with byte-accurate base64url payloads, transport/auth/provider doubles, in-memory containers): header decoding (RFC 2047 B/Q, adjacency), rule regex semantics, Gmail JSON parsing (part walks, charsets, mapping fallbacks), client behavior (pagination, 401-retry-once, batchModify chunking, empty-ids no-op), PKCE vector + secret-less request shapes, token refresh state machine (single-flight, invalid_grant contract), and the full sync (dedupe, self-heal, watermark invariant, failure taxonomy, windows, mid-sync deletion, dispatch routing).

## Deferred / known limits

- Newsletters sit in the inbox until the next sync (no push in a no-backend design).
- CSS `background-image` remotes aren't cached (only `<img>`); CSS-hidden tracking pixels can be fetched once at ingest (documented).
- Plain-text linkification; a "Newsletters" sidebar grouping separate from RSS; multiple accounts; IMAP provider — all future work the `MailProviderClient` seam anticipates.
