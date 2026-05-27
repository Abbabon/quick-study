## Context

The QuickStudy panel is a borderless `NSPanel` managed by `PanelController`. It is shown via global hotkey (`AppDelegate` + `KeyboardShortcuts`), and hidden by Esc, click-away (`windowDidResignKey`), or the hotkey toggling it off. Across hide/show cycles, the panel keeps its `NSHostingView` and the underlying `AppModel`, so `model.query`, `model.results`, and `model.selectedID` persist until the process exits.

For Spotlight-style launchers, persistence is a feature when you reopen seconds later to refine a search, and an annoyance when you reopen hours later expecting a clean slate. The chosen behavior — clear after the panel has been hidden longer than a configurable timeout — preserves the fast-refine case while restoring a clean default after the panel has effectively been "away" for a while.

Constraints:
- `AppModel` is `@MainActor` and the source of truth for search state.
- `PanelController` already owns the lifecycle decisions (`show`/`hide`/`toggle`); centralizing the timeout check there avoids leaking lifecycle awareness into the model.
- Settings already uses `@AppStorage`-backed `UserDefaults` keys (`enterBehavior`, `UIScale.storageKey`). We follow the same pattern.

## Goals / Non-Goals

**Goals:**
- Clear the previous query when reopening the panel after a configurable idle interval.
- Make the timeout user-configurable, with sensible presets and a "Never" option.
- Default to a value that matches Spotlight-like muscle memory (60 seconds).
- Zero behavioral change when the user reopens within the timeout window.

**Non-Goals:**
- Clearing the search while the panel is open (no inactivity timer running in the panel).
- Closing or hiding the panel based on inactivity.
- Persisting/restoring the query across app launches.
- Migrating, evicting, or invalidating the `NSCache<NSString, CachedCard>` detail cache — it is bounded by `NSCache` policy and survives a state reset.
- Adding any background timer or scheduling work while the panel is hidden — the check happens lazily on next `show()`.

## Decisions

### Decision 1: Lazy check on `show()`, not a background timer
On `hide()`, record `Date.now` as `lastHiddenAt`. On `show()`, compare `Date.now - lastHiddenAt` against the configured timeout, and if expired, call a new `AppModel.resetSearchState()` before presenting the panel.

**Why:** No timers, no background work, no risk of firing while the panel is hidden or after sleep/wake. The panel is hidden far more often than it is shown; checking on `show()` is essentially free and fires exactly once per show.

**Alternative considered — Timer scheduled on `hide()`:** Adds `DispatchSourceTimer` or `Task.sleep` complexity, doesn't compose well with system sleep, and offers no user-visible benefit (the user sees the state when they reopen, not while it's hidden).

### Decision 2: Timeout setting stored as `Double` seconds with `0 == Never`
`@AppStorage("clearSearchTimeout") var clearSearchTimeoutSeconds: Double = 60`. A value of `0` disables the timeout entirely.

**Why:** Matches the `@AppStorage` pattern already used in `SettingsView`. `Double` cleanly serializes through `UserDefaults` and pairs with `Date.timeIntervalSince`. Using a sentinel `0` for "Never" avoids modelling an optional in storage.

**Alternative considered — enum-backed string key like `enterBehavior`:** Cleaner type safety, but the value space here is naturally numeric (durations) and we want presets to be ordered. A picker over fixed `Double` cases gives us both.

### Decision 3: Presets via `Picker`, not a free-form slider
Behavior section gets a `Picker("Clear search after:")` with cases: Never (0), 30s, 1m (default), 5m, 15m, 1h.

**Why:** Discrete, predictable values; matches the existing `Picker` style of the "On Enter" row in the same section. Avoids the calibration problem of a slider for a "set once" preference.

### Decision 4: `resetSearchState()` lives on `AppModel`, not `PanelController`
`PanelController` decides *when* to reset; `AppModel` knows *how*. The method clears `query`, `selectedID`, `selectedCard`, and `results` (not the `NSCache` detail cache — it is bounded and harmless).

**Why:** Keeps lifecycle policy and state ownership separate. Setting `query = ""` would also trigger `onChange` → `runSearch()` via SwiftUI binding, which would set `results = []` anyway, but explicit reset is more legible and order-independent.

### Decision 5: Track `lastHiddenAt` only in `PanelController`
Not stored in `UserDefaults` — only in memory. After an app restart, the panel naturally opens fresh (model state is empty), so cross-launch tracking is unnecessary.

## Risks / Trade-offs

- **[Risk]** First-ever `show()` has no prior `lastHiddenAt`; could spuriously clear (no-op) or skip the check. → **Mitigation:** Initialize `lastHiddenAt = nil`; treat `nil` as "no prior hide, nothing to clear" — skip the reset on first show.
- **[Risk]** System sleep/wake affects wall-clock comparisons. → **Mitigation:** `Date` is wall-clock; if the laptop sleeps for 8 hours and the user reopens, the timeout has clearly expired, which is the desired behavior. Using `Date` (not `CFAbsoluteTimeGetCurrent` or a monotonic clock) is correct here.
- **[Trade-off]** Picker presets are fixed. A user who wants "10 minutes" cannot enter it. → Acceptable for a setting most users will configure once.
- **[Risk]** Default of 60s might feel too aggressive for users who frequently re-open to refine the same search. → **Mitigation:** Configurable; "Never" is one click away. Revisit if feedback indicates otherwise.
