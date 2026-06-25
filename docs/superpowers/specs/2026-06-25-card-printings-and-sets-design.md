# Card printings & set markings — design

**Date:** 2026-06-25
**Branch:** `feat/card-printings-and-sets`
**Status:** Approved design, pre-implementation

## Problem

Two related gaps:

1. **No printings.** The app ingests Scryfall's `oracle_cards` bulk — one row per unique
   card. Each card therefore stores exactly one `set_code`/`set_name` (Scryfall's chosen
   representative printing). There is no way to see "which sets is this card in," the way
   Scryfall's card page lists every printing.
2. **Set-name search is broken.** `SearchEngine.setNameScore` matches a query against each
   card's single stored set. So searching a set name (e.g. "modern horizons") only returns
   the handful of cards whose one representative printing happens to be that set — a tiny,
   misleading slice of the set.

Both are the same missing data: per-card printing membership.

The user also wants the data to support a documented **future** feature: "show and download
other versions of this card / a specific version (cache)."

## Goals

- Store set metadata ("set markings") in the DB.
- Store every card's printings (which sets it appears in).
- Show a Scryfall-style **Printings** list in the card preview.
- Clicking a set in that list changes the search to that set's name.
- Fix set-name search so it returns **all** cards printed in the named set.
- Document the future "download other versions / per-version image cache" path.

## Non-goals (YAGNI)

- Rendering set symbols as images. We **store** `icon_svg_uri` but display set codes as text.
  (macOS `NSImage` can't load SVG natively; an asset pipeline is future work.)
- Downloading or caching per-printing images. The schema reserves `printing_id` for it; no
  download flow is built now.
- Pulling printings during the lightweight silent background ingest (bandwidth choice below).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Printings data source | Scryfall `default_cards` bulk (~one English printing per card+set) |
| Set marks display | Text (set name + code); `icon_svg_uri` stored for the future |
| Printings UX now | List in preview; click set → search that set's name |
| Ingest wiring | Manual refresh only; silent background ingest stays oracle-only (~30 MB) |

## Architecture

### 1. Data model — `Sources/Shared`

The join key is the crux. Our `cards` primary key is the Scryfall `id` of one representative
printing; printings link to a card by the stable **`oracle_id`**, which we do not currently
store. Three new migrations in `CardStore`:

- **v5 — add `oracle_id` to `cards`** (`.text`, indexed). Backfilled by the next ingest;
  `oracle_cards` JSON already carries `oracle_id`. `ScryfallCard` gains `oracle_id`; `Card`
  gains `oracleID`.
- **v6 — `sets` table** ("set markings"):
  `code` TEXT PK (uppercase), `name` TEXT, `released_at` TEXT, `set_type` TEXT,
  `card_count` INTEGER, `icon_svg_uri` TEXT.
- **v7 — `printings` table**:
  `printing_id` TEXT PK (Scryfall per-printing UUID), `oracle_id` TEXT indexed,
  `set_code` TEXT, `set_name` TEXT, `collector_number` TEXT, `released_at` TEXT,
  `rarity` TEXT.

`printing_id` is the reserved hook: a future "download this version" resolves it to an image
and caches under a per-printing directory (see Future work).

New read models:

- `Card.Printing` — `setCode`, `setName`, `collectorNumber`, `releasedAt`, `rarity`. Drives
  the preview list.
- (Internal) a lightweight set-index row used by search; no public model needed beyond what
  `loadSetIndex()` returns.

`Card` gains `oracleID: String?` so the preview can query printings for the selected card.

### 2. Fetcher — `mtg-fetcher`

New `--printings` flag. When present, after the existing oracle `ingest` phase the fetcher
runs two new phases:

- **`sets`** — GET `https://api.scryfall.com/sets` (small JSON list) → `upsertSets`. Uses the
  same `User-Agent`/`Accept` headers as the bulk index.
- **`printings`** — `bulkInfo(type: "default_cards")` → download to
  `bulk-default.json` (cached on disk; re-downloaded only when missing) → parse to
  `[Card.Printing]`+`oracle_id`+`printing_id` → `upsertPrintings` in batches of 1000, one
  NDJSON progress tick per batch.

Parsing rules for `default_cards` mirror the oracle parse: skip `token`,
`double_faced_token`, `art_series`, `emblem` layouts. Keep all sets including digital
(matches Scryfall's default prints view); filter to `lang == "en"` to avoid duplicate
language rows. Rows missing `oracle_id` are skipped.

Phase strings `"sets"` and `"printings"` are free-form `phase` values — no NDJSON schema
change — but the documented phase lists in `ProgressEmitter.swift`, `FetcherProcess.swift`,
and `CLAUDE.md` are updated in lockstep.

`FetcherProcess.Mode` mapping:

| Mode | Args | Used by |
|---|---|---|
| `.full` | `["--printings"]` | manual Refresh (with images), first download |
| `.ingestPrintings` *(new)* | `["--no-images","--printings"]` | manual text-only refresh |
| `.ingestOnly` | `["--no-images"]` | **silent background ingest (unchanged, oracle-only)** |
| `.imagesOnly` | `["--images-only"]` | unchanged (no printings) |
| `.ingestArtwork` / `.downloadAllArt` | unchanged | game data |

`AppModel.startRefresh(skipImages:)` maps `false → .full`, `true → .ingestPrintings`.
`runSilentIngest` keeps `.ingestOnly`.

### 3. Search — `SearchEngine`

The engine gains an in-memory **set index**: for each set, its code/name (+ lowercased) and
the list of member card IDs. Built once at launch from `printings ⨝ cards` (~1000 sets;
~100 k member pairs — a few MB, like `loadMinis`).

`search(query, limit)` becomes:

1. Score every `Mini` by **name** only (exact → prefix → token-start → substring →
   subsequence) — unchanged.
2. Iterate the ~1000 set entries; score the query against each set's code (exact, 500) and
   name (exact 450 / prefix·token-start 350). For a matching set, every member contributes a
   candidate score of `setScore + lengthBonus(member.name)`.
3. Merge name + set candidates into a by-ID map, keeping the **max** score per card; sort
   desc; take `limit`.

This removes the buggy per-`Mini` set scoring (the `Mini.setCode/setName` fields stay for
other callers but are no longer read by the ranker). Result: a set query returns all member
cards, ranked, capped at `limit`. Empty `printings` ⇒ empty set index ⇒ set search yields
nothing (graceful pre-refresh).

`CardStore.loadSetIndex()` runs the join:
`SELECT c.id, c.name, c.colors, p.set_code, p.set_name FROM printings p JOIN cards c ON c.oracle_id = p.oracle_id`,
grouped by set. `AppModel.refreshDBState` loads it into the engine alongside `loadMinis`.

### 4. App + UI

- `CardStore`: `loadSetIndex()`, `printings(forOracleID:)`, `upsertSets(_:)`,
  `upsertPrintings(_:)`, and counts for diagnostics. `cardFromRow` includes `oracle_id`.
- `AppModel`: `@Published selectedPrintings: [Card.Printing]`, loaded lazily when a card is
  selected (cached like the detail row); `searchSet(_ name:)` sets `query = name`, which the
  existing `TextField` binding + `onChange → runSearch` turns into a search.
- `CardPreview`: a **Printings** section under the oracle text / P-T. Each row shows
  `Set Name (CODE) · YYYY · rarity`; tapping calls an injected `onSetTap(setName)` →
  `model.searchSet`. Printings + callback are passed in from `SearchPanel` (same pattern as
  the existing `lists`/`onAddToList` injection).

### 5. Docs

- `docs/architecture.md`: new `sets`/`printings` tables, `oracle_id` join key, `sets`/
  `printings` fetcher phases, set-index search, and a **Future work** subsection (below).
- `CLAUDE.md`: subprocess phase list + a one-line note on the new tables/flag.

## Future work (documented, not built)

**Show & download other versions of a card.** The `printings` table already keys every
printing by `printing_id`. A future flow can:

1. List versions (already available from `printings(forOracleID:)`).
2. On request, resolve `printing_id` → image (Scryfall card-by-id endpoint or stored
   `image_uris`) and cache it under a per-printing path (e.g.
   `Paths.imagesDir/printings/<printing_id>.jpg`), parallel to the existing per-card cache.
3. Optionally render set symbols using the stored `sets.icon_svg_uri` once an SVG
   rasterization path exists.

No schema change is required for step 1–2; symbols (step 3) only consume an already-stored
column.

## Testing

- `SearchEngineTests` golden cases: (a) a set-name query returns multiple member cards;
  (b) a set-code query returns members; (c) an exact card-name match still outranks a
  set match for the same token. Tests construct a `SearchEngine` with minis **and** a set
  index.
- Fetcher `sets`/`printings` phases require network + a large download; verified manually
  via `swift run mtg-fetcher --no-images --printings` and inspecting row counts. (No unit
  test harness exists for the fetcher today; out of scope to add one.)
- Manual end-to-end: refresh, open a card, confirm the Printings list, click a set, confirm
  the search fills with the set name and returns many cards.

## Risk / impact notes

- `default_cards` is ~140 MB; gated behind `--printings` and manual refresh only, so silent
  background syncs stay ~30 MB.
- Launch adds one extra grouped query (`loadSetIndex`) over ~100 k rows — comparable to the
  existing `loadMinis`; acceptable, runs in the same `refreshDBState` path.
