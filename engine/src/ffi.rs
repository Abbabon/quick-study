//! UniFFI surface for the Swift app: build the search index from the SQLite DB, search it.
use crate::search::{DEFAULT_LIMIT, Hit, Index};
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, uniffi::Error)]
pub enum EngineError {
    Index(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Index(m) = self;
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
}
