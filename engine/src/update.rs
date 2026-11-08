//! Scryfall "new cards" check: compares the live `oracle_cards.updated_at` from the bulk-data
//! index against the `bulk_updated_at` we last ingested. No blob download, no card counting.
use crate::{Result, scryfall::Client};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

/// Scryfall stamps are ISO-8601 with an offset, fractional seconds optional.
pub fn parse_stamp(s: &str) -> Option<OffsetDateTime> { OffsetDateTime::parse(s, &Rfc3339).ok() }

pub fn stamp_unix_ms(s: &str) -> Option<i64> {
    parse_stamp(s).map(|d| (d.unix_timestamp_nanos() / 1_000_000) as i64)
}

/// True when the remote bulk is strictly newer than our ingested baseline. No baseline or an
/// unparseable stamp is false (first run is handled by the download prompt).
pub fn is_newer_than_ingested(remote: &str, ingested: Option<&str>) -> bool {
    match (parse_stamp(remote), ingested.and_then(parse_stamp)) {
        (Some(r), Some(i)) => r > i,
        _ => false,
    }
}

/// The live `updated_at` of a bulk type (e.g. `oracle_cards`).
pub async fn latest_stamp(kind: &str) -> Result<String> { Ok(Client::new()?.bulk_info(kind).await?.updated_at) }

#[cfg(test)]
mod tests {
    use super::*;
    const OLDER: &str = "2024-06-01T09:00:00.000+00:00";
    const NEWER: &str = "2024-06-10T09:00:31.443+00:00";

    #[test]
    fn newer_than_ingested() {
        assert!(is_newer_than_ingested(NEWER, Some(OLDER)));
        assert!(!is_newer_than_ingested(NEWER, Some(NEWER)));
        assert!(!is_newer_than_ingested(OLDER, Some(NEWER)));
        assert!(!is_newer_than_ingested(NEWER, None));
        assert!(!is_newer_than_ingested("nope", Some(OLDER)));
        assert!(!is_newer_than_ingested(NEWER, Some("nope")));
    }

    #[test]
    fn parses_with_and_without_fraction() {
        assert!(parse_stamp("2024-06-10T09:00:31+00:00").is_some());
        assert!(parse_stamp("2024-06-10T09:00:31Z").is_some());
        assert_eq!(stamp_unix_ms(NEWER).unwrap() % 1000, 443);
        assert!(parse_stamp("not-a-date").is_none());
    }
}
