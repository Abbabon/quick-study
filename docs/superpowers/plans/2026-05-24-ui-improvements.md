# UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enlarge the card preview image by ~50%, add a UI Scale slider in Settings, and add a Clear Image Cache button.

**Architecture:** Three independent slices on top of the existing SwiftUI/AppKit panel. A new `UIScale` value type centralizes font/padding multiplication; `@AppStorage("uiScale")` carries the user's preference. The panel is recreated on next open whenever the scale changes. A new `ImageCache` namespace holds pure static functions for measuring and clearing the images directory so they can be unit-tested against a temp directory.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (NSPanel/NSAlert), XCTest, GRDB (unchanged).

**Spec:** `docs/superpowers/specs/2026-05-24-ui-improvements-design.md`

---

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `Sources/QuickStudy/Views/CardPreview.swift` | Modify | Larger image frame; scale text via `UIScale`. |
| `Sources/QuickStudy/Views/SearchPanel.swift` | Modify | Larger `minWidth/minHeight`; scale search-field font/padding. |
| `Sources/QuickStudy/Views/ResultList.swift` | Modify | Scale row font, thumbnail, padding. |
| `Sources/QuickStudy/PanelController.swift` | Modify | Larger base panel; multiply size by scale; recreate panel on scale change. |
| `Sources/QuickStudy/SettingsView.swift` | Modify | New "Appearance" and "Cache" sections. |
| `Sources/QuickStudy/AppModel.swift` | Modify | Thin wrappers over `ImageCache` plus a formatted size property. |
| `Sources/QuickStudy/UIScale.swift` | Create | Value type that multiplies font sizes and paddings. |
| `Sources/QuickStudy/ImageCache.swift` | Create | Pure static helpers: `size(at:)` and `clear(at:)`. |
| `Tests/SearchEngineTests/UIScaleTests.swift` | Create | Verify `UIScale.font` / `UIScale.pad` math. |
| `Tests/SearchEngineTests/ImageCacheTests.swift` | Create | Verify size aggregation and clearing against a temp directory. |

---

## Task 1: Enlarge the card preview image and grow the panel

**Files:**
- Modify: `Sources/QuickStudy/Views/CardPreview.swift:23`
- Modify: `Sources/QuickStudy/PanelController.swift:34`
- Modify: `Sources/QuickStudy/Views/SearchPanel.swift:18`

No unit tests — this is a pure layout change verified by building and eyeballing the panel.

- [ ] **Step 1: Enlarge the image frame in `CardPreview`**

In `Sources/QuickStudy/Views/CardPreview.swift`, change line 23 from:

```swift
                .frame(maxWidth: 220, maxHeight: 320)
```

to:

```swift
                .frame(maxWidth: 330, maxHeight: 480)
```

- [ ] **Step 2: Grow the NSPanel default size**

In `Sources/QuickStudy/PanelController.swift`, change line 34 from:

```swift
        let size = NSSize(width: 760, height: 460)
```

to:

```swift
        let size = NSSize(width: 900, height: 560)
```

- [ ] **Step 3: Grow the SwiftUI minimum frame**

In `Sources/QuickStudy/Views/SearchPanel.swift`, change line 18 from:

```swift
        .frame(minWidth: 720, minHeight: 420)
```

to:

```swift
        .frame(minWidth: 860, minHeight: 520)
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/Views/CardPreview.swift Sources/QuickStudy/PanelController.swift Sources/QuickStudy/Views/SearchPanel.swift
git commit -m "feat(ui): enlarge card preview image and panel"
```

---

## Task 2: Create `UIScale` value type with tests

**Files:**
- Create: `Sources/QuickStudy/UIScale.swift`
- Create: `Tests/SearchEngineTests/UIScaleTests.swift`

`UIScale` is a tiny pure value type. It holds a `Double` factor and exposes helpers that multiply font sizes and paddings. Defining it once keeps all call sites consistent.

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/UIScaleTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import QuickStudy

final class UIScaleTests: XCTestCase {
    func testIdentityScaleReturnsInputValues() {
        let scale = UIScale(value: 1.0)
        XCTAssertEqual(scale.pad(10), 10, accuracy: 0.0001)
        XCTAssertEqual(scale.size(14), 14, accuracy: 0.0001)
    }

    func testGreaterThanOneScalesUp() {
        let scale = UIScale(value: 1.5)
        XCTAssertEqual(scale.pad(10), 15, accuracy: 0.0001)
        XCTAssertEqual(scale.size(14), 21, accuracy: 0.0001)
    }

    func testLessThanOneScalesDown() {
        let scale = UIScale(value: 0.8)
        XCTAssertEqual(scale.pad(10), 8, accuracy: 0.0001)
        XCTAssertEqual(scale.size(20), 16, accuracy: 0.0001)
    }

    func testFromDefaultsClampsToValidRange() {
        XCTAssertEqual(UIScale.clamp(0.5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(UIScale.clamp(3.0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(UIScale.clamp(1.25), 1.25, accuracy: 0.0001)
    }

    func testDefaultValueIsOne() {
        XCTAssertEqual(UIScale.defaultValue, 1.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SearchEngineTests.UIScaleTests`
Expected: FAIL — `UIScale` is not defined.

- [ ] **Step 3: Implement `UIScale`**

Create `Sources/QuickStudy/UIScale.swift`:

```swift
import Foundation
import SwiftUI

/// Multiplies font sizes and paddings by a user-controlled factor.
///
/// Stored in `UserDefaults` under the key ``UIScale/storageKey`` and
/// surfaced in SwiftUI views via `@AppStorage("uiScale")`. The card
/// image frame deliberately does NOT use this scale — the image was
/// enlarged separately and should stay at a fixed size.
struct UIScale {
    static let storageKey = "uiScale"
    static let defaultValue: Double = 1.0
    static let minValue: Double = 0.75
    static let maxValue: Double = 2.0

    let value: Double

    init(value: Double) {
        self.value = Self.clamp(value)
    }

    func pad(_ v: CGFloat) -> CGFloat { v * CGFloat(value) }
    func size(_ v: CGFloat) -> CGFloat { v * CGFloat(value) }

    func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: self.size(size), weight: weight, design: design)
    }

    static func clamp(_ raw: Double) -> Double {
        min(max(raw, minValue), maxValue)
    }

    /// Reads the current scale from `UserDefaults`. Used by non-SwiftUI
    /// callers like `PanelController` that can't use `@AppStorage`.
    static func current() -> UIScale {
        let raw = UserDefaults.standard.object(forKey: storageKey) as? Double ?? defaultValue
        return UIScale(value: raw)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SearchEngineTests.UIScaleTests`
Expected: PASS — all five tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/UIScale.swift Tests/SearchEngineTests/UIScaleTests.swift
git commit -m "feat(ui): add UIScale value type"
```

---

## Task 3: Apply `UIScale` to `SearchPanel`, `ResultList`, and `CardPreview`

**Files:**
- Modify: `Sources/QuickStudy/Views/SearchPanel.swift`
- Modify: `Sources/QuickStudy/Views/ResultList.swift`
- Modify: `Sources/QuickStudy/Views/CardPreview.swift`

Each view reads `@AppStorage("uiScale")` once at the top of `body`, constructs a local `UIScale`, then uses `scale.size(...)` / `scale.pad(...)` / `scale.font(...)` instead of hard-coded values. No unit tests — verified visually after Task 5 wires the slider.

- [ ] **Step 1: Scale the search field in `SearchPanel`**

In `Sources/QuickStudy/Views/SearchPanel.swift`, add an `@AppStorage` property right after the existing `enterBehaviorRaw`:

```swift
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
```

Replace the `searchField` computed property with:

```swift
    private var searchField: some View {
        let scale = UIScale(value: uiScaleValue)
        return HStack(spacing: scale.pad(8)) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(scale.font(18, weight: .medium))
            TextField("Search MTG cards…", text: $model.query)
                .textFieldStyle(.plain)
                .font(scale.font(22, weight: .light))
                .focused($searchFocused)
                .onChange(of: model.query) { model.runSearch() }
                .onSubmit { handleEnter() }
                .onKeyPress(.upArrow) { model.selectPrev(); return .handled }
                .onKeyPress(.downArrow) { model.selectNext(); return .handled }
        }
        .padding(.horizontal, scale.pad(18))
        .padding(.vertical, scale.pad(14))
    }
```

Replace the `placeholderHint` computed property with:

```swift
    private var placeholderHint: some View {
        let scale = UIScale(value: uiScaleValue)
        return VStack(spacing: scale.pad(8)) {
            Text("Type a card name")
                .font(scale.font(17))
                .foregroundStyle(.secondary)
            Text("\(model.totalCards) cards • ↑↓ to navigate • Esc to close")
                .font(scale.font(11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

Also update the result-list column width in `content` to scale. Replace the lines:

```swift
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: 280)
```

with:

```swift
                let scale = UIScale(value: uiScaleValue)
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: scale.size(280))
```

- [ ] **Step 2: Scale the result rows in `ResultList`**

In `Sources/QuickStudy/Views/ResultList.swift`, add at the top of the `Row` struct:

```swift
        @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
```

Replace the `Row.body` with:

```swift
        var body: some View {
            let scale = UIScale(value: uiScaleValue)
            return HStack(spacing: scale.pad(10)) {
                Thumbnail(id: mini.id)
                    .frame(width: scale.size(28), height: scale.size(40))
                Text(mini.name)
                    .lineLimit(1)
                    .font(scale.font(14))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, scale.pad(10))
            .padding(.vertical, scale.pad(4))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
```

- [ ] **Step 3: Scale the text column in `CardPreview`**

In `Sources/QuickStudy/Views/CardPreview.swift`, add at the top of the `CardPreview` struct (just after `let card: Card?`):

```swift
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
```

Replace the `body` with:

```swift
    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        return Group {
            if let card = card {
                content(card: card, scale: scale)
            } else {
                Color.clear
            }
        }
        .padding(scale.pad(16))
    }
```

Replace the `content(card:)` function with:

```swift
    @ViewBuilder
    private func content(card: Card, scale: UIScale) -> some View {
        HStack(alignment: .top, spacing: scale.pad(16)) {
            cardImage(for: card.id)
                .frame(maxWidth: 330, maxHeight: 480)
            VStack(alignment: .leading, spacing: scale.pad(8)) {
                HStack {
                    Text(card.name).font(scale.font(17, weight: .bold))
                    Spacer()
                    if let cost = card.manaCost {
                        Text(cost)
                            .font(scale.font(13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let type = card.typeLine {
                    Text(type).font(scale.font(12)).foregroundStyle(.secondary)
                }
                if let text = card.oracleText, !text.isEmpty {
                    Text(text)
                        .font(scale.font(13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = card.power, let t = card.toughness {
                    Text("\(p) / \(t)").font(scale.font(11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

Note: the card image frame stays hard-coded at `330 × 480` — it must not scale. The previous code used semantic SwiftUI fonts (`.title3`, `.subheadline`, etc.); we are intentionally switching to numeric sizes so the scale multiplier composes predictably. Sizes chosen to match the approximate native sizes: `.title3 ≈ 17`, `.subheadline ≈ 12`, `.body ≈ 13`, `.footnote ≈ 11`.

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/Views/SearchPanel.swift Sources/QuickStudy/Views/ResultList.swift Sources/QuickStudy/Views/CardPreview.swift
git commit -m "feat(ui): apply UIScale to search panel, result list, and preview text"
```

---

## Task 4: Scale panel size in `PanelController` and recreate on change

**Files:**
- Modify: `Sources/QuickStudy/PanelController.swift`

`PanelController` is `NSObject`-based AppKit code, so it reads the scale via `UIScale.current()` rather than `@AppStorage`. It tracks the scale used at construction; when `show()` is called and the stored scale differs, the existing panel is disposed so the next call rebuilds it with the new size.

No unit tests — AppKit panel layout is not unit-testable here.

- [ ] **Step 1: Track the scale used at panel construction**

In `Sources/QuickStudy/PanelController.swift`, change the property declarations near the top of the class from:

```swift
    private var panel: NSPanel?
    private let model: AppModel
```

to:

```swift
    private var panel: NSPanel?
    private var panelScale: Double = UIScale.defaultValue
    private let model: AppModel
```

- [ ] **Step 2: Recreate the panel when the scale changes**

Replace the `show()` method with:

```swift
    func show() {
        let currentScale = UIScale.current().value
        if let existing = panel, currentScale != panelScale {
            existing.orderOut(nil)
            panel = nil
        }
        if panel == nil {
            panel = makePanel()
            panelScale = currentScale
        }
        guard let panel = panel else { return }
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: Multiply the panel base size by the current scale**

Replace the first three lines of `makePanel()` (currently lines 33-35) from:

```swift
    private func makePanel() -> NSPanel {
        let size = NSSize(width: 760, height: 460)
        let panel = SpotlightPanel(
```

to:

```swift
    private func makePanel() -> NSPanel {
        let scale = UIScale.current()
        let size = NSSize(width: scale.size(900), height: scale.size(560))
        let panel = SpotlightPanel(
```

Note: the line `let size = NSSize(width: 900, height: 560)` was set in Task 1. Task 4 changes it to scale-aware.

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/PanelController.swift
git commit -m "feat(ui): scale NSPanel size and recreate on UIScale change"
```

---

## Task 5: Add "Appearance" section with UI Scale slider in Settings

**Files:**
- Modify: `Sources/QuickStudy/SettingsView.swift`

- [ ] **Step 1: Add the appearance section to `SettingsView`**

In `Sources/QuickStudy/SettingsView.swift`, add a new `@AppStorage` after the existing one:

```swift
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
```

Insert a new section between the "Behavior" and "Database" sections (after the `Section("Behavior") { ... }` closing brace, before `Section("Database") { ... }`):

```swift
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("UI Scale:")
                        Spacer()
                        Text("\(Int((uiScaleValue * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $uiScaleValue, in: UIScale.minValue ... UIScale.maxValue, step: 0.05)
                    Text("Applies the next time you open the search panel.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
```

- [ ] **Step 2: Build and verify**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Manual sanity check (record in commit if blocked)**

Run the app:

```bash
MTG_FETCHER_PATH="$(swift build --show-bin-path)/mtg-fetcher" swift run QuickStudy
```

Open Settings, drag the UI Scale slider to 150%, close & reopen the search panel via the global hotkey — fonts/paddings in the search field, result rows, and preview text should be noticeably larger; the card image should look the same size as before. Drag to 80%, repeat — everything text-side should shrink, image unchanged.

If you can't run the app interactively, skip this step and rely on Task 8's verification.

- [ ] **Step 4: Commit**

```bash
git add Sources/QuickStudy/SettingsView.swift
git commit -m "feat(settings): add UI Scale slider in Appearance section"
```

---

## Task 6: Create `ImageCache` helpers with tests

**Files:**
- Create: `Sources/QuickStudy/ImageCache.swift`
- Create: `Tests/SearchEngineTests/ImageCacheTests.swift`

Pure file-system functions parameterized by URL so they can be unit-tested against a temp directory.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SearchEngineTests/ImageCacheTests.swift`:

```swift
import XCTest
@testable import QuickStudy

final class ImageCacheTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickstudy-imagecache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testSizeIsZeroForEmptyDirectory() throws {
        XCTAssertEqual(try ImageCache.size(at: tmpDir), 0)
    }

    func testSizeSumsFileBytes() throws {
        try Data(repeating: 0x41, count: 1000).write(to: tmpDir.appendingPathComponent("a.jpg"))
        try Data(repeating: 0x42, count: 2500).write(to: tmpDir.appendingPathComponent("b.jpg"))
        XCTAssertEqual(try ImageCache.size(at: tmpDir), 3500)
    }

    func testSizeIsZeroForMissingDirectory() throws {
        let missing = tmpDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(try ImageCache.size(at: missing), 0)
    }

    func testClearDeletesFilesAndReturnsBytesFreed() throws {
        try Data(repeating: 0x41, count: 1000).write(to: tmpDir.appendingPathComponent("a.jpg"))
        try Data(repeating: 0x42, count: 2500).write(to: tmpDir.appendingPathComponent("b.jpg"))
        let freed = try ImageCache.clear(at: tmpDir)
        XCTAssertEqual(freed, 3500)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.path), "directory itself should be preserved")
    }

    func testClearOnMissingDirectoryReturnsZero() throws {
        let missing = tmpDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(try ImageCache.clear(at: missing), 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SearchEngineTests.ImageCacheTests`
Expected: FAIL — `ImageCache` is not defined.

- [ ] **Step 3: Implement `ImageCache`**

Create `Sources/QuickStudy/ImageCache.swift`:

```swift
import Foundation

/// Pure helpers for measuring and clearing a directory of cached image
/// files. The directory itself is preserved on `clear` so the fetcher
/// can write into it again on the next refresh.
enum ImageCache {
    /// Total size in bytes of all regular files directly inside `dir`.
    /// Returns 0 if the directory does not exist.
    static func size(at dir: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        for url in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let bytes = values.fileSize {
                total += Int64(bytes)
            }
        }
        return total
    }

    /// Deletes all regular files inside `dir` (keeping `dir` itself).
    /// Returns the number of bytes freed. Returns 0 for a missing dir.
    @discardableResult
    static func clear(at dir: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var freed: Int64 = 0
        for url in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                if let bytes = values.fileSize { freed += Int64(bytes) }
                try fm.removeItem(at: url)
            }
        }
        return freed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SearchEngineTests.ImageCacheTests`
Expected: PASS — all five tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/ImageCache.swift Tests/SearchEngineTests/ImageCacheTests.swift
git commit -m "feat(cache): add ImageCache helpers for measuring and clearing"
```

---

## Task 7: Wire `ImageCache` into `AppModel` and add Clear Cache UI

**Files:**
- Modify: `Sources/QuickStudy/AppModel.swift`
- Modify: `Sources/QuickStudy/SettingsView.swift`

`AppModel` exposes a published formatted-size string plus a method to refresh it and a method to clear. SettingsView adds a "Cache" section with the size, a destructive button, and an `NSAlert` confirmation.

- [ ] **Step 1: Add cache state and methods to `AppModel`**

In `Sources/QuickStudy/AppModel.swift`, add a new `@Published` property next to the existing ones (right after `@Published var lastRefresh: String?`):

```swift
    @Published var imageCacheSizeFormatted: String = "—"
```

Add these methods at the end of the class, just before the final `}`:

```swift
    // MARK: - Image cache

    func refreshImageCacheSize() {
        let bytes = (try? ImageCache.size(at: Paths.imagesDir)) ?? 0
        imageCacheSizeFormatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Returns bytes freed. Refreshes the published formatted size.
    @discardableResult
    func clearImageCache() -> Int64 {
        let freed = (try? ImageCache.clear(at: Paths.imagesDir)) ?? 0
        refreshImageCacheSize()
        return freed
    }
```

Then update `refreshDBState()` to refresh the cache size too. Change its last line (currently inside the `do` block, after `dbState = .ready; engine.load(...)`) by appending one line — replace the whole `do { ... } catch { ... }` block with:

```swift
        do {
            let n = try store.count()
            totalCards = n
            lastRefresh = try? store.meta("last_refresh")
            if n == 0 {
                dbState = .empty
            } else {
                dbState = .ready
                engine.load(try store.loadMinis())
            }
            refreshImageCacheSize()
        } catch {
            dbState = .unknown
        }
```

- [ ] **Step 2: Add the Cache section to `SettingsView`**

In `Sources/QuickStudy/SettingsView.swift`, append a new section after the `Section("Database") { ... }` closing brace, before the `Form`'s closing brace:

```swift
            Section("Cache") {
                HStack {
                    Text("Image cache:")
                    Spacer()
                    Text(model.imageCacheSizeFormatted).foregroundStyle(.secondary)
                }
                Button("Clear Image Cache…", role: .destructive) { confirmClearImageCache() }
            }
```

Also add the helper function inside `SettingsView`, just before the closing `}` of the struct:

```swift
    private func confirmClearImageCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Image Cache?"
        alert.informativeText = "This will delete \(model.imageCacheSizeFormatted) of cached card images. The card database is preserved — you can re-download images via Refresh Now."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        // Make "Clear" the destructive (non-default) button.
        if alert.buttons.count >= 2 {
            alert.buttons[1].hasDestructiveAction = true
        }
        let response = alert.runModal()
        // First button = Cancel (.alertFirstButtonReturn), second = Clear.
        if response == .alertSecondButtonReturn {
            model.clearImageCache()
        }
    }
```

Add `import AppKit` to the top of `SettingsView.swift` if it's not already imported.

- [ ] **Step 3: Refresh the size when Settings opens**

Add an `.onAppear` to the existing `Form` in `SettingsView.body`. Replace:

```swift
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 380, idealHeight: 380)
```

with:

```swift
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 380, idealHeight: 380)
        .onAppear { model.refreshImageCacheSize() }
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 5: Run the existing test suite**

Run: `swift test`
Expected: all tests pass (`SearchEngineTests`, `UIScaleTests`, `ImageCacheTests`).

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/AppModel.swift Sources/QuickStudy/SettingsView.swift
git commit -m "feat(settings): add Clear Image Cache button with size display"
```

---

## Task 8: End-to-end manual verification

**Files:** none.

This is the spec's verification checklist. Run through it before declaring done.

- [ ] **Step 1: Build the app**

Run: `./scripts/build-app.sh`
Expected: builds successfully into `./dist/QuickStudy.app`.

- [ ] **Step 2: Launch and verify card image is larger**

Open `./dist/QuickStudy.app`, trigger the global hotkey, type a card name. The preview image on the right should be visibly larger than before and the panel itself wider.

- [ ] **Step 3: Verify UI Scale slider works**

Open the app's Settings (menu-bar icon → Settings…). Drag UI Scale to 150%. Close Settings, dismiss the panel (Esc), reopen via hotkey. Fonts and paddings should be larger; the card image should be the same size as in Step 2. Repeat with 80% — text smaller, image unchanged.

- [ ] **Step 4: Verify Cache section displays a non-zero size**

If you've done a refresh that downloaded images, the "Image cache:" row should show e.g. "245.7 MB". If you have no images cached, it should show "Zero KB" or similar.

- [ ] **Step 5: Verify Clear Image Cache works**

Click "Clear Image Cache…". The alert should show the size. Click Cancel — files remain (verify with `ls ~/Library/Application\ Support/QuickStudy/images/ | wc -l`). Click again, confirm Clear — the images directory is empty and the Settings row updates to "Zero KB".

- [ ] **Step 6: Verify preview shows placeholder after clearing**

With the cache cleared, reopen the panel, search for a card. The preview should show the "Image not downloaded" placeholder where the image used to be.

No commit for this task — it's verification only.

---

## Self-Review Notes (resolved)

- Spec coverage: all three goals have tasks (1, 3-5, 6-7). Verification (Task 8) maps to the spec's verification section.
- Type consistency: `UIScale.storageKey`, `UIScale.defaultValue`, `UIScale.minValue`, `UIScale.maxValue`, `UIScale.current()`, `UIScale.clamp(_:)`, `UIScale.size(_:)`, `UIScale.pad(_:)`, `UIScale.font(_:weight:design:)`, `ImageCache.size(at:)`, `ImageCache.clear(at:)`, `AppModel.imageCacheSizeFormatted`, `AppModel.refreshImageCacheSize()`, `AppModel.clearImageCache()` — all introduced once and referenced consistently.
- Placeholder scan: no TBDs, no "implement appropriately", no skipped test code.
- Note on font-size mapping in Task 3: SwiftUI semantic fonts were replaced with numeric sizes so `UIScale.font(_:)` multiplies cleanly. The chosen values (17/13/12/11) approximate the native sizes at default scale.
