## Context

QuickStudy is a menu-bar app whose panel shows a search-results list (left) and a single card preview (right). State lives in one `@MainActor` `AppModel`; the preview is driven by `AppModel.selectedCard`, loaded lazily by `AppModel.select(_ id:)` from `CardStore` and cached in an `NSCache`. All sizing flows through `UIScale`. There are two card projections in `Sources/Shared/Card.swift`: the full `Card` and the lightweight `Card.Mini` (`init(id:name:)`).

This design adds a persistent, user-curated set of pinned cards rendered as a bottom row, without disturbing the search/ranking path or the SQLite schema.

## Goals / Non-Goals

**Goals:**
- Pin/unpin the previewed card from one control (preview-pane button) that also binds ⌘P.
- A persistent pinned bottom row, visible across searches and empty/no-match states.
- Clicking a pinned card reuses the existing `select(_:)` path to swap the preview.
- Per-entry unpin, always visible.
- Pins survive app restarts.

**Non-Goals:**
- No reordering of pinned cards by drag (insertion order only).
- No SQLite schema change; no new DB table.
- No sync across machines; persistence is local `UserDefaults`.
- No limit/paging on the number of pins (a horizontal scroll handles overflow).

## Decisions

### Pin state lives in AppModel as `[Card.Mini]`
`AppModel` is already the single source of truth and is `@MainActor`, so SwiftUI reactivity is automatic. A `@Published var pinned: [Card.Mini]` ordered array preserves pin order and is cheap to render (thumbnail + name need only `id` and `name`). Methods: `isPinned(_:)`, `togglePin(_:)`, `togglePinSelected()`, `unpin(_:)`.
- *Alternative considered:* a `Set<String>` of ids. Rejected — loses order and forces a name lookup to render each row.

### Persist via UserDefaults, storing id + name
`Card.Mini` is not `Codable`, so persistence uses a tiny private `Codable` ref `{ id, name }`, JSON-encoded under one `UserDefaults` key. Storing the name avoids a `CardStore` read per pin just to draw the row; the full `Card` for the preview is still fetched lazily through the existing `select(_:)`/`NSCache` path when a pin is clicked. `loadPins()` runs in `AppModel.init()`.
- *Alternative considered:* the `meta` KV table in SQLite. Rejected — pins are a UI preference, not card data; `UserDefaults` keeps the DB schema untouched and matches how other UI prefs (`@AppStorage`) are stored.

### One control drives both the button and ⌘P
The preview-pane pin button attaches `.keyboardShortcut("p", modifiers: .command)`. A SwiftUI command shortcut on a `Button` fires even while the search `TextField` is focused, which is more reliable for a modified key than `.onKeyPress`. This yields the button and the shortcut from a single control with no duplicate wiring. Because the button only exists while a card is previewed, ⌘P is naturally scoped to "there is something to pin."

### Keep CardPreview decoupled
`CardPreview` takes a `card: Card?` today. Rather than inject the whole `AppModel`, pass `isPinned: Bool` and `onTogglePin: () -> Void`; `SearchPanel` supplies `model.isPinned(card.id)` and `{ model.togglePinSelected() }`. This keeps the view dumb and easy to preview.

### Extract a reusable `Thumbnail`
The `Thumbnail` view is currently `private` inside `ResultList.swift`. Move it to `Views/Thumbnail.swift` as an internal type (behavior unchanged) so both `ResultList` and the new `PinnedRow` share one image-loading implementation.

### Mount the pinned row outside the results HStack
The pinned row is added at the bottom of `SearchPanel`'s root `VStack` (after `content`), shown when `dbState == .ready && !pinned.isEmpty`, with a thin divider above. Placing it outside the results `HStack` (which only renders when there are results) keeps pins visible and clickable even with an empty query or no matches.

## Risks / Trade-offs

- **Stale pin name** → A card's printed name effectively never changes in Scryfall data, and the click path re-fetches the full `Card` by `id`, so a stale stored name only affects the row label. Acceptable; could be refreshed on load if ever needed.
- **Pinned card removed from a future DB refresh** → Clicking it would find no detail and the preview stays empty. Low likelihood (cards aren't removed); the row still renders from stored `id`/`name`. Could prune unknown ids on load as a follow-up.
- **⌘P collision** → ⌘P is the system Print shortcut, but this is a borderless accessory panel with no print command, so binding it to pin is safe.
- **Many pins overflow the row** → The row is a horizontal `ScrollView`, so overflow scrolls rather than breaking layout.
