# Performance baseline (Stage 0)

> 2026-11-08 · branch `feat/rust-stage-0-perf` · M-series Mac, arm64, release builds installed to `/Applications`.
> Targets come from Q16 in `docs/rust-migration-plan.md`.

## Summary

| Target | Before | After | Met? |
|---|---|---|---|
| `SearchEngine.search` p99 < 1 ms (real 35.8k-card corpus, release bench) | p50 44.9 ms · p99 102.4 ms | p50 0.09 ms · p99 0.87–0.89 ms | **Yes** |
| Keystroke → results drawn p99 < 16 ms (installed app) | p50 74 ms · p99 99 ms | p50 23 ms · p99 60 ms (quiet machine) | **No** |
| Hotkey → panel, warm < 100 ms | p50 61 ms · max 102 ms | p50 66–69 ms · max 86–92 ms (quiet machine) | Borderline yes, but see the open question below |
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
| Hide the Recently Added and Lists columns | no change (21.0 vs 20.8 ms) | n/a |
| Stub out `CardPreview` | p50 unchanged, p90 −8 ms | n/a |
| Stub out `ResultList` | −5 ms | n/a |
| `ResultList` LazyVStack → VStack | +6 ms | Reverted |
| Rows keyed by position + `.task(id:)` thumbnails | +4 ms | Reverted |
| `CardPreview` `Equatable` + fixed-height printings list + searching in the field binding (one render pass instead of two) | 25 vs 20 ms, inside the noise on a loaded machine | Reverted as unproven |

Thumbnail JPEG decode is not on the main thread. `NSImage(contentsOf:)` is lazy, and the decode happens on Core Animation worker threads, so it was left alone. The fetcher-progress, Settings/game-window folder-scan and `GameSession` suspects are not on the typing or hotkey path, so they were not touched.

Next steps for the 16 ms target, all on the UI side:

- profile on a quiet machine with the replay hook and the SwiftUI instrument's layout lanes;
- cut row cost in `ResultList.Row` (per-row `contextMenu`, background shape, hairline ring);
- avoid relaying out the preview when the top card doesn't change.

## Open question: warm open after Esc

With the replay hook, a panel open while the app is still active after a previous hide took about 425 ms wall time, but only about 4 ms of main-thread CPU. `NSApp.activate` and `makeKeyAndOrderFront` each took under 12 ms. An open after another app was frontmost took 23–53 ms. So the time is spent waiting, not computing. It may be WindowServer, which was at 30–50% CPU at the time.

The quiet-machine osascript runs went through Finder between opens and showed 46–92 ms. It was not confirmed with the real hotkey in the "Esc, then hotkey again" sequence: the user was at the machine, and synthetic keystrokes could have gone to their terminal. Re-check on a quiet machine. If it reproduces, the likely next step is to make the nonactivating panel key without a full app activation.

## Caveats

- **Filter-only full-text queries** (`o:…`, `t:…` with no name) scan about 6 MB of rules text in about 5 ms. That is inside a frame but outside the 1 ms search target; `testFullTextFilterLatency` guards it at < 8 ms. Making it faster needs an index, which suits the stage-2 Rust work.
- **Non-ASCII queries** ("æther") take the String path for about 100 non-ASCII names and all set names: about 0.75 ms.
- **The one-off 9,308-query ranking comparison** is not committed. Its durable replacement is the fast-path-vs-reference test, which runs on the local DB and skips without one.
