# Accurate new-card detection + offline image fetch

**Date:** 2026-06-18
**Branch:** `feat/accurate-card-update-detection`

## Problem

The card-update notification feels broken: the menu-bar dot lights up and a
notification fires, but running "Refresh Database…" often finds nothing new.

Root cause: detection is **timestamp-only**. `UpdateChecker.shouldPrompt`
compares Scryfall's `oracle_cards.updated_at` against the `bulk_updated_at` we
last ingested. Scryfall regenerates that bulk file roughly daily for reasons
unrelated to new card releases, so the timestamp advances constantly. The dot
is therefore mostly false alarms, and the only way to clear it is a heavyweight
full manual refresh that frequently yields zero new cards.

The app *does* already auto-check (launch, 2h timer, wake-from-sleep, panel
open) — so "it doesn't check by itself" is really a symptom of the coarse,
timestamp-based signal, not a missing check.

## Goal

- Detect **genuinely new cards**, not just a newer bulk timestamp.
- Keep card *text* current automatically so search never goes stale.
- Surface the dot/notification **only when new cards actually landed**.
- On accept, download just those cards' images for offline use.

## Decisions (confirmed)

1. **Resolution model:** auto-ingest card text silently; offer image download
   on accept (not fully silent image fetch).
2. **Auto-download:** the silent ingest downloads the ~30–50 MB bulk on any
   network whenever the stamp advances (≈ once/day max). No prompt.
3. **Dot behavior:** persists until the user downloads images or dismisses.
   Cards are already searchable; only images are pending.

## Flow

Two-tier so we don't pull the bulk file on every poll:

1. **Cheap gate (existing cadence — launch / 2h timer / wake / panel open):**
   `checkForUpdates` fetches only the small bulk-index `updated_at`. If it is
   not strictly newer than our ingested baseline, stop.

2. **Silent ingest (automatic):** when the stamp is newer, run
   `mtg-fetcher --no-images` in the background. It downloads the bulk, upserts
   card text (search is immediately current), and writes `bulk_updated_at`. This
   advances the baseline, so the cheap gate self-dedupes — it won't re-trigger
   for the same stamp. No visible progress bar; this is background work.

3. **Surface only if real:** the fetcher reports a **new-card count** (rows
   inserted that were not already in the DB). If `> 0` *and* the stamp has not
   been dismissed → light the dot and post a notification:
   *"Added N new cards — download images for offline use."* If `0` → nothing
   surfaces. This eliminates the false alarm.

4. **Images on accept:** the menu item / notification action / Settings button
   runs `mtg-fetcher --images-only`. It reuses the bulk JSON already on disk,
   skips re-download and re-ingest, and downloads only missing images (the
   downloader already filters files already on disk). Because the user
   initiated it, progress shows in Settings via the existing `refreshState`.

### Dismiss

Dismiss suppresses only the dot/notification for the current (and older)
stamp — it does **not** suppress the silent ingest. Search stays current even
if the user keeps dismissing; only image download is deferred.

## Components & changes

### `Sources/Fetcher/Fetcher.swift`
- **New-card count:** snapshot `store.cardCount()` before ingest and after;
  `newCards = max(0, after - before)`. The fetcher never deletes cards, so the
  delta is the count of brand-new cards. Emit it on the `done` event.
- **`--images-only` mode:** parse a new flag. When set: skip parse+ingest and
  the meta writes; if `bulk-oracle.json` is absent, download it first (needs the
  bulk index); then run the existing image phase. When the file is present
  (normal case, right after a silent ingest) no bulk download happens.

### `Sources/Fetcher/ProgressEmitter.swift` + `Sources/QuickStudy/FetcherProcess.swift`
- Add `newCards: Int?` to the NDJSON event schema, in lockstep (per the
  subprocess-protocol rule in CLAUDE.md). `Event` gains `newCards`; the emitter's
  `emit(...)` gains a `newCards` parameter; `FetcherProcess.Event` /
  `EventDecoded` gain the field.

### `Sources/Shared/CardStore.swift`
- Add `func cardCount() throws -> Int` (`SELECT COUNT(*) FROM cards`).

### `Sources/QuickStudy/UpdateChecker.swift`
- Add `static func isNewerThanIngested(remote:ingested:) -> Bool` — the
  remote-strictly-newer-than-baseline test **without** the dismissed check. This
  gates the silent ingest.
- Keep `shouldPrompt` (with the dismissed check) for the dot-gating decision,
  applied after ingest together with the new-card count.

### `Sources/QuickStudy/AppModel.swift`
- `checkForUpdates(force:)`: when `isNewerThanIngested` is true and no fetcher is
  busy, trigger the silent ingest instead of setting `updateAvailable = true`.
- New silent-ingest path: runs the fetcher with `--no-images`, reads `newCards`
  from the `done` event. On completion, if `newCards > 0` and the stamp is not
  dismissed, set `newCardsPendingImages = newCards` and `availableUpdateStamp`.
  Runs without touching the visible `refreshState`.
- New `newCardsPendingImages: Int` published property drives the dot/menu/
  notification. `updateAvailable` is kept as a computed
  `newCardsPendingImages > 0` so existing view bindings keep working without a
  rename sweep.
- `startImageDownload()`: runs the fetcher with `--images-only`; surfaces
  progress through `refreshState`. On `done`, set `newCardsPendingImages = 0`.
- **Serialisation:** a single guard ensures the background ingest and a manual
  refresh / image download never run two fetcher processes against the DB at
  once. Manual user actions take priority; the background ingest skips if a
  fetch is already running and is retried on the next check.
- `dismissUpdate()`: clears the dot and records the dismissed stamp (unchanged
  shape); does not stop future ingests.

### `Sources/QuickStudy/QuickStudyApp.swift` + `SettingsView.swift`
- Dot lights on `newCardsPendingImages > 0` (or app update), same as today.
- Menu item / notification copy reflects the new model, e.g.
  "Download Images (N new cards)…" and notification body
  "Added N new cards. Download images for offline use?"
- The accept actions call `startImageDownload()` instead of a full
  `startRefresh`.

## Testing

- `UpdateChecker` golden-style unit tests for `isNewerThanIngested`
  (newer / equal / older / unparsable / missing baseline) and for the combined
  dot-gating decision (newCards>0 & not dismissed → show; newCards==0 → hide;
  dismissed-newer → hide).
- `CardStore.cardCount()` unit test (insert N, expect N).
- Fetcher `--images-only` and the new-card count verified by building the app
  and a manual run (integration; not unit-tested).

## Out of scope

- No server and no card-by-card Scryfall API diffing — detection piggybacks on
  the ingest the fetcher already performs.
- No network-type restriction (Wi-Fi vs cellular) on the auto-download; can be
  added later if desired.
- Backfilling images for pre-existing cards is not a goal, though `--images-only`
  will naturally pick up any missing image as a side effect.
