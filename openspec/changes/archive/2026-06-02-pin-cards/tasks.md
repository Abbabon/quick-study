## 1. Pin state & persistence in AppModel

- [x] 1.1 Add `@Published var pinned: [Card.Mini] = []` to `AppModel` (`Sources/QuickStudy/AppModel.swift`)
- [x] 1.2 Add a private `Codable` ref struct `{ id, name }` and a `UserDefaults` key (e.g. `"pinnedCards"`) for persistence
- [x] 1.3 Add `private func persistPins()` (JSON-encode `pinned` → ref array → UserDefaults) and `private func loadPins()` (decode → `Card.Mini(id:name:)`), calling `loadPins()` from `init()`
- [x] 1.4 Add `func isPinned(_ id: String) -> Bool`
- [x] 1.5 Add `func togglePin(_ mini: Card.Mini)` (append if absent, remove if present, then `persistPins()`)
- [x] 1.6 Add `func togglePinSelected()` building `Card.Mini(id:name:)` from `selectedCard`; no-op when `selectedCard == nil`
- [x] 1.7 Add `func unpin(_ id: String)` (remove + `persistPins()`)

## 2. Extract a reusable Thumbnail

- [x] 2.1 Move `private struct Thumbnail` out of `ResultList.swift` into new `Sources/QuickStudy/Views/Thumbnail.swift` as an internal type (behavior unchanged)
- [x] 2.2 Update `ResultList.swift` to use the extracted `Thumbnail`; confirm it still builds

## 3. Pin button in the preview pane

- [x] 3.1 Extend `CardPreview` (`Sources/QuickStudy/Views/CardPreview.swift`) to accept `isPinned: Bool` and `onTogglePin: () -> Void`
- [x] 3.2 Add a Pin/Unpin `Button` in the detail header area whose icon reflects `isPinned` (e.g. `pin.fill` vs `pin`), calling `onTogglePin`
- [x] 3.3 Attach `.keyboardShortcut("p", modifiers: .command)` to the button so ⌘P toggles the pin even while the search field is focused

## 4. Pinned bottom row view

- [x] 4.1 Create `Sources/QuickStudy/Views/PinnedRow.swift`: a horizontal `ScrollView` over `model.pinned`, each entry = `Thumbnail` + name, sized via `UIScale`
- [x] 4.2 Highlight the entry whose `id == model.selectedID` using the `RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))` treatment from `ResultList.Row`
- [x] 4.3 Add `.onTapGesture { model.select(entry.id) }` so clicking a pin swaps the preview
- [x] 4.4 Add an always-visible `xmark.circle.fill` unpin button on each entry calling `model.unpin(entry.id)`

## 5. Mount the pinned row in the panel

- [x] 5.1 In `SearchPanel.swift`, add the `PinnedRow` to the bottom of the root `VStack` (after `content`) with a `Divider().opacity(0.3)` above it, shown when `model.dbState == .ready && !model.pinned.isEmpty`
- [x] 5.2 Wire the preview pin button where `CardPreview` is constructed: `isPinned: model.isPinned(card.id)`, `onTogglePin: { model.togglePinSelected() }`

## 6. Verify

- [x] 6.1 `swift build` succeeds and `swift test` stays green (search ranking untouched)
- [x] 6.2 Run the app and verify: ⌘P and the preview button pin/unpin; clicking a pin swaps the preview; each entry's ✕ removes only that card; the row stays visible with an empty query; pins survive quit + relaunch
