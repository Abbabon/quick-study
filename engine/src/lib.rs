//! QuickStudy data engine: schema + migrations, fetcher, search, app reads, card lists, update checks.
pub mod db;
pub mod fetch;
pub mod images;
pub mod paths;
pub mod progress;
pub mod query;
pub mod scryfall;
pub mod search;
pub mod store;
pub mod update;

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

/// UTC "YYYY-MM-DD", `days` days (24 h each) before now.
pub fn today_minus_days(days: u32) -> String {
    (time::OffsetDateTime::now_utc() - time::Duration::days(days as i64))
        .format(time::macros::format_description!("[year]-[month]-[day]"))
        .unwrap()
}

/// Is `s` a well-formed "YYYY-MM-DD" day?
pub fn valid_day(s: &str) -> bool {
    time::Date::parse(s, time::macros::format_description!("[year]-[month]-[day]")).is_ok()
}

/// UTC "yyyy-MM-dd HH:mm:ss": the list created/updated stamp.
pub fn timestamp() -> String {
    time::OffsetDateTime::now_utc()
        .format(time::macros::format_description!("[year]-[month]-[day] [hour]:[minute]:[second]"))
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

#[cfg(feature = "ffi")]
mod ffi;
#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
