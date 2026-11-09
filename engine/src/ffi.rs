//! UniFFI surface for the Swift app: the search index, and `Database` (reads + card lists).
use crate::search::{DEFAULT_LIMIT, Hit, Index};
use crate::store::{self, ArtworkRow, CardDetail, ListSummary, PrintingRow, RecentCard, SetRow};
use crate::{db, update};
use rusqlite::{Connection, OpenFlags};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, uniffi::Error)]
pub enum EngineError {
    Index(String),
    Db(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (Self::Index(m) | Self::Db(m)) = self;
        write!(f, "{m}")
    }
}

impl std::error::Error for EngineError {}

#[derive(uniffi::Record)]
pub struct SearchResult {
    /// Top 20, best first.
    pub hits: Vec<Hit>,
    /// Matches before the limit.
    pub total: u32,
}

/// The in-memory search index. Immutable once built; build a new one after a refresh.
#[derive(uniffi::Object)]
pub struct SearchIndex(Index);

#[uniffi::export]
impl SearchIndex {
    /// Reads cards/printings from the DB at `db_path` (read-only) and builds the index.
    /// Slow (~100s of ms): call off the main thread.
    #[uniffi::constructor]
    pub fn open(db_path: String) -> Result<Arc<Self>, EngineError> {
        Index::open(Path::new(&db_path)).map(|i| Arc::new(Self(i))).map_err(|e| EngineError::Index(e.to_string()))
    }

    #[uniffi::constructor]
    pub fn empty() -> Arc<Self> { Arc::new(Self(Index::empty())) }

    pub fn card_count(&self) -> u32 { self.0.len() as u32 }

    /// Parses the search-box string (name + inline filters) and ranks.
    pub fn search(&self, query: String) -> SearchResult {
        let r = self.0.search(&query, DEFAULT_LIMIT);
        SearchResult { hits: r.hits, total: r.total as u32 }
    }

    /// Plain name ranking with no filter syntax and a caller-chosen limit (autocomplete).
    pub fn search_name(&self, name: String, limit: u32) -> Vec<Hit> {
        self.0.search_counted(&name, &[], limit as usize).hits
    }
}

fn db_err(e: crate::Error) -> EngineError { EngineError::Db(e.to_string()) }

/// The app's database: opens (and migrates) the SQLite file, then serves reads and list edits.
/// Two connections in WAL mode (alongside the separate fetcher process): reads never
/// wait behind a list write. Every call blocks, so call it off the main thread unless it is a
/// single tiny list edit.
#[derive(uniffi::Object)]
pub struct Database {
    write: Mutex<Connection>,
    read: Mutex<Connection>,
}

fn lock(m: &Mutex<Connection>) -> MutexGuard<'_, Connection> { m.lock().unwrap_or_else(|p| p.into_inner()) }

#[uniffi::export]
impl Database {
    /// Creates the file if needed and applies any pending migrations.
    #[uniffi::constructor]
    pub fn open(db_path: String) -> Result<Arc<Self>, EngineError> {
        let write = db::open(Path::new(&db_path)).map_err(db_err)?;
        let read = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI)
            .and_then(|c| c.busy_timeout(std::time::Duration::from_secs(5)).map(|_| c))
            .map_err(|e| EngineError::Db(e.to_string()))?;
        Ok(Arc::new(Self { write: Mutex::new(write), read: Mutex::new(read) }))
    }

    pub fn card_count(&self) -> Result<u32, EngineError> { store::count(&lock(&self.read), "cards").map_err(db_err) }
    pub fn artwork_count(&self) -> Result<u32, EngineError> { store::count(&lock(&self.read), "artworks").map_err(db_err) }
    pub fn meta(&self, key: String) -> Result<Option<String>, EngineError> { db::meta(&lock(&self.read), &key).map_err(db_err) }

    pub fn card(&self, id: String) -> Result<Option<CardDetail>, EngineError> { store::card(&lock(&self.read), &id).map_err(db_err) }
    pub fn printings(&self, oracle_id: String) -> Result<Vec<PrintingRow>, EngineError> { store::printings(&lock(&self.read), &oracle_id).map_err(db_err) }
    pub fn recently_added(&self, lookback_days: u32, limit: u32) -> Result<Vec<RecentCard>, EngineError> {
        store::recently_added(&lock(&self.read), lookback_days, limit).map_err(db_err)
    }
    pub fn recent_sets(&self, limit: u32, preview_days: u32) -> Result<Vec<SetRow>, EngineError> {
        store::recent_sets(&lock(&self.read), limit, preview_days).map_err(db_err)
    }
    pub fn sets_by_release(&self, limit: u32, preview_days: u32) -> Result<Vec<SetRow>, EngineError> {
        store::sets_by_release(&lock(&self.read), limit, preview_days).map_err(db_err)
    }
    pub fn random_card_id(&self) -> Result<Option<String>, EngineError> { store::random_card_id(&lock(&self.read)).map_err(db_err) }
    pub fn artworks(&self) -> Result<Vec<ArtworkRow>, EngineError> { store::artworks(&lock(&self.read)).map_err(db_err) }

    pub fn load_lists(&self) -> Result<Vec<ListSummary>, EngineError> { store::load_lists(&lock(&self.read)).map_err(db_err) }
    pub fn list_items(&self, list_id: String) -> Result<Vec<Hit>, EngineError> { store::list_items(&lock(&self.read), &list_id).map_err(db_err) }
    pub fn create_list(&self, name: String) -> Result<ListSummary, EngineError> { store::create_list(&lock(&self.write), &name).map_err(db_err) }
    pub fn rename_list(&self, id: String, name: String) -> Result<(), EngineError> { store::rename_list(&lock(&self.write), &id, &name).map_err(db_err) }
    pub fn delete_list(&self, id: String) -> Result<(), EngineError> { store::delete_list(&mut lock(&self.write), &id).map_err(db_err) }
    pub fn add_card(&self, card_id: String, list_id: String) -> Result<(), EngineError> { store::add_card(&mut lock(&self.write), &card_id, &list_id).map_err(db_err) }
    pub fn remove_card(&self, card_id: String, list_id: String) -> Result<(), EngineError> { store::remove_card(&mut lock(&self.write), &card_id, &list_id).map_err(db_err) }
    pub fn set_list_order(&self, list_id: String, ordered_card_ids: Vec<String>) -> Result<(), EngineError> {
        store::set_list_order(&mut lock(&self.write), &list_id, &ordered_card_ids).map_err(db_err)
    }
}

/// Live `updated_at` of Scryfall's `oracle_cards` bulk file, or `None` on any network/parse error.
#[uniffi::export(async_runtime = "tokio")]
pub async fn latest_oracle_stamp() -> Option<String> { update::latest_stamp("oracle_cards").await.ok() }

/// True when `remote` is strictly newer than the ingested `bulk_updated_at` baseline.
#[uniffi::export]
pub fn is_newer_than_ingested(remote: String, ingested: Option<String>) -> bool {
    update::is_newer_than_ingested(&remote, ingested.as_deref())
}

/// Scryfall stamp -> unix milliseconds (`None` if unparseable).
#[uniffi::export]
pub fn stamp_unix_ms(stamp: String) -> Option<i64> { update::stamp_unix_ms(&stamp) }
