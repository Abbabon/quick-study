# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Never develop directly on `master`. **For each new feature, create a dedicated git worktree** so multiple features can be developed simultaneously without stepping on each other's working tree.

```sh
# Create a worktree + branch for a new feature (sibling dir, keeps master clean)
git worktree add ../quick-study-<feature> -b feat/<feature>

# List active worktrees
git worktree list

# Remove a worktree once its branch is merged
git worktree remove ../quick-study-<feature>
```

Guidelines:
- One worktree per in-flight feature; name the branch `feat/<feature>` and the directory `quick-study-<feature>`.
- Keep each worktree's changes scoped to its own feature — don't mix unrelated work onto one branch.
- The SPM build cache (`.build`) is per-worktree; the first `swift build` in a fresh worktree may re-fetch/re-compile dependencies.
- The shared SQLite DB and image dir live under `~/Library/Application Support/QuickStudy/` and are *not* per-worktree — concurrent fetcher runs across worktrees write the same DB, so avoid running `mtg-fetcher --printings` from two worktrees at once.

### Committing & delivering for review

These are non-negotiable when working in a worktree — skipping them means the user
tests the wrong build and the work appears lost:

- **Commit as you go.** After each self-contained change builds + tests green,
  commit it on the feature branch (don't leave a pile of uncommitted edits at the
  end). Commit messages end with the `Co-Authored-By` trailer.
- **Install for the user to verify, don't just build.** A `swift build` or a
  bundle in the worktree's `dist/` is NOT what the user launches. When a change is
  meant for the user to check, run `./scripts/install-local.sh` so it lands in
  `/Applications` (kills the running instance, re-signs, relaunches). Then tell the
  user it's the installed app they should test.
- **Verify on the installed build.** Any "this is faster / fixed" claim must be
  observed on the `/Applications` copy, not the master checkout in the primary
  working dir.

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
- **`Sources/QuickStudy`** (SwiftUI menu-bar app) — runs as a `.regular` Dock app (`LSUIElement = NO` + `NSApp.setActivationPolicy(.regular)`) while also living in the menu bar. `AppDelegate` wires the global hotkey via Sindre Sorhus's `KeyboardShortcuts`. `PanelController` is a borderless non-activating `NSPanel` with an `NSVisualEffectView` (`.hudWindow`) — Spotlight-style. `AppModel` (`@MainActor ObservableObject`) holds query/results/refresh state and owns `SearchEngine`, `CardStore`, `FetcherProcess`, and an `NSCache` for full-row detail.

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
