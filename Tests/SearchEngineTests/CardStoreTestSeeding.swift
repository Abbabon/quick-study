import Foundation
import GRDB
@testable import Shared

/// Test-only fixture writers. Production card data is written by the Rust `mtg-fetcher`
/// (engine/); the app never writes cards, so these live with the tests that seed with them.
extension CardStore {
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
                    INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, oracle_id, set_code, set_name, date_added, first_seen, rarity, cmc)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        rarity = excluded.rarity,
                        cmc = excluded.cmc,
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
                    c.rarity, c.cmc,
                ])
            }
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
}
