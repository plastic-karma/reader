# Editions — Batched Article Reveal: Design & Implementation Plan

> **Status:** in progress — M1 (models, schedule math, publishing core) in this PR; M2 scheduler backend, M3 edition-mode UI, M4 polish to follow, one PR per milestone, `bridge test` green after each.

## Context

The reader shows every article the moment it syncs. This feature batches reading instead: articles and newsletters accumulate invisibly and are **revealed together as a numbered, stored "edition"** on a chosen cadence — a newspaper delivery for feeds. Two view modes: **Global** (exactly today's behavior) and **Edition** (a picker browses editions; articles not yet in any edition are hidden), plus a manual **"Create Edition Now"** that batches everything since the last edition.

Product decisions (user-confirmed):
- Cadence presets **Manual only / Daily / Every 2 days / Weekly** (weekly picks a weekday), each at a configurable time of day (default 06:00). Shipping default: Manual — nothing publishes until the user opts in.
- The **first edition sweeps the entire existing library** (read state untouched).
- A boundary with no new articles still **publishes an empty edition** ("all caught up" is honest content).
- In edition mode, **unread badges and Mark All as Read scope to the selected edition**; Global mode stays byte-identical to today.
- Read/unread mechanics unchanged; saved-link snapshots are never part of editions.
- Boundaries missed while the app was closed collapse into **one catch-up edition, published after the launch refresh completes** (sync-then-publish, so the morning's newsletters make the morning edition).

## Architecture

```
Settings UI ──► RefreshScheduler (@MainActor @Observable — extended, no second scheduler)
                 ├─ editionFrequency / editionTimeOfDayMinutes / editionWeekday (UserDefaults mirrors)
                 ├─ nextEditionDate (observable, UI caption) · isCreatingEdition
                 ├─ createEditionNow()  (façade; engine stays private)
                 └─ loop: [refresh?] → engine.publishDueEditionIfNeeded → sleep min(interval, boundary)
                               ▼
               RefreshEngine (@ModelActor — single writer for ALL edition inserts)
                 ├─ publishEdition(scheduledFor:isManual:publishedAt:)        ← await-free = atomic
                 └─ publishDueEditionIfNeeded(cadence:now:calendar:) → Date?  ← due check + next wake
                               ▼
               EditionSchedule (nonisolated pure Calendar math — no clock seam)

ContentView ──► EditionContext (@MainActor @Observable env object: mode + edition selection)
                 gating threaded through the one membership gate matches(_:_:within:)
```

Extending `RefreshScheduler` (vs. a second scheduler/engine): it already owns the engine, the only wake-up loop, and the settings-mirror pattern; sync-then-publish falls out of one loop for free, and a second `RefreshEngine` (= second ModelContext) could race concurrent inserts into `#Unique` upsert collisions.

## Data model (lightweight auto-migration only)

- **`Edition`** (new `@Model`): `number: Int` (1-based, sequential), `publishedAt: Date`, `scheduledFor: Date` (nominal boundary; == publishedAt for manual editions), `isManual: Bool`, `articles` relationship (`deleteRule: .nullify`, inverse `Article.edition`). **Deliberately no `#Unique` on `number`**: SwiftData unique constraints upsert-on-collision, which would silently *merge* editions on a numbering bug; uniqueness is guaranteed by the single-writer invariant instead (every Edition is created by the await-free `RefreshEngine.publishEdition`).
- **`Article.edition: Edition?`** — nil-defaulted (the Feed newsletter-fields migration pattern); nil = pending the next edition. Saved links never get one.
- **`EditionCadence`** (value struct): `frequency` (manual|daily|every2Days|weekly) + `minutesOfDay` + `weekday`, mirroring three UserDefaults scalars 1:1; `make(frequencyRaw:minutesOfDay:weekday:)` assembles leniently (unknown → manual, values clamped).
- `Edition.self` registered in the app `Schema` and every preview/test container (8 sites).

## Key algorithms

**Grid math (`Services/EditionSchedule.swift`, pure)** — `dueBoundary(cadence:lastScheduledFor:now:calendar:)` = the latest grid point at-or-before `now` not covered by the last edition (exactly one even when many boundaries elapsed — multi-boundary gaps collapse into a single catch-up); `nextBoundary(...)` = earliest boundary strictly after `now` (the scheduler's wake-up). Daily/weekly are an **absolute wall-clock grid** (`calendar.nextDate(after:matching:)`; manual editions never shift it); every2Days is **anchored on the last edition's day** (manual editions restart the two-day count). No prior edition + active cadence ⇒ the latest elapsed grid point is immediately due (inaugural sweep publishes within one loop iteration of activation, not next morning). Calendar arithmetic keeps boundaries at local wall-clock time across DST.

**Publishing (`RefreshEngine`)** — `publishEdition(scheduledFor:isManual:publishedAt:)`: number = latest+1, sweep = fetch `#Predicate { $0.edition == nil }` then in-memory saved-links filter (the `Article.markAllRead` pattern), insert + assign + save with rollback-on-failure (returns nil; due-ness derives from the persisted latest edition, so the next wake retries). **Await-free — atomic w.r.t. actor reentrancy**; that is what makes numbering collision-free. `publishDueEditionIfNeeded(cadence:now:calendar:)` publishes at most one due edition and returns the next boundary for the scheduler's sleep.

**Scheduling (`RefreshScheduler`, M2)** — three cadence mirror props (the `intervalMinutes` didSet pattern), loop rewritten to sleep `min(refresh interval, time-to-boundary)` and run the due check **after** any refresh in the iteration (sync-then-publish; the launch refresh therefore feeds the catch-up edition). Interval 0 + active cadence keeps the loop alive (today it breaks on 0). `createEditionNow()`: publishes immediately without a refresh ("to now" = what's on device), coalesced via `isCreatingEdition`; manual editions never require a loop restart (they only push boundaries later). `Task.sleep` uses ContinuousClock — deadlines elapse across machine sleep and fire promptly on wake.

## UI (M3)

- **`EditionContext`** (@MainActor @Observable env object): `mode` (global|editions, UserDefaults-mirrored, key `viewMode`) + `selection` (`.latest` follow-newest | `.specific(id)`, deliberately not persisted — every launch opens on the latest edition).
- **Gating**: `matches(_:_:within: Edition?)` — the single membership gate; nil (global mode) compiles to today's behavior. Threads through `visibleArticles`, `flattenedVisibleArticles` (j/k), `totalUnreadCount`, `Feed.unreadCount(within:)` badges.
- **Masthead** below the filter picker in edition mode: a Menu labeled with the active edition (inline Picker over all editions + "Create Edition Now"), caption "Next edition Tue 6:00 AM · 12 waiting".
- Toolbar segmented mode picker; View-menu commands ⌘1/⌘2 (mode), ⌘[/⌘] (older/newer edition), ⌘⇧E (Create Edition Now). Scoped mark-all-read variants: `Article.markAllRead(in:within:)`, `Feed.markAllRead(within:)` — nil delegates to existing paths.
- Empty states: `.noEditions` (onboarding), `.editionCaughtUp`, `.emptyEdition`. In edition mode, feeds with nothing in the selected edition are hidden even under All (a newspaper shows only sections that ran; management lives in global mode).
- Settings → General gains an "Editions" section: frequency picker, weekday picker (weekly), `DatePicker(.hourAndMinute)` bound to `editionTimeOfDayMinutes`.

## Testing

All offline, in-memory containers, fixed dates through `now:`/`calendar:` parameters (no clock seam): `EditionScheduleTests` (grid math: daily/weekly/every2Days, exact-boundary instants, multi-day catch-up collapse, bootstrap, manual-anchor semantics, Berlin DST transitions incl. the skipped-02:30 roll-forward, cadence clamping), `EditionPublishTests` (sweep membership incl. saved-links exclusion and inaugural full-library sweep, numbering, empty editions, due/no-op/catch-up contract, ingest-then-publish freshness), `ModelSchemaTests` additions (round-trip, nullify-on-edition-delete, cascade-shrink), `MarkAllReadTests` additions (edition-scoped variants + nil-scope equivalence). The scheduler loop itself stays untested (house precedent) — every decision it makes is delegated to tested pure/engine code.

## Milestones (one PR each; `bridge build` + `bridge test` green after each)

1. **M1 Foundation** *(this PR — invisible: nothing calls the new code yet)* — models + math + engine publishing + scoped helpers + tests + this doc. Human step before merging: migration smoke against a **copy** of the real store.
2. **M2 Scheduler backend** *(still invisible: default frequency manual ⇒ loop behaves like today)* — cadence mirrors, loop rewrite, `createEditionNow()`, `nextEditionDate`.
3. **M3 Edition mode UI** — EditionContext, ContentView gating/masthead/empty states, commands, Settings section.
4. **M4 Polish** — pending caption, displayLabel refinements, smoke fixes, status update here.

## Risks / deferred

- **Lightweight migration** (new entity + optional to-one on Article) is additive and matches the Feed-fields precedent, but on-disk migration is CI-untestable → manual store-copy smoke at M1.
- **Actor reentrancy**: publish methods must stay await-free; an inserted `await` reopens sweep/numbering interleaving (comment-guarded).
- **DST/timezones**: Calendar-driven grid, Berlin-fixture-tested; a timezone change between wakes just recomputes on the next wake.
- Deferred: deleting/re-cutting editions (nullify rule already returns articles to the pending pool), edition-aware notifications, surfacing failed publish saves (currently bounded silent retry).
