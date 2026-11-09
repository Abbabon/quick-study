//! App-facing reads and card-list edits (what Swift's `CardStore` used to do through GRDB).
//! Pure `rusqlite` over a `&Connection`; the UniFFI object in `ffi.rs` only adds locking.
use crate::search::Hit;
use crate::{Result, lower, timestamp, today_minus_days};
use rusqlite::{Connection, OptionalExtension, params};

/// Decodes a JSON-text array column (`colors`, `games`); anything unreadable is empty.
fn arr(raw: Option<String>) -> Vec<String> {
    raw.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

/// Full `cards` row as the preview needs it (set code/name/date are intentionally not
/// loaded: the Swift detail model never filled them).
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct CardDetail {
    pub id: String,
    pub name: String,
    pub mana_cost: Option<String>,
    pub type_line: Option<String>,
    pub oracle_text: Option<String>,
    pub power: Option<String>,
    pub toughness: Option<String>,
    pub colors: Vec<String>,
    pub image_path: Option<String>,
    pub scryfall_uri: String,
    pub oracle_id: Option<String>,
    pub rarity: Option<String>,
    pub cmc: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PrintingRow {
    pub printing_id: String,
    pub oracle_id: Option<String>,
    pub set_code: String,
    pub set_name: String,
    pub collector_number: Option<String>,
    pub released_at: Option<String>,
    pub rarity: Option<String>,
    pub digital: bool,
    pub games: Vec<String>,
}

/// Recently Added row; `first_seen` is the stored "YYYY-MM-DD".
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct RecentCard {
    pub id: String,
    pub name: String,
    pub colors: Vec<String>,
    pub set_code: Option<String>,
    pub set_name: Option<String>,
    pub first_seen: String,
}

#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ArtworkRow {
    pub illustration_id: String,
    pub card_id: String,
    pub card_name: String,
    pub artist: String,
    pub art_crop_url: String,
    pub colors: Vec<String>,
    pub set_code: Option<String>,
}

/// A set for the start screen's "new sets" strip.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SetRow {
    pub code: String,
    pub name: String,
    /// "YYYY-MM-DD"
    pub released_at: String,
    pub set_type: Option<String>,
    pub icon_svg_uri: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ListSummary {
    pub id: String,
    pub name: String,
    pub created_at: String,
    pub updated_at: String,
    pub item_count: u32,
}

pub fn card(c: &Connection, id: &str) -> Result<Option<CardDetail>> {
    Ok(c.query_row(
        "SELECT id, name, mana_cost, type_line, oracle_text, power, toughness, colors, image_path, scryfall_uri, oracle_id, rarity, cmc FROM cards WHERE id = ?",
        [id],
        |r| Ok(CardDetail {
            id: r.get(0)?, name: r.get(1)?, mana_cost: r.get(2)?, type_line: r.get(3)?, oracle_text: r.get(4)?,
            power: r.get(5)?, toughness: r.get(6)?, colors: arr(r.get(7)?), image_path: r.get(8)?,
            scryfall_uri: r.get(9)?, oracle_id: r.get(10)?, rarity: r.get(11)?, cmc: r.get(12)?,
        }),
    ).optional()?)
}

/// All printings of a card, newest first.
pub fn printings(c: &Connection, oracle_id: &str) -> Result<Vec<PrintingRow>> {
    let mut st = c.prepare_cached(
        "SELECT printing_id, oracle_id, set_code, set_name, collector_number, released_at, rarity, digital, games
         FROM printings WHERE oracle_id = ? ORDER BY released_at DESC, set_code ASC")?;
    let rows = st.query_map([oracle_id], |r| Ok(PrintingRow {
        printing_id: r.get(0)?, oracle_id: r.get(1)?, set_code: r.get(2)?, set_name: r.get(3)?,
        collector_number: r.get(4)?, released_at: r.get(5)?, rarity: r.get(6)?,
        digital: r.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0, games: arr(r.get(8)?),
    }))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Cards first seen in our DB within `lookback_days`, newest first (see `first_seen` in db.rs).
pub fn recently_added(c: &Connection, lookback_days: u32, limit: u32) -> Result<Vec<RecentCard>> {
    let lower_bound = today_minus_days(lookback_days);
    let mut st = c.prepare_cached(
        "SELECT id, name, colors, set_code, set_name, first_seen FROM cards
         WHERE first_seen IS NOT NULL AND first_seen >= ? ORDER BY first_seen DESC, name ASC LIMIT ?")?;
    let rows = st.query_map(params![lower_bound, limit], |r| Ok(RecentCard {
        id: r.get(0)?, name: r.get(1)?, colors: arr(r.get(2)?), set_code: r.get(3)?, set_name: r.get(4)?,
        first_seen: r.get(5)?,
    }))?;
    // Unparseable dates are skipped, as the Swift loader did.
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?.into_iter().filter(|r| crate::valid_day(&r.first_seen)).collect())
}

pub fn artworks(c: &Connection) -> Result<Vec<ArtworkRow>> {
    let mut st = c.prepare_cached(
        "SELECT illustration_id, card_id, card_name, artist, art_crop_url, colors, set_code FROM artworks")?;
    let rows = st.query_map([], |r| Ok(ArtworkRow {
        illustration_id: r.get(0)?, card_id: r.get(1)?, card_name: r.get(2)?, artist: r.get(3)?,
        art_crop_url: r.get(4)?, colors: arr(r.get(5)?), set_code: r.get(6)?,
    }))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Most recently released main-line sets (expansions, core, masters, commander, draft
/// innovations, funny), newest first, including ones releasing within `preview_days` from now.
/// Empty until a `--printings` refresh has filled `sets`.
pub fn recent_sets(c: &Connection, limit: u32, preview_days: u32) -> Result<Vec<SetRow>> {
    let mut st = c.prepare_cached(
        "SELECT code, name, released_at, set_type, icon_svg_uri FROM sets
         WHERE released_at IS NOT NULL AND released_at <= ?
           AND set_type IN ('expansion','core','masters','commander','draft_innovation','funny')
         ORDER BY released_at DESC, name ASC LIMIT ?")?;
    let rows = st.query_map(params![crate::today_plus_days(preview_days), limit], |r| Ok(SetRow {
        code: r.get(0)?, name: r.get(1)?, released_at: r.get(2)?, set_type: r.get(3)?, icon_svg_uri: r.get(4)?,
    }))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// A uniformly random card id, `None` when the DB has no cards.
pub fn random_card_id(c: &Connection) -> Result<Option<String>> {
    Ok(c.query_row("SELECT id FROM cards ORDER BY RANDOM() LIMIT 1", [], |r| r.get(0)).optional()?)
}

pub fn count(c: &Connection, table: &str) -> Result<u32> {
    let sql = match table {
        "cards" => "SELECT COUNT(*) FROM cards",
        "artworks" => "SELECT COUNT(*) FROM artworks",
        "sets" => "SELECT COUNT(*) FROM sets",
        "printings" => "SELECT COUNT(*) FROM printings",
        _ => return Err(format!("unknown table {table}").into()),
    };
    Ok(c.query_row(sql, [], |r| r.get::<_, i64>(0))? as u32)
}

// ---------- card lists ----------

pub fn create_list(c: &Connection, name: &str) -> Result<ListSummary> {
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let now = timestamp();
    c.execute("INSERT INTO card_lists (id, name, name_lower, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        params![id, name, lower(name), now, now])?;
    Ok(ListSummary { id, name: name.into(), created_at: now.clone(), updated_at: now, item_count: 0 })
}

/// All lists, oldest first, each with its card count.
pub fn load_lists(c: &Connection) -> Result<Vec<ListSummary>> {
    let mut st = c.prepare_cached(
        "SELECT l.id, l.name, l.created_at, l.updated_at,
                (SELECT COUNT(*) FROM card_list_items i WHERE i.list_id = l.id)
         FROM card_lists l ORDER BY l.created_at ASC, l.name ASC")?;
    let rows = st.query_map([], |r| Ok(ListSummary {
        id: r.get(0)?, name: r.get(1)?, created_at: r.get(2)?, updated_at: r.get(3)?,
        item_count: r.get::<_, i64>(4)? as u32,
    }))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn rename_list(c: &Connection, id: &str, name: &str) -> Result<()> {
    c.execute("UPDATE card_lists SET name = ?, name_lower = ?, updated_at = ? WHERE id = ?",
        params![name, lower(name), timestamp(), id])?;
    Ok(())
}

/// Deletes a list and its membership rows in one transaction (`foreign_keys` stays off).
pub fn delete_list(c: &mut Connection, id: &str) -> Result<()> {
    let tx = c.transaction()?;
    tx.execute("DELETE FROM card_list_items WHERE list_id = ?", [id])?;
    tx.execute("DELETE FROM card_lists WHERE id = ?", [id])?;
    Ok(tx.commit()?)
}

/// Appends a card; a no-op if it is already a member. Bumps the list's `updated_at`.
pub fn add_card(c: &mut Connection, card_id: &str, list_id: &str) -> Result<()> {
    let tx = c.transaction()?;
    let next: i64 = tx.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM card_list_items WHERE list_id = ?", [list_id], |r| r.get(0))?;
    tx.execute("INSERT INTO card_list_items (list_id, card_id, position, added_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(list_id, card_id) DO NOTHING", params![list_id, card_id, next, timestamp()])?;
    tx.execute("UPDATE card_lists SET updated_at = ? WHERE id = ?", params![timestamp(), list_id])?;
    Ok(tx.commit()?)
}

pub fn remove_card(c: &mut Connection, card_id: &str, list_id: &str) -> Result<()> {
    let tx = c.transaction()?;
    tx.execute("DELETE FROM card_list_items WHERE list_id = ? AND card_id = ?", [list_id, card_id])?;
    tx.execute("UPDATE card_lists SET updated_at = ? WHERE id = ?", params![timestamp(), list_id])?;
    Ok(tx.commit()?)
}

/// Cards in a list ordered by `position`; items whose card is gone are skipped. `rarity` is
/// left empty, matching what the Swift loader returned.
pub fn list_items(c: &Connection, list_id: &str) -> Result<Vec<Hit>> {
    let mut st = c.prepare_cached(
        "SELECT c.id, c.name, c.colors, c.set_code, c.set_name FROM card_list_items i
         JOIN cards c ON c.id = i.card_id WHERE i.list_id = ? ORDER BY i.position ASC")?;
    let rows = st.query_map([list_id], |r| Ok(Hit {
        id: r.get(0)?, name: r.get(1)?, colors: arr(r.get(2)?), set_code: r.get(3)?, set_name: r.get(4)?, rarity: None,
    }))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Rewrites positions to match `ordered`; ids not in the list are ignored.
pub fn set_list_order(c: &mut Connection, list_id: &str, ordered: &[String]) -> Result<()> {
    let tx = c.transaction()?;
    {
        let mut st = tx.prepare_cached("UPDATE card_list_items SET position = ? WHERE list_id = ? AND card_id = ?")?;
        for (i, id) in ordered.iter().enumerate() { st.execute(params![i as i64, list_id, id])?; }
    }
    tx.execute("UPDATE card_lists SET updated_at = ? WHERE id = ?", params![timestamp(), list_id])?;
    Ok(tx.commit()?)
}
