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
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, colors FROM cards")
            let decoder = JSONDecoder()
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? decoder.decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Mini(id: row["id"], name: row["name"], colors: colors)
            }
        }
    }

    /// Cards that appeared on Scryfall within the last `lookbackDays`, newest first.
    /// Driven by `date_added`, which holds the earliest date Scryfall reports for the
    /// card — its spoiler/preview date when present, otherwise its release date — so
    /// freshly-spoiled (but unreleased) cards surface ahead of already-released ones.
    public func recentlyAdded(lookbackDays: Int = 30, limit: Int = 200) throws -> [Card.Recent] {
        let lowerBound = Self.dateString(daysAgo: lookbackDays)
        // Upper-bound at today: unreleased future sets carry a future date and must
        // not masquerade as "recently added".
        let upperBound = Self.dateString(daysAgo: 0)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, colors, set_code, set_name, date_added
                FROM cards
                WHERE date_added IS NOT NULL AND date_added >= ? AND date_added <= ?
                ORDER BY date_added DESC
                LIMIT ?
                """, arguments: [lowerBound, upperBound, limit])
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

    // MARK: - Writes (fetcher only)

    public func upsert(_ cards: [Card]) throws {
        try dbQueue.write { db in
            for c in cards {
                let colorsJSON = (try? String(data: JSONEncoder().encode(c.colors), encoding: .utf8)) ?? "[]"
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
                        -- Keep the EARLIEST date Scryfall reports for this card: when a
                        -- future-dated set is later spoiled, `previewed_at` (computed into
                        -- excluded.date_added) is earlier than the frozen `released_at`, so
                        -- MIN moves it back to its spoiler date. A plain COALESCE froze the
                        -- first value and left spoiled cards stuck at a future release date.
                        date_added = min(COALESCE(date_added, excluded.date_added), excluded.date_added)
                """, arguments: [
                    c.id, c.name, c.name.lowercased(),
                    c.manaCost, c.typeLine, c.oracleText,
                    c.power, c.toughness,
                    colorsJSON,
                    c.imagePath,
                    c.scryfallURI,
                    c.setCode, c.setName, c.dateAdded,
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
