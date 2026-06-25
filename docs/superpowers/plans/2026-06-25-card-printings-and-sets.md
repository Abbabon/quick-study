# Card Printings & Set Markings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store every card's printings and a set catalog, show a Scryfall-style Printings list in the card preview (click a set → search it), and fix set-name search so it returns all cards printed in the named set.

**Architecture:** Add a `sets` catalog and a `printings` table (one row per card+set, from Scryfall's `default_cards` bulk), joined to existing `cards` by a new `oracle_id` column. The fetcher gains a `--printings` flag that pulls both. `SearchEngine` gains an in-memory set index so a set query expands to all member cards. The preview lists printings with MTGO/Arena display toggles.

**Tech Stack:** Swift 5.9+, GRDB (SQLite), SwiftUI/AppKit (macOS 14+), XCTest. Two executables (`QuickStudy` app + `mtg-fetcher` CLI) share `Sources/Shared`.

## Global Constraints

- Minimum target: macOS 14.
- The app never parses bulk JSON in-process; only the fetcher (`mtg-fetcher`) writes the DB.
- Subprocess protocol: every fetcher progress tick is one NDJSON line on stdout, decoded by `FetcherProcess`. New `phase` strings need no schema change but must be documented in `Fetcher/ProgressEmitter.swift`, `QuickStudy/FetcherProcess.swift`, and `CLAUDE.md` in lockstep.
- Existing DB migrations run through **v5**; new migrations are **v6, v7, v8**.
- Commits use the repo identity (Abbabon <netanel.amit@gmail.com>); end commit messages with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer. Work stays on branch `feat/card-printings-and-sets`.
- `swift test` must pass after every task that touches testable code.

---

## File structure

- `Package.swift` — add `Fetcher` to the test target so `ScryfallClient` parsing is testable.
- `Sources/Shared/Card.swift` — add `Card.oracleID`; add `Card.Printing` and `Card.SetGroup`.
- `Sources/Shared/SetInfo.swift` *(new)* — the set-catalog model.
- `Sources/Shared/CardStore.swift` — migrations v6/v7/v8; `oracle_id` in upsert/read; `upsertSets`, `upsertPrintings`, `printings(forOracleID:)`, `loadSetIndex`, counts.
- `Sources/Fetcher/ScryfallClient.swift` — `oracle_id` on the oracle parse; `fetchSets()`; `parsePrintings(at:)`.
- `Sources/Fetcher/Fetcher.swift` — `--printings` flag, `sets` + `printings` phases.
- `Sources/Fetcher/ProgressEmitter.swift` — phase-list doc comment.
- `Sources/QuickStudy/FetcherProcess.swift` — `Mode` additions/changes.
- `Sources/QuickStudy/SearchEngine.swift` — set index + reworked scoring.
- `Sources/QuickStudy/AppModel.swift` — load set index; `selectedPrintings`; `searchSet`; refresh mode mapping.
- `Sources/QuickStudy/Views/CardPreview.swift` — Printings section + MTGO/Arena filtering.
- `Sources/QuickStudy/Views/SearchPanel.swift` — pass printings + `onSetTap` to `CardPreview`.
- `Sources/QuickStudy/SettingsView.swift` — two Search toggles.
- `Tests/SearchEngineTests/CardPrintingTests.swift` *(new)*, `CardStorePrintingsTests.swift` *(new)*, `ScryfallPrintingParseTests.swift` *(new)*; edits to `SearchEngineTests.swift`.
- `docs/architecture.md`, `CLAUDE.md` — documentation.

---

## Task 1: Shared models — `oracleID`, `Card.Printing`, `Card.SetGroup`, `SetInfo`

**Files:**
- Modify: `Sources/Shared/Card.swift`
- Create: `Sources/Shared/SetInfo.swift`
- Test: `Tests/SearchEngineTests/CardPrintingTests.swift`

**Interfaces:**
- Produces:
  - `Card.oracleID: String?` and `Card.init(..., oracleID: String? = nil)`.
  - `Card.Printing` with `printingID, oracleID, setCode, setName, collectorNumber, releasedAt, rarity, digital, games` plus computed `id`, `year`, `isMTGOOnly`, `isArenaOnly`.
  - `Card.SetGroup` with `code, name, memberIDs`.
  - `SetInfo` with `code, name, releasedAt, setType, cardCount, iconSVGURI`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/CardPrintingTests.swift`:

```swift
import XCTest
import Shared

final class CardPrintingTests: XCTestCase {
    private func printing(digital: Bool, games: [String], released: String? = "2019-06-14") -> Card.Printing {
        Card.Printing(printingID: "p", oracleID: "o", setCode: "TST", setName: "Test",
                      collectorNumber: "1", releasedAt: released, rarity: "rare",
                      digital: digital, games: games)
    }

    func testMTGOOnlyDetection() {
        let p = printing(digital: true, games: ["mtgo"])
        XCTAssertTrue(p.isMTGOOnly)
        XCTAssertFalse(p.isArenaOnly)
    }

    func testArenaOnlyDetection() {
        let p = printing(digital: true, games: ["arena"])
        XCTAssertTrue(p.isArenaOnly)
        XCTAssertFalse(p.isMTGOOnly)
    }

    func testPaperPrintingIsNeitherDigitalOnly() {
        let p = printing(digital: false, games: ["paper", "mtgo"])
        XCTAssertFalse(p.isMTGOOnly)
        XCTAssertFalse(p.isArenaOnly)
    }

    func testYearFromReleaseDate() {
        XCTAssertEqual(printing(digital: false, games: ["paper"]).year, "2019")
        XCTAssertNil(printing(digital: false, games: ["paper"], released: nil).year)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardPrintingTests`
Expected: FAIL — `Card.Printing` is not defined (compile error).

- [ ] **Step 3: Add the models**

In `Sources/Shared/Card.swift`, add `oracleID` to the `Card` struct. Add the stored property after `setName` and before `dateAdded`:

```swift
    public let setCode: String?
    public let setName: String?
    /// Stable Scryfall oracle identity (`oracle_id`). The join key to the `printings`
    /// table. Distinct from `id`, which is one representative printing's UUID. NULL on
    /// rows ingested before this column existed (backfilled by the next ingest).
    public let oracleID: String?
    public let dateAdded: String?  // "YYYY-MM-DD" (Scryfall released_at), nil if unknown
```

Add the `oracleID` parameter to `Card.init`, after `setName` and before `dateAdded`, and assign it:

```swift
        setCode: String? = nil,
        setName: String? = nil,
        oracleID: String? = nil,
        dateAdded: String? = nil
    ) {
```

```swift
        self.setCode = setCode
        self.setName = setName
        self.oracleID = oracleID
        self.dateAdded = dateAdded
```

Then add these two nested types inside the `Card` struct (after the existing `Recent` struct, before the closing brace):

```swift
    /// One printing of a card (a card+set row from Scryfall's `default_cards`). Drives the
    /// preview Printings list. `oracleID` links it back to the oracle `Card`. `digital` +
    /// `games` distinguish MTGO/Arena-only printings for the display toggles. `printing_id`
    /// is reserved for a future "download this specific version" flow.
    public struct Printing: Sendable, Equatable, Identifiable {
        public let printingID: String
        public let oracleID: String?
        public let setCode: String
        public let setName: String
        public let collectorNumber: String?
        public let releasedAt: String?   // "YYYY-MM-DD"
        public let rarity: String?
        public let digital: Bool
        public let games: [String]       // e.g. ["paper","mtgo"], ["arena"]

        public var id: String { printingID }
        /// Four-digit year of `releasedAt`, if present.
        public var year: String? { releasedAt.map { String($0.prefix(4)) } }
        /// A digital printing that exists only on Magic Online.
        public var isMTGOOnly: Bool { digital && games == ["mtgo"] }
        /// A digital printing that exists only on Arena.
        public var isArenaOnly: Bool { digital && games == ["arena"] }

        public init(printingID: String, oracleID: String?, setCode: String, setName: String,
                    collectorNumber: String?, releasedAt: String?, rarity: String?,
                    digital: Bool, games: [String]) {
            self.printingID = printingID
            self.oracleID = oracleID
            self.setCode = setCode
            self.setName = setName
            self.collectorNumber = collectorNumber
            self.releasedAt = releasedAt
            self.rarity = rarity
            self.digital = digital
            self.games = games
        }
    }

    /// A set and the IDs of the cards printed in it. Built by `CardStore.loadSetIndex()`
    /// and consumed by `SearchEngine` so a set query expands to all its member cards.
    public struct SetGroup: Sendable, Equatable {
        public let code: String
        public let name: String
        public let memberIDs: [String]

        public init(code: String, name: String, memberIDs: [String]) {
            self.code = code
            self.name = name
            self.memberIDs = memberIDs
        }
    }
```

Create `Sources/Shared/SetInfo.swift`:

```swift
import Foundation

/// A Magic set ("set markings") from Scryfall's `/sets` endpoint. `iconSVGURI` is stored
/// for a future set-symbol rendering pass; today the UI shows set codes as text.
public struct SetInfo: Sendable, Equatable, Identifiable {
    public let code: String          // uppercase, primary key
    public let name: String
    public let releasedAt: String?   // "YYYY-MM-DD"
    public let setType: String?
    public let cardCount: Int?
    public let iconSVGURI: String?

    public var id: String { code }

    public init(code: String, name: String, releasedAt: String?, setType: String?,
                cardCount: Int?, iconSVGURI: String?) {
        self.code = code
        self.name = name
        self.releasedAt = releasedAt
        self.setType = setType
        self.cardCount = cardCount
        self.iconSVGURI = iconSVGURI
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardPrintingTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/Card.swift Sources/Shared/SetInfo.swift Tests/SearchEngineTests/CardPrintingTests.swift
git commit -m "feat(shared): add oracleID, Card.Printing, Card.SetGroup, SetInfo

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Migrations v6/v7/v8 + `oracle_id` in upsert & read

**Files:**
- Modify: `Sources/Shared/CardStore.swift` (migrator ~line 82-101; `upsert` ~line 205; `cardFromRow` ~line 442)
- Test: `Tests/SearchEngineTests/CardStorePrintingsTests.swift` (created here, extended in Task 3)

**Interfaces:**
- Consumes: `Card.oracleID` (Task 1).
- Produces: `cards.oracle_id` column persisted/read; `sets` and `printings` tables exist.

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/CardStorePrintingsTests.swift`:

```swift
import XCTest
import Shared

final class CardStorePrintingsTests: XCTestCase {
    func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-printings-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    func testOracleIDRoundTrips() throws {
        let store = try makeStore()
        let card = Card(id: "c1", name: "Lightning Bolt", manaCost: "{R}", typeLine: "Instant",
                        oracleText: nil, power: nil, toughness: nil, colors: ["R"],
                        imagePath: nil, scryfallURI: "", setCode: "LEA", setName: "Limited Edition Alpha",
                        oracleID: "oracle-bolt", dateAdded: "1993-08-05")
        try store.upsert([card])
        XCTAssertEqual(try store.card(id: "c1")?.oracleID, "oracle-bolt")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardStorePrintingsTests`
Expected: FAIL — `card(id:)` returns a `Card` whose `oracleID` is `nil` (the upsert/read don't carry it yet). Assertion fails.

- [ ] **Step 3: Add migrations and wire `oracle_id`**

In `Sources/Shared/CardStore.swift`, in the `migrator` computed property, insert these three migrations after the `m.registerMigration("v5")` block and before `return m`:

```swift
        m.registerMigration("v6") { db in
            // `oracle_id` = the stable Scryfall oracle identity, the join key from `cards`
            // to `printings`. Backfilled by the next ingest (oracle_cards carries it);
            // NULL until then, so set search is simply empty before the first --printings run.
            try db.alter(table: "cards") { t in
                t.add(column: "oracle_id", .text).indexed()
            }
        }
        m.registerMigration("v7") { db in
            // Set catalog ("set markings"). `icon_svg_uri` is stored for future symbol
            // rendering; the UI shows set codes as text for now. Populated by the fetcher.
            try db.create(table: "sets") { t in
                t.column("code", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("released_at", .text)
                t.column("set_type", .text)
                t.column("card_count", .integer)
                t.column("icon_svg_uri", .text)
            }
        }
        m.registerMigration("v8") { db in
            // One row per printing (card+set), from Scryfall's default_cards bulk. Linked
            // to `cards` by `oracle_id`. `digital`/`games` drive the MTGO/Arena display
            // toggles. `printing_id` is reserved for a future per-version image download.
            try db.create(table: "printings") { t in
                t.column("printing_id", .text).primaryKey()
                t.column("oracle_id", .text).indexed()
                t.column("set_code", .text).notNull()
                t.column("set_name", .text).notNull()
                t.column("collector_number", .text)
                t.column("released_at", .text)
                t.column("rarity", .text)
                t.column("digital", .integer).notNull().defaults(to: 0)
                t.column("games", .text).notNull().defaults(to: "[]")
            }
        }
```

In `upsert(_:)`, add `oracle_id` to the INSERT. Change the column list and VALUES line (add `oracle_id` after `scryfall_uri`, add one `?`):

```swift
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, oracle_id, set_code, set_name, date_added, first_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
```

In the same statement's `ON CONFLICT(id) DO UPDATE SET`, add an `oracle_id` line (after `scryfall_uri = excluded.scryfall_uri,`):

```swift
                        scryfall_uri = excluded.scryfall_uri,
                        oracle_id = excluded.oracle_id,
                        set_code = excluded.set_code,
```

In that statement's `arguments:` array, add `c.oracleID` after `c.scryfallURI,`:

```swift
                    c.scryfallURI,
                    c.oracleID,
                    c.setCode, c.setName, c.dateAdded, firstSeen,
```

In `cardFromRow(_:)`, add `oracleID` to the `Card(...)` constructor (after `scryfallURI`):

```swift
            imagePath: row["image_path"],
            scryfallURI: row["scryfall_uri"],
            oracleID: row["oracle_id"]
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardStorePrintingsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/CardStore.swift Tests/SearchEngineTests/CardStorePrintingsTests.swift
git commit -m "feat(store): migrations for oracle_id, sets, printings tables

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: CardStore — `upsertSets`, `upsertPrintings`, `printings(forOracleID:)`, `loadSetIndex`

**Files:**
- Modify: `Sources/Shared/CardStore.swift` (add a `// MARK: - Sets & Printings` section before `// MARK: - Helpers`)
- Test: `Tests/SearchEngineTests/CardStorePrintingsTests.swift` (extend)

**Interfaces:**
- Consumes: `Card.Printing`, `Card.SetGroup`, `SetInfo` (Task 1); `cards.oracle_id` (Task 2).
- Produces:
  - `func upsertSets(_ sets: [SetInfo]) throws`
  - `func upsertPrintings(_ printings: [Card.Printing]) throws`
  - `func printings(forOracleID: String) throws -> [Card.Printing]`
  - `func loadSetIndex() throws -> [Card.SetGroup]`
  - `func setsCount() throws -> Int`, `func printingsCount() throws -> Int`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SearchEngineTests/CardStorePrintingsTests.swift`:

```swift
    func testPrintingsRoundTripAndSetIndex() throws {
        let store = try makeStore()
        // Two cards sharing nothing but both present so the set-index join resolves.
        try store.upsert([
            Card(id: "c1", name: "Lightning Bolt", manaCost: nil, typeLine: nil, oracleText: nil,
                 power: nil, toughness: nil, colors: ["R"], imagePath: nil, scryfallURI: "",
                 setCode: "LEA", setName: "Alpha", oracleID: "oracle-bolt", dateAdded: nil),
            Card(id: "c2", name: "Counterspell", manaCost: nil, typeLine: nil, oracleText: nil,
                 power: nil, toughness: nil, colors: ["U"], imagePath: nil, scryfallURI: "",
                 setCode: "LEA", setName: "Alpha", oracleID: "oracle-cs", dateAdded: nil),
        ])
        try store.upsertSets([
            SetInfo(code: "LEA", name: "Limited Edition Alpha", releasedAt: "1993-08-05",
                    setType: "core", cardCount: 295, iconSVGURI: "https://x/lea.svg"),
            SetInfo(code: "M21", name: "Core Set 2021", releasedAt: "2020-07-03",
                    setType: "core", cardCount: 397, iconSVGURI: nil),
        ])
        try store.upsertPrintings([
            Card.Printing(printingID: "p1", oracleID: "oracle-bolt", setCode: "LEA", setName: "Limited Edition Alpha",
                          collectorNumber: "161", releasedAt: "1993-08-05", rarity: "common",
                          digital: false, games: ["paper"]),
            Card.Printing(printingID: "p2", oracleID: "oracle-bolt", setCode: "M21", setName: "Core Set 2021",
                          collectorNumber: "148", releasedAt: "2020-07-03", rarity: "uncommon",
                          digital: false, games: ["paper", "mtgo"]),
            Card.Printing(printingID: "p3", oracleID: "oracle-cs", setCode: "LEA", setName: "Limited Edition Alpha",
                          collectorNumber: "54", releasedAt: "1993-08-05", rarity: "uncommon",
                          digital: false, games: ["paper"]),
        ])

        XCTAssertEqual(try store.setsCount(), 2)
        XCTAssertEqual(try store.printingsCount(), 3)

        // Bolt has two printings, newest first.
        let boltPrints = try store.printings(forOracleID: "oracle-bolt")
        XCTAssertEqual(boltPrints.map(\.setCode), ["M21", "LEA"])

        // The set index groups LEA's two member cards.
        let index = try store.loadSetIndex()
        let lea = index.first { $0.code == "LEA" }
        XCTAssertNotNil(lea)
        XCTAssertEqual(Set(lea!.memberIDs), Set(["c1", "c2"]))
        let m21 = index.first { $0.code == "M21" }
        XCTAssertEqual(m21?.memberIDs, ["c1"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardStorePrintingsTests/testPrintingsRoundTripAndSetIndex`
Expected: FAIL — `upsertSets`/`upsertPrintings`/etc. are not defined (compile error).

- [ ] **Step 3: Implement the methods**

In `Sources/Shared/CardStore.swift`, add this section immediately before `// MARK: - Helpers`:

```swift
    // MARK: - Sets & Printings (fetcher writes; app reads)

    public func setsCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sets") ?? 0 }
    }

    public func printingsCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM printings") ?? 0 }
    }

    public func upsertSets(_ sets: [SetInfo]) throws {
        try dbQueue.write { db in
            for s in sets {
                try db.execute(sql: """
                    INSERT INTO sets (code, name, released_at, set_type, card_count, icon_svg_uri)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(code) DO UPDATE SET
                        name = excluded.name,
                        released_at = excluded.released_at,
                        set_type = excluded.set_type,
                        card_count = excluded.card_count,
                        icon_svg_uri = excluded.icon_svg_uri
                """, arguments: [s.code, s.name, s.releasedAt, s.setType, s.cardCount, s.iconSVGURI])
            }
        }
    }

    public func upsertPrintings(_ printings: [Card.Printing]) throws {
        try dbQueue.write { db in
            for p in printings {
                let gamesJSON = (try? String(data: JSONEncoder().encode(p.games), encoding: .utf8)) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO printings (printing_id, oracle_id, set_code, set_name, collector_number, released_at, rarity, digital, games)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(printing_id) DO UPDATE SET
                        oracle_id = excluded.oracle_id,
                        set_code = excluded.set_code,
                        set_name = excluded.set_name,
                        collector_number = excluded.collector_number,
                        released_at = excluded.released_at,
                        rarity = excluded.rarity,
                        digital = excluded.digital,
                        games = excluded.games
                """, arguments: [
                    p.printingID, p.oracleID, p.setCode, p.setName, p.collectorNumber,
                    p.releasedAt, p.rarity, p.digital ? 1 : 0, gamesJSON,
                ])
            }
        }
    }

    /// All printings of a card, newest first. `digital`/`games` are decoded so the UI can
    /// filter MTGO/Arena printings.
    public func printings(forOracleID oracleID: String) throws -> [Card.Printing] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT printing_id, oracle_id, set_code, set_name, collector_number, released_at, rarity, digital, games
                FROM printings WHERE oracle_id = ?
                ORDER BY released_at DESC, set_code ASC
                """, arguments: [oracleID])
            let decoder = JSONDecoder()
            return rows.map { row in
                let gamesRaw: String = row["games"] ?? "[]"
                let games = (try? decoder.decode([String].self, from: Data(gamesRaw.utf8))) ?? []
                return Card.Printing(
                    printingID: row["printing_id"], oracleID: row["oracle_id"],
                    setCode: row["set_code"], setName: row["set_name"],
                    collectorNumber: row["collector_number"], releasedAt: row["released_at"],
                    rarity: row["rarity"], digital: (row["digital"] ?? 0) != 0, games: games)
            }
        }
    }

    /// Inverted index: each set with the IDs of cards printed in it. Joins `printings` to
    /// `cards` by `oracle_id`, so only cards present in `cards` (the search corpus) appear.
    /// Used by `SearchEngine` to expand a set query to all member cards.
    public func loadSetIndex() throws -> [Card.SetGroup] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.set_code AS code, p.set_name AS name, c.id AS card_id
                FROM printings p JOIN cards c ON c.oracle_id = p.oracle_id
                """)
            var order: [String] = []
            var names: [String: String] = [:]
            var members: [String: [String]] = [:]
            var seen: [String: Set<String>] = [:]
            for row in rows {
                let code: String = row["code"]
                let cardID: String = row["card_id"]
                if members[code] == nil {
                    order.append(code)
                    members[code] = []
                    seen[code] = []
                    names[code] = row["name"]
                }
                if seen[code]?.contains(cardID) == false {
                    members[code]?.append(cardID)
                    seen[code]?.insert(cardID)
                }
            }
            return order.map { Card.SetGroup(code: $0, name: names[$0] ?? $0, memberIDs: members[$0] ?? []) }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardStorePrintingsTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/CardStore.swift Tests/SearchEngineTests/CardStorePrintingsTests.swift
git commit -m "feat(store): upsert/read for sets & printings, plus set index

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Scryfall parsing — oracle_id, `fetchSets()`, `parsePrintings(at:)`

**Files:**
- Modify: `Package.swift` (add `Fetcher` to the test target's dependencies)
- Modify: `Sources/Fetcher/ScryfallClient.swift`
- Test: `Tests/SearchEngineTests/ScryfallPrintingParseTests.swift`

**Interfaces:**
- Consumes: `Card.Printing`, `SetInfo` (Task 1).
- Produces:
  - `ScryfallClient.parsePrintings(at: URL) throws -> [Card.Printing]`
  - `ScryfallClient.fetchSets() async throws -> [SetInfo]`
  - `ScryfallCard` now decodes `oracle_id`; `toCard()` sets `Card.oracleID`.

Note: `parsePrintings` is unit-tested with a local fixture (offline). `fetchSets` hits the network and is verified manually in Task 5. The fetcher's module name is its **target name `Fetcher`** (not the product name `mtg-fetcher`).

- [ ] **Step 0: Make the Fetcher target testable**

In `Package.swift`, add `"Fetcher"` to the `SearchEngineTests` test target's `dependencies` so its `ScryfallClient` can be imported:

```swift
        .testTarget(
            name: "SearchEngineTests",
            dependencies: ["QuickStudy", "Shared", "Fetcher"],
            path: "Tests/SearchEngineTests"
        ),
```

> NOTE: SwiftPM supports unit-testing an executable target this way (the `@main` in `Fetcher.swift` is handled by the test build). If linking fails with a duplicate-`main` error, the fallback is to move the pure parsing types (`ScryfallPrinting`, `parsePrintings`) into `Sources/Shared` and import `Shared` instead — they depend only on `Shared`/`Foundation`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/ScryfallPrintingParseTests.swift`:

```swift
import XCTest
@testable import Fetcher
import Shared
```

```swift
final class ScryfallPrintingParseTests: XCTestCase {
    /// Minimal default_cards-shaped fixture: one English paper printing, one MTGO-only
    /// digital printing, one Japanese row (skipped), one token layout (skipped), one row
    /// missing oracle_id (skipped).
    private let fixture = """
    [
      {"id":"p1","oracle_id":"o1","set":"m21","set_name":"Core Set 2021","collector_number":"148",
       "released_at":"2020-07-03","rarity":"uncommon","digital":false,"games":["paper","mtgo"],"lang":"en","layout":"normal"},
      {"id":"p2","oracle_id":"o1","set":"pmtg1","set_name":"Magic Online Promos","collector_number":"1",
       "released_at":"2019-01-01","rarity":"rare","digital":true,"games":["mtgo"],"lang":"en","layout":"normal"},
      {"id":"p3","oracle_id":"o1","set":"m21","set_name":"Core Set 2021","collector_number":"148",
       "released_at":"2020-07-03","rarity":"uncommon","digital":false,"games":["paper"],"lang":"ja","layout":"normal"},
      {"id":"p4","oracle_id":"o2","set":"tm21","set_name":"Core 2021 Tokens","collector_number":"1",
       "released_at":"2020-07-03","rarity":"common","digital":false,"games":["paper"],"lang":"en","layout":"token"},
      {"id":"p5","set":"m21","set_name":"Core Set 2021","collector_number":"X",
       "released_at":"2020-07-03","rarity":"common","digital":false,"games":["paper"],"lang":"en","layout":"normal"}
    ]
    """

    private func writeFixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prints-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParsePrintingsFiltersAndMaps() throws {
        let client = ScryfallClient()
        let prints = try client.parsePrintings(at: writeFixture())
        // p1 (en paper) and p2 (en mtgo) kept; p3 (ja), p4 (token), p5 (no oracle_id) dropped.
        XCTAssertEqual(prints.map(\.printingID), ["p1", "p2"])
        XCTAssertEqual(prints[0].setCode, "M21")              // uppercased
        XCTAssertEqual(prints[0].games, ["paper", "mtgo"])
        XCTAssertFalse(prints[0].isMTGOOnly)
        XCTAssertTrue(prints[1].isMTGOOnly)                   // p2 digital + ["mtgo"]
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScryfallPrintingParseTests`
Expected: FAIL — `parsePrintings` is not defined (compile error).

- [ ] **Step 3: Implement parsing**

In `Sources/Fetcher/ScryfallClient.swift`, add `oracle_id` to the private `ScryfallCard` struct's properties (next to `set`/`set_name`):

```swift
    let set: String?
    let set_name: String?
    let oracle_id: String?
    let preview: Preview?
```

In `ScryfallCard.toCard()`, pass it into the returned `Card` (after `setName:`):

```swift
            setCode: set?.uppercased(),
            setName: set_name,
            oracleID: oracle_id,
```

Add the printing JSON shape and parser. Place the struct next to the other private Scryfall shapes (e.g. after `ScryfallArtwork`), and the public `parsePrintings`/`fetchSets` inside the existing `ScryfallClient` class or an extension. Add at the end of the file:

```swift
// MARK: - Scryfall raw JSON shape (default_cards printing)

/// Minimal projection of a Scryfall card object as it appears in the `default_cards`
/// bulk file — one row per printing (card+set).
private struct ScryfallPrinting: Decodable {
    let id: String
    let oracle_id: String?
    let set: String
    let set_name: String
    let collector_number: String?
    let released_at: String?
    let rarity: String?
    let digital: Bool?
    let games: [String]?
    let lang: String?
    let layout: String?

    func toPrinting() -> Card.Printing? {
        // Skip the same junk layouts as the card ingest.
        if let l = layout, ["token", "double_faced_token", "art_series", "emblem"].contains(l) {
            return nil
        }
        // English only — default_cards still carries some non-English rows; filtering keeps
        // one printing per set instead of one per language.
        if let lang, lang != "en" { return nil }
        // No oracle_id ⇒ can't link to a card (rare split/reversible rows); skip.
        guard let oracle_id else { return nil }
        return Card.Printing(
            printingID: id, oracleID: oracle_id,
            setCode: set.uppercased(), setName: set_name,
            collectorNumber: collector_number, releasedAt: released_at, rarity: rarity,
            digital: digital ?? false, games: games ?? [])
    }
}

// MARK: - Scryfall raw JSON shape (/sets)

private struct ScryfallSet: Decodable {
    let code: String
    let name: String
    let released_at: String?
    let set_type: String?
    let card_count: Int?
    let icon_svg_uri: String?
}

private struct ScryfallSetList: Decodable { let data: [ScryfallSet] }

public extension ScryfallClient {
    /// Decode the `default_cards` bulk JSON into `Card.Printing` records, filtered to English
    /// non-token printings with an oracle_id. Whole-file decode like `parseBulk`; the fetcher
    /// is a short-lived process so transient memory for the ~150 MB blob is acceptable.
    func parsePrintings(at url: URL) throws -> [Card.Printing] {
        let data = try Data(contentsOf: url)
        let raws = try JSONDecoder().decode([ScryfallPrinting].self, from: data)
        return raws.compactMap { $0.toPrinting() }
    }

    /// Fetches the full set catalog from `https://api.scryfall.com/sets`.
    func fetchSets() async throws -> [SetInfo] {
        var request = URLRequest(url: URL(string: "https://api.scryfall.com/sets")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuickStudy/1.0 (+https://github.com/Abbabon/quick-study)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let list = try JSONDecoder().decode(ScryfallSetList.self, from: data)
        return list.data.map {
            SetInfo(code: $0.code.uppercased(), name: $0.name, releasedAt: $0.released_at,
                    setType: $0.set_type, cardCount: $0.card_count, iconSVGURI: $0.icon_svg_uri)
        }
    }
}
```

> NOTE: `session` is a `private let` on `ScryfallClient`; the new methods live in a same-file extension, which can access `private` members, so no visibility change is needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScryfallPrintingParseTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/Fetcher/ScryfallClient.swift Tests/SearchEngineTests/ScryfallPrintingParseTests.swift
git commit -m "feat(fetcher): parse default_cards printings & /sets, carry oracle_id

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Fetcher wiring — `--printings` flag, `sets` + `printings` phases

**Files:**
- Modify: `Sources/Fetcher/Fetcher.swift`
- Modify: `Sources/Fetcher/ProgressEmitter.swift` (doc comment)
- Modify: `Sources/QuickStudy/FetcherProcess.swift` (`Mode`)

**Interfaces:**
- Consumes: `ScryfallClient.fetchSets`, `parsePrintings` (Task 4); `CardStore.upsertSets`, `upsertPrintings` (Task 3).
- Produces: `mtg-fetcher --printings` runs `sets`+`printings` phases; `FetcherProcess.Mode.ingestPrintings`; `.full` now passes `--printings`.

No unit test (network + 150 MB download); verified manually in Step 4.

- [ ] **Step 1: Add the `--printings` flag and phases**

In `Sources/Fetcher/Fetcher.swift`, read the flag near the other arg parses:

```swift
        let downloadArt = args.contains("--download-art")
        let printings = args.contains("--printings")
```

After the oracle ingest block — specifically after this existing line:

```swift
            let newCards = max(0, try store.count() - countBefore)
```

insert the sets + printings pass (runs for both `--printings` with and without `--no-images`, because it precedes the `if skipImages` early return):

```swift
            // Sets catalog + per-card printings (manual refresh only; gated by --printings).
            if printings {
                emitter.emit(phase: "sets", message: "fetching set catalog")
                let sets = try await client.fetchSets()
                try store.upsertSets(sets)
                emitter.emit(phase: "sets", done: sets.count, total: sets.count)

                let defaultBulkURL = Paths.supportDir.appendingPathComponent("bulk-default.json", isDirectory: false)
                emitter.emit(phase: "printings", message: "fetching default_cards bulk index")
                let pInfo = try await client.bulkInfo(type: "default_cards")
                // Re-download only when the file is missing or Scryfall's stamp moved.
                let storedStamp = try store.meta("printings_updated_at")
                if !FileManager.default.fileExists(atPath: defaultBulkURL.path) || storedStamp != pInfo.updated_at {
                    try await client.downloadBulkJSON(from: pInfo, to: defaultBulkURL)
                }
                emitter.emit(phase: "printings", message: "parsing printings")
                let prints = try client.parsePrintings(at: defaultBulkURL)
                emitter.emit(phase: "printings", done: 0, total: prints.count)
                var pDone = 0
                for batch in prints.chunked(into: 1000) {
                    try store.upsertPrintings(batch)
                    pDone += batch.count
                    emitter.emit(phase: "printings", done: pDone, total: prints.count)
                }
                try store.setMeta("printings_updated_at", pInfo.updated_at)
            }
```

- [ ] **Step 2: Document the new phases**

In `Sources/Fetcher/ProgressEmitter.swift`, update the `Event.phase` doc comment:

```swift
        public let phase: String        // "json" | "ingest" | "sets" | "printings" | "images" | "done" | "error"
```

In `Sources/QuickStudy/FetcherProcess.swift`, update the `Mode` enum and its `arguments`:

```swift
    enum Mode {
        case full           // json → ingest → sets → printings → images
        case ingestOnly     // json → ingest (no images, no printings) — silent background sync
        case ingestPrintings // json → ingest → sets → printings (no images) — manual text-only refresh
        case imagesOnly     // reuse bulk JSON → images only
        case ingestArtwork  // unique_artwork → artwork metadata (no images)
        case downloadAllArt // unique_artwork → metadata + all art_crops

        var arguments: [String] {
            switch self {
            case .full: return ["--printings"]
            case .ingestOnly: return ["--no-images"]
            case .ingestPrintings: return ["--no-images", "--printings"]
            case .imagesOnly: return ["--images-only"]
            case .ingestArtwork: return ["--artwork"]
            case .downloadAllArt: return ["--artwork", "--download-art"]
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual smoke test (network — needs ~150 MB download)**

Run:
```bash
swift run mtg-fetcher --no-images --printings
```
Watch stdout for `sets` then `printings` NDJSON lines ending in a `done` event. Then verify rows landed:
```bash
sqlite3 "$HOME/Library/Application Support/QuickStudy/cards.sqlite" \
  "SELECT (SELECT COUNT(*) FROM sets), (SELECT COUNT(*) FROM printings), (SELECT COUNT(*) FROM cards WHERE oracle_id IS NOT NULL);"
```
Expected: sets in the hundreds/low thousands, printings ~100k+, and a large oracle_id-populated card count.

> If you cannot run the network download in this environment, note it and defer this step to the human verifier; the unit-tested parse (Task 4) covers the mapping logic.

- [ ] **Step 5: Commit**

```bash
git add Sources/Fetcher/Fetcher.swift Sources/Fetcher/ProgressEmitter.swift Sources/QuickStudy/FetcherProcess.swift
git commit -m "feat(fetcher): --printings flag runs sets & printings phases

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: SearchEngine — set index + reworked scoring (fixes set-name search)

**Files:**
- Modify: `Sources/QuickStudy/SearchEngine.swift`
- Test: `Tests/SearchEngineTests/SearchEngineTests.swift`

**Interfaces:**
- Consumes: `Card.SetGroup` (Task 1).
- Produces:
  - `SearchEngine.init(minis:sets:)` and `load(_:sets:)` (both `sets` default `[]`).
  - `search(_:limit:)` returns name matches **plus** every card in a set whose code/name matches the query.

- [ ] **Step 1: Write the failing test**

In `Tests/SearchEngineTests/SearchEngineTests.swift`, add a `setGroups` corpus next to the existing `setCorpus` (after the `setCorpus` declaration):

```swift
    /// Set membership matching `setCorpus`, as `CardStore.loadSetIndex()` would produce it.
    private let setGroups: [Card.SetGroup] = [
        Card.SetGroup(code: "MSC", name: "Mishra's Set", memberIDs: ["s0", "s1"]),
        Card.SetGroup(code: "MH3", name: "Modern Horizons 3", memberIDs: ["s2"]),
        Card.SetGroup(code: "JTM", name: "Jace's Tome", memberIDs: ["s3"]),
        Card.SetGroup(code: "M21", name: "Core 2021", memberIDs: ["s4"]),
        Card.SetGroup(code: "ZZZ", name: "Promo Set", memberIDs: ["s5"]),
    ]
```

Add a new golden test in the `// MARK: - Set code / set name` section:

```swift
    func testSetNameReturnsAllMembers() {
        let engine = SearchEngine(minis: setCorpus, sets: setGroups)
        let names = engine.search("mishra").map(\.name)
        XCTAssertTrue(names.contains("Mox Sapphire"))
        XCTAssertTrue(names.contains("Black Lotus"))
    }
```

Update the four existing set tests to pass the index: change every occurrence of `SearchEngine(minis: setCorpus)` to `SearchEngine(minis: setCorpus, sets: setGroups)` (use a single replace-all over the file for that exact string).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SearchEngineTests`
Expected: FAIL — `init(minis:sets:)` doesn't exist (compile error), and/or set tests fail because set scoring still reads `Mini.setCode`.

- [ ] **Step 3: Rework the engine**

Replace the body of `Sources/QuickStudy/SearchEngine.swift` from the class declaration onward with:

```swift
public final class SearchEngine {
    public private(set) var minis: [Card.Mini] = []
    private var setGroups: [Card.SetGroup] = []
    private var minisByID: [String: Card.Mini] = [:]

    public init(minis: [Card.Mini] = [], sets: [Card.SetGroup] = []) {
        load(minis, sets: sets)
    }

    public func load(_ minis: [Card.Mini], sets: [Card.SetGroup] = []) {
        self.minis = minis
        self.setGroups = sets
        self.minisByID = Dictionary(minis.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Returns up to `limit` cards ranked best-first. A card scores by the best of its name
    /// match and any set (code/name) match that includes it.
    public func search(_ query: String, limit: Int = 20) -> [Card.Mini] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var bestByID: [String: Int] = [:]

        // Name matches.
        for m in minis {
            if let s = Self.score(query: q, name: m.nameLower) {
                if s > (bestByID[m.id] ?? Int.min) { bestByID[m.id] = s }
            }
        }

        // Set matches: a matching set contributes every member card, scored in a band below
        // high-confidence name matches. This is what makes "modern horizons" return the whole
        // set rather than the few cards whose representative printing happens to be that set.
        for g in setGroups {
            var base: Int? = Self.setCodeScoreBase(query: q, code: g.code.lowercased())
            if let s = Self.setNameScoreBase(query: q, setName: g.name.lowercased()) {
                base = max(base ?? Int.min, s)
            }
            guard let setBase = base else { continue }
            for id in g.memberIDs {
                guard let m = minisByID[id] else { continue }
                let cand = setBase + Self.lengthBonus(m.nameLower)
                if cand > (bestByID[id] ?? Int.min) { bestByID[id] = cand }
            }
        }

        let scored = bestByID.compactMap { (id, score) -> (Int, Card.Mini)? in
            guard let m = minisByID[id] else { return nil }
            return (score, m)
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
    }

    /// Pure name scoring. `nil` means no match.
    static func score(query q: String, name n: String) -> Int? {
        if n == q { return 1000 + lengthBonus(n) }       // exact
        if n.hasPrefix(q) { return 800 + lengthBonus(n) } // prefix
        if matchesTokenStart(query: q, name: n) { return 600 + lengthBonus(n) } // token-start
        if n.contains(q) { return 400 + lengthBonus(n) }  // substring
        if let spread = subsequenceSpread(query: q, name: n) { return 200 - spread } // subsequence
        return nil
    }

    /// Base score for an exact set-code match (the caller adds a per-member length bonus).
    /// Exact-only: a 3-letter code is a deliberate signal, ranked above weak name matches
    /// (substring/subsequence) but below high-confidence name matches.
    static func setCodeScoreBase(query q: String, code: String) -> Int? {
        q == code ? 500 : nil
    }

    /// Base score for a set-name match. Exact (450) or prefix/token-start (350). Substring
    /// and subsequence are intentionally skipped — set names share filler words that would
    /// otherwise flood results.
    static func setNameScoreBase(query q: String, setName n: String) -> Int? {
        if n == q { return 450 }
        if n.hasPrefix(q) || matchesTokenStart(query: q, name: n) { return 350 }
        return nil
    }

    static func lengthBonus(_ n: String) -> Int {
        // Shorter names rank a bit higher: bonus is 100 for length 1, decaying.
        max(0, 100 - n.count)
    }

    /// True if `q` (possibly multi-word) matches the start of consecutive tokens in `n`.
    /// Also covers single-word queries that start a non-first token (e.g. "bolt" → "Lightning Bolt").
    private static func matchesTokenStart(query q: String, name n: String) -> Bool {
        let tokens = n.split(separator: " ").map(String.init)
        if !q.contains(" ") {
            return tokens.contains { $0.hasPrefix(q) } && !(tokens.first?.hasPrefix(q) ?? true)
        }
        let qWords = q.split(separator: " ").map(String.init)
        if qWords.count > tokens.count { return false }
        outer: for start in 0...(tokens.count - qWords.count) {
            for (i, qw) in qWords.enumerated() {
                if !tokens[start + i].hasPrefix(qw) { continue outer }
            }
            return true
        }
        return false
    }

    /// Walks `q` through `n` as a subsequence. Returns the "spread" (distance from first to
    /// last matched char) if all chars matched; nil otherwise.
    private static func subsequenceSpread(query q: String, name n: String) -> Int? {
        let qChars = Array(q)
        let nChars = Array(n)
        var qi = 0
        var firstIdx = -1
        var lastIdx = -1
        for (i, c) in nChars.enumerated() {
            if qi < qChars.count && c == qChars[qi] {
                if firstIdx < 0 { firstIdx = i }
                lastIdx = i
                qi += 1
            }
        }
        return qi == qChars.count ? lastIdx - firstIdx : nil
    }
}
```

Keep the file's leading `import Foundation` / `import Shared` and the doc comment above the class (update the doc comment's scoring layers to mention the set index drives set matches). `lengthBonus` and `matchesTokenStart` change visibility as shown (`lengthBonus` becomes non-private `static` so the search loop can call it; that's fine within the file).

> NOTE: `Card.Mini.setCodeLower` / `setNameLower` are no longer read by the ranker (the set index supersedes them). Leave the fields on `Card.Mini` — other call sites construct `Mini` with them and they're harmless.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SearchEngineTests`
Expected: PASS (all existing name tests, the four updated set tests, and the new `testSetNameReturnsAllMembers`).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS (no regressions in other suites).

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/SearchEngine.swift Tests/SearchEngineTests/SearchEngineTests.swift
git commit -m "fix(search): set query returns all member cards via printings index

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: AppModel — load set index, selected printings, searchSet, refresh mode

**Files:**
- Modify: `Sources/QuickStudy/AppModel.swift`

**Interfaces:**
- Consumes: `CardStore.loadSetIndex`, `printings(forOracleID:)` (Task 3); `SearchEngine.load(_:sets:)` (Task 6); `FetcherProcess.Mode.ingestPrintings` (Task 5); `Card.Printing` (Task 1).
- Produces:
  - `AppModel.selectedPrintings: [Card.Printing]` (`@Published`).
  - `AppModel.searchSet(_ name: String)`.

No new unit test (UI/`@MainActor` glue); covered by build + Task 9 manual verification.

- [ ] **Step 1: Add the published printings property**

In `Sources/QuickStudy/AppModel.swift`, after `@Published var selectedCard: Card?` (line ~11):

```swift
    @Published var selectedCard: Card?
    /// Printings of the selected card, for the preview's Printings list. Loaded lazily on
    /// selection from `CardStore.printings(forOracleID:)`.
    @Published var selectedPrintings: [Card.Printing] = []
```

- [ ] **Step 2: Load the set index on DB refresh**

In `refreshDBState()`, change the minis load to also load the set index:

```swift
                engine.load(try store.loadMinis(), sets: (try? store.loadSetIndex()) ?? [])
```

- [ ] **Step 3: Load printings when a card is selected, clear when deselected**

Replace the `select(_:)` method body so both the cached and freshly-fetched paths populate `selectedPrintings`:

```swift
    func select(_ id: String) {
        selectedID = id
        if let cached = detailCache.object(forKey: id as NSString) {
            selectedCard = cached.card
            loadPrintings(for: cached.card)
            return
        }
        guard let store = store else { return }
        if let card = try? store.card(id: id) {
            selectedCard = card
            detailCache.setObject(CachedCard(card), forKey: id as NSString)
            loadPrintings(for: card)
        }
    }

    /// Loads the selected card's printings (empty if it has no `oracleID`, e.g. ingested
    /// before printings existed or before the first --printings refresh).
    private func loadPrintings(for card: Card) {
        guard let store = store, let oid = card.oracleID else { selectedPrintings = []; return }
        selectedPrintings = (try? store.printings(forOracleID: oid)) ?? []
    }
```

In `deselect()`, clear printings too:

```swift
    func deselect() {
        selectedID = nil
        selectedCard = nil
        selectedRecent = nil
        selectedPrintings = []
    }
```

In `runSearch()`, in the empty-query branch where `selectedCard` is cleared, also clear printings (inside the `if selectedRecent == nil {` block):

```swift
            if selectedRecent == nil {
                selectedID = nil
                selectedCard = nil
                selectedPrintings = []
            }
```

- [ ] **Step 4: Add `searchSet` and update the refresh mode mapping**

Add `searchSet` after `runSearch()`:

```swift
    /// Fills the search field with a set's name and runs the search, so clicking a printing
    /// jumps to "everything in that set". The set index makes the set-name query expand to
    /// all member cards.
    func searchSet(_ name: String) {
        query = name
        runSearch()
    }
```

In `startRefresh(skipImages:)`, map the text-only refresh to the printings-bearing mode (silent background ingest in `runSilentIngest` stays `.ingestOnly`, unchanged):

```swift
            await self?.fetcher.run(mode: skipImages ? .ingestPrintings : .full) { event in
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/AppModel.swift
git commit -m "feat(app): load set index, selected printings, searchSet

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: UI — Printings section, set-click search, MTGO/Arena toggles

**Files:**
- Modify: `Sources/QuickStudy/Views/CardPreview.swift`
- Modify: `Sources/QuickStudy/Views/SearchPanel.swift`
- Modify: `Sources/QuickStudy/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.selectedPrintings`, `searchSet` (Task 7); `Card.Printing.isMTGOOnly/isArenaOnly/year` (Task 1).
- Produces: a Printings list in the preview; two `@AppStorage` toggles `showMTGOPrintings` / `showArenaPrintings` (default `true`).

- [ ] **Step 1: Add printings inputs and filtering to CardPreview**

In `Sources/QuickStudy/Views/CardPreview.swift`, add inputs after `onAddToNewList` and the AppStorage toggles after the existing `@AppStorage`:

```swift
    var onAddToNewList: () -> Void = {}
    /// Printings of the previewed card (Scryfall-style list).
    var printings: [Card.Printing] = []
    /// Called with a set name when the user taps a printing — drives "search this set".
    var onSetTap: (String) -> Void = { _ in }
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @AppStorage("showMTGOPrintings") private var showMTGOPrintings: Bool = true
    @AppStorage("showArenaPrintings") private var showArenaPrintings: Bool = true
```

Add the filtered list and the section view. Add these methods inside `CardPreview` (e.g. after `cardImage`):

```swift
    /// Printings minus the digital platforms the user has hidden in Settings.
    private var visiblePrintings: [Card.Printing] {
        printings.filter { p in
            if p.isMTGOOnly && !showMTGOPrintings { return false }
            if p.isArenaOnly && !showArenaPrintings { return false }
            return true
        }
    }

    @ViewBuilder
    private func printingsSection(scale: UIScale) -> some View {
        VStack(alignment: .leading, spacing: scale.pad(4)) {
            Text("Printings (\(visiblePrintings.count))")
                .font(scale.font(11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visiblePrintings) { p in
                        Button { onSetTap(p.setName) } label: {
                            HStack(spacing: scale.pad(6)) {
                                Text(p.setName).font(scale.font(12)).lineLimit(1)
                                Text("(\(p.setCode))").font(scale.font(11)).foregroundStyle(.secondary)
                                Spacer(minLength: scale.pad(4))
                                if let y = p.year {
                                    Text(y).font(scale.font(11)).foregroundStyle(.tertiary)
                                }
                                if let r = p.rarity, !r.isEmpty {
                                    Text(r.capitalized).font(scale.font(10)).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, scale.pad(2))
                        }
                        .buttonStyle(.plain)
                        .help("Search \(p.setName)")
                    }
                }
            }
            .frame(maxHeight: scale.size(150))
        }
        .padding(.top, scale.pad(4))
    }
```

In `content(card:scale:)`, insert the section between the power/toughness line and the `Spacer()`:

```swift
                if let p = card.power, let t = card.toughness {
                    Text("\(p) / \(t)").font(scale.font(11)).foregroundStyle(.secondary)
                }
                if !visiblePrintings.isEmpty {
                    printingsSection(scale: scale)
                }
                Spacer()
```

- [ ] **Step 2: Pass printings + onSetTap from SearchPanel**

In `Sources/QuickStudy/Views/SearchPanel.swift`, in the `cardPreview` computed view, add the two new arguments to the `CardPreview(...)` initializer (after `onAddToNewList:`):

```swift
                onAddToNewList: {
                    if let id = model.selectedCard?.id {
                        model.addToNewList(id)
                        if !model.listsColumnVisible { model.toggleListsColumn() }
                    }
                },
                printings: model.selectedPrintings,
                onSetTap: { model.searchSet($0) }
            )
```

- [ ] **Step 3: Add the two Settings toggles**

In `Sources/QuickStudy/SettingsView.swift`, add two `@AppStorage` vars next to `showRecentlyAdded` (~line 205):

```swift
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("showMTGOPrintings") private var showMTGOPrintings: Bool = true
    @AppStorage("showArenaPrintings") private var showArenaPrintings: Bool = true
```

In `searchPane`, insert two rows after the "Show recently added cards" `SettingsRow` and before the "Clear search after" row (which keeps `last: true`):

```swift
                SettingsRow(symbol: "clock.arrow.circlepath", style: TileStyle(0x5B6BE0, 0x7A45B6),
                            label: "Show recently added cards") {
                    Toggle("", isOn: $showRecentlyAdded).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "o.circle.fill", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                            label: "Show MTGO printings") {
                    Toggle("", isOn: $showMTGOPrintings).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "a.circle.fill", style: TileStyle(0xFF9F0A, 0xE0457A),
                            label: "Show Arena printings") {
                    Toggle("", isOn: $showArenaPrintings).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "clock", style: TileStyle(0xFF9F0A, 0xFF7A00),
                            label: "Clear search after", last: true) {
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/Views/CardPreview.swift Sources/QuickStudy/Views/SearchPanel.swift Sources/QuickStudy/SettingsView.swift
git commit -m "feat(ui): printings list with set-click search and MTGO/Arena toggles

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Documentation + end-to-end verification

**Files:**
- Modify: `docs/architecture.md`
- Modify: `CLAUDE.md`

**Interfaces:** none (docs + manual verification).

- [ ] **Step 1: Update `docs/architecture.md`**

Add a section documenting:
- the `sets` table (set markings; `icon_svg_uri` stored for future symbols) and `printings` table (one row per card+set, linked by `oracle_id`);
- the `oracle_id` column on `cards` as the join key;
- the fetcher's `--printings` flag and the `sets` / `printings` phases (manual refresh only; silent background ingest stays oracle-only);
- `SearchEngine`'s set index (set query → all member cards);
- a **Future work** subsection, verbatim intent: "Show & download other versions of a card — the `printings` table keys every printing by `printing_id`; a future flow lists versions, resolves `printing_id` → image, and caches under a per-printing path (e.g. `images/printings/<printing_id>.jpg`); set symbols can later use the stored `sets.icon_svg_uri`."

- [ ] **Step 2: Update `CLAUDE.md`**

- In the "Subprocess protocol" subsection, add `sets` and `printings` to the documented phase list.
- In the "Database" subsection, add one line noting the `sets` and `printings` tables and the `oracle_id` join key.
- Note the `mtg-fetcher --printings` flag near the existing fetcher command docs.

- [ ] **Step 3: Full test suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Build and run the app to verify end-to-end**

```bash
./scripts/build-app.sh
open dist/QuickStudy.app
```
(Per repo note, `swift run QuickStudy` crashes at launch — always use the bundle.) In the app:
1. Refresh card data (full refresh) so the `--printings` pass runs (or run `swift run mtg-fetcher --no-images --printings` first).
2. Search a card name, open it → confirm a **Printings** list appears below the oracle text.
3. Click a printing's set → the search field fills with the set name and the results show **many** cards from that set (the bug fix).
4. Settings → Search → toggle "Show MTGO printings"/"Show Arena printings" off → confirm digital-only printings disappear from the list.

> If the environment can't run the GUI/network, note it and defer Steps 3–4 (manual GUI) to the human verifier.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md CLAUDE.md
git commit -m "docs: printings/sets tables, fetcher phases, future versions note

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (for the executor)

- **Migration numbering:** existing DB is at v5; this plan adds v6/v7/v8. Do not renumber.
- **Backward compatibility:** `Card.init` gains `oracleID` with a default, so existing call sites and tests keep compiling. `SearchEngine.init`/`load` gain `sets` with a default `[]`.
- **Pre-refresh behavior:** before a `--printings` refresh, `printings`/`sets` are empty and `cards.oracle_id` is NULL → the preview shows no Printings list and set search returns nothing. This is expected and graceful.
- **Type consistency:** `Card.Printing` is the single type for both ingest (`upsertPrintings`) and display (`printings(forOracleID:)`). `loadSetIndex` returns `[Card.SetGroup]`, consumed directly by `SearchEngine`.
