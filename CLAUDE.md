# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Unit tests (SearchEngine golden cases)
swift test

# Run a single test
swift test --filter SearchEngineTests.SearchEngineTests/testExactBeatsPrefix

# Build the .app bundle (Release) into ./dist, codesigns ad-hoc
./scripts/build-app.sh           # or: ./scripts/build-app.sh debug

# Build, then install into /Applications (kills running instance, re-signs, relaunches)
./scripts/install-local.sh       # or: ./scripts/install-local.sh debug

# Dev iteration without the .app bundle — the app shells out to mtg-fetcher,
# so MTG_FETCHER_PATH must point at the built binary or it won't find it.
swift run mtg-fetcher --no-images
# Add --printings to also run the sets + printings phases (~150 MB default_cards download; manual refresh only)
swift run mtg-fetcher --no-images --printings
MTG_FETCHER_PATH="$(swift build --show-bin-path)/mtg-fetcher" swift run QuickStudy

# Regenerate the app icon (needs Python 3 + Pillow)
python3 scripts/generate-icon.py
```

`swift build` may pull `GRDB.swift` and `KeyboardShortcuts` from SPM on first run (needs network). Minimum target is macOS 14.

## Architecture

Two executables sharing one SQLite DB and one image directory under `~/Library/Application Support/QuickStudy/`. This split is the core design choice — keep it. The app never parses bulk JSON in-process; it always shells out.

- **`Sources/Shared`** — library imported by both executables. Owns `Paths`, the `Card` / `Card.Mini` models, and the GRDB-backed `CardStore` (migrations, upserts, meta kv). Any cross-boundary contract belongs here.
- **`Sources/Fetcher`** (`mtg-fetcher` CLI) — the only writer. Four phases (`json` → `ingest` → `images` → `done`/`error`), each emitting one NDJSON line per progress tick to stdout, mirrored to `~/Library/Logs/QuickStudy/fetcher.log`. Idempotent and resumable: image downloads skip files already on disk; ingest is `INSERT … ON CONFLICT DO UPDATE`. `--no-images` skips phase 3.
- **`Sources/QuickStudy`** (SwiftUI menu-bar app) — `LSUIElement = YES`, no Dock icon. `AppDelegate` wires the global hotkey via Sindre Sorhus's `KeyboardShortcuts`. `PanelController` is a borderless non-activating `NSPanel` with an `NSVisualEffectView` (`.hudWindow`) — Spotlight-style. `AppModel` (`@MainActor ObservableObject`) holds query/results/refresh state and owns `SearchEngine`, `CardStore`, `FetcherProcess`, and an `NSCache` for full-row detail.

### Subprocess protocol

`FetcherProcess` spawns `mtg-fetcher`, reads stdout incrementally via `Pipe.readabilityHandler`, splits on `\n`, decodes each NDJSON line, and forwards to `AppModel.applyFetcherEvent(_:)` on the main actor. Schema:

```json
{"phase":"json|ingest|images|sets|printings|start|done|error","done":<int|null>,"total":<int|null>,"message":<string|null>}
```

When adding a new phase or field, update both `Fetcher/ProgressEmitter.swift` and `QuickStudy/FetcherProcess.swift` in lockstep.

### Search engine

`SearchEngine` is intentionally synchronous, in-memory, no debounce, no SQLite hit per keystroke. All ~25k `Card.Mini` rows (~2 MB) are loaded at launch. Layered scorer: exact → prefix → token-start → substring → subsequence/initials, each with a `lengthBonus = max(0, 100 - name.count)` so short names win on ambiguous queries. Target latency <1 ms — `SearchEngineTests` golden cases protect ranking order; add a case there before tweaking weights. Detail rows for highlighted IDs are fetched lazily from SQLite via `NSCache`.

### Database

GRDB with WAL + `synchronous=NORMAL`. Migrations via `DatabaseMigrator` in `CardStore`. `cards` table is indexed on `name_lower`; `meta` is a kv table (`last_refresh`, `bulk_updated_at`). Migration v6 adds `cards.oracle_id` (the join key to `printings`); v7 adds the `sets` table (code, name, set_type, card_count, `icon_svg_uri` — stored for future symbol rendering); v8 adds the `printings` table (one row per card+set, indexed on `oracle_id`). Schema changes require a new migration registered in `CardStore`.

### Bundling

`scripts/build-app.sh` assembles the `.app` from `swift build` output: both binaries land in `Contents/MacOS/` (so the app finds `mtg-fetcher` next to itself without `MTG_FETCHER_PATH`), `Info.plist` and `AppIcon.icns` go to standard locations, then ad-hoc codesigned. Don't rely on Xcode project files — there are none.

## Reference docs

- `docs/architecture.md` — full shipped design, including the per-file table, NSPanel flags, and a "suggested subtask split" for future work.
- `docs/plan.md` — original spec and decision rationale; verification checklist at the end is the authoritative end-to-end test list.
- `docs/STATUS.md` — known caveats (Sendable/StrictConcurrency, `onKeyPress` macOS-14 requirement, LaunchAgent toggle not yet wired).
