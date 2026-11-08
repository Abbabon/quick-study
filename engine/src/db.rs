//! SQLite store and migrations. The ledger keeps the `grdb_migrations` name GRDB used, so databases
//! created before the Swift side dropped GRDB are not migrated again. v1..v9 are what GRDB applied;
//! new schema changes are added here only.
use crate::{Result, lower, scryfall::{Artwork, Card, Printing, SetInfo}, today};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashSet;
use std::path::Path;

/// (identifier, statements). SQL text mirrors what GRDB generates, so `sqlite_master` is identical.
const MIGRATIONS: &[(&str, &[&str])] = &[
    ("v1", &[
        r#"CREATE TABLE "cards" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "name_lower" TEXT NOT NULL, "mana_cost" TEXT, "type_line" TEXT, "oracle_text" TEXT, "power" TEXT, "toughness" TEXT, "colors" TEXT NOT NULL DEFAULT '[]', "image_path" TEXT, "scryfall_uri" TEXT NOT NULL)"#,
        r#"CREATE INDEX "cards_on_name_lower" ON "cards"("name_lower")"#,
        r#"CREATE TABLE "meta" ("key" TEXT PRIMARY KEY, "value" TEXT NOT NULL)"#,
    ]),
    ("v2", &[
        r#"ALTER TABLE "cards" ADD COLUMN "date_added" TEXT"#,
        r#"ALTER TABLE "cards" ADD COLUMN "set_code" TEXT"#,
        r#"ALTER TABLE "cards" ADD COLUMN "set_name" TEXT"#,
    ]),
    ("v3", &[
        r#"ALTER TABLE "cards" ADD COLUMN "first_seen" TEXT"#,
        r#"CREATE INDEX "cards_on_first_seen" ON "cards"("first_seen")"#,
        // Backfill (UTC today) is bound at run time: see `migrate`.
    ]),
    ("v4", &[
        r#"CREATE TABLE "artworks" ("illustration_id" TEXT PRIMARY KEY, "card_id" TEXT NOT NULL, "card_name" TEXT NOT NULL, "card_name_lower" TEXT NOT NULL, "artist" TEXT NOT NULL, "artist_lower" TEXT NOT NULL, "art_crop_url" TEXT NOT NULL, "colors" TEXT NOT NULL DEFAULT '[]', "set_code" TEXT)"#,
        r#"CREATE INDEX "artworks_on_artist" ON "artworks"("artist")"#,
    ]),
    ("v5", &[
        r#"CREATE TABLE "card_lists" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "name_lower" TEXT NOT NULL, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)"#,
        r#"CREATE TABLE "card_list_items" ("list_id" TEXT NOT NULL, "card_id" TEXT NOT NULL, "position" INTEGER NOT NULL, "added_at" TEXT NOT NULL, PRIMARY KEY ("list_id", "card_id"))"#,
        r#"CREATE INDEX "card_list_items_on_list_id" ON "card_list_items"("list_id")"#,
    ]),
    ("v6", &[
        r#"ALTER TABLE "cards" ADD COLUMN "oracle_id" TEXT"#,
        r#"CREATE INDEX "cards_on_oracle_id" ON "cards"("oracle_id")"#,
    ]),
    ("v7", &[
        r#"CREATE TABLE "sets" ("code" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "released_at" TEXT, "set_type" TEXT, "card_count" INTEGER, "icon_svg_uri" TEXT)"#,
    ]),
    ("v8", &[
        r#"CREATE TABLE "printings" ("printing_id" TEXT PRIMARY KEY, "oracle_id" TEXT, "set_code" TEXT NOT NULL, "set_name" TEXT NOT NULL, "collector_number" TEXT, "released_at" TEXT, "rarity" TEXT, "digital" INTEGER NOT NULL DEFAULT 0, "games" TEXT NOT NULL DEFAULT '[]')"#,
        r#"CREATE INDEX "printings_on_oracle_id" ON "printings"("oracle_id")"#,
    ]),
    ("v9", &[
        r#"ALTER TABLE "cards" ADD COLUMN "rarity" TEXT"#,
        r#"ALTER TABLE "cards" ADD COLUMN "cmc" DOUBLE"#,
    ]),
];

pub fn open(path: &Path) -> Result<Connection> {
    let mut c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_secs(5))?;
    c.pragma_update(None, "journal_mode", "WAL")?;
    c.pragma_update(None, "synchronous", "NORMAL")?;
    migrate(&mut c)?;
    Ok(c)
}

pub fn migrate(c: &mut Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")?;
    for (id, stmts) in MIGRATIONS {
        let done: bool = c.query_row("SELECT 1 FROM grdb_migrations WHERE identifier = ?", [id], |_| Ok(()))
            .optional()?.is_some();
        if done { continue; }
        let tx = c.transaction()?;
        for s in *stmts { tx.execute_batch(s)?; }
        if *id == "v3" {
            // Earlier of (date_added, today); NULL stays NULL.
            let t = today();
            tx.execute(
                "UPDATE cards SET first_seen = CASE WHEN date_added IS NULL THEN NULL WHEN date_added > ?1 THEN ?1 ELSE date_added END",
                [&t])?;
        }
        tx.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", [id])?;
        tx.commit()?;
    }
    Ok(())
}

pub fn count_cards(c: &Connection) -> Result<usize> {
    Ok(c.query_row("SELECT COUNT(*) FROM cards", [], |r| r.get::<_, i64>(0))? as usize)
}

pub fn meta(c: &Connection, key: &str) -> Result<Option<String>> {
    Ok(c.query_row("SELECT value FROM meta WHERE key = ?", [key], |r| r.get(0)).optional()?)
}

pub fn set_meta(c: &Connection, key: &str, value: &str) -> Result<()> {
    c.execute("INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])?;
    Ok(())
}

fn json<T: serde::Serialize>(v: &T) -> String { serde_json::to_string(v).unwrap_or_else(|_| "[]".into()) }

/// One transaction per call (callers batch ~1000 rows, like the Swift fetcher).
pub fn upsert_cards(c: &mut Connection, cards: &[Card]) -> Result<()> {
    // first_seen for brand-new rows: earlier of today and the card's own date; never updated.
    let today = today();
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached(r#"
            INSERT INTO cards (id, name, name_lower, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, oracle_id, set_code, set_name, date_added, first_seen, rarity, cmc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, name_lower = excluded.name_lower, mana_cost = excluded.mana_cost,
                type_line = excluded.type_line, oracle_text = excluded.oracle_text, power = excluded.power,
                toughness = excluded.toughness, colors = excluded.colors, scryfall_uri = excluded.scryfall_uri,
                oracle_id = excluded.oracle_id, set_code = excluded.set_code, set_name = excluded.set_name,
                rarity = excluded.rarity, cmc = excluded.cmc,
                date_added = min(COALESCE(date_added, excluded.date_added), excluded.date_added)"#)?;
        for k in cards {
            let first_seen = match &k.date_added { Some(d) if *d < today => d.as_str(), _ => today.as_str() };
            st.execute(params![
                k.id, k.name, lower(&k.name), k.mana_cost, k.type_line, k.oracle_text, k.power, k.toughness,
                json(&k.colors), None::<String>, k.scryfall_uri, k.oracle_id, k.set_code, k.set_name,
                k.date_added, first_seen, k.rarity, k.cmc,
            ])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn upsert_artworks(c: &mut Connection, arts: &[Artwork]) -> Result<()> {
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached(r#"
            INSERT INTO artworks (illustration_id, card_id, card_name, card_name_lower, artist, artist_lower, art_crop_url, colors, set_code)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(illustration_id) DO UPDATE SET
                card_id = excluded.card_id, card_name = excluded.card_name, card_name_lower = excluded.card_name_lower,
                artist = excluded.artist, artist_lower = excluded.artist_lower, art_crop_url = excluded.art_crop_url,
                colors = excluded.colors, set_code = excluded.set_code"#)?;
        for a in arts {
            st.execute(params![a.illustration_id, a.card_id, a.card_name, lower(&a.card_name), a.artist,
                lower(&a.artist), a.art_crop_url, json(&a.colors), a.set_code])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn upsert_sets(c: &mut Connection, sets: &[SetInfo]) -> Result<()> {
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached(r#"
            INSERT INTO sets (code, name, released_at, set_type, card_count, icon_svg_uri) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET name = excluded.name, released_at = excluded.released_at,
                set_type = excluded.set_type, card_count = excluded.card_count, icon_svg_uri = excluded.icon_svg_uri"#)?;
        for s in sets {
            st.execute(params![s.code, s.name, s.released_at, s.set_type, s.card_count, s.icon_svg_uri])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn upsert_printings(c: &mut Connection, ps: &[Printing]) -> Result<()> {
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached(r#"
            INSERT INTO printings (printing_id, oracle_id, set_code, set_name, collector_number, released_at, rarity, digital, games)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(printing_id) DO UPDATE SET oracle_id = excluded.oracle_id, set_code = excluded.set_code,
                set_name = excluded.set_name, collector_number = excluded.collector_number,
                released_at = excluded.released_at, rarity = excluded.rarity, digital = excluded.digital,
                games = excluded.games"#)?;
        for p in ps {
            st.execute(params![p.printing_id, p.oracle_id, p.set_code, p.set_name, p.collector_number,
                p.released_at, p.rarity, p.digital as i64, json(&p.games)])?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Batched `image_path` writes (one transaction for the whole slice).
pub fn set_image_paths(c: &mut Connection, ids: &[String]) -> Result<()> {
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached("UPDATE cards SET image_path = ? WHERE id = ?")?;
        for id in ids {
            st.execute(params![format!("images/{id}.jpg"), id])?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Deletes cards the latest COMPLETE ingest no longer produces; list entries on a stale
/// card are remapped to a surviving same-name card first. Returns rows removed.
pub fn reconcile_cards(c: &mut Connection, keep: &HashSet<String>) -> Result<usize> {
    let stale_ids: Vec<String> = {
        let mut st = c.prepare("SELECT id FROM cards")?;
        st.query_map([], |r| r.get::<_, String>(0))?.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter().filter(|id| !keep.contains(id)).collect()
    };
    if stale_ids.is_empty() { return Ok(0); }
    let stale: HashSet<&String> = stale_ids.iter().collect();
    let tx = c.transaction()?;
    for sid in &stale_ids {
        let lists: Vec<String> = tx.prepare("SELECT list_id FROM card_list_items WHERE card_id = ?")?
            .query_map([sid], |r| r.get(0))?.collect::<std::result::Result<_, _>>()?;
        if lists.is_empty() { continue; }
        let Some(name) = tx.query_row("SELECT name FROM cards WHERE id = ?", [sid], |r| r.get::<_, String>(0)).optional()? else { continue };
        let cands: Vec<String> = tx.prepare("SELECT id FROM cards WHERE name = ? AND id <> ? ORDER BY id")?
            .query_map([&name, sid], |r| r.get(0))?.collect::<std::result::Result<_, _>>()?;
        let Some(survivor) = cands.iter().find(|i| keep.contains(*i) && !stale.contains(i)) else { continue };
        for l in &lists {
            // OR IGNORE: survivor already in the list -> the stale entry is dropped below.
            tx.execute("UPDATE OR IGNORE card_list_items SET card_id = ? WHERE list_id = ? AND card_id = ?", [survivor, l, sid])?;
        }
    }
    for chunk in stale_ids.chunks(500) {
        let ph = vec!["?"; chunk.len()].join(",");
        tx.execute(&format!("DELETE FROM card_list_items WHERE card_id IN ({ph})"), rusqlite::params_from_iter(chunk))?;
        tx.execute(&format!("DELETE FROM cards WHERE id IN ({ph})"), rusqlite::params_from_iter(chunk))?;
    }
    tx.commit()?;
    Ok(stale_ids.len())
}
