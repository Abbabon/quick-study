# Quick Study — Architecture

This document captures the shipped architecture for future subtasking and onboarding. It reflects what's on disk after the initial build; for the original spec and decision rationale, see `docs/plan.md`.

## 1. System overview

```
┌─────────────────────────────────────────────────────────────────────┐
│            ~/Library/Application Support/QuickStudy/              │
│                                                                     │
│   cards.sqlite         images/<uuid>.jpg         bulk-oracle.json   │
│        ▲   ▲                  ▲                       ▲             │
│        │   │                  │                       │             │
│   read │   │ write       read │              write    │ write       │
│        │   │                  │                       │             │
│   ┌────┴───┴─────┐   ┌────────┴───────────────────────┴──┐          │
│   │ QuickStudy   │   │              mtg-fetcher           │          │
│   │    .app      │──▶│   (CLI; spawned as subprocess)     │          │
│   │ (menu bar)   │   │   Scryfall bulk JSON + images      │          │
│   └──────────────┘   └────────────────────────────────────┘          │
│        ▲                                                            │
│        │ ⌥⌘M (configurable)                                         │
└────────┼────────────────────────────────────────────────────────────┘
        user
```

Two executables, one SQLite database, one image directory. The app spawns the fetcher as a subprocess and streams NDJSON progress events from its stdout into the UI.

## 2. Components

### 2.1 `Shared` (Swift library)

Used by both executables. Keeps every cross-boundary contract in one place.

| File | Purpose |
|---|---|
| `Sources/Shared/Paths.swift` | Locations on disk: support dir, images dir, DB URL, log file. Creates dirs lazily. |
| `Sources/Shared/Card.swift` | `Card` (full row) and `Card.Mini` (id+name, loaded in-memory for search). |
| `Sources/Shared/CardStore.swift` | GRDB-backed SQLite reader/writer. Migrations, upsert, image-path setter, meta kv. |

### 2.2 `mtg-fetcher` (CLI executable)

The "separate scrape/cache flow" — owns all writes to the DB and image dir. Idempotent and resumable.

Flow:

1. **`json` phase** — fetch Scryfall's bulk-data index, pick `oracle_cards`, download the bulk JSON (~50 MB).
2. **`ingest` phase** — decode into `Card` records, upsert into SQLite in batches of 1000.
3. **`images` phase** — extract `(id, normal-image-url)` refs from the bulk JSON, download in parallel (concurrency 8) into `images/<uuid>.jpg`. Skips files already on disk so reruns are cheap.
4. **`done` / `error`** — terminal event.

Each phase emits one NDJSON line per progress tick to stdout:
```json
{"phase":"images","done":1234,"total":25000}
```
Mirrored to `~/Library/Logs/QuickStudy/fetcher.log` in human-readable form.

CLI flags:
- `--no-images` — JSON + ingest only, skip image download.

| File | Purpose |
|---|---|
| `Sources/Fetcher/Fetcher.swift` | `@main`, orchestrates the four phases. |
| `Sources/Fetcher/ScryfallClient.swift` | Bulk-data API client + JSON parser. |
| `Sources/Fetcher/ImageDownloader.swift` | Actor with bounded concurrency. |
| `Sources/Fetcher/ProgressEmitter.swift` | NDJSON-to-stdout + log-file mirror. |

### 2.3 `QuickStudy` (SwiftUI app executable)

Menu-bar-resident app. No Dock icon (`LSUIElement = YES` in Info.plist + `NSApp.setActivationPolicy(.accessory)` at runtime).

| File | Purpose |
|---|---|
| `Sources/QuickStudy/QuickStudyApp.swift` | `@main`, `AppDelegate`, status-bar menu, global hotkey wiring via `KeyboardShortcuts`. |
| `Sources/QuickStudy/PanelController.swift` | Borderless `NSPanel` with `NSVisualEffectView` (`.hudWindow`). Floating, non-activating, auto-dismisses on focus loss / Esc. |
| `Sources/QuickStudy/AppModel.swift` | `@MainActor ObservableObject`. Holds query, results, selection, refresh state. Owns `SearchEngine`, `CardStore`, `FetcherProcess`, `NSCache` for detail rows. |
| `Sources/QuickStudy/SearchEngine.swift` | In-memory fuzzy ranker (see §3). |
| `Sources/QuickStudy/FetcherProcess.swift` | Spawns `mtg-fetcher` via `Process`, parses NDJSON from stdout, calls back on the main actor. |
| `Sources/QuickStudy/Views/SearchPanel.swift` | Top-level panel content: search field + result body. Handles ↑↓/Enter/Esc. |
| `Sources/QuickStudy/Views/ResultList.swift` | Left list with thumbnail + name, keyboard nav, scroll-into-view. |
| `Sources/QuickStudy/Views/CardPreview.swift` | Right pane: large image + formatted oracle text. |
| `Sources/QuickStudy/Views/DownloadPromptView.swift` | First-run / refresh-in-progress UI shown inside the panel. |
| `Sources/QuickStudy/SettingsView.swift` | Hotkey rebinder, Enter-behavior picker, refresh button + progress. |

## 3. Search engine

All ~25k card names (~2 MB) are loaded into memory at app launch as `[Card.Mini]`. Each keystroke runs synchronously through a layered scorer (no debouncing, no async, no SQLite hit):

| Layer | Score | Trigger |
|---|---|---|
| Exact match | 1000 + length bonus | `name == query` |
| Prefix | 800 + length bonus | `name.hasPrefix(query)` |
| Token-start | 600 + length bonus | each query word prefix-matches consecutive name tokens |
| Substring | 400 + length bonus | `name.contains(query)` |
| Subsequence/initials | 200 − spread | every query char appears in order, scored by tightness |

`lengthBonus = max(0, 100 - name.count)` favors shorter names so "Bolt" beats "Lightning Bolt of the …" when the query is "bolt". Top 20 returned. Detail rows for highlighted IDs are fetched lazily from SQLite via `NSCache`.

Target latency: <1 ms per keystroke. Verified by `Tests/SearchEngineTests/SearchEngineTests.swift` golden cases.

## 4. Database schema

```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,        -- Scryfall UUID
    name TEXT NOT NULL,
    name_lower TEXT NOT NULL,   -- indexed
    mana_cost TEXT,
    type_line TEXT,
    oracle_text TEXT,
    power TEXT,
    toughness TEXT,
    colors TEXT NOT NULL DEFAULT '[]',   -- JSON array
    image_path TEXT,            -- relative to images dir; NULL if not yet downloaded
    scryfall_uri TEXT NOT NULL
);
CREATE INDEX cards_name_lower ON cards (name_lower);

CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- known keys: last_refresh, bulk_updated_at
```

WAL journal mode, `synchronous = NORMAL`. Migrations via GRDB's `DatabaseMigrator`.

## 5. Process boundaries & coupling

Only the SQLite DB and image directory are shared state between the two executables. The app does not in-process the bulk JSON — it always shells out to the fetcher. This is the key design choice that makes the "separate scrape/cache flow" requirement clean:

- The fetcher can be invoked from a `launchd` LaunchAgent (template at `Resources/com.abbabon.quickstudy.refresh.plist`) for weekly background refreshes, independent of the app being running.
- The fetcher can be run from the command line during development, decoupled from any UI work.
- The app starts fast (no parsing on launch), reads only what it needs (minis at startup, full rows on selection).

## 6. Hotkey & panel behavior

`KeyboardShortcuts` (Sindre Sorhus, MIT) handles the global hotkey, including the rebinder UI in Settings. Default is ⌥⌘M, stored in `UserDefaults` under the package's keys.

Panel:
- `NSPanel` subclass with `canBecomeKey = true` (the search field needs key status to accept input) but `canBecomeMain = false`.
- Style mask: `[.borderless, .nonactivatingPanel, .fullSizeContentView]`.
- Level: `.floating`. Collection behavior includes `.canJoinAllSpaces` and `.fullScreenAuxiliary` so it appears over full-screen apps.
- Background: clear panel + `NSVisualEffectView` (`.hudWindow` material) → matches Spotlight blur/vibrancy.
- Dismissal: Esc (via `cancelOperation`) or `windowDidResignKey` (click outside).
- Position: horizontally centered, slightly above vertical center of the active screen's visible frame.

## 7. Subprocess protocol (NDJSON over stdout)

Every line is one JSON object:

```json
{"phase": "ingest" | "images" | "json" | "done" | "error" | "start",
 "done":  <int|null>,
 "total": <int|null>,
 "message": <string|null>}
```

The app reads stdout incrementally via `Pipe.readabilityHandler`, buffers, splits on `\n`, decodes each complete line, and forwards events to `AppModel.applyFetcherEvent(_:)` on the main actor.

## 8. Resilience

- **Image download** is fully resumable: skips files already on disk; failures are silent (next refresh retries).
- **Bulk JSON** is re-downloaded each refresh — Scryfall publishes daily.
- **Ingest** uses `INSERT … ON CONFLICT(id) DO UPDATE`, so partial runs are safe to retry.
- **Search engine** rebuilds its in-memory index on `AppModel.refreshDBState()` after any refresh.

## 9. Suggested subtask split for future iterations

Each row below is independently shippable:

| # | Subtask | Files |
|---|---|---|
| A | Multi-printing picker — arrow through art variants | `CardStore`, `CardPreview`, schema additions |
| B | Oracle-text full-text search via FTS5 | `CardStore` migration, `SearchEngine` query mode toggle |
| C | Saved searches / favorites | new `favorites` table, list view |
| D | Mana symbol rendering (replace `{R}` etc. with images) | `CardPreview` text formatter, `Resources/symbols/` |
| E | Deck builder pane | new view, `decks` table |
| F | App icon + status-bar icon assets | `Resources/Assets.xcassets/` |
| G | ~~Launch-at-login toggle in Settings~~ — **done** via `SMAppService.mainApp` (`LoginItem.swift`), not a LaunchAgent | `SettingsView`, `LoginItem.swift` |
| H | Crash log → user-visible error banner | `AppModel`, `SearchPanel` |

## 10. Verification

See the verification checklist at the end of `docs/plan.md` — it remains the authoritative end-to-end test list.
