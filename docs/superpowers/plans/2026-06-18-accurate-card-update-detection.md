# Accurate New-Card Detection + Offline Image Fetch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace timestamp-only update detection with accurate new-card detection: silently ingest card text when Scryfall changes, surface the menu-bar dot only when genuinely new cards landed, and download their images for offline use on accept.

**Architecture:** A cheap bulk-index timestamp check gates a silent background `mtg-fetcher --no-images` run that reports how many brand-new cards were inserted. The dot/notification fire only when that count is `> 0`. Accept runs `mtg-fetcher --images-only`, reusing the on-disk bulk JSON to download only missing images. The fetcher and the app's `FetcherProcess` exchange a new `newCards` field over the existing NDJSON protocol.

**Tech Stack:** Swift 5.9+, SwiftUI menu-bar app (macOS 14+), GRDB (SQLite), two SPM executables (`QuickStudy`, `mtg-fetcher`) sharing `Shared`. Tests via `swift test` (XCTest, single `SearchEngineTests` target).

---

## File Structure

- `Sources/Shared/CardStore.swift` — add `cardCount()` (read query). *Modify.*
- `Sources/Fetcher/ProgressEmitter.swift` — add `newCards` to event + `emit`. *Modify.*
- `Sources/QuickStudy/FetcherProcess.swift` — add `newCards` to event; replace `skipImages: Bool` with a `Mode` enum so it can run full / ingest-only / images-only. *Modify.*
- `Sources/Fetcher/Fetcher.swift` — count new cards, emit on `done`; add `--images-only` mode. *Modify.*
- `Sources/QuickStudy/UpdateChecker.swift` — add `isNewerThanIngested`. *Modify.*
- `Sources/QuickStudy/AppModel.swift` — silent ingest path, `newCardsPendingImages`, `startImageDownload`, fetcher serialization, `updateAvailable` computed. *Modify.*
- `Sources/QuickStudy/QuickStudyApp.swift` — accept actions call `startImageDownload`; copy. *Modify.*
- `Sources/QuickStudy/SettingsView.swift` — badge + button copy/wiring. *Modify.*
- `Tests/SearchEngineTests/CardStoreCountTests.swift` — `cardCount()` test. *Create.*
- `Tests/SearchEngineTests/UpdateCheckerTests.swift` — `isNewerThanIngested` tests. *Modify.*

Note: the test target is named `SearchEngineTests` but holds all unit tests; new test files go in `Tests/SearchEngineTests/`.

---

## Task 1: `CardStore.cardCount()`

**Files:**
- Modify: `Sources/Shared/CardStore.swift` (after `meta(_:)`, around line 111)
- Create: `Tests/SearchEngineTests/CardStoreCountTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/CardStoreCountTests.swift`:

```swift
import XCTest
import Shared

final class CardStoreCountTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-count-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String) -> Card {
        Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
             power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
             setCode: "TST", setName: "Test Set", dateAdded: "2024-01-01")
    }

    func testCountIsZeroOnEmptyStore() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.cardCount(), 0)
    }

    func testCountReflectsInsertedCards() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha"), card("b", "Bravo")])
        XCTAssertEqual(try store.cardCount(), 2)
    }

    func testCountDoesNotDoubleCountUpserts() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha")])
        try store.upsert([card("a", "Alpha renamed")]) // same id → update, not insert
        XCTAssertEqual(try store.cardCount(), 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardStoreCountTests`
Expected: FAIL to compile — `value of type 'CardStore' has no member 'cardCount'`.

- [ ] **Step 3: Add `cardCount()`**

In `Sources/Shared/CardStore.swift`, immediately after the `meta(_:)` method (line 111):

```swift
    /// Total number of rows in `cards`. Used by the fetcher to compute how many
    /// brand-new cards an ingest added (count delta before vs after).
    public func cardCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardStoreCountTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/CardStore.swift Tests/SearchEngineTests/CardStoreCountTests.swift
git commit -m "feat(store): add cardCount() for new-card delta"
```

---

## Task 2: Add `newCards` to the NDJSON protocol (both sides, lockstep)

CLAUDE.md requires updating `ProgressEmitter.swift` and `FetcherProcess.swift` together. No behavior yet — just the field — so the build stays green.

**Files:**
- Modify: `Sources/Fetcher/ProgressEmitter.swift`
- Modify: `Sources/QuickStudy/FetcherProcess.swift`

- [ ] **Step 1: Add `newCards` to the emitter**

In `Sources/Fetcher/ProgressEmitter.swift`, replace the `Event` struct and `emit` method:

```swift
    public struct Event: Encodable {
        public let phase: String        // "json" | "ingest" | "images" | "done" | "error"
        public let done: Int?
        public let total: Int?
        public let message: String?
        public let newCards: Int?       // count of brand-new cards (on "done" after ingest)
    }

    public func emit(phase: String, done: Int? = nil, total: Int? = nil,
                     message: String? = nil, newCards: Int? = nil) {
        let event = Event(phase: phase, done: done, total: total, message: message, newCards: newCards)
        if let data = try? encoder.encode(event),
           var line = String(data: data, encoding: .utf8) {
            line.append("\n")
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let human = "[\(stamp)] \(phase) done=\(done.map(String.init) ?? "-") total=\(total.map(String.init) ?? "-") newCards=\(newCards.map(String.init) ?? "-") \(message ?? "")\n"
        logHandle?.write(Data(human.utf8))
    }
```

- [ ] **Step 2: Add `newCards` to `FetcherProcess.Event` and the decoder**

In `Sources/QuickStudy/FetcherProcess.swift`, replace the `Event` struct, `EventDecoded` struct, and the `onEvent(Event(...))` decode call inside the readability handler:

```swift
    struct Event {
        let phase: String
        let done: Int?
        let total: Int?
        let message: String?
        let newCards: Int?
    }

    private struct EventDecoded: Decodable {
        let phase: String
        let done: Int?
        let total: Int?
        let message: String?
        let newCards: Int?
    }
```

Then update the decode forwarding line inside `readabilityHandler`:

```swift
                if let decoded = try? JSONDecoder().decode(EventDecoded.self, from: line) {
                    onEvent(Event(phase: decoded.phase, done: decoded.done, total: decoded.total,
                                  message: decoded.message, newCards: decoded.newCards))
                }
```

And update the three synthetic `Event(...)` constructions in `run` (the "error"/"spawn failed"/"exit" events) to pass `newCards: nil`. For example:

```swift
            onEvent(Event(phase: "error", done: nil, total: nil, message: "mtg-fetcher not found", newCards: nil))
```
```swift
            onEvent(Event(phase: "error", done: nil, total: nil, message: "spawn failed: \(error)", newCards: nil))
```
```swift
        onEvent(Event(phase: "exit", done: nil, total: nil, message: nil, newCards: nil))
```

- [ ] **Step 3: Build to verify both targets compile**

Run: `swift build`
Expected: builds with no errors. (`newCards` is unused for now; that's fine — it's an optional struct field, no warning.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Fetcher/ProgressEmitter.swift Sources/QuickStudy/FetcherProcess.swift
git commit -m "feat(protocol): add newCards field to fetcher NDJSON events"
```

---

## Task 3: Fetcher reports the new-card count

**Files:**
- Modify: `Sources/Fetcher/Fetcher.swift`

- [ ] **Step 1: Count before/after ingest and emit on done**

In `Sources/Fetcher/Fetcher.swift`, replace the ingest block (lines ~27–44, from `// 3. Parse + ingest` through the `if skipImages { ... return }` block) with:

```swift
            // 3. Parse + ingest
            let cards = try client.parseBulk(at: bulkURL)
            let countBefore = try store.cardCount()
            emitter.emit(phase: "ingest", done: 0, total: cards.count)
            // Upsert in batches so SQLite write-locks don't dominate.
            let batchSize = 1000
            var done = 0
            for batch in cards.chunked(into: batchSize) {
                try store.upsert(batch)
                done += batch.count
                emitter.emit(phase: "ingest", done: done, total: cards.count)
            }
            try store.setMeta("last_refresh", ISO8601DateFormatter().string(from: Date()))
            try store.setMeta("bulk_updated_at", info.updated_at)
            // The fetcher never deletes cards, so the row-count delta is the number
            // of brand-new cards this ingest added.
            let newCards = max(0, try store.cardCount() - countBefore)

            // 4. Image download (unless --no-images)
            if skipImages {
                emitter.emit(phase: "done", message: "skipping images", newCards: newCards)
                return
            }
```

Then update the final success emit (the `emitter.emit(phase: "done", message: "complete")` line at the end of the image phase) to carry the count too:

```swift
            emitter.emit(phase: "done", message: "complete", newCards: newCards)
```

- [ ] **Step 2: Build and run the fetcher against a real DB to verify**

Run:
```bash
swift run mtg-fetcher --no-images 2>/dev/null | tail -1
```
Expected: the last NDJSON line is the `done` event and includes `"newCards":` with an integer (likely `0` on a second run, since the DB is already populated; a large number on first populate). Example:
`{"phase":"done","message":"skipping images","newCards":0}`

(If the DB is empty/first run, `newCards` equals the full corpus size — that's correct.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Fetcher/Fetcher.swift
git commit -m "feat(fetcher): report new-card count on done"
```

---

## Task 4: Fetcher `--images-only` mode

Skips parse+ingest and meta writes; reuses the on-disk bulk JSON (downloads it only if absent); downloads missing images. The image phase already skips files already on disk.

**Files:**
- Modify: `Sources/Fetcher/Fetcher.swift`

- [ ] **Step 1: Parse the flag and branch**

In `Sources/Fetcher/Fetcher.swift`, replace the top of `main()` (the flag parse + emitter start, lines ~7–11):

```swift
        let args = CommandLine.arguments
        let imagesOnly = args.contains("--images-only")
        let skipImages = args.contains("--no-images")

        let emitter = ProgressEmitter(logURL: Paths.fetcherLogURL)
        emitter.emit(phase: "start", message: "mtg-fetcher starting (imagesOnly=\(imagesOnly) skipImages=\(skipImages))")
```

- [ ] **Step 2: Add the images-only path inside the `do` block**

In `Sources/Fetcher/Fetcher.swift`, immediately after `let client = ScryfallClient()` (line ~15), insert an early branch that handles images-only and returns before the normal json/ingest flow:

```swift
            let bulkURL = Paths.supportDir.appendingPathComponent("bulk-oracle.json", isDirectory: false)

            // Images-only: reuse the bulk JSON already on disk (download it only if
            // missing) and download just the images not yet cached. No ingest.
            if imagesOnly {
                if !FileManager.default.fileExists(atPath: bulkURL.path) {
                    emitter.emit(phase: "json", message: "bulk JSON missing — downloading")
                    let info = try await client.bulkInfo(type: "oracle_cards")
                    try await client.downloadBulkJSON(from: info, to: bulkURL)
                }
                let refs = try client.extractImageRefs(at: bulkURL)
                emitter.emit(phase: "images", done: 0, total: refs.count)
                let downloader = ImageDownloader(concurrency: 8)
                await downloader.download(refs: refs, store: store) { done, total in
                    emitter.emit(phase: "images", done: done, total: total)
                }
                emitter.emit(phase: "done", message: "images complete")
                return
            }
```

Then in the existing normal flow below, **remove** the now-duplicate `let bulkURL = ...` declaration (line ~23, `let bulkURL = Paths.supportDir.appendingPathComponent("bulk-oracle.json", isDirectory: false)`) since `bulkURL` is now declared once above. The subsequent `try await client.downloadBulkJSON(from: info, to: bulkURL)` keeps working with the hoisted constant.

- [ ] **Step 3: Build and smoke-test images-only**

Run:
```bash
swift build && swift run mtg-fetcher --images-only 2>/dev/null | tail -1
```
Expected: ends with `{"phase":"done","message":"images complete"}`. If images already exist, the `images` progress shows `done == total` quickly with no new downloads.

- [ ] **Step 4: Commit**

```bash
git add Sources/Fetcher/Fetcher.swift
git commit -m "feat(fetcher): add --images-only mode reusing on-disk bulk"
```

---

## Task 5: `FetcherProcess` mode (full / ingest-only / images-only)

Replace the `skipImages: Bool` parameter with a `Mode` enum so the app can launch all three runs.

**Files:**
- Modify: `Sources/QuickStudy/FetcherProcess.swift`

- [ ] **Step 1: Add the `Mode` enum and use it in `run`**

In `Sources/QuickStudy/FetcherProcess.swift`, add the enum inside `FetcherProcess` (e.g. just below the `Event` struct):

```swift
    enum Mode {
        case full          // json → ingest → images
        case ingestOnly    // json → ingest (no images)
        case imagesOnly    // reuse bulk JSON → images only

        var arguments: [String] {
            switch self {
            case .full: return []
            case .ingestOnly: return ["--no-images"]
            case .imagesOnly: return ["--images-only"]
            }
        }
    }
```

Then change the `run` signature and the `process.arguments` line:

```swift
    func run(mode: Mode, onEvent: @escaping (Event) -> Void) async {
```
```swift
        process.arguments = mode.arguments
```

- [ ] **Step 2: Update the one existing caller (`AppModel.startRefresh`)**

In `Sources/QuickStudy/AppModel.swift`, inside `startRefresh`, change:

```swift
            await self?.fetcher.run(skipImages: skipImages) { event in
```
to:

```swift
            await self?.fetcher.run(mode: skipImages ? .ingestOnly : .full) { event in
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/QuickStudy/FetcherProcess.swift Sources/QuickStudy/AppModel.swift
git commit -m "refactor(app): FetcherProcess.run takes a Mode (full/ingestOnly/imagesOnly)"
```

---

## Task 6: `UpdateChecker.isNewerThanIngested`

Gates the silent ingest (ignores the dismissed stamp, so search always stays current). The existing `shouldPrompt` stays for the dot decision.

**Files:**
- Modify: `Sources/QuickStudy/UpdateChecker.swift`
- Modify: `Tests/SearchEngineTests/UpdateCheckerTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/SearchEngineTests/UpdateCheckerTests.swift`, add inside the class (after the existing tests):

```swift
    func testIsNewerThanIngestedTrueWhenRemoteNewer() {
        XCTAssertTrue(UpdateChecker.isNewerThanIngested(remote: newer, ingested: older))
    }

    func testIsNewerThanIngestedFalseWhenEqual() {
        XCTAssertFalse(UpdateChecker.isNewerThanIngested(remote: newer, ingested: newer))
    }

    func testIsNewerThanIngestedFalseWhenOlder() {
        XCTAssertFalse(UpdateChecker.isNewerThanIngested(remote: older, ingested: newer))
    }

    func testIsNewerThanIngestedFalseWithNoBaseline() {
        XCTAssertFalse(UpdateChecker.isNewerThanIngested(remote: newer, ingested: nil))
    }

    func testIsNewerThanIngestedFalseOnMalformedRemote() {
        XCTAssertFalse(UpdateChecker.isNewerThanIngested(remote: "nope", ingested: older))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UpdateCheckerTests`
Expected: FAIL to compile — `type 'UpdateChecker' has no member 'isNewerThanIngested'`.

- [ ] **Step 3: Implement it**

In `Sources/QuickStudy/UpdateChecker.swift`, add inside the `enum UpdateChecker`, just above `shouldPrompt`:

```swift
    /// True when Scryfall's bulk is strictly newer than our ingested baseline.
    /// Unlike `shouldPrompt`, this ignores the dismissed stamp: a newer bulk should
    /// always trigger a silent ingest so search stays current; the dismissed stamp
    /// only suppresses the user-facing dot/notification afterward.
    static func isNewerThanIngested(remote: String, ingested: String?) -> Bool {
        guard let remoteDate = parse(remote) else { return false }
        guard let ingestedDate = ingested.flatMap(parse) else { return false }
        return remoteDate > ingestedDate
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter UpdateCheckerTests`
Expected: PASS (existing + 5 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/UpdateChecker.swift Tests/SearchEngineTests/UpdateCheckerTests.swift
git commit -m "feat(update): isNewerThanIngested gate for silent ingest"
```

---

## Task 7: AppModel — silent ingest, pending-images state, image download, serialization

**Files:**
- Modify: `Sources/QuickStudy/AppModel.swift`

- [ ] **Step 1: Replace `updateAvailable` storage with `newCardsPendingImages` + a busy guard**

In `Sources/QuickStudy/AppModel.swift`, replace the published property (line ~25):

```swift
    /// True when Scryfall has card data newer than what we last ingested.
    @Published var updateAvailable: Bool = false
```
with:

```swift
    /// Number of brand-new cards ingested in the background whose images are not yet
    /// downloaded. Drives the menu-bar dot, dropdown item, and notification.
    @Published var newCardsPendingImages: Int = 0
    /// Back-compat alias for existing view bindings: true while images are pending.
    var updateAvailable: Bool { newCardsPendingImages > 0 }
    /// Set while a background silent ingest is running, so the cheap check doesn't
    /// launch a second fetcher and `startRefresh`/`startImageDownload` can defer.
    private var backgroundSyncing = false
```

- [ ] **Step 2: Rewrite `checkForUpdates` to trigger the silent ingest**

Replace the entire `checkForUpdates(force:)` method body (lines ~299–321) with:

```swift
    func checkForUpdates(force: Bool = false) {
        guard dbState == .ready else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        if !force, let last = defaults.object(forKey: UpdateKeys.lastCheck) as? Date,
           now.timeIntervalSince(last) < Self.checkThrottle { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let remote = await UpdateChecker.fetchLatestStamp() else { return }
            defaults.set(now, forKey: UpdateKeys.lastCheck)
            let ingested = (try? self.store?.meta("bulk_updated_at")) ?? nil
            // Newer bulk → silently ingest card text so search stays current. The dot
            // is decided afterward from the actual new-card count.
            if UpdateChecker.isNewerThanIngested(remote: remote, ingested: ingested) {
                self.availableUpdateStamp = remote
                self.runSilentIngest(stamp: remote)
            }
        }
    }
```

- [ ] **Step 3: Add `runSilentIngest` and `startImageDownload`**

Insert these two methods right after `checkForUpdates` (before `dismissUpdate`):

```swift
    /// Runs `mtg-fetcher --no-images` in the background (no visible progress). On
    /// completion, if brand-new cards were added and `stamp` isn't dismissed, lights
    /// the dot/notification by setting `newCardsPendingImages`.
    private func runSilentIngest(stamp: String) {
        guard !backgroundSyncing else { return }
        // Don't run two fetchers against the DB at once; a manual refresh wins.
        if case .running = refreshState { return }
        backgroundSyncing = true
        Task { [weak self] in
            await self?.fetcher.run(mode: .ingestOnly) { event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event.phase {
                    case "done":
                        self.refreshDBState()
                        let dismissed = UserDefaults.standard.string(forKey: UpdateKeys.dismissedStamp)
                        let suppressed: Bool = {
                            guard let dismissed, let d = UpdateChecker.parse(dismissed),
                                  let r = UpdateChecker.parse(stamp) else { return false }
                            return d >= r
                        }()
                        if let added = event.newCards, added > 0, !suppressed {
                            self.newCardsPendingImages = added
                        }
                    case "error":
                        break // leave state unchanged; next check retries
                    case "exit":
                        self.backgroundSyncing = false
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Downloads images for cards already ingested (user-initiated from the dot/menu/
    /// Settings). Reuses the on-disk bulk JSON; only missing images are fetched.
    /// Shows progress via `refreshState`.
    func startImageDownload() {
        guard case .idle = refreshState, !backgroundSyncing else { return }
        refreshState = .running(phase: "images", done: 0, total: 0)
        Task { [weak self] in
            await self?.fetcher.run(mode: .imagesOnly) { event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event.phase {
                    case "done":
                        self.refreshState = .idle
                        self.refreshDBState()
                        self.newCardsPendingImages = 0
                    case "error":
                        self.refreshState = .error(event.message ?? "unknown error")
                    case "exit":
                        if case .running = self.refreshState { self.refreshState = .idle }
                    default:
                        self.refreshState = .running(phase: event.phase,
                                                     done: event.done ?? 0,
                                                     total: event.total ?? 0)
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Update `dismissUpdate` and `applyFetcherEvent` to the new state**

In `dismissUpdate()` (line ~324), replace `updateAvailable = false` with `newCardsPendingImages = 0`:

```swift
    func dismissUpdate() {
        if let stamp = availableUpdateStamp {
            UserDefaults.standard.set(stamp, forKey: UpdateKeys.dismissedStamp)
        }
        newCardsPendingImages = 0
    }
```

In `applyFetcherEvent` (the manual full-refresh path), replace the `done` case's `updateAvailable = false` with `newCardsPendingImages = 0`:

```swift
        case "done":
            refreshState = .idle
            refreshDBState()
            // Baseline (`bulk_updated_at`) is now current, so any pending prompt is stale.
            newCardsPendingImages = 0
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors. (`updateAvailable` is now computed; `$updateAvailable` Combine publishers in `QuickStudyApp` will be fixed in Task 8 — if the build fails there, that's expected and addressed next. To keep this task's build green, proceed to Task 8 before running the app, but `swift build` should still succeed because `@Published` removal of `updateAvailable` breaks `model.$updateAvailable`.)

> Note: `model.$updateAvailable` in `QuickStudyApp.swift` will no longer compile once `updateAvailable` stops being `@Published`. If `swift build` errors there, that is expected — complete Task 8, then build. Commit this task only after Task 8 builds clean, or temporarily keep the two commits together.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/AppModel.swift
git commit -m "feat(app): silent ingest + pending-images state + image download"
```

---

## Task 8: Wire UI — menu-bar dot, dropdown item, notification, Settings

`newCardsPendingImages` now drives the dot; accept actions call `startImageDownload`; the publisher must observe the new property.

**Files:**
- Modify: `Sources/QuickStudy/QuickStudyApp.swift`
- Modify: `Sources/QuickStudy/SettingsView.swift`

- [ ] **Step 1: Observe the new property and update copy in `QuickStudyApp`**

In `Sources/QuickStudy/QuickStudyApp.swift`, replace the Combine subscription (line ~82):

```swift
        model.$updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateUI() }
            .store(in: &cancellables)
```
with:

```swift
        model.$newCardsPendingImages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateUI() }
            .store(in: &cancellables)
```

In `refreshUpdateUI()`, update the card-update menu item title to reflect the count and the new action. Replace the `let cardUpdate = model.updateAvailable` line and the `updateMenuItem?.isHidden = !cardUpdate` line with:

```swift
        let cardUpdate = model.newCardsPendingImages > 0
        let appActionable = model.appUpdateState.isActionable

        if cardUpdate {
            let n = model.newCardsPendingImages
            updateMenuItem?.title = "Download Images (\(n) new card\(n == 1 ? "" : "s"))…"
        }
        updateMenuItem?.isHidden = !cardUpdate
```

(Delete the now-duplicate `let cardUpdate` / `let appActionable` lines that previously opened the method.)

- [ ] **Step 2: Point the menu item's action at image download**

The `updateMenuItem` currently targets `#selector(refreshNow)` (created at line ~52). Change its creation to a new selector:

```swift
        updateMenuItem = NSMenuItem(title: "Download Images…",
                                    action: #selector(downloadNewImages), keyEquivalent: "")
```

Add `#selector(downloadNewImages)` to the `for item in menu.items where ...` target-assignment loop (the `||` chain around line ~67), and add the method near `refreshNow`:

```swift
    @objc private func downloadNewImages() {
        model.startImageDownload()
    }
```

- [ ] **Step 3: Repoint the notification action**

The card-update notification's "Update Now" should now download images, not run a full refresh. In `Sources/QuickStudy/QuickStudyApp.swift`, change (line ~43):

```swift
        notifier.onUpdateAction = { [weak self] in self?.model.startRefresh(skipImages: false) }
```
to:

```swift
        notifier.onUpdateAction = { [weak self] in self?.model.startImageDownload() }
```

- [ ] **Step 4: Update notification copy**

In `Sources/QuickStudy/NotificationManager.swift`, the body is built in `post(stamp:)`. Since the message should mention the count, change `notifyIfNeeded(stamp:)` and `post(stamp:)` to take a count. Replace the `notifyIfNeeded(stamp:)` signature and its two `self.post(stamp:)` calls, plus `post`:

```swift
    func notifyIfNeeded(stamp: String, newCards: Int) {
        guard UserDefaults.standard.string(forKey: notifiedStampKey) != stamp else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { self.post(stamp: stamp, newCards: newCards) }
                }
            case .authorized, .provisional:
                self.post(stamp: stamp, newCards: newCards)
            default:
                break
            }
        }
    }

    private func post(stamp: String, newCards: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Quick Study"
        content.body = "Added \(newCards) new card\(newCards == 1 ? "" : "s"). Download images for offline use?"
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: "card-update-\(stamp)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(stamp, forKey: notifiedStampKey)
    }
```

Also change the "Update Now" action title to fit the new meaning (line ~31):

```swift
        let action = UNNotificationAction(identifier: Self.updateActionID,
                                          title: "Download Images",
                                          options: [.foreground])
```

- [ ] **Step 5: Pass the count from `refreshUpdateUI`**

In `Sources/QuickStudy/QuickStudyApp.swift`, update the notify call (line ~158):

```swift
        if cardUpdate, let stamp = model.availableUpdateStamp {
            notifier.notifyIfNeeded(stamp: stamp, newCards: model.newCardsPendingImages)
        }
```

- [ ] **Step 6: Update Settings copy/wiring**

In `Sources/QuickStudy/SettingsView.swift`, the `statusBadge` (line ~418) currently reads `model.updateAvailable` (still valid as a computed property) and shows "Update available". Update the text and add a download button. Replace the `statusBadge` body's `Text(...)` line:

```swift
                    Text("\(model.newCardsPendingImages) new card\(model.newCardsPendingImages == 1 ? "" : "s") added — images pending")
```

If the badge has an associated action button that calls `model.startRefresh(...)` for the card-update case, repoint it to `model.startImageDownload()`. (The existing "Refresh Database" / "Refresh Cards Only" buttons around lines 443–448 stay as-is — they are the manual full refresh, unrelated to the dot.)

- [ ] **Step 7: Build and run unit tests**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/QuickStudy/QuickStudyApp.swift Sources/QuickStudy/SettingsView.swift Sources/QuickStudy/NotificationManager.swift
git commit -m "feat(ui): dot/menu/notification reflect new-cards-pending-images"
```

---

## Task 9: End-to-end manual verification

**Files:** none (verification only).

- [ ] **Step 1: Build the app bundle**

Run: `./scripts/build-app.sh`
Expected: `./dist/QuickStudy.app` built and ad-hoc signed, no errors.

- [ ] **Step 2: Simulate a stale baseline to force a real ingest**

The silent ingest triggers when `bulk_updated_at` is older than Scryfall's. To exercise it, set the baseline back in time, then launch:

```bash
sqlite3 ~/Library/Application\ Support/QuickStudy/cards.sqlite \
  "UPDATE meta SET value='2000-01-01T00:00:00.000+00:00' WHERE key='bulk_updated_at';"
```
(Adjust the DB filename if different; check `~/Library/Application Support/QuickStudy/`.)

- [ ] **Step 3: Launch and observe**

Run: `open ./dist/QuickStudy.app` then watch the log:

```bash
tail -f ~/Library/Logs/QuickStudy/fetcher.log
```
Expected: within a moment of launch a `--no-images` run appears (`start ... skipImages=true`), ending in a `done` line with a `newCards` count. Because the baseline was reset but the cards already exist, `newCards` is likely `0` → **no dot appears** (this is the false-alarm fix working). The `bulk_updated_at` is now current.

- [ ] **Step 4: Verify the dot path with genuinely new cards**

To see the dot, delete a few cards so the ingest re-inserts them as "new", reset the baseline, and relaunch:

```bash
sqlite3 ~/Library/Application\ Support/QuickStudy/cards.sqlite \
  "DELETE FROM cards WHERE id IN (SELECT id FROM cards LIMIT 3); \
   UPDATE meta SET value='2000-01-01T00:00:00.000+00:00' WHERE key='bulk_updated_at';"
```
Relaunch the app. Expected: silent ingest reports `newCards` ≥ 1 → red dot appears in the menu bar, dropdown shows "Download Images (N new cards)…", and (if notifications are authorized) a banner "Added N new cards. Download images for offline use?".

- [ ] **Step 5: Verify accept downloads images**

Click "Download Images…" (menu) or the notification action. Expected: a `--images-only` run appears in the log ending `images complete`; Settings shows progress; the dot clears (`newCardsPendingImages = 0`). Re-opening shows no dot.

- [ ] **Step 6: Final commit (if any verification tweaks were needed)**

```bash
git add -A
git commit -m "chore: verification fixups for new-card detection"
```
(Skip if nothing changed.)

---

## Self-Review notes

- **Spec coverage:** cheap gate (Task 7 `checkForUpdates`), silent ingest (Tasks 3,5,7), new-card count (Tasks 1,3), dot only when real (Tasks 7,8), images-on-accept (Tasks 4,5,7,8), dismiss-doesn't-stop-ingest (Tasks 6,7), serialization (Task 7 `backgroundSyncing` + `refreshState` guards), copy changes (Task 8). All covered.
- **Type consistency:** `FetcherProcess.Mode` (.full/.ingestOnly/.imagesOnly), `newCards: Int?` on both event types, `newCardsPendingImages: Int`, `startImageDownload()`, `runSilentIngest(stamp:)`, `isNewerThanIngested(remote:ingested:)`, `cardCount()`, `notifyIfNeeded(stamp:newCards:)` — names match across tasks.
- **Known build ordering caveat:** removing `@Published` from `updateAvailable` breaks `model.$updateAvailable` in `QuickStudyApp.swift`; Task 8 Step 1 fixes it. Build clean only after Task 8. Noted in Task 7 Step 5.
