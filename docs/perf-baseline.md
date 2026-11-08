# Performance baseline (Stage 0)

> 2026-11-08 · branch `feat/rust-stage-0-perf` · M-series Mac, arm64, release builds installed to `/Applications`.
> Targets come from Q16 in `docs/rust-migration-plan.md`.

## Summary

| Target | Before | After | Met? |
|---|---|---|---|
| `SearchEngine.search` p99 < 1 ms (real 35.8k-card corpus, release bench) | p50 44.9 ms · p99 102.4 ms | p50 0.09 ms · p99 0.87–0.89 ms | **Yes** |
| Keystroke → results drawn p99 < 16 ms (installed app) | p50 74 ms · p99 99 ms | p50 23 ms · p99 60 ms (quiet machine, Stage 0); render work then cut a further 30–55% in Stage 0b (bench p50 5.5 → 3.5 ms, p90 12 → 5 ms) | **No** (see Stage 0b: at typing pace the same work takes ~5× the CPU) |
| Hotkey → panel, warm < 100 ms | p50 61 ms · max 102 ms | p50 10 ms · max 20 ms (Stage 0b, replay) | **Yes** (the ~425 ms reading was an instrumentation artifact, see Stage 0b) |
| Hotkey → panel, first open < 300 ms | 249 ms | 186–258 ms (osascript), 108–147 ms (replay) | **Yes** |
| Launch DB load (search usable) | 2.3–2.7 s | 0.76 s | Not a Q16 target; fixed in passing |

**Was search the bottleneck? Yes, in the baseline.** It was the largest single cost. In the shipped build, search took 46 ms of the 74 ms p50 keystroke (68 of 99 ms at p99), all on the main thread. After the fix, in-app search takes 0.2–0.9 ms. Nearly all of the remaining ~20 ms per keystroke is SwiftUI layout and rendering of the results list and card preview, not search. So porting search to Rust (stage 2) is no longer a performance fix: Swift search now meets its 1 ms target. Stage 2 would be "Rust for its own sake", which the plan allows. The typing-lag target now depends on UI work, which stays in Swift whatever the engine language.

## Method

### Instrumentation (`Sources/QuickStudy/Perf.swift`, left on)

- Signpost intervals in the Points of Interest category, plus one `perf <name> <ms> ms …` log line per measured interaction. Read the lines back with:
  `log show --last 5m --style compact --predicate 'subsystem == "com.abbabon.quickstudy" AND category == "perf"'`
- `keystroke`: starts at the key event's timestamp, so time the event spent queued counts. It ends when the main run loop next sleeps for 8 ms or more, after the Core Animation commit. Fields:
  - `first=`: the first committed frame;
  - `cpu=`: main-thread CPU time;
  - `search=`: `QueryParser` + `SearchEngine` time.
- `panel.open`: the same measure, taken from `PanelController.show()`, tagged `first` or `warm`.
- Other lines: `panel.make`, `panel.activate`, `panel.orderFront`, `db.load`, `cache.sizes`, `detail.load` and `thumb.decode`.

### Benchmark (`Tests/SearchEngineTests/SearchEngineBenchmarkTests.swift`)

- Loads the engine from a temp copy of the local DB. The live DB is never opened, and the test skips when no DB exists.
- Types each of 8 queries keystroke by keystroke (every prefix), plus 6 whole queries that hit the set, filter and non-ASCII paths.
- Asserts p99 < 1 ms in optimized builds only. Run it with:
  `swift test -c release -Xswiftc -enable-testing --filter SearchEngineBenchmarkTests`

### Driving the installed app

- **Before/after on a quiet machine (morning run):** `osascript` / System Events. For each of 8 queries it activates Finder, presses the real ⌥⌘M hotkey, types at 80 ms per key, backspaces and presses Esc. These numbers include OS input delivery.
- **Later runs:** the user was at the machine, so automation switched to an opt-in replay hook. Launch with `open /Applications/QuickStudy.app --args -perfReplay YES` (the flag is not persisted), then trigger with `notifyutil -p com.abbabon.quickstudy.perf.replay`. Each run takes about 11 s:
  - it opens the panel;
  - it posts real key events to it (NSTextView → binding → SwiftUI), typing and deleting 3 queries;
  - it hands focus back to the previous app.

  These runs exclude OS input delivery and the Carbon hotkey dispatch.
- The later runs had a load average of 10–22 on 14 cores. In-app search was 3–4× slower than on the quiet morning run, and wall-clock times got much noisier. The `cpu=` field was added for this reason; it was stable to about ±3 ms between identical runs.

## Before (master @ c9da453, installed, osascript, quiet machine)

| Metric | n | p50 | p90 | p99 |
|---|---|---|---|---|
| keystroke → idle | 146 | 74.1 ms | 89.5 ms | 99.0 ms |
| in-app search | 140 | 46.4 ms | 56.1 ms | 68.0 ms |
| panel open, first | 1 | 249 ms | | |
| panel open, warm | 7 | 60.6 ms | 101.6 ms (max) | |
| db.load at launch | | ~2.5 s | | |

Release bench: p50 44.9 ms, p99 102.4 ms. The `o:"draw a card"` query took 108 ms.

## After

### Search fast path only (osascript, quiet machine)

| Metric | n | p50 | p90 | p99 |
|---|---|---|---|---|
| keystroke → idle | 184 | 22.8 ms | 42.0 ms | 60.3 ms |
| keystroke → first frame (later run) | 182 | 20.9 ms | 32.1 ms | 64.7 ms |
| in-app search | 180 | 0.22 ms | 0.57 ms | 2.67 ms |
| panel open, first | 1 | 258 ms | | |
| panel open, warm | 7 | 66.3 ms | 85.6 ms (max) | |

### Final branch (replay, load average 10–15)

| Metric | n | p50 | p90 | p99 |
|---|---|---|---|---|
| keystroke main-thread CPU | 165 | 19.0 ms | 48.2 ms | 86.8 ms |
| keystroke → first frame (wall) | 165 | 39.5 ms | 146 ms | 269 ms |
| in-app search | 159 | 0.76 ms | 2.13 ms | 13.9 ms |
| panel open, first | 1 | 123 ms (CPU 93 ms) | | |
| db.load / cache.sizes | | 0.76 s / 1.69 s | | |

Release bench: name typing p50 0.089 ms, p99 0.87 ms. Filter-only full-text scans take about 5 ms (see the caveats).

## Root causes and fixes

1. **The search scan ran Swift `String` operations on 35.8k cards per keystroke** (fixed).
   - The per-card work was Character-level `contains`, `split`, `Array(name)` and String-keyed dictionaries.
   - Names are now flattened into one byte buffer with precomputed token bounds and length bonus. Printable-ASCII names, which is all but about 100, are matched on bytes. That is exactly equivalent for ASCII; other names keep the original String scorer.
   - A per-name ASCII bitmask and a subsequence-first pass reject most non-matches early.
   - Scores live in an index-addressed scratch array, and the name/id tiebreak is a precomputed rank.
   - Filters are precompiled. Type and oracle text use `memmem` when the text is provably equivalent at byte level.
   - Ranking is unchanged:
     - top-20 results and totals are identical on 9,308 real-corpus queries against the old engine (one-off check);
     - `testFastPathMatchesReferenceScoring` keeps the fast path checked against the String reference;
     - new golden cases cover non-ASCII names, multi-word token-start and full order.
2. **The engine was built on the main actor at launch.** It is now built in the background load task.
3. **Folder-size scans delayed "DB ready" by about 1.7 s at launch.** They stat about 85k image and art files, and the panel showed "Loading database…" until they finished. They now run after the engine is applied.

## Still missing the target, and why

**Keystroke p99 < 16 ms is not met.** About 20 ms of main-thread work remains per keystroke, almost all in `NSHostingView.layout`:

- SwiftUI view-graph update and layout, including the lazy-stack size estimation over the result rows;
- the `CardPreview` relayout;
- the Core Animation commit.

The SwiftUI instrument shows view-body updates themselves are cheap. The cost is in layout.

Experiments, measured as main-thread CPU p50 over 3 replay runs:

| Change | Result | Kept? |
|---|---|---|
| Hide the Recently Added and Lists columns | no change (21.0 vs 20.8 ms); the Stage 0b bench later showed −2.6 ms | Fixed in Stage 0b |
| Stub out `CardPreview` | p50 unchanged, p90 −8 ms | n/a |
| Stub out `ResultList` | −5 ms | n/a |
| `ResultList` LazyVStack → VStack | +6 ms | Reverted |
| Rows keyed by position + `.task(id:)` thumbnails | +4 ms (replay noise); the Stage 0b bench later showed p90 −42% | Adopted in Stage 0b |
| `CardPreview` `Equatable` + fixed-height printings list + searching in the field binding (one render pass instead of two) | 25 vs 20 ms, inside the noise on a loaded machine | Reverted as unproven |

Thumbnail JPEG decode is not on the main thread. `NSImage(contentsOf:)` is lazy, and the decode happens on Core Animation worker threads, so it was left alone. The fetcher-progress, Settings/game-window folder-scan and `GameSession` suspects are not on the typing or hotkey path, so they were not touched.

Next steps for the 16 ms target, all on the UI side:

- profile on a quiet machine with the replay hook and the SwiftUI instrument's layout lanes;
- cut row cost in `ResultList.Row` (per-row `contextMenu`, background shape, hairline ring);
- avoid relaying out the preview when the top card doesn't change.

## Stage 0b (follow-up): warm reopen and keystroke render

### Warm reopen after Esc: a measurement artifact, not a stall

- **The reading.** The ~425 ms reopen (with ~4 ms main-thread CPU) came from `Perf.interactionStart()`. It took its start time from `NSApp.currentEvent`, which is simply the last event the app processed.
- **Why it was wrong.** In the replay, `show()` runs from a timer about 4 replay steps after the last key-down, so the start was backdated by ~400 ms. No real wait was involved: `NSApp.activate` and `makeKeyAndOrderFront` each took < 12 ms.
- **The fix (instrumentation only).**
  - `panel.open` now starts at `show()`.
  - Searches take their start from a local key-down monitor, and each key-down is used once.
- **Re-measured warm opens:**
  - right after the fix: 5–56 ms (p50 14 ms);
  - on the final build: 7–20 ms (p50 10 ms, CPU 3 ms).

  Both cases are covered: the app still active after a hide, and another app frontmost (the replay hands focus back between runs). In both, the replay's key events reached the search field, so keyboard focus works.
- **Not covered.** The real Carbon hotkey dispatch before `show()` is outside what the app can see.

### Keystroke render: profiled, two root causes fixed

**How it was profiled:**

- **SwiftUI instrument.** View-update time, attributed to the nearest app view, put most of it in the result rows: `RarityBadge`, `Thumbnail`, the `ResultList` row modifiers, and explicit `.id` (`IDView`).
- **A new synchronous bench.** It sets the query, then forces SwiftUI update, layout, display and the CA commit inline. It keeps the minimum main-thread CPU per step over 5 repeats, which made A/B comparisons reliable to ±0.3 ms on a busy machine.
  - Run it: launch with `--args -perfReplay YES`, then `notifyutil -p com.abbabon.quickstudy.perf.bench`.
  - The bench walks 72 typing/deleting steps over "lightning bolt", "llanowar elves" and "sol ring".
- **Stub experiments** (bench p50 / p90):

| Stubbed out | Effect |
|---|---|
| Card preview | −0.1 ms |
| Header buttons | −0.1 ms |
| Count footer | −0.1 ms |
| Row context menu | ~0 |
| Row thumbnail | ~0 |
| Row badge | −0.3 / −2 ms |
| Recently Added column (unchanged by typing) | −1.2 ms |
| Lists column (unchanged by typing) | −1.4 ms |
| Whole results list | −2.2 ms p50, and removed the 12–15 ms spikes |

Rows that are re-filled are cheap. The cost was rows being *created*: ~0.35 ms each, and every keystroke replaced most of the 20.

**Root causes and fixes:**

1. **Result rows were keyed by card id.**
   - Typing swapped most row identities, so SwiftUI tore down and rebuilt row subgraphs on every key.
   - Rows are now keyed by position and refilled in place.
   - `Thumbnail` now loads via `.task(id:)` and only shows an image whose id matches, so a reused row never shows another card's art.
   - Rows take the UI scale from the list rather than one `@AppStorage` each.
2. **The Lists and Recently Added columns observed the whole model.**
   - Together with their rows, they re-rendered on every keystroke without changing.
   - They now receive only the values they display and are `Equatable` (`.equatable()`), with the model kept for actions.

**Bench, main-thread CPU per step, min over repeats:**

| | p50 | p90 | max |
|---|---|---|---|
| Back-to-back steps, before | 5.1–5.9 ms | 10.8–12.4 ms | 12.9–14.7 ms |
| Back-to-back steps, after | 3.3–3.8 ms | 4.8–5.4 ms | 8.7–9.1 ms |
| 100 ms idle before each step (typing pace), before | 28.6 ms | 43.0 ms | 49.6 ms |
| 100 ms idle before each step (typing pace), after | 22.1 ms | 29.6 ms | 41.6 ms |

**Replay** (real key events through NSTextView; load average 9–10, so wall-clock is noisy):

- keystroke main-thread CPU: p50 18.6 ms, p90 45.8 ms, p99 96.6 ms;
- first frame (wall): p50 39.6 ms, p99 144.5 ms.

Per-pass CPU logging shows almost all of each keystroke's CPU lands in the first run-loop pass. The 3–10 later passes cost ~0 ms, so animations and thumbnail completions are not the problem.

### Why the 16 ms p99 target is still missed

- **Same code, 5–7× the CPU time.** The app-side render work is now 3.3–3.8 ms p50 and < 9 ms worst case when measured back-to-back. With 100 ms of idle before each step, as in real typing, the identical steps cost 17–29 ms of main-thread CPU.
- **This points at core state, not app code.** The likely cause is the core clocking down between keys, or the main thread landing on an efficiency core on this loaded machine. Every millisecond of intrinsic work costs ~5 ms at typing pace.
- **Not yet checked: real keystrokes.** Real keys arrive through WindowServer with an interactive scheduling boost that the replay's in-app `NSApp.postEvent` events may not get. So the replay may overstate real typing. Check it with real keystrokes on a quiet machine. That needs external synthetic input or a person typing, which was not allowed while the user was at the machine.
- **The remaining spike.** The first character after an empty field builds the whole results list and 20 rows: ~9 ms intrinsic, ~40 ms at typing pace.

What closing the gap would take, roughly from cheapest to most effort:

1. **Keep a pool of 20 row slots alive** across empty queries, so the first character refills rows instead of building them. This removes the spike.
2. **Turn off `isMovableByWindowBackground`.** It is −0.35 ms (9%) per step, because AppKit recomputes the panel's opaque/draggable regions on each commit. It changes how the panel is dragged, so it was not done.
3. **Move the results list to an `NSTableView`** with cell reuse. It is a contained rewrite of one view, and the most likely way to get per-key work to ~1 ms.
4. **Confirm the real-keystroke numbers** first. If real HID input gets the scheduling boost, the shipped build may already be close to the target.

## Caveats

- **Filter-only full-text queries** (`o:…`, `t:…` with no name) scan about 6 MB of rules text in about 5 ms. That is inside a frame but outside the 1 ms search target; `testFullTextFilterLatency` guards it at < 8 ms. Making it faster needs an index, which suits the stage-2 Rust work.
- **Non-ASCII queries** ("æther") take the String path for about 100 non-ASCII names and all set names: about 0.75 ms.
- **The one-off 9,308-query ranking comparison** is not committed. Its durable replacement is the fast-path-vs-reference test, which runs on the local DB and skips without one.

## Stage 2: search in Rust through UniFFI

> 2026-11-08 · branch `feat/rust-stage-2-search` · same machine, load average 7–12.

The Swift `SearchEngine` and `QueryParser` were ported 1:1 into the `engine` crate and deleted. The index is built in Rust by reading SQLite directly; the app calls `SearchIndex.search(query:)`, which parses, ranks and returns the top-20 hits plus the total.

**Equivalence replay (gate).** Before the Swift engine was deleted, 143,503 queries ran through both engines on a copy of the real DB (35,769 cards, 780 sets): typing prefixes of every 5th card name, initialisms and subsequences, substrings, multi-word token starts, set codes and set names, 24 filter forms combined with name prefixes, filter-only queries, every non-ASCII name with all its prefixes, NFD and ASCII-folded variants, and combining-mark, case and whitespace oddities. Top-20 ids, order, totals and the hit payload (name, set code, rarity, color identity) were identical on all 143,503 (141,566 non-empty): **0 diffs**. The test lived in commit "test: Swift-vs-Rust search equivalence replay" and was deleted with the Swift engine.

**Search latency** (release bench on the real corpus; Rust figures include parsing and marshalling 20 hits across the FFI):

| | Swift (Stage 0) | Rust via FFI | Target |
|---|---|---|---|
| Name typing, 505 searches: p50 | 0.086 ms | 0.126 ms | |
| Name typing: p99 | 0.857 ms | 0.854 ms (max 1.03 ms, the 1-letter `l`) | < 1 ms: **met** |
| Full-text filters (`o:`/`t:`/`c:` without a name), p50 | 4.92 ms | 2.71 ms | no worse: **met** |
| Full-text filters, p99 | 5.30 ms | 4.05 ms | no worse: **met** |

p50 is ~40 µs higher: that is the FFI plus building 20 records of strings per call. Tail latency is unchanged, and the full-text scan is 25–45% faster.

**Launch DB load** (`db.load`, search usable): 0.76 s in Stage 0 → 0.37–0.52 s. Rust reads the three tables itself and no longer builds 35k Swift `Card.Mini`s, a filter-field dictionary and a set index.

**Keystroke render bench** (Stage 0b synchronous bench on the installed build, 72 steps, main-thread CPU per step, min over repeats; load average 7–11):

| | Stage 0b | Stage 2 |
|---|---|---|
| Back-to-back: p50 / p90 / max | 3.3–3.8 / 4.8–5.4 / 8.7–9.1 ms | 3.40–3.78 / 5.00–5.42 / 8.95–9.24 ms (3 runs) |
| 100 ms idle before each step: p50 / p90 / max | 22.1 / 29.6 / 41.6 ms | 18.7 / 29.1 / 30.6 ms (1 run) |

No regression. The keystroke p99 < 16 ms target is still limited by SwiftUI layout, exactly as in Stage 0b.

**App Store sandbox** (`build-appstore.sh --adhoc`): the static library links into the app binary; inside the container the engine opens the container DB read-only, builds the 35,769-card index in 0.5 s and answers searches; a refresh through the debug hook re-indexed the sandboxed DB and searches kept working. `-debugSearch YES` plus `notifyutil -p com.abbabon.quickstudy.debug.search` logs results from any build.

**Caveats.**
- Behavior is deliberately identical to Stage 0, including the cases where Swift is quirky: the filter-only branch ignores duplicate ids, `mv:` parses with Rust's `f64` (differs from Swift `Double(String)` only for hex floats like `mv:0x10`), and `s:` set codes compare byte-wise.
- The static library carries its own bundled SQLite. GRDB in the same binary resolves `sqlite3_*` to it instead of the system library; all app and store tests pass on it.


## Stage 3: database reads and card lists in Rust

> 2026-11-08 · branch `feat/rust-stage-3-db` · release builds run with `QUICKSTUDY_DATA_DIR` pointing at a copy of the real DB (35,769 cards, 52,230 artworks), load average 6-19. Master (GRDB) and the branch were alternated 3-4 times each.

**Data parity (gate).** Before GRDB was deleted, a harness dumped what `CardStore` returned for 336 sampled cards (basic lands with 843-869 printings, double-faced cards, `Æ`/`û`/`ö` names, a missing id), the 200 Recently Added rows, all 52,230 artworks, both card lists with their items, counts and meta keys. The same dump through the Rust `Database` was byte-identical, and the `grdb_migrations` ledger still has 9 rows. One deliberate behavior note: the cutoff for "recently added" is now "now minus N x 24 h, in UTC", where Swift subtracted calendar days in local time; they differ only across a DST change.

**Launch `db.load`** (search usable): GRDB build 497 / 518 / 516 / 536 ms (one 695 ms outlier); Rust 466 / 461 / 492 / 496 / 486 ms. Stage 2 recorded 0.37-0.52 s on a quieter machine.

**Detail load** (`detail.load`, off the main actor; first load in a fresh process):

| Card | GRDB | Rust |
|---|---|---|
| Plains, 843 printings | 11.3 / 15.0 / 13.9 / 18.5 ms (a first run hit 33 ms) | 17.5-23 ms (13 ms when repeated) |
| Lightning Bolt, 75 printings | 1.35-1.85 ms | 1.4-2.5 ms |
| Delver of Secrets, 8 printings | 0.6 ms | 0.3-0.5 ms |

The Rust query itself takes 0.65 ms warm. The extra ~7 ms on an 843-printing card is UniFFI lifting about 7,500 strings into Swift plus the mapping to `Card.Printing`. It is paid once per card (the result is cached), off the main thread, and below one frame, so it was accepted rather than adding a packed format.

**Keystroke render bench** (synchronous bench, 72 steps, main-thread CPU per step, same machine back to back):

| | p50 | p90 | max |
|---|---|---|---|
| GRDB build (2 runs) | 3.41 / 3.37 ms | 4.96 / 4.81 ms | 8.90 / 8.78 ms |
| Rust build (2 runs) | 3.28 / 3.34 ms | 4.82 / 4.75 ms | 8.70 / 8.50 ms |

No regression.

**One SQLite.** `nm -m` on the release app shows no locally defined `_sqlite3_*` symbols; the binary links `/usr/lib/libsqlite3.dylib`. (The Stage 2 caveat about a bundled copy shadowing GRDB's is obsolete: GRDB is gone.)

**App Store sandbox** (`build-appstore.sh --adhoc`): launched, built the 35,769-card index in 0.5 s, answered searches, loaded details (Plains: 843 printings) and a list edit made through the `-debugDB` hook persisted in the container DB. `-debugDB YES` plus `notifyutil -p com.abbabon.quickstudy.debug.db` (read-only) or `.debug.db.write` (creates a scratch list) logs the report.
