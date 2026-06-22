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
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, set_code, set_name, date_added, first_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

    // MARK: - Helpers

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
            scryfallURI: row["scryfall_uri"]
        )
    }
}
