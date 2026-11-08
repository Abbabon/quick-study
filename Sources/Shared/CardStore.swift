import Foundation
import GRDB

/// SQLite-backed store for the app (reads + user card lists). The Rust fetcher (`engine/`) is the
/// only writer of card data; it shares this schema via GRDB's `grdb_migrations` ledger.
public final class CardStore {
    public let dbQueue: DatabaseQueue

    public init(url: URL = Paths.databaseURL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "cards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("name_lower", .text).notNull().indexed()
                t.column("mana_cost", .text)
                t.column("type_line", .text)
                t.column("oracle_text", .text)
                t.column("power", .text)
                t.column("toughness", .text)
                t.column("colors", .text).notNull().defaults(to: "[]")
                t.column("image_path", .text)
                t.column("scryfall_uri", .text).notNull()
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "cards") { t in
                t.add(column: "date_added", .text)
                t.add(column: "set_code", .text)
                t.add(column: "set_name", .text)
            }
        }
        m.registerMigration("v3") { db in
            // `first_seen` = when the card first appeared in our DB, the honest
            // "is this new" signal. Scryfall's `date_added` (preview/release date) is
            // unreliable: products like Commander precons get bulk-added with only a
            // future `released_at` and no per-card preview date, so date-based detection
            // hid genuinely-new spoilers behind their release date.
            try db.alter(table: "cards") { t in
                t.add(column: "first_seen", .text).indexed()
            }
            // Backfill: the earlier of (date_added, today). Future-dated unreleased
            // spoilers clamp to today so they surface now; already-released cards keep
            // their real date so genuinely-old cards stay out of the recent window.
            // Cards with no date stay NULL (we can't attribute a first-seen retroactively).
            let today = Self.dateString(daysAgo: 0)
            try db.execute(sql: """
                UPDATE cards SET first_seen =
                    CASE WHEN date_added IS NULL THEN NULL
                         WHEN date_added > ? THEN ?
                         ELSE date_added END
                """, arguments: [today, today])
        }
        m.registerMigration("v4") { db in
            // Distinct artworks for the game modes, from Scryfall's `unique_artwork`
            // bulk set (one row per illustration_id). Populated only by the fetcher.
            try db.create(table: "artworks") { t in
                t.column("illustration_id", .text).primaryKey()
                t.column("card_id", .text).notNull()
                t.column("card_name", .text).notNull()
                t.column("card_name_lower", .text).notNull()
                t.column("artist", .text).notNull().indexed()  // indexed: distractor / DISTINCT sampling
                t.column("artist_lower", .text).notNull()
                t.column("art_crop_url", .text).notNull()
                t.column("colors", .text).notNull().defaults(to: "[]")
                t.column("set_code", .text)
            }
        }
        m.registerMigration("v5") { db in
            // User-curated card collections. `card_lists` is the named list; membership
            // lives in `card_list_items` (many-to-many, ordered by `position`). Populated
            // and edited only by the app — the fetcher never touches these.
            try db.create(table: "card_lists") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("name_lower", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "card_list_items") { t in
                t.column("list_id", .text).notNull().indexed()
                t.column("card_id", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("added_at", .text).notNull()
                t.primaryKey(["list_id", "card_id"])
            }
        }
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
        m.registerMigration("v9") { db in
            // `rarity` = the representative printing's rarity (drives the at-a-glance badge);
            // `cmc` = Scryfall mana value (drives the `mv:`/`cmc:` search filter). Both ride
            // the normal oracle_cards ingest — no --printings run needed. NULL until the next
            // ingest backfills them, so `r:`/`mv:` filters simply skip un-refreshed rows.
            try db.alter(table: "cards") { t in
                t.add(column: "rarity", .text)
                t.add(column: "cmc", .double)
            }
        }
        return m
    }

    // MARK: - Reads

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0
        }
    }

    public func loadMinis() throws -> [Card.Mini] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, colors, set_code, set_name, rarity FROM cards")
            let decoder = JSONDecoder()
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Mini(id: row["id"], name: row["name"], colors: colors,
                                 setCode: row["set_code"], setName: row["set_name"],
                                 rarity: row["rarity"])
            }
        }
    }

    /// Per-card metadata for the in-memory inline search filters, keyed by card `id`.
    /// Pulls the filterable card columns in one pass and folds in the set of rarities the
    /// card has ever been printed at (from `printings`, joined on `oracle_id`), so that
    /// `r:common` means "ever printed common". The card's own representative `rarity` is
    /// unioned in as a fallback, so basic rarity filtering works even before a `--printings`
    /// refresh has populated the printings table. All rarities are lowercased.
    public func loadFilterFields() throws -> [String: Card.FilterFields] {
        try dbQueue.read { db in
            // oracle_id -> set of printing rarities
            var raritiesByOracle: [String: Set<String>] = [:]
            let pRows = try Row.fetchAll(db, sql: """
                SELECT oracle_id, rarity FROM printings
                WHERE oracle_id IS NOT NULL AND rarity IS NOT NULL
                """)
            for row in pRows {
                guard let oid: String = row["oracle_id"], let r: String = row["rarity"] else { continue }
                raritiesByOracle[oid, default: []].insert(r.lowercased())
            }

            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, oracle_id, colors, type_line, oracle_text, cmc, rarity FROM cards
                """)
            var result: [String: Card.FilterFields] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let id: String = row["id"]
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                var rarities: Set<String> = []
                if let oid: String = row["oracle_id"], let printed = raritiesByOracle[oid] {
                    rarities.formUnion(printed)
                }
                if let rep: String = row["rarity"] { rarities.insert(rep.lowercased()) }
                let type: String? = row["type_line"]
                let oracle: String? = row["oracle_text"]
                result[id] = Card.FilterFields(
                    colors: colors,
                    typeLineLower: type?.lowercased(),
                    oracleTextLower: oracle?.lowercased(),
                    cmc: row["cmc"],
                    rarities: rarities)
            }
            return result
        }
    }

    /// Cards that first appeared in our DB within the last `lookbackDays`, newest first.
    /// Driven by `first_seen` (set to ingest time on insert), not Scryfall's dates, so a
    /// freshly-ingested card surfaces regardless of its release date — including spoiled
    /// cards whose set is still unreleased. `first_seen` is never in the future, so no
    /// upper bound is needed.
    public func recentlyAdded(lookbackDays: Int = 30, limit: Int = 200) throws -> [Card.Recent] {
        let lowerBound = Self.dateString(daysAgo: lookbackDays)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, colors, set_code, set_name, first_seen
                FROM cards
                WHERE first_seen IS NOT NULL AND first_seen >= ?
                ORDER BY first_seen DESC, name ASC
                LIMIT ?
                """, arguments: [lowerBound, limit])
            let decoder = JSONDecoder()
            return rows.compactMap { row in
                guard let seen = Self.parseDate(row["first_seen"]) else { return nil }
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Recent(id: row["id"], name: row["name"], colors: colors,
                                   setCode: row["set_code"], setName: row["set_name"],
                                   firstSeen: seen)
            }
        }
    }

    public func card(id: String) throws -> Card? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return Self.cardFromRow(row)
        }
    }

    public func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func artworkCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artworks") ?? 0
        }
    }

    /// Loads all artworks into memory for the game engine (~48k tiny rows, like `loadMinis`).
    public func loadArtworks() throws -> [Artwork] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT illustration_id, card_id, card_name, artist, art_crop_url, colors, set_code
                FROM artworks
                """)
            let decoder = JSONDecoder()
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Artwork(
                    illustrationID: row["illustration_id"],
                    cardID: row["card_id"],
                    cardName: row["card_name"],
                    artist: row["artist"],
                    artCropURL: row["art_crop_url"],
                    colors: colors,
                    setCode: row["set_code"]
                )
            }
        }
    }

    public func distinctArtists() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT artist FROM artworks ORDER BY artist")
        }
    }

    // MARK: - Lists

    /// Creates an empty list and returns it. `name` is stored as-is; `name_lower` backs
    /// case-insensitive lookups/sorting later if needed.
    public func createList(name: String) throws -> CardList {
        let id = UUID().uuidString
        let now = Self.timestamp()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO card_lists (id, name, name_lower, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, name, name.lowercased(), now, now])
        }
        return CardList(id: id, name: name, createdAt: now, updatedAt: now, itemCount: 0)
    }

    /// All lists, oldest first, each with its current card count.
    public func loadLists() throws -> [CardList] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.name, l.created_at, l.updated_at,
                       (SELECT COUNT(*) FROM card_list_items i WHERE i.list_id = l.id) AS item_count
                FROM card_lists l
                ORDER BY l.created_at ASC, l.name ASC
                """)
            return rows.map { row in
                CardList(id: row["id"], name: row["name"],
                         createdAt: row["created_at"], updatedAt: row["updated_at"],
                         itemCount: row["item_count"] ?? 0)
            }
        }
    }

    public func renameList(id: String, name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE card_lists SET name = ?, name_lower = ?, updated_at = ? WHERE id = ?
                """, arguments: [name, name.lowercased(), Self.timestamp(), id])
        }
    }

    /// Deletes a list and all its membership rows in one transaction (cascade-in-code,
    /// since `PRAGMA foreign_keys` is left off globally).
    public func deleteList(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM card_list_items WHERE list_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM card_lists WHERE id = ?", arguments: [id])
        }
    }

    /// Appends a card to a list. No-op if the card is already a member (the composite
    /// primary key makes the insert idempotent). Bumps the list's `updated_at`.
    public func addCard(cardID: String, toList listID: String) throws {
        try dbQueue.write { db in
            let nextPosition = try Int.fetchOne(db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM card_list_items WHERE list_id = ?",
                arguments: [listID]) ?? 0
            try db.execute(sql: """
                INSERT INTO card_list_items (list_id, card_id, position, added_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(list_id, card_id) DO NOTHING
                """, arguments: [listID, cardID, nextPosition, Self.timestamp()])
            try db.execute(sql: "UPDATE card_lists SET updated_at = ? WHERE id = ?",
                           arguments: [Self.timestamp(), listID])
        }
    }

    public func removeCard(cardID: String, fromList listID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM card_list_items WHERE list_id = ? AND card_id = ?",
                           arguments: [listID, cardID])
            try db.execute(sql: "UPDATE card_lists SET updated_at = ? WHERE id = ?",
                           arguments: [Self.timestamp(), listID])
        }
    }

    /// Cards in a list as `Card.Mini`s, ordered by `position`. Joins `cards` so identity /
    /// set metadata is populated exactly like `loadMinis()`. Items whose card is missing
    /// from `cards` (e.g. removed in a later bulk) are skipped.
    public func listItems(listID: String) throws -> [Card.Mini] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.name, c.colors, c.set_code, c.set_name
                FROM card_list_items i
                JOIN cards c ON c.id = i.card_id
                WHERE i.list_id = ?
                ORDER BY i.position ASC
                """, arguments: [listID])
            let decoder = JSONDecoder()
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Mini(id: row["id"], name: row["name"], colors: colors,
                                 setCode: row["set_code"], setName: row["set_name"])
            }
        }
    }

    /// Rewrites positions to match `orderedCardIDs` (e.g. after a drag-reorder). IDs not
    /// already in the list are ignored.
    public func setListOrder(listID: String, orderedCardIDs: [String]) throws {
        try dbQueue.write { db in
            for (index, cardID) in orderedCardIDs.enumerated() {
                try db.execute(sql: """
                    UPDATE card_list_items SET position = ? WHERE list_id = ? AND card_id = ?
                    """, arguments: [index, listID, cardID])
            }
            try db.execute(sql: "UPDATE card_lists SET updated_at = ? WHERE id = ?",
                           arguments: [Self.timestamp(), listID])
        }
    }

    // MARK: - Sets & Printings (written by the Rust fetcher; app reads)

    public func setsCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sets") ?? 0 }
    }

    public func printingsCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM printings") ?? 0 }
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

    // MARK: - Helpers

    /// UTC second-granularity timestamp for list created/updated stamps.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func timestamp(_ date: Date = Date()) -> String {
        timestampFormatter.string(from: date)
    }

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

    private static func cardFromRow(_ row: Row) -> Card {
        let colorsRaw: String = row["colors"] ?? "[]"
        let colors = (try? JSONDecoder().decode([String].self, from: Data(colorsRaw.utf8))) ?? []
        return Card(
            id: row["id"],
            name: row["name"],
            manaCost: row["mana_cost"],
            typeLine: row["type_line"],
            oracleText: row["oracle_text"],
            power: row["power"],
            toughness: row["toughness"],
            colors: colors,
            imagePath: row["image_path"],
            scryfallURI: row["scryfall_uri"],
            oracleID: row["oracle_id"],
            rarity: row["rarity"],
            cmc: row["cmc"]
        )
    }
}
