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
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM cards")
            return rows.map { Card.Mini(id: $0["id"], name: $0["name"]) }
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
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        name_lower = excluded.name_lower,
                        mana_cost = excluded.mana_cost,
                        type_line = excluded.type_line,
                        oracle_text = excluded.oracle_text,
                        power = excluded.power,
                        toughness = excluded.toughness,
                        colors = excluded.colors,
                        scryfall_uri = excluded.scryfall_uri
                """, arguments: [
                    c.id, c.name, c.name.lowercased(),
                    c.manaCost, c.typeLine, c.oracleText,
                    c.power, c.toughness,
                    colorsJSON,
                    c.imagePath,
                    c.scryfallURI,
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
