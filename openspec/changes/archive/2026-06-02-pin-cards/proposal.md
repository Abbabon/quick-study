## Why

While searching, a user often wants to keep a small working set of cards at hand (a play group, a combo, cards to compare) but the panel only ever shows the one currently-highlighted card. Every comparison means re-typing a query and losing the previous card. A persistent "pinned" set lets the user collect cards and flip between them instantly.

## What Changes

- Add the ability to **pin** the currently-previewed card via a button in the preview pane and the **⌘P** in-panel keyboard shortcut. The control toggles, so the same action unpins.
- Add a **persistent bottom row** that displays the pinned cards across searches — visible even when the current query is empty or has no matches.
- **Clicking a pinned card** in the bottom row swaps the main preview to that card.
- Each pinned entry has its **own always-visible ✕ control** to unpin just that card.
- **Pins persist across app restarts** (stored in `UserDefaults`).

## Capabilities

### New Capabilities
- `card-pinning`: pinning/unpinning the previewed card (button + ⌘P shortcut), the persistent pinned bottom row, click-a-pin-to-preview behavior, per-entry unpin, and persistence of pins across launches.

### Modified Capabilities
<!-- No existing requirement-level behavior changes. The preview pane gains a pin
     control, but that behavior is owned by the new card-pinning capability. -->

## Impact

- **New code**: `Sources/QuickStudy/Views/PinnedRow.swift`, `Sources/QuickStudy/Views/Thumbnail.swift` (extracted from `ResultList.swift` for reuse).
- **Modified code**: `AppModel.swift` (pinned state, persistence, toggle/unpin methods), `CardPreview.swift` (pin button + ⌘P shortcut), `SearchPanel.swift` (mount the pinned row, wire the button), `ResultList.swift` (use the extracted `Thumbnail`).
- **Storage**: a new `UserDefaults` key holding the pinned card list (`id` + `name`). No SQLite schema change.
- **Dependencies**: none added.
