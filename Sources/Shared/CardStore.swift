import Foundation
import GRDB

/// SQLite-backed store for cards. Used by both the app (read) and the fetcher (write).
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
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, colors, set_code, set_name FROM cards")
            let decoder = JSONDecoder()
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Mini(id: row["id"], name: row["name"], colors: colors,
                                 setCode: row["set_code"], setName: row["set_name"])
            }
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

    // MARK: - Writes (fetcher only)

    public func upsert(_ cards: [Card]) throws {
        // Stamp brand-new rows with their first-seen date: the earlier of today (now,
        // when we're ingesting) and the card's own date. Future-dated spoilers clamp to
        // today so they read as "just appeared"; back-catalog cards keep their real date
        // so a one-off ingest of old data doesn't flood Recently Added.
        let today = Self.dateString(daysAgo: 0)
        try dbQueue.write { db in
            for c in cards {
                let colorsJSON = (try? String(data: JSONEncoder().encode(c.colors), encoding: .utf8)) ?? "[]"
                let firstSeen = (c.dateAdded.map { $0 < today ? $0 : today }) ?? today
                try db.execute(sql: """
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, oracle_id, set_code, set_name, date_added, first_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        oracle_id = excluded.oracle_id,
                        set_code = excluded.set_code,
                        set_name = excluded.set_name,
                        -- Keep the EARLIEST date Scryfall reports for this card: when a
                        -- future-dated set is later spoiled, `previewed_at` (computed into
                        -- excluded.date_added) is earlier than the frozen `released_at`, so
                        -- MIN moves it back to its spoiler date. A plain COALESCE froze the
                        -- first value and left spoiled cards stuck at a future release date.
                        date_added = min(COALESCE(date_added, excluded.date_added), excluded.date_added)
                        -- first_seen is intentionally NOT updated: it records when we first
                        -- saw the card and must never move once set.
                """, arguments: [
                    c.id, c.name, c.name.lowercased(),
                    c.manaCost, c.typeLine, c.oracleText,
                    c.power, c.toughness,
                    colorsJSON,
                    c.imagePath,
                    c.scryfallURI,
                    c.oracleID,
                    c.setCode, c.setName, c.dateAdded, firstSeen,
                ])
            }
        }
    }

    public func setImagePath(_ path: String, forID id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE cards SET image_path = ? WHERE id = ?", arguments: [path, id])
        }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    public func upsertArtworks(_ artworks: [Artwork]) throws {
        try dbQueue.write { db in
            for a in artworks {
                let colorsJSON = (try? String(data: JSONEncoder().encode(a.colors), encoding: .utf8)) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO artworks (illustration_id, card_id, card_name, card_name_lower, artist, artist_lower, art_crop_url, colors, set_code)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(illustration_id) DO UPDATE SET
                        card_id = excluded.card_id,
                        card_name = excluded.card_name,
                        card_name_lower = excluded.card_name_lower,
                        artist = excluded.artist,
                        artist_lower = excluded.artist_lower,
                        art_crop_url = excluded.art_crop_url,
                        colors = excluded.colors,
                        set_code = excluded.set_code
                """, arguments: [
                    a.illustrationID, a.cardID, a.cardName, a.cardName.lowercased(),
                    a.artist, a.artist.lowercased(), a.artCropURL, colorsJSON, a.setCode,
                ])
            }
        }
    }

    public func cardsMissingImages() throws -> [(id: String, scryfallURI: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, scryfall_uri FROM cards WHERE image_path IS NULL")
            return rows.map { ($0["id"], $0["scryfall_uri"]) }
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
            oracleID: row["oracle_id"]
        )
    }
}
