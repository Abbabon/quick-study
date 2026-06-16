# Recently Added — Design Spec

Date: 2026-06-16
Branch: `feat/recently-added`

## Overview

A **Recently Added** feature for Quick Study: a collapsible left column inside the
search panel that surfaces the card printings most recently ingested from
Scryfall's bulk-data feed. A user who just refreshed (or just installed) can scan
and jump to what's new without typing. A "{n} New" pill flags cards that landed
in the last 7 days.

This recreates the HTML/React design reference in SwiftUI using the app's existing
views and conventions (`SearchPanel`, `ResultList`, `CardPreview`, `PinnedRow`,
`Thumbnail`, `DS` tokens, `UIScale`). The reference is a pixel/interaction spec,
not code to port.

## Key decisions (resolved during brainstorming)

1. **Data source stays `oracle_cards`.** The app ingests one row per oracle card
   (deduplicated by name), which the in-memory search engine depends on. We do
   **not** switch to `default_cards` (per-printing) — it would ~5× the DB and
   break the "one row per name" model. Each oracle row carries a representative
   printing's `set` / `set_name` / `released_at`, which is what we surface.
2. **`date_added` = the card's `released_at`** (date-only, `"YYYY-MM-DD"`), stamped
   once on first insert and never overwritten on later refreshes. This makes
   "Recently Added" effectively "recently released cards in your DB", and the
   column populates immediately after the first ingest (no empty initial state).
3. **Load the full 30-day window; show ~6 rows, scroll for the rest.** No hard
   `LIMIT 6` — the query returns everything within 30 days (capped at 200 for
   safety), the column body is sized to ~6 rows and scrolls vertically.
4. **In scope:** the column, sidebar toggle, preview meta strip, and a
   Settings → Behavior toggle ("Show recently added cards", default on).
   **Deferred:** in-column keyboard navigation (↑/↓/↩ within the column).

## Constants

- New window: **7 days** · Look-back window: **30 days** · Visible rows: **~6**
  (scroll for more) · Safety cap on query: **200**.

## A. Data layer

### Migration `v2` (`CardStore`)

Add to `cards`:

- `date_added TEXT` — Scryfall `released_at`, `"YYYY-MM-DD"`, lexically sortable.
- `set_code TEXT`
- `set_name TEXT`

### Parsing & models

- `ScryfallCard` gains `released_at: String?`, `set: String?`, `set_name: String?`;
  `toCard()` carries them through.
- `Card` gains `setCode: String?`, `setName: String?`, `dateAdded: String?`
  (date-only string). These are populated from the row; existing callers/inits
  updated.
- New projection `Card.Recent` — `id, name, identity, setCode, setName,
  dateAdded: Date`. (`dateAdded` parsed from the stored `"YYYY-MM-DD"`.)

### Upsert semantics (the crux)

`upsert(_:)` includes `date_added`, `set_code`, `set_name` in the INSERT VALUES.
In the `ON CONFLICT DO UPDATE SET` clause:

- `set_code = excluded.set_code`, `set_name = excluded.set_name` (refresh on reprint)
- `date_added = COALESCE(date_added, excluded.date_added)` — fills NULLs once
  (backfills pre-migration rows on the next ingest), never overwrites an existing
  value. Idempotent and resumable, matching the existing ingest contract.

New cards lacking `released_at` fall back to today's date at insert time.

### New read

```swift
func recentlyAdded(lookbackDays: Int = 30, limit: Int = 200) throws -> [Card.Recent]
```

`SELECT id, name, colors, set_code, set_name, date_added FROM cards
 WHERE date_added IS NOT NULL AND date_added >= ?
 ORDER BY date_added DESC LIMIT ?`

where `?` threshold is `today − lookbackDays` formatted `"YYYY-MM-DD"`.

## B. Model / state (`AppModel`)

- `@Published var recentlyAdded: [Card.Recent] = []` — populated in
  `refreshDBState()` (alongside `engine.load`) and after a `done` fetcher event.
- `@Published var recentlyAddedExpanded: Bool = true` — session UI state, flipped
  by the sidebar toggle. Not persisted.
- `@Published var selectedRecent: Card.Recent? = nil` — set when a recent row is
  clicked; drives the preview meta strip. Cleared on any `query` change and on
  normal result selection.
- `var newCount: Int` — `recentlyAdded.filter { now − dateAdded ≤ 7 days }.count`.
- `var showsRecentColumn: Bool` — `showRecentlyAdded (setting) && !recentlyAdded.isEmpty`.
- `func selectRecent(_ r: Card.Recent)` — `select(r.id)`, set `selectedRecent`,
  **clear `query`** so the panel enters browse mode (preview spans the content area).

`showRecentlyAdded` is read via `UserDefaults`/`@AppStorage` ("showRecentlyAdded",
default `true`).

## C. UI

All sizes via `UIScale`; all colors/radii/motion via `DS`.

### `RecentlyAddedColumn.swift` (new)

- Fixed width **222pt**, full content-band height, **0.5px** trailing separator.
- **Header** (`PaneHeader`): padding `10/8/6/12`, gap 6 — `clock` SF Symbol (15pt,
  secondary) + "Recently Added" (13pt semibold) + `{n} New` accent **Badge** when
  `newCount > 0`. 0.5px hairline directly under the header.
- **List**: scrolling `LazyVStack` of `RecentRow`, sized to ~6 rows then scrolls;
  container padding `2/6/6`, 1px row gap.

### `RecentRow`

- Padding `4/8`, radius 6 (`DS.Radius.sm`), gap 10:
  - `Thumbnail(id:identity:)` ~28–32pt wide at 63:88 ratio.
  - Name (14pt, 1-line ellipsis); trailing **6pt accent dot** iff ≤7 days.
  - Secondary line (11pt): `"{Set Name} · {relative time}"`, the `· {time}`
    portion tertiary.
  - Hover → `DS.hover`-equivalent; selected (`mini.id == selectedID`) →
    `DS.selection`. Transition ~0.08s.

### `RelativeTime` helper

`today / 1 day ago / N days ago / 1 week ago / N weeks ago` (day-granularity).

### `SearchPanel` changes

- **Sidebar toggle**: borderless icon button at the leading edge of the
  search-field row, hit area 30×30, radius 6, SF Symbol `sidebar.leading`
  (fallback `sidebar.left`), 18pt. Accent when expanded, secondary when collapsed.
  Only rendered when `showsRecentColumn`. Toggles `recentlyAddedExpanded`.
- **Column placement**: wrap `content` in an `HStack`; render
  `RecentlyAddedColumn` to its left when `showsRecentColumn &&
  recentlyAddedExpanded`. Panel width animates with `DS.Motion.resize` (~0.2s),
  skipped under `prefers-reduced-motion` (`@Environment(\.accessibilityReduceMotion)`).
- **Preview meta strip**: above `cardPreview`, shown when `selectedRecent != nil`.
  Padding `8/16`, 0.5px bottom hairline, 11pt secondary: optional "New" accent
  Badge (≤7d) then `"Added {relative time} · {Set Name} ({CODE})"`.

### `SettingsView`

- "Show recently added cards" toggle in the **Behavior** group, `@AppStorage`,
  default on. When off, the column and toggle disappear entirely.

## D. Testing

`swift test` (XCTest), matching the existing `SearchEngineTests` style:

- `CardStoreTests` (new or extended): insert rows with known `date_added`, assert
  `recentlyAdded` returns newest-first, respects the 30-day cutoff, honors the
  cap, and that re-`upsert` does **not** overwrite an existing `date_added`
  (`COALESCE` behavior) while NULLs get backfilled.
- `RelativeTimeTests`: bucket boundaries (today, 1 day, N days, 1 week, N weeks).

## Out of scope / coexistence

- In-column keyboard navigation (deferred).
- Coexists with the Pinned row (independent region); a card may be both recent and
  pinned. No change to search, results, or pinned behavior.
