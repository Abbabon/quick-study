## Why

When the user dismisses the search panel and reopens it later, the previous query is still in the field and the previous result is still selected. For a Spotlight-style launcher invoked dozens of times per day, a stale query is usually noise — the user almost always wants a fresh search. Today the only way to start clean is to manually select-all and delete. A timer-based reset on the hidden panel matches the muscle memory of Spotlight/Raycast without disrupting users who reopen the panel immediately to continue refining a query.

## What Changes

- Track the time the panel was last hidden in `PanelController`.
- On `show()`, if `now - lastHiddenAt >= timeout`, clear the search state before presenting the panel (empty `query`, clear `selectedID`, `selectedCard`, and `results`).
- Reopening within the timeout window preserves the existing query and selection (current behavior).
- Add a configurable timeout in Settings under the existing **Behavior** section. Persisted via `@AppStorage` with key `clearSearchTimeout` (seconds, `Double`).
- Provide preset durations including a "Never" option that disables the auto-clear entirely. Default: 60 seconds.

## Capabilities

### New Capabilities
- `panel-session`: Defines when the search panel preserves state across show/hide cycles versus resetting to a clean session. Covers the timeout-based clear behavior, the persisted setting, and the panel show/hide lifecycle interaction.

### Modified Capabilities
<!-- None: no existing specs in openspec/specs/. -->

## Impact

- **Code**:
  - `Sources/QuickStudy/PanelController.swift` — track `lastHiddenAt`, consult timeout setting on `show()`, call a new reset method on the model when expired.
  - `Sources/QuickStudy/AppModel.swift` — add `resetSearchState()` that clears `query`, `selectedID`, `selectedCard`, and `results` (and lets the existing `NSCache` for detail rows live on, since it's bounded).
  - `Sources/QuickStudy/SettingsView.swift` — new picker row in the **Behavior** section bound to `@AppStorage("clearSearchTimeout")`.
- **Persistence**: One new `UserDefaults` key (`clearSearchTimeout`, `Double` seconds; `0` = never). No schema changes, no migrations.
- **No impact** on: `mtg-fetcher` subprocess, SQLite/`CardStore`, search engine, or fetcher NDJSON protocol.
