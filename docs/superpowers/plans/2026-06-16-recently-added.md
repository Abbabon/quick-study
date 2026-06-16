# Recently Added Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a collapsible "Recently Added" column to the Quick Study search panel that surfaces cards most recently ingested from Scryfall, with a "{n} New" pill, a sidebar toggle, a preview meta strip, and a Settings toggle.

**Architecture:** Capture each oracle card's `released_at` as a `date_added` column (stamped once via `COALESCE` upsert, never overwritten) plus `set_code`/`set_name`. `AppModel` loads the 30-day window into `recentlyAdded: [Card.Recent]`; `SearchPanel` renders a 222pt `RecentlyAddedColumn` left of the result list, width-animated like the Pinned row. Selecting a recent card clears the query (browse mode) and shows a meta strip above the preview.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB (SQLite), XCTest. macOS 14+.

---

## File Structure

- `Sources/Shared/Card.swift` — add `setCode`/`setName`/`dateAdded` to `Card` (defaulted, appended); add `Card.Recent` projection.
- `Sources/Shared/CardStore.swift` — migration `v2`; upsert new columns; `recentlyAdded(...)` read.
- `Sources/Fetcher/ScryfallClient.swift` — parse `released_at`/`set`/`set_name`; carry into `toCard()`.
- `Sources/QuickStudy/RelativeTime.swift` — new: relative-time string helper.
- `Sources/QuickStudy/AppModel.swift` — recent state + `selectRecent`.
- `Sources/QuickStudy/Views/RecentlyAddedColumn.swift` — new: header + list + row.
- `Sources/QuickStudy/Views/SearchPanel.swift` — toggle button, column placement, meta strip.
- `Sources/QuickStudy/SettingsView.swift` — Behavior toggle.
- `Tests/SearchEngineTests/CardStoreRecentTests.swift` — new.
- `Tests/SearchEngineTests/RelativeTimeTests.swift` — new.

---

## Task 1: Card model + `Card.Recent` projection

**Files:**
- Modify: `Sources/Shared/Card.swift`

- [ ] **Step 1: Add the new stored fields to `Card`** (appended after `scryfallURI`, defaulted so existing positional call sites keep compiling)

In `Sources/Shared/Card.swift`, add three properties after `public let scryfallURI: String`:

```swift
    public let setCode: String?
    public let setName: String?
    public let dateAdded: String?  // "YYYY-MM-DD" (Scryfall released_at), nil if unknown
```

Update the initializer signature to append these with defaults, and assign them:

```swift
    public init(
        id: String,
        name: String,
        manaCost: String?,
        typeLine: String?,
        oracleText: String?,
        power: String?,
        toughness: String?,
        colors: [String],
        imagePath: String?,
        scryfallURI: String,
        setCode: String? = nil,
        setName: String? = nil,
        dateAdded: String? = nil
    ) {
        self.id = id
        self.name = name
        self.manaCost = manaCost
        self.typeLine = typeLine
        self.oracleText = oracleText
        self.power = power
        self.toughness = toughness
        self.colors = colors
        self.imagePath = imagePath
        self.scryfallURI = scryfallURI
        self.setCode = setCode
        self.setName = setName
        self.dateAdded = dateAdded
    }
```

- [ ] **Step 2: Add the `Card.Recent` projection**

Inside `struct Card`, after the `Mini` struct, add:

```swift
    /// Projection for the Recently Added column: identity for the thumbnail tint,
    /// set label, and a parsed date for relative-time + the ≤7-day "new" flag.
    public struct Recent: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let identity: ColorIdentity
        public let setCode: String?
        public let setName: String?
        public let dateAdded: Date

        public init(id: String, name: String, colors: [String],
                    setCode: String?, setName: String?, dateAdded: Date) {
            self.id = id
            self.name = name
            self.identity = ColorIdentity(colors: colors)
            self.setCode = setCode
            self.setName = setName
            self.dateAdded = dateAdded
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors (existing `Card(...)` call sites still compile because new params are defaulted).

- [ ] **Step 4: Commit**

```bash
git add Sources/Shared/Card.swift
git commit -m "feat(shared): add set/date_added fields and Card.Recent projection"
```

---

## Task 2: CardStore migration, upsert, and `recentlyAdded` query (TDD)

**Files:**
- Modify: `Sources/Shared/CardStore.swift`
- Test: `Tests/SearchEngineTests/CardStoreRecentTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/CardStoreRecentTests.swift`:

```swift
import XCTest
import Shared

final class CardStoreRecentTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-recent-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    private func card(_ id: String, _ name: String, daysAgo: Int) -> Card {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Card(id: id, name: name, manaCost: nil, typeLine: nil, oracleText: nil,
                    power: nil, toughness: nil, colors: [], imagePath: nil, scryfallURI: "",
                    setCode: "TST", setName: "Test Set", dateAdded: f.string(from: date))
    }

    func testRecentlyAddedNewestFirstWithinWindow() throws {
        let store = try makeStore()
        try store.upsert([
            card("a", "Alpha", daysAgo: 1),
            card("b", "Bravo", daysAgo: 5),
            card("c", "Charlie", daysAgo: 40),   // outside 30-day window
        ])
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200)
        XCTAssertEqual(recent.map(\.id), ["a", "b"])
        XCTAssertEqual(recent.first?.setName, "Test Set")
    }

    func testRecentlyAddedRespectsLimit() throws {
        let store = try makeStore()
        try store.upsert((0..<10).map { card("id\($0)", "Card \($0)", daysAgo: $0) })
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.id), ["id0", "id1", "id2"])
    }

    func testUpsertDoesNotOverwriteExistingDateAdded() throws {
        let store = try makeStore()
        try store.upsert([card("a", "Alpha", daysAgo: 2)])
        // Re-upsert the same id with a much older date_added — should be ignored (COALESCE).
        try store.upsert([card("a", "Alpha Renamed", daysAgo: 100)])
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200)
        XCTAssertEqual(recent.map(\.id), ["a"])  // still within window → original date kept
        XCTAssertEqual(recent.first?.name, "Alpha Renamed")  // other fields do update
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CardStoreRecentTests`
Expected: FAIL — `recentlyAdded` is not a member of `CardStore` / migration columns missing.

- [ ] **Step 3: Add migration `v2`**

In `Sources/Shared/CardStore.swift`, inside `migrator`, after the `m.registerMigration("v1")` block and before `return m`, add:

```swift
        m.registerMigration("v2") { db in
            try db.alter(table: "cards") { t in
                t.add(column: "date_added", .text)
                t.add(column: "set_code", .text)
                t.add(column: "set_name", .text)
            }
        }
```

- [ ] **Step 4: Update `upsert` to write the new columns**

Replace the SQL in `upsert(_:)` with the version below (adds three columns to the INSERT, refreshes set fields on conflict, and `COALESCE`s `date_added` so it's stamped once):

```swift
                try db.execute(sql: """
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, set_code, set_name, date_added)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        name_lower = excluded.name_lower,
                        mana_cost = excluded.mana_cost,
                        type_line = excluded.type_line,
                        oracle_text = excluded.oracle_text,
                        power = excluded.power,
                        toughness = excluded.toughness,
                        colors = excluded.colors,
                        scryfall_uri = excluded.scryfall_uri,
                        set_code = excluded.set_code,
                        set_name = excluded.set_name,
                        date_added = COALESCE(date_added, excluded.date_added)
                """, arguments: [
                    c.id, c.name, c.name.lowercased(),
                    c.manaCost, c.typeLine, c.oracleText,
                    c.power, c.toughness,
                    colorsJSON,
                    c.imagePath,
                    c.scryfallURI,
                    c.setCode, c.setName, c.dateAdded,
                ])
```

- [ ] **Step 5: Add the `recentlyAdded` read**

In the `// MARK: - Reads` section of `CardStore.swift`, after `loadMinis()`, add:

```swift
    /// Cards ingested within the last `lookbackDays`, newest first. Driven by
    /// `date_added` (the card's Scryfall release date, stamped once on first insert).
    public func recentlyAdded(lookbackDays: Int = 30, limit: Int = 200) throws -> [Card.Recent] {
        let threshold = Self.dateString(daysAgo: lookbackDays)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, colors, set_code, set_name, date_added
                FROM cards
                WHERE date_added IS NOT NULL AND date_added >= ?
                ORDER BY date_added DESC
                LIMIT ?
                """, arguments: [threshold, limit])
            let decoder = JSONDecoder()
            return rows.compactMap { row in
                guard let added = Self.parseDate(row["date_added"]) else { return nil }
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Recent(id: row["id"], name: row["name"], colors: colors,
                                   setCode: row["set_code"], setName: row["set_name"],
                                   dateAdded: added)
            }
        }
    }
```

In the `// MARK: - Helpers` section, add a shared date formatter and the two helpers:

```swift
    /// UTC, day-granularity formatter matching the stored `date_added` ("YYYY-MM-DD").
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dateString(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return dayFormatter.string(from: date)
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return dayFormatter.date(from: raw)
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter CardStoreRecentTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/Shared/CardStore.swift Tests/SearchEngineTests/CardStoreRecentTests.swift
git commit -m "feat(store): v2 migration + date_added/set columns + recentlyAdded query"
```

---

## Task 3: Parse `released_at`/`set`/`set_name` in the fetcher

**Files:**
- Modify: `Sources/Fetcher/ScryfallClient.swift`

- [ ] **Step 1: Add the raw fields to `ScryfallCard`**

In `Sources/Fetcher/ScryfallClient.swift`, add to the `ScryfallCard` struct's stored properties (after `let layout: String?`):

```swift
    let released_at: String?
    let set: String?
    let set_name: String?
```

- [ ] **Step 2: Carry them into `toCard()`**

In `toCard()`, change the trailing `return Card(...)` so the last arguments become (a card with no `released_at` falls back to today so brand-new printings still surface):

```swift
        return Card(
            id: id,
            name: name,
            manaCost: manaCost,
            typeLine: typeLine,
            oracleText: (oracleText?.isEmpty == false) ? oracleText : nil,
            power: power,
            toughness: toughness,
            colors: colors,
            imagePath: nil,
            scryfallURI: scryfallPage,
            setCode: set?.uppercased(),
            setName: set_name,
            dateAdded: released_at ?? Self.todayString
        )
```

Add a `todayString` helper to `ScryfallCard` (near `imageDownloadURL`):

```swift
    static var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds clean. (Decoding ignores unknown keys, so the new optional fields decode safely from real bulk JSON.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Fetcher/ScryfallClient.swift
git commit -m "feat(fetcher): parse released_at and set into Card"
```

---

## Task 4: `RelativeTime` helper (TDD)

**Files:**
- Create: `Sources/QuickStudy/RelativeTime.swift`
- Test: `Tests/SearchEngineTests/RelativeTimeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/RelativeTimeTests.swift`:

```swift
import XCTest
@testable import QuickStudy

final class RelativeTimeTests: XCTestCase {
    private func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    func testBuckets() {
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 0)), "today")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 1)), "1 day ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 3)), "3 days ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 7)), "1 week ago")
        XCTAssertEqual(RelativeTime.string(for: date(daysAgo: 21)), "3 weeks ago")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RelativeTimeTests`
Expected: FAIL — `RelativeTime` not found.

- [ ] **Step 3: Implement the helper**

Create `Sources/QuickStudy/RelativeTime.swift`:

```swift
import Foundation

/// Day-granularity relative-time strings for the Recently Added column.
/// Buckets: today / 1 day ago / N days ago / 1 week ago / N weeks ago.
enum RelativeTime {
    static func string(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startOfNow = cal.startOfDay(for: now)
        let startOfThen = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startOfThen, to: startOfNow).day ?? 0
        switch days {
        case ..<1:
            return "today"
        case 1:
            return "1 day ago"
        case 2..<7:
            return "\(days) days ago"
        default:
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RelativeTimeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/RelativeTime.swift Tests/SearchEngineTests/RelativeTimeTests.swift
git commit -m "feat(app): RelativeTime helper for Recently Added"
```

---

## Task 5: AppModel recent state

**Files:**
- Modify: `Sources/QuickStudy/AppModel.swift`

- [ ] **Step 1: Add published state**

In `AppModel`, after `@Published var pinned: [Card.Mini] = []`, add:

```swift
    @Published var recentlyAdded: [Card.Recent] = []
    /// Session UI state for the Recently Added column (not persisted).
    @Published var recentlyAddedExpanded: Bool = true
    /// The recent card currently shown via the column, driving the preview meta strip.
    @Published var selectedRecent: Card.Recent?
```

- [ ] **Step 2: Add derived helpers and the constant**

After the `private final class CachedCard` line (or anywhere in the class body), add:

```swift
    /// Cards added within this many days get the accent "new" treatment.
    static let newWindowDays = 7

    /// Count of recently-added cards that landed within the "new" window.
    var newCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recentlyAdded.filter { $0.dateAdded >= cutoff }.count
    }

    func isNew(_ recent: Card.Recent) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.newWindowDays, to: Date()) ?? Date()
        return recent.dateAdded >= cutoff
    }

    /// Whether the column should appear at all: enabled in settings AND non-empty.
    var showsRecentColumn: Bool {
        UserDefaults.standard.object(forKey: "showRecentlyAdded") as? Bool ?? true
        ? !recentlyAdded.isEmpty
        : false
    }
```

- [ ] **Step 3: Load recents in `refreshDBState()`**

In `refreshDBState()`, inside the `dbState = .ready` branch, right after `engine.load(try store.loadMinis())`, add:

```swift
                recentlyAdded = (try? store.recentlyAdded()) ?? []
```

- [ ] **Step 4: Add `selectRecent` and clear `selectedRecent` appropriately**

Add this method near `select(_:)`:

```swift
    /// Opens a card from the Recently Added column: selects it, records it for the
    /// preview meta strip, and clears the query so the panel enters browse mode.
    func selectRecent(_ recent: Card.Recent) {
        query = ""
        results = []
        select(recent.id)
        selectedRecent = recent
    }
```

In `runSearch()`, at the top of the method, clear the recent context so a normal search drops the meta strip:

```swift
        selectedRecent = nil
```

In `deselect()`, also clear it:

```swift
        selectedRecent = nil
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/AppModel.swift
git commit -m "feat(app): AppModel state for Recently Added"
```

---

## Task 6: `RecentlyAddedColumn` view

**Files:**
- Create: `Sources/QuickStudy/Views/RecentlyAddedColumn.swift`

- [ ] **Step 1: Create the view**

Create `Sources/QuickStudy/Views/RecentlyAddedColumn.swift`:

```swift
import SwiftUI
import AppKit
import Shared

/// Collapsible left column listing the most recently ingested cards.
/// 222pt fixed width with a hairline trailing separator; body shows ~6 rows
/// and scrolls for the rest of the 30-day window.
struct RecentlyAddedColumn: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        VStack(alignment: .leading, spacing: 0) {
            header(scale: scale)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.pad(1)) {
                    ForEach(model.recentlyAdded) { recent in
                        RecentRow(
                            recent: recent,
                            isNew: model.isNew(recent),
                            selected: recent.id == model.selectedID
                        ) {
                            model.selectRecent(recent)
                        }
                    }
                }
                .padding(.horizontal, scale.pad(6))
                .padding(.top, scale.pad(2))
                .padding(.bottom, scale.pad(6))
            }
        }
        .frame(width: scale.size(222))
    }

    private func header(scale: UIScale) -> some View {
        HStack(spacing: scale.pad(6)) {
            Image(systemName: "clock")
                .font(scale.font(15))
                .foregroundStyle(.secondary)
            Text("Recently Added")
                .font(scale.font(13, weight: .semibold))
            if model.newCount > 0 {
                Text("\(model.newCount) New")
                    .font(scale.font(11, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, scale.pad(8))
                    .padding(.vertical, scale.pad(2))
                    .background(Capsule().fill(DS.selection))
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: scale.pad(10), leading: scale.pad(12),
                            bottom: scale.pad(6), trailing: scale.pad(8)))
    }
}

/// One card in the Recently Added list: thumbnail, name (+ ≤7-day accent dot),
/// and a "{Set} · {relative time}" secondary line.
private struct RecentRow: View {
    let recent: Card.Recent
    let isNew: Bool
    let selected: Bool
    let onTap: () -> Void
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @State private var hovering = false

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        HStack(spacing: scale.pad(10)) {
            Thumbnail(id: recent.id, identity: recent.identity)
                .frame(width: scale.size(30), height: scale.size(42))
            VStack(alignment: .leading, spacing: scale.pad(2)) {
                HStack(spacing: scale.pad(4)) {
                    Text(recent.name)
                        .font(scale.font(14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isNew {
                        Circle()
                            .fill(DS.accent)
                            .frame(width: scale.size(6), height: scale.size(6))
                    }
                }
                secondaryLine(scale: scale)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.pad(8))
        .padding(.vertical, scale.pad(4))
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(selected ? DS.selection : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(DS.Motion.selectScroll, value: hovering)
    }

    private func secondaryLine(scale: UIScale) -> some View {
        (
            Text(recent.setName ?? recent.setCode ?? "—")
                .foregroundStyle(.secondary)
            + Text(" · \(RelativeTime.string(for: recent.dateAdded))")
                .foregroundStyle(.tertiary)
        )
        .font(scale.font(11))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/Views/RecentlyAddedColumn.swift
git commit -m "feat(app): RecentlyAddedColumn view"
```

---

## Task 7: Wire the column, toggle, and meta strip into `SearchPanel`

**Files:**
- Modify: `Sources/QuickStudy/Views/SearchPanel.swift`

- [ ] **Step 1: Add reduced-motion environment and the expand binding helper**

Near the top of `SearchPanel`, after the existing `@AppStorage` lines, add:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true
```

- [ ] **Step 2: Add the sidebar toggle to the search-field row**

In `searchField`, insert the toggle button as the first child of the `HStack` (before the magnifier `Image`), but only when the column is available:

```swift
        return HStack(spacing: scale.pad(8)) {
            if model.showsRecentColumn {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.resize) {
                        model.recentlyAddedExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(scale.font(18))
                        .foregroundStyle(model.recentlyAddedExpanded ? DS.accent : Color.secondary)
                        .frame(width: scale.size(30), height: scale.size(30))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .help(model.recentlyAddedExpanded ? "Hide Recently Added" : "Show Recently Added")
            }
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
```

(Adjust leading padding: when the toggle is present it sits at the row's leading edge; the existing `scale.pad(18)` horizontal padding is acceptable and keeps the 14pt-ish inset. Leave as-is.)

- [ ] **Step 3: Render the column left of `content`**

In `body`, replace the `content` line in the outer `VStack` so the column sits beside it:

```swift
        return VStack(spacing: 0) {
            searchField
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                if model.showsRecentColumn && model.recentlyAddedExpanded {
                    RecentlyAddedColumn(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().opacity(0.5)
                }
                content
            }
            if model.dbState == .ready && !model.pinned.isEmpty {
                Divider().opacity(0.3)
                PinnedRow(model: model)
            }
        }
        .frame(minWidth: scale.size(860), minHeight: scale.size(520))
        .animation(reduceMotion ? nil : DS.Motion.resize, value: model.recentlyAddedExpanded)
        .animation(reduceMotion ? nil : DS.Motion.resize, value: model.showsRecentColumn)
        .tint(DS.accent)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
```

- [ ] **Step 4: Add the preview meta strip**

Change `cardPreview` to prepend the strip when a recent card is open. Replace the `cardPreview` computed property with:

```swift
    private var cardPreview: some View {
        VStack(spacing: 0) {
            if let recent = model.selectedRecent {
                metaStrip(recent)
                Divider().opacity(0.5)
            }
            CardPreview(
                card: model.selectedCard,
                isPinned: model.selectedCard.map { model.isPinned($0.id) } ?? false,
                onTogglePin: { model.togglePinSelected() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metaStrip(_ recent: Card.Recent) -> some View {
        let scale = UIScale(value: uiScaleValue)
        let code = recent.setCode.map { " (\($0))" } ?? ""
        let set = recent.setName ?? recent.setCode ?? "—"
        return HStack(spacing: scale.pad(8)) {
            if model.isNew(recent) {
                Text("New")
                    .font(scale.font(11, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, scale.pad(8))
                    .padding(.vertical, scale.pad(2))
                    .background(Capsule().fill(DS.selection))
            }
            Text("Added \(RelativeTime.string(for: recent.dateAdded)) · \(set)\(code)")
                .font(scale.font(11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.pad(16))
        .padding(.vertical, scale.pad(8))
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/Views/SearchPanel.swift
git commit -m "feat(app): wire Recently Added column, toggle, and meta strip into SearchPanel"
```

---

## Task 8: Settings toggle

**Files:**
- Modify: `Sources/QuickStudy/SettingsView.swift`

- [ ] **Step 1: Add the AppStorage and toggle**

Add to the `@AppStorage` block near the top of `SettingsView`:

```swift
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true
```

In the `Section("Behavior")`, after the "Clear search after:" picker, add:

```swift
                Toggle("Show recently added cards", isOn: $showRecentlyAdded)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/SettingsView.swift
git commit -m "feat(settings): add Show recently added cards toggle"
```

---

## Task 9: Full verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests pass (existing + `CardStoreRecentTests` + `RelativeTimeTests`).

- [ ] **Step 2: Build and run the app against the real DB**

Run:
```bash
MTG_FETCHER_PATH="$(swift build --show-bin-path)/mtg-fetcher" swift run QuickStudy
```

Manually verify (open the panel via the hotkey):
- If the DB predates this feature: column is empty/absent until a refresh stamps `date_added`. Trigger `Refresh Cards Only` from Settings; after it completes the column appears with the latest set's cards.
- Column shows at 222pt to the left of the result list with a hairline; header shows "Recently Added" and an "{n} New" pill when recent cards exist.
- The `sidebar.leading` toggle hides/shows the column with a ~0.2s width animation; accent when open, secondary when closed.
- Clicking a recent row clears the search and shows the card with the "Added … · Set (CODE)" meta strip (with a leading "New" badge when ≤7 days).
- Settings → Behavior → "Show recently added cards" off ⇒ column and toggle disappear entirely.

- [ ] **Step 3: Final commit if any manual fixes were needed** (otherwise skip)

---

## Self-Review notes

- **Spec coverage:** data layer (Tasks 1–3), state (Task 5), column/header/row (Task 6), toggle + width animation + meta strip + reduced motion (Task 7), settings (Task 8), tests (Tasks 2 & 4). Keyboard nav intentionally deferred per spec.
- **Type consistency:** `Card.Recent` fields (`id, name, identity, setCode, setName, dateAdded: Date`) used identically across CardStore, AppModel, and the views; `recentlyAdded(lookbackDays:limit:)`, `RelativeTime.string(for:)`, `model.isNew(_:)`, `model.newCount`, `model.showsRecentColumn`, `model.selectRecent(_:)` referenced consistently.
- **No placeholders:** every step shows concrete code/commands.
