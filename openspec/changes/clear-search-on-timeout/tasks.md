## 1. Model: reset search state

- [x] 1.1 Add `resetSearchState()` to `AppModel` that sets `query = ""`, `selectedID = nil`, `selectedCard = nil`, and `results = []`.
- [x] 1.2 Verify (manually or via a quick log) that setting `query = ""` does not double-trigger search work in a way that re-populates `results` before the reset completes. — Confirmed via `SearchEngine.search(_:)` line 31: empty/whitespace queries early-return `[]`, so any `onChange→runSearch` race lands in the `else if results.isEmpty` branch that also clears `selectedID`/`selectedCard`. End state is identical to the explicit reset.

## 2. Settings: timeout preference

- [x] 2.1 Define a `ClearSearchTimeout` enum (or a typed wrapper) with cases for the presets: never (0), 30s, 60s, 5m, 15m, 1h, including display labels and `seconds: Double` values. Keep it co-located with `EnterBehavior` for consistency.
- [x] 2.2 Add the `@AppStorage("clearSearchTimeout")` key with default `60.0` in `SettingsView`.
- [x] 2.3 Add a `Picker("Clear search after:", selection: ...)` row to the **Behavior** section of `SettingsView`, immediately under the existing "On Enter" picker. Use `.pickerStyle(.inline)` to match.

## 3. Panel: lazy timeout check on show

- [x] 3.1 Add `private var lastHiddenAt: Date?` to `PanelController`.
- [x] 3.2 In `hide()`, set `lastHiddenAt = Date()` after `panel?.orderOut(nil)`.
- [x] 3.3 In `show()`, before `panel.makeKeyAndOrderFront(nil)`, read the configured timeout from `UserDefaults` (key `clearSearchTimeout`, default `60`). If non-zero and `lastHiddenAt != nil` and `Date().timeIntervalSince(lastHiddenAt!) >= timeout`, call `model.resetSearchState()`. — Implemented as `clearSearchIfTimedOut()`. Class is now `@MainActor` so it can call the `@MainActor` model method directly (AppDelegate already invokes `PanelController` from the main actor).
- [x] 3.4 Make sure the existing UI-scale rebuild path in `show()` (which sets `panel = nil`) does not interfere with `lastHiddenAt`; the timestamp is owned by the controller, not the panel. — Verified: `lastHiddenAt` lives on `PanelController`, untouched by the `panel = nil` rebuild branch.
- [x] 3.5 Confirm `windowDidResignKey(_:)` → `hide()` path also stamps `lastHiddenAt` (it routes through `hide()`, so this should be automatic — verify). — Verified: `windowDidResignKey` calls `hide()`, which now sets `lastHiddenAt`.

## 4. Manual verification

- [x] 4.1 Build with `./scripts/build-app.sh debug` (or `swift run QuickStudy` with `MTG_FETCHER_PATH` set per `CLAUDE.md`). — `swift build` succeeds with no warnings or errors.
- [x] 4.2 With default settings (60s), type a query, hide the panel, reopen immediately → query and selection preserved. — Confirmed by user.
- [x] 4.3 With default settings, type a query, hide the panel, wait >60s, reopen → query empty, no selection, no results, placeholder hint visible. — Confirmed by user.
- [x] 4.4 Set timeout to "Never" in Settings, repeat the long-wait case → state preserved. — Confirmed by user.
- [x] 4.5 Set timeout to 30s, confirm boundary behavior (hide, wait ~25s reopen preserved; wait ~35s reopen cleared). — Confirmed by user.
- [x] 4.6 Confirm Settings opens, picker shows the chosen value across an app relaunch. — Confirmed by user.
- [x] 4.7 Sanity-check: `swift test` still passes (the `SearchEngine` golden tests should be unaffected). — 17/17 tests pass.
