# UI Improvements: Larger Image, UI Scale, Clear Cache

**Date:** 2026-05-24
**Scope:** Three small SwiftUI/AppKit changes to the QuickStudy menu-bar app.

## Goals

1. **Larger card image in preview** — make the card art more prominent (~50% bigger).
2. **UI Scale slider in Settings** — let users scale text and chrome (not the card image) from 75% to 200%.
3. **Clear Image Cache button in Settings** — let users free disk space without doing a full DB reset.

## 1. Larger Card Image

| Property | Before | After |
| --- | --- | --- |
| `CardPreview` image frame | `maxWidth: 220, maxHeight: 320` | `maxWidth: 330, maxHeight: 480` |
| `PanelController` panel size | `760 × 460` | `900 × 560` |
| `SearchPanel` minimum frame | `minWidth: 720, minHeight: 420` | `minWidth: 860, minHeight: 520` |

The card image keeps its aspect ratio via `scaledToFit`, so we only need to enlarge the bounding frame. Panel grows in both dimensions to keep the text column reasonable.

## 2. UI Scale Slider

### Storage
- New `@AppStorage("uiScale")` double, default `1.0`, valid range `0.75 ... 2.0`.

### Scope
- **Scales:** all explicit font sizes and paddings in `SearchPanel`, `ResultList`, and `CardPreview`, plus result-list thumbnail size.
- **Does not scale:** the card image frame (it already grew via change #1) and the `NSVisualEffectView` corner radius.

### Implementation strategy
A small helper struct or environment value, e.g.:

```swift
struct UIScale {
    let value: Double
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * value, weight: weight)
    }
    func pad(_ v: CGFloat) -> CGFloat { v * value }
}
```

Each SwiftUI view that contains the panel reads `@AppStorage("uiScale")` once at the top of `body` and constructs a `UIScale` to use locally. Call sites updated:

- `SearchPanel.searchField`: search-glass icon (18pt), text field (22pt), horizontal/vertical paddings.
- `SearchPanel.placeholderHint`: title3 / caption font sizes (use `.system(size:)` so scaling works uniformly).
- `ResultList.Row`: row text (14pt), thumbnail frame (28×40), horizontal/vertical paddings.
- `CardPreview.content`: title3/body/13pt/subheadline/footnote fonts and `.padding(16)`.

### Panel sizing
The `NSPanel` is sized in `PanelController.makePanel()`. It will multiply both the base panel size (`900 × 560`) and the result-list column width (`280`) by the current `uiScale` value read from `UserDefaults.standard.double(forKey: "uiScale")`.

### Live update
**Out of scope.** Scale changes take effect the next time the panel is opened (`PanelController.show()` already calls `makePanel()` lazily — we only need to recreate the panel after a scale change, or simply rely on the user closing and reopening it). The simplest implementation: in `PanelController.show()`, if `panel != nil` and the stored scale differs from the scale used at construction, dispose and recreate. That keeps the model dumb and avoids reactive plumbing.

### Settings UI
New "Appearance" section in `SettingsView`:

```swift
Section("Appearance") {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text("UI Scale:")
            Spacer()
            Text("\(Int(uiScale * 100))%").foregroundStyle(.secondary)
        }
        Slider(value: $uiScale, in: 0.75 ... 2.0, step: 0.05)
        Text("Applies the next time you open the search panel.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
```

## 3. Clear Image Cache Button

### Behavior
- A new "Cache" section in `SettingsView` shows the on-disk size of the images directory.
- A "Clear Image Cache…" button triggers an `NSAlert`:
  - Title: "Clear Image Cache?"
  - Message: "This will delete N MB of cached card images. The card database is preserved. You can re-download images via Refresh Now."
  - Buttons: "Cancel" (default), "Clear" (destructive).
- On confirm: delete all files under `Paths.imagesDir` (keep the directory itself), then refresh the displayed size.

### Implementation
- New `AppModel` methods:
  - `imageCacheSize() -> Int64` — sums file sizes under `Paths.imagesDir`. Called once on Settings open and after clearing.
  - `clearImageCache() throws -> Int64` — enumerates and removes files, returns bytes freed. Does not touch the SQLite DB or in-memory `NSCache`.
- Size formatting via `ByteCountFormatter` (`.useMB`, `.file`).
- Computing size synchronously is fine for ~25k JPEGs (≤ a few hundred ms on a cold disk; instant when cached). If it ever becomes slow we can move to a `Task`.

### Settings UI sketch
```swift
Section("Cache") {
    HStack {
        Text("Image cache:")
        Spacer()
        Text(model.imageCacheSizeFormatted).foregroundStyle(.secondary)
    }
    Button("Clear Image Cache…", role: .destructive) { confirmAndClear() }
}
```

## Files Touched

| File | Change |
| --- | --- |
| `Sources/QuickStudy/Views/CardPreview.swift` | Larger image frame; read `uiScale`; scale fonts and padding. |
| `Sources/QuickStudy/Views/SearchPanel.swift` | Larger minFrame; scale fonts/paddings in search field + placeholder. |
| `Sources/QuickStudy/Views/ResultList.swift` | Scale row font, thumbnail size, paddings. |
| `Sources/QuickStudy/PanelController.swift` | Larger base panel; multiply by `uiScale`; recreate-on-scale-change in `show()`. |
| `Sources/QuickStudy/SettingsView.swift` | New "Appearance" and "Cache" sections; slider; clear-cache flow. |
| `Sources/QuickStudy/AppModel.swift` | `imageCacheSize()` and `clearImageCache()` methods. |

No changes to `Shared`, `Fetcher`, schema, or tests.

## Out of Scope

- Live UI-scale updates while the panel is open.
- Scaling the card image (intentional — image was just enlarged).
- Clearing the SQLite DB or in-memory `NSCache` (separate "factory reset" feature, not requested).
- Settings-window scaling.

## Verification

- Open the app, verify the card image in preview is visibly larger and panel is roomier.
- Open Settings → Appearance, drag slider to 150%, close, reopen panel → fonts/paddings larger, image unchanged.
- Drag slider to 80%, reopen panel → fonts smaller.
- Settings → Cache shows a non-zero MB figure after a refresh has populated images.
- Click "Clear Image Cache…", cancel — files remain. Click again, confirm — `~/Library/Application Support/QuickStudy/images/` is empty; size in Settings updates to "Zero KB" (or similar).
- After clearing, the preview shows the "Image not downloaded" placeholder.
