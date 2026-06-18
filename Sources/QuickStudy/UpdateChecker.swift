import Foundation
import Shared

/// Decides whether Scryfall has card data newer than what we last ingested.
///
/// Client-direct: we read `oracle_cards.updated_at` from Scryfall's small, CDN-cached
/// bulk-data index and compare it against the `bulk_updated_at` meta value the fetcher
/// wrote after the last successful ingest. No server, no card counting.
enum UpdateChecker {
    /// Returns the live `oracle_cards.updated_at`, or `nil` on any network/parse error
    /// (callers treat `nil` as "leave current state unchanged").
    static func fetchLatestStamp(type: String = "oracle_cards") async -> String? {
        do { return try await ScryfallBulk.info(type: type).updated_at }
        catch { return nil }
    }

    /// True when Scryfall's bulk is strictly newer than our ingested baseline.
    /// Unlike `shouldPrompt`, this ignores the dismissed stamp: a newer bulk should
    /// always trigger a silent ingest so search stays current; the dismissed stamp
    /// only suppresses the user-facing dot/notification afterward.
    static func isNewerThanIngested(remote: String, ingested: String?) -> Bool {
        guard let remoteDate = parse(remote) else { return false }
        guard let ingestedDate = ingested.flatMap(parse) else { return false }
        return remoteDate > ingestedDate
    }

    /// Pure decision used by both the live check and the unit tests.
    ///
    /// Prompt only when we have a baseline (`ingested`), the remote stamp is strictly
    /// newer, and the user hasn't already dismissed that same (or a newer) stamp.
    static func shouldPrompt(remote: String, ingested: String?, dismissed: String?) -> Bool {
        guard let remoteDate = parse(remote) else { return false }
        guard let ingestedDate = ingested.flatMap(parse) else { return false }
        guard remoteDate > ingestedDate else { return false }
        if let dismissedDate = dismissed.flatMap(parse), dismissedDate >= remoteDate { return false }
        return true
    }

    /// Scryfall stamps are ISO-8601 with a timezone offset; fractional seconds are
    /// usually present but not guaranteed, so try both shapes.
    static func parse(_ stamp: String) -> Date? {
        if let date = isoWithFraction.date(from: stamp) { return date }
        return isoPlain.date(from: stamp)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
