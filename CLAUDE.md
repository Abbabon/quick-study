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
# FIRST, on a fresh clone (and after any engine/ change): build the Rust engine. It produces the
# gitignored engine/EngineFFI.xcframework + Sources/EngineBindings/engine.swift that SwiftPM needs,
# and `swift build` / `swift test` fail with "Missing engine/EngineFFI.xcframework" without it.
./scripts/build-engine.sh        # also prints the mtg-fetcher path; build/install/release scripts call it

# Rust tests (search + query-parser golden cases, schema/parity tests)
cargo test --manifest-path engine/Cargo.toml --features ffi

# Swift tests (thin FFI smoke test + app/store tests)
swift test

# Run a single test
swift test --filter SearchEngineTests.EngineFFITests/testSearchesTheDatabaseAndMarshalsHits

# Build the .app bundle (Release) into ./dist, codesigns ad-hoc
./scripts/build-app.sh           # or: ./scripts/build-app.sh debug

# Build, then install into /Applications (kills running instance, re-signs, relaunches)
./scripts/install-local.sh       # or: ./scripts/install-local.sh debug

# The fetcher is Rust (engine/, toolchain pinned in engine/rust-toolchain.toml; install via rustup).
cargo test --manifest-path engine/Cargo.toml          # schema-vs-fixture, parse, upsert, reconcile, store/list, update-check tests (add --features ffi to also build the UniFFI layer)
cargo run --manifest-path engine/Cargo.toml --release -- --no-images
# Add --printings to also run the sets + printings phases (~150 MB default_cards download; manual refresh only)
cargo run --manifest-path engine/Cargo.toml --release -- --no-images --printings
# Scratch run that never touches the real DB/images: QUICKSTUDY_DATA_DIR=/some/dir (logs go to <dir>/logs)

# Dev iteration without the .app bundle — the app shells out to mtg-fetcher,
# so MTG_FETCHER_PATH must point at the built binary or it won't find it.
MTG_FETCHER_PATH="$PWD/engine/target/release/mtg-fetcher" swift run QuickStudy   # GUI tests: use build-app.sh (swift run QuickStudy crashes without a bundle)

# App icon: Resources/AppIcon-1024.png is the source; Resources/AppIcon.icns is built from it
# (sips resizes -> iconutil -c icns) and committed. No build step regenerates it.
```

`swift build` may pull `KeyboardShortcuts` from SPM (the only Swift package dependency) on first run (needs network). Minimum target is macOS 14.

## Architecture

Two executables (a Swift app and a Rust CLI) sharing one SQLite DB and one image directory under `~/Library/Application Support/QuickStudy/`. This split is the core design choice — keep it. The app never parses bulk JSON in-process; it always shells out.

- **`Sources/Shared`** — small Swift library of view types and macOS-side helpers: `Paths`, the `Card` / `Card.Mini` / `Card.Printing` / `Card.Recent` models, `CardList`, `Artwork`, the pure `GameEngine`. No database code: all DB access lives in `engine/`. `Paths` is mirrored by `engine/src/paths.rs` — change both together.
- **`engine/`** (Rust crate: lib + `mtg-fetcher` bin + `ffi` feature; the whole migration plan in `docs/rust-migration-plan.md`) — owns **all** database access and migrations (the schema lives only in `db.rs`; GRDB is gone), card ingest, the search engine, card lists and the Scryfall update check (below). The migration ledger keeps GRDB's `grdb_migrations` table name so databases created before the move are not migrated again (`engine/tests/schema.rs` diffs `sqlite_master` against a GRDB-created fixture). Streams bulk JSONL (no whole-file decode), gunzips in-process (`flate2`), throttles progress to ~10/s, downloads images 32-wide with batched DB writes. Core phases (`json` → `ingest` → `images` → `done`/`error`), each emitting one NDJSON line per progress tick to stdout, mirrored to `~/Library/Logs/QuickStudy/fetcher.log`. Optional phases: `sets` and `printings` (`--printings`, manual refresh only) and `artwork` (`--artwork` ingests unique_artwork metadata and exits; `--download-art` also downloads art crops in an `images` pass). `--images-only` reuses the on-disk bulk JSON and downloads only missing images, with no ingest. Idempotent and resumable: image downloads skip files already on disk; ingest is `INSERT … ON CONFLICT DO UPDATE`. `--no-images` skips the images phase.
- **Known constraint:** `SearchPanel` uses `onKeyPress`, which requires macOS 14. The package minimum is already macOS 14 (`Package.swift`); lowering it means replacing those handlers with an `NSEvent` local key monitor in `PanelController`.
- **`Sources/QuickStudy`** (SwiftUI menu-bar app) — runs as a `.regular` Dock app (`LSUIElement = NO` + `NSApp.setActivationPolicy(.regular)`) while also living in the menu bar. `AppDelegate` wires the global hotkey via Sindre Sorhus's `KeyboardShortcuts`. `PanelController` is a borderless non-activating `NSPanel` with an `NSVisualEffectView` (`.hudWindow`) — Spotlight-style. `AppModel` (`@MainActor ObservableObject`) holds query/results/refresh state and owns the Rust `SearchIndex` and `Database`, `FetcherProcess`, and an `NSCache` for full-row detail.

### Subprocess protocol

`FetcherProcess` spawns `mtg-fetcher`, reads stdout incrementally via `Pipe.readabilityHandler`, splits on `\n`, decodes each NDJSON line, and forwards to `AppModel.applyFetcherEvent(_:)` on the main actor. Schema:

```json
{"phase":"json|ingest|images|sets|printings|artwork|start|done|error","done":<int|null>,"total":<int|null>,"message":<string|null>,"newCards":<int|null>}
```

`newCards` is set only on the final `done` of an ingest run (brand-new cards added). Absent fields are omitted. When adding a new phase or field, update both `engine/src/progress.rs` and `QuickStudy/FetcherProcess.swift` (plus the captured-output test `FetcherEventDecodeTests`) in lockstep.

### Search engine

Lives in Rust: `engine/src/search.rs` (ranker + filters + read-only SQLite index load) and `engine/src/query.rs` (parser), exposed to Swift through UniFFI (`engine/src/ffi.rs`, `ffi` cargo feature). The FFI surface is `SearchIndex.open(dbPath:)` / `.empty()`, `.search(query:) -> SearchResult(hits: [Hit], total)` (parses name + inline filters, top 20), `.searchName(name:limit:)` (plain name ranking, used by Guess-the-Card autocomplete) and `.cardCount()`. `Hit` carries what the UI needs (`id`, `name`, `colors`, `setCode`, `setName`, `rarity`); `Sources/QuickStudy/EngineHit.swift` maps it to `Card.Mini`.

The index is built **by Rust reading SQLite directly** (read-only connection to `Paths.databaseURL`), not by Swift marshalling minis. `AppModel.loadEngineInBackground` builds it off the main actor and swaps it in; it is rebuilt after every refresh exactly as before. Search is synchronous, in-memory, no debounce, no SQLite hit per keystroke. Layered scorer: exact → prefix → token-start → substring → subsequence/initials, each with a `lengthBonus = max(0, 100 - name.count)` so short names win. Printable-ASCII names are matched on a flattened byte buffer; other names use a grapheme-cluster scorer mimicking Swift `String` semantics (NFD-normalized Characters). It was a deliberate 1:1 port of the old Swift engine — ranking changes are bugs; `engine/tests/search.rs` golden cases protect ranking order (add a case before tweaking weights). Target p99 <1 ms through the FFI — `swift test -c release -Xswiftc -enable-testing --filter EngineBenchmarkTests` benchmarks the real corpus. Perf numbers, instrumentation and the replay hook: `docs/perf-baseline.md`. The `-debugSearch YES` launch flag arms a notification hook that logs search results from the live (installed or sandboxed) engine. Detail rows for highlighted IDs are fetched lazily from SQLite via `NSCache`.

The engine is linked as a static library (`engine/EngineFFI.xcframework`, a SwiftPM local `binaryTarget`, arm64 only, built release regardless of the Swift config) with rusqlite linked against the **system** `libsqlite3` (no `bundled` feature) so the process has exactly one SQLite shared — a bundled copy would define its own `sqlite3_*` symbols next to the system one (two SQLites in one process). `Package.swift` links `sqlite3` explicitly on `EngineBindings` since GRDB no longer does. Don't re-enable `bundled` on macOS (a future Windows build can gate it behind a non-default feature); check with `nm -m` that no `_sqlite3_*` symbol is locally defined.

### Database

Rust owns it (`engine/src/db.rs` migrations + fetcher upserts, `engine/src/store.rs` app reads and list edits), WAL + `synchronous=NORMAL`. Swift reaches it through the UniFFI `Database` object (`Database.open(dbPath:)` runs pending migrations; `AppModel` holds one). It keeps two connections, a read-only one and a writer, each behind a mutex, alongside the separate fetcher process (WAL handles the concurrency). Calls block, so `AppModel` makes them off the main actor for the launch load and detail load; list edits are single tiny writes made synchronously. FFI surface: `cardCount`, `artworkCount`, `meta(key:)`, `card(id:)` → `CardDetail`, `printings(oracleId:)` → `[PrintingRow]`, `recentlyAdded(lookbackDays:limit:)`, `artworks()` (Guess games), `loadLists` / `listItems` / `createList` / `renameList` / `deleteList` / `addCard` / `removeCard` / `setListOrder`, plus free functions `latestOracleStamp()` (async; fetches Scryfall's bulk-data index), `isNewerThanIngested` and `stampUnixMs`. `Sources/QuickStudy/DatabaseMapping.swift` maps the records onto the `Shared` view types. `AppUpdateChecker` (GitHub release check) stays Swift next to `AppUpdater`: it is plain URLSession + semver glue tied to the macOS self-updater, not data-engine logic. `-debugDB YES` arms a notification hook that logs counts, lists and timed detail loads from a live build (`.debug.db.write` additionally creates a scratch list; sandbox checks only).

`cards` table is indexed on `name_lower`; `meta` is a kv table (`last_refresh`, `bulk_updated_at`). Migration v4 adds the `artworks` table (unique_artwork metadata); v5 adds `card_lists` and `card_list_items` (user card lists); v6 adds `cards.oracle_id` (the join key to `printings`); v7 adds the `sets` table (code, name, set_type, card_count, `icon_svg_uri` — stored for future symbol rendering); v8 adds the `printings` table (one row per card+set, indexed on `oracle_id`); v9 adds `cards.rarity` and `cards.cmc` (rows ingested before v9 stay NULL until the next ingest). Schema changes require a new migration in `engine/src/db.rs` (and a refreshed `engine/tests/fixtures` schema snapshot).

### Bundling

`scripts/build-app.sh` first runs `scripts/build-engine.sh` (the single entry point, also called by `build-appstore.sh`, `install-local.sh` and `release.sh` via `build-app.sh`: UniFFI static lib → XCFramework + Swift bindings, plus `mtg-fetcher`; `cargo build --target aarch64-apple-darwin`, arm64-only, deployment target 14.0), then assembles the `.app` from `swift build` output plus the Rust fetcher: both binaries land in `Contents/MacOS/` (so the app finds `mtg-fetcher` next to itself without `MTG_FETCHER_PATH`), `Info.plist` and `AppIcon.icns` go to standard locations, then ad-hoc codesigned. Don't rely on Xcode project files — there are none.

## Reference docs

- `docs/architecture.md` — full shipped design, including the per-file table, NSPanel flags, and a "suggested subtask split" for future work.
- `openspec/specs/` — current behavior requirements per capability.
- `docs/rust-migration-plan.md` — agreed staged plan for moving the engine to Rust (Stage 0 → fetcher → search → DB; all stages done).
