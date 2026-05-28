## 1. Verify card-search

- [x] 1.1 Run `swift test --filter SearchEngineTests` and confirm all golden cases pass against the documented tier ordering and length-bonus behavior.
- [x] 1.2 For each scenario in `specs/card-search/spec.md` that does NOT map to an existing golden test (notably: empty-query short-circuit, performance target, corpus reload after refresh), record a follow-up to add a test.
- [x] 1.3 In the running app, type a multi-character query rapidly and confirm there is no debounce delay and results update on every keystroke.

## 2. Verify card-detail

- [x] 2.1 In the running app, observe that selecting a result triggers detail loading and the image renders. Confirm non-selected results do not load details (e.g., by observing instrumented logs or via SQLite query counts during scrolling).
- [x] 2.2 Re-select a previously viewed card and confirm the detail appears without a fresh store read (NSCache hit).
- [x] 2.3 Run a search that produces results, then change the query so the previously selected card is no longer in the list — confirm the first new result becomes selected.
- [x] 2.4 With results visible, press the down-arrow at the bottom of the list and the up-arrow at the top — confirm selection clamps rather than wraps.

## 3. Verify card-data-refresh

- [x] 3.1 Build the fetcher (`swift build`) and run `swift run mtg-fetcher --no-images`. Capture stdout and confirm a `start` event, one or more `json` events, `ingest` events with `done` advancing toward `total`, no `images` events, and a final `done` event.
- [x] 3.2 Re-run the fetcher immediately. Confirm the second run completes successfully (idempotent ingest, no duplicates introduced — verify via `SELECT COUNT(*)` on the `cards` table before and after).
- [x] 3.3 Run the fetcher WITHOUT `--no-images` once to populate the cache, then delete a handful of image files and re-run. Confirm only the missing files are re-downloaded (resumable images).
- [x] 3.4 Temporarily set `MTG_FETCHER_PATH` to a non-existent path and trigger a refresh from the app. Confirm the receiver observes an `error` event with a descriptive message and the refresh state ends in error.
- [x] 3.5 Confirm the `meta` table contains `last_refresh` (ISO-8601) and `bulk_updated_at` after a successful run.

## 4. Verify panel-session

- [x] 4.1 Launch the app and confirm no Dock icon appears.
- [x] 4.2 Trigger the configured global hotkey — confirm the panel appears as a borderless HUD with vibrancy and rounded corners, centered and biased to the upper portion of the active screen.
- [x] 4.3 With the panel visible, click outside it — confirm it dismisses on resign-key.
- [x] 4.4 Re-show the panel, press Escape — confirm it dismisses.
- [x] 4.5 Trigger the hotkey twice in a row — confirm the second invocation hides the visible panel.
- [x] 4.6 Switch a connected display to a smaller-than-panel resolution (or simulate by docking the panel near a screen edge after manually moving it) — confirm the panel origin clamps so the panel stays fully on-screen.
- [x] 4.7 Open the app over a full-screen application — confirm the panel renders above it as an auxiliary panel.
- [x] 4.8 Change the UI scale in Settings, then hide and re-show the panel — confirm the panel rebuilds at the new scale.

## 5. Verify image-cache

- [x] 5.1 Confirm the images directory is created under the QuickStudy Application Support folder and contains image files after a successful refresh.
- [x] 5.2 In Settings, observe the displayed cache size matches the actual on-disk total (verify via `du -sh` on the images directory).
- [x] 5.3 With the app idle (no refresh in progress), activate the Clear Image Cache control — confirm files are removed, the directory itself still exists, and the Settings UI updates the displayed size to zero (or near zero, accounting for hidden files).
- [x] 5.4 Start a refresh, and while it is running, confirm the Clear Image Cache control is not actionable.

## 6. Capture follow-ups

- [x] 6.1 For every drift between spec and observed behavior surfaced in tasks 1-5, write a one-line follow-up entry below. Each follow-up should later become its own change proposal — do NOT modify code as part of this change.
- [x] 6.2 Confirm `openspec validate baseline-capabilities` passes before requesting archive.

### Follow-ups discovered during verification

<!-- One bullet per drift item. Format: capability — observed behavior vs spec — proposed change name. -->
