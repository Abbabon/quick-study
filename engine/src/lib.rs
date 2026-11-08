//! QuickStudy data engine. Stage 1: everything the `mtg-fetcher` binary needs.
pub mod db;
pub mod fetch;
pub mod images;
pub mod paths;
pub mod progress;
pub mod scryfall;

pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T> = std::result::Result<T, Error>;

/// Swift's `String.lowercased()`: per-scalar mapping, no context (so Σ is always σ).
pub fn lower(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// UTC "YYYY-MM-DD".
pub fn today() -> String {
    time::OffsetDateTime::now_utc()
        .format(time::macros::format_description!("[year]-[month]-[day]"))
        .unwrap()
}

/// UTC ISO-8601 at second precision, e.g. `2026-11-08T11:41:05Z`.
pub fn iso_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(time::macros::format_description!(
            "[year]-[month]-[day]T[hour]:[minute]:[second]Z"
        ))
        .unwrap()
}
