# QuickStudy → Rust engine migration plan

> Status: **Stages 0, 1 and 2 done; stage 3 next** (was: post-grill, awaiting confirmation) · 2026-11-08 · baseline `master` @ 865d2f2 (v0.6.1-dev)

## Goal

- Move QuickStudy's engine to Rust, as a shared core that a future Windows client can reuse.
- Keep the macOS UI native (SwiftUI/AppKit).
- Fix the two real pain points along the way:
  1. typing lag in the search panel;
  2. slow hotkey → panel open.

Rust is a goal in its own right, not only a perf fix.

## Decisions (from the grill)

| # | Decision | Choice |
|---|---|---|
| Q1 | What's slow | Typing lag + hotkey → panel open (not the fetcher) |
| Q2 | Why Rust | Rust is a goal; at least the engine moves |
| Q3 | Cross-platform | Yes, Windows (and maybe Linux) eventually |
| Q4 | App Store | Must-ship; account exists; upload comes later |
| Q5 | Core scope | **Data engine in Rust:** models, schema + migrations, search, query parser, card lists, update checks, fetcher logic. Each UI keeps presentation state, windows, hotkey and tray. |
| Q6 | Process model | **Keep the split.** `mtg-fetcher` stays a separate process, now a thin Rust binary over the core crate. NDJSON protocol unchanged. |
| Q7 | Lag fix timing | **Phase 0 in Swift first:** measure, then fix |
| Q8 | Second platform | Core designed to be portable; Windows is the next target; UI toolkit chosen after the macOS core is proven |
| Q9 | Bridge | **UniFFI** (async + callbacks; C# bindings exist for a possible WinUI client) |
| Q10 | Layout | **Monorepo, one crate at `engine/`:** core lib + `ffi` feature (UniFFI) + `mtg-fetcher` bin. Split into a workspace only when Windows needs it. |
| Q11 | Order | **Phase 0 → fetcher → search → database** |
| Q12 | Search port | **1:1.** Golden tests are the gate; improvements come after. |
| Q13 | Intel | **arm64-only**; revisit at App Store upload |
| Q14 | Migrations during transition | **Port v1–v9 to Rust in stage 2, using GRDB's `grdb_migrations` ledger** (same identifiers; schema-diff test). Schema **frozen at v9** until stage 4. The ledger stays permanently. |
| Q15 | XCFramework | **Gitignored, built by `scripts/build-engine.sh`.** Called from build/install/release scripts; a fresh clone runs it once. |
| Q16 | Phase 0 targets | Keystroke → results drawn p99 < 16 ms; hotkey → panel < 100 ms warm / < 300 ms first open; `SearchEngine.search` p99 < 1 ms on 35k cards |
| Q17 | gzip under sandbox | **Defer to the Rust fetcher** (`flate2`). App Store upload happens after stage 2. |

## Baseline facts (2026-11-08)

- **Fetcher (after the bulk-index fix):** oracle refresh takes ~6 s (download 1.0 s, parse 2.4 s, ingest 2.0 s).
- **Full image run:** ~33 min at 8 concurrent downloads, about 97% of wall-clock time.
- **Search:** linear scan over 34.7k cards on the main actor, with per-call allocations, **never benchmarked**. The golden corpus has only 10 names.
- **Known main-thread work:**
  - folder-size scans over ~85k files (Settings, game window);
  - `GameSession` loading 49.8k artworks;
  - one NDJSON event plus one main-actor Task per image;
  - full-JPEG thumbnail decode with no downsampling.
- **Fetcher waste:**
  - ~35k one-row transactions on every images run;
  - a new `JSONEncoder` per row;
  - a new `ISO8601DateFormatter` per event;
  - the 558 MB `default_cards` decoded whole.
- **Memory:** 96 MB idle footprint. Binaries are arm64-only; release builds are ad-hoc signed.
- **No CI.** All gates are local runs.

## Stage 0: measure and fix in Swift (~1–2 days)

1. Add `os_signpost` intervals for: launch DB load, `runSearch`, results render, hotkey → panel visible, detail load and thumbnail decode.
2. Add a `SearchEngine` benchmark test on a real 35k-card fixture (dumped from the DB) that asserts p99 < 1 ms.
3. Measure on the installed `/Applications` build and record the numbers in `docs/perf-baseline.md`.
4. Fix whatever misses the Q16 targets. Likely candidates:
   - folder-size scans → detached + cached;
   - `GameSession` load → off main;
   - progress throttled to ≤10 events/s;
   - thumbnail downsampling (`CGImageSourceCreateThumbnailAtIndex`);
   - SwiftUI results-list invalidation;
   - pre-warming the panel's hosting view at launch.
5. **Exit:** Q16 targets met on the installed build, with numbers committed. Record in the baseline doc whether search alone was ever the bottleneck.

## Stage 1: `engine/` crate + Rust `mtg-fetcher`

> **Status: done** (branch `feat/rust-stage-1-fetcher`). Parity gate: zero `.dump` diff between the Swift and Rust fetchers, both on a fresh DB (oracle → printings → artwork) and on a copy of the real DB seeded with stale cards, list entries and a future-dated `date_added`; the downloaded bulk files are also byte-identical (`flate2` vs `/usr/bin/gunzip`). Sandbox smoke test (`build-appstore.sh --adhoc`, refresh + bounded image download inside the container) green.
>
> | Measure (this machine) | Swift | Rust |
> |---|---|---|
> | Oracle refresh (`--no-images`, fresh DB) | 3.5 s, 548 MB RSS | 1.8 s, 58 MB |
> | `--printings` run | 11.3 s, 1.5 GB RSS | 5.9 s, 57 MB |
> | `--artwork` | 8.3 s, 733 MB | 2.0 s, 47 MB |
> | 1,381 images (8 vs 32 concurrent) | 13.4 s | 4.6 s |
>
> Deliberately reproduced Swift behavior: `printings` is upsert-only (stale rows are never reconciled, so a long-lived DB keeps ~250 rows more than the phase total); `artworks` upsert collapses duplicate `illustration_id`s (fresh DB: 52,215 rows vs a 52,277 phase total). `QUICKSTUDY_DATA_DIR` (both Swift `Paths` and Rust) relocates data for scratch/parity runs.

### Scaffold

- `engine/Cargo.toml` with a pinned `rust-toolchain.toml`.
- Deps:
  - `rusqlite` (`bundled`);
  - `serde` / `serde_json` for streaming JSONL;
  - `flate2`;
  - `reqwest` (rustls) + `tokio`;
  - `time`.

### Schema

- Port migrations v1–v9 into `engine`, writing to the `grdb_migrations` ledger with identical identifiers.
- **Schema-diff test:** create a DB via GRDB, create one via Rust, and require `sqlite_master` to match.
- Schema frozen at v9 until stage 3 ends.

### Fetcher

A port of every phase, honoring the contract byte-for-byte:

- **CLI flags:** `--no-images`, `--printings`, `--images-only`, `--artwork`, `--download-art`. Exit 1 on error.
- **NDJSON events** `{phase, done, total, message, newCards}`:
  - phases: `start|json|ingest|sets|printings|artwork|images|done|error`;
  - `done` carries `newCards`;
  - progress throttled.
- **Paths:**
  - `~/Library/Application Support/QuickStudy/{cards.sqlite, images/, art/}`;
  - log at `~/Library/Logs/QuickStudy/fetcher.log`;
  - legacy `MTGSpotlight` migration;
  - sandbox container resolution.
- **DB semantics:**
  - `first_seen` is never updated; `date_added` takes the min of old and new;
  - set codes uppercased;
  - `name_lower` must equal Swift's `lowercased()`;
  - JSON-text columns `cards.colors`, `artworks.colors`, `printings.games`;
  - per-column date formats;
  - meta keys;
  - reconcile of `card_list_items`;
  - `image_path = "images/<id>.jpg"`.
- **Image layout:** `images/<id>.jpg`, `images/<id>_back.jpg`, `art/<illustration_id>.jpg`.
- **Scryfall etiquette:**
  - descriptive `User-Agent` + `Accept` on every request;
  - API traffic < 10 req/s;
  - image CDN is not rate-limited, so 16–32 concurrent downloads with batched DB writes.

### Parity gate

- Run the Swift and Rust fetchers against the same cached bulk files into two DB copies.
- Require a zero `.dump` diff, excluding timestamps.
- Add golden Unicode rows ("Æther", "Lim-Dûl", "Jötun").
- Swift `FetcherProcess` must decode captured Rust NDJSON.

### Build

- `build-app.sh` runs `cargo build --release` and copies the binary to `Contents/MacOS/mtg-fetcher`.
- `build-appstore.sh --adhoc` smoke test: a refresh runs end-to-end inside the sandbox.

### Cutover and cleanup

- Delete `Sources/Fetcher` and the fetcher-only write paths in `CardStore`.
- Update CLAUDE.md: dev commands, `MTG_FETCHER_PATH` pointing at `engine/target/...`, and `newCards` in the schema.

### Targets

- Oracle refresh ≤ 2 s.
- Printings peak RSS < 100 MB.
- Images 2–3× faster than the stage-0 baseline.

**Exit:** parity gate green, sandbox smoke test green, installed build refreshing correctly. **App Store upload is unblocked from here.**

## Stage 2: search + query parser via UniFFI

> **Status: done** (branch `feat/rust-stage-2-search`). Deviations from the steps below:
> - **Index source:** Rust builds the index by reading SQLite directly (read-only, path from Swift), instead of `SearchIndex::build(minis)` over FFI. The FFI is `SearchIndex.open(dbPath:)` / `.empty()`, `.search(query:)` (parses internally, so `parse_query` is not exported), `.searchName(name:limit:)` (Guess-the-Card autocomplete) and `.cardCount()`.
> - **Build script:** `scripts/build-fetcher.sh` was replaced by `scripts/build-engine.sh` (static lib → XCFramework + generated Swift bindings in `Sources/EngineBindings`, plus `mtg-fetcher`).
> - **Gates:** 143,503-query replay with 0 diffs (not 1k); p99 0.854 ms through the FFI; sandbox smoke test green. Numbers in `docs/perf-baseline.md`.

1. Add the `ffi` feature: UniFFI exports for `SearchIndex::build(minis)`, `search(query, filters) -> [Hit]` and `parse_query`.
2. Add `scripts/build-engine.sh`, which runs `cargo build` and then packages the XCFramework (gitignored) as an SPM `binaryTarget`. Build, install and release scripts call it.
3. 1:1 port of the scorer: exact → prefix → token-start → substring → subsequence/initials, `lengthBonus`, top-20.
4. Port all golden `SearchEngineTests` cases to Rust and keep a thin Swift test that calls through FFI.
5. `AppModel.runSearch` calls Rust, and the Swift `SearchEngine`/`QueryParser` are deleted.

**Exit:**
- golden tests green in Rust;
- Q16 targets still met through FFI;
- no ranking diffs on a large query replay (Swift vs Rust compared in one test before deletion).

## Stage 3: DB read layer + card lists via UniFFI

1. Move every remaining `CardStore` operation behind the Rust API:
   - `loadMinis`, the set index, filter fields, detail + printings, recently added, card lists CRUD;
   - update checks (Scryfall "new cards", GitHub app update).
2. Remove the GRDB dependency. `Shared` either disappears or shrinks to Swift-side view types.
3. The schema freeze lifts: new migrations go into Rust only.

**Exit:**
- `Package.resolved` no longer contains GRDB;
- user card lists survive the upgrade on a copy of the real DB;
- Q16 targets still met.

## Later (not scheduled)

- **Windows client.** Split `engine/` into a workspace (`core`, `ffi`, `fetcher`) when it starts. Choose the UI toolkit then: Tauri v2 / Slint / native WinUI 3 via UniFFI C# bindings.
- **Linux.** Wayland global hotkeys only work via the GlobalShortcuts portal (KDE, Hyprland). Treat Linux as best-effort.
- Search improvements beyond the 1:1 port.
- Intel/universal builds.

## Non-goals

- A Rust UI on macOS.
- Folding the fetcher into the app process.
- Changing data sources.

## Risks

| Risk | Mitigation |
|---|---|
| Data drift (lowercasing, dates, upsert rules) | Parity gate + Unicode golden rows |
| Migration divergence between GRDB and Rust during stages 1–2 | Schema-diff test + v9 freeze |
| Sandbox rejects something in the Rust binary or static lib | `--adhoc` App Store smoke test at stages 1 and 2 |
| FFI overhead eats the per-keystroke budget | Q16 targets re-checked through FFI at stage 2 exit |
| Two toolchains, no CI | `build-engine.sh` called by every script; consider a minimal GitHub Actions job once Rust lands (not planned) |
| Stage 2 turns out to be "for Rust's sake" (search was never the bottleneck) | Accepted. Rust is a goal (Q2); the baseline doc records it honestly |

## Workflow

- Each stage gets its own worktree and branch (`feat/rust-stage-N-…`), per CLAUDE.md.
- Commit as you go, and verify on the installed build via `install-local.sh`.
- Each stage starts with an `/opsx:propose` change built from this plan.
